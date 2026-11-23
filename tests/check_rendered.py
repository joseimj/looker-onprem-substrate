#!/usr/bin/env python3
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Checks rendered manifests against the Substrate v1.0.0 API definitions.

  * actor-template.yaml and egress-policy.yaml are walked against the messages
    in api/ateapi/v1/ateapi.proto (field names, nesting, lists vs scalars).
  * worker-pool.yaml is walked against the WorkerPool CRD's OpenAPI schema.
  * Plain Kubernetes objects get cross-reference checks (labels, volumes,
    services, secret keys) since no kubectl or API server is available here.
"""
import argparse
import re
import sys
import pathlib
import yaml

errors = []
WORKLOADS = ("Deployment", "StatefulSet", "DaemonSet")


def err(where, message):
  errors.append(f"{where}: {message}")


# ---- proto ---------------------------------------------------------------
def parse_proto(text):
  messages, enums, stack = {}, {}, []
  field_re = re.compile(
      r"^\s*(repeated\s+|optional\s+)?(map<\s*\w+\s*,\s*[\w.]+\s*>|[\w.]+)\s+(\w+)\s*=\s*\d+")
  for raw in text.splitlines():
    line = raw.split("//")[0].rstrip()
    if not line.strip():
      continue
    m = re.match(r"^\s*(message|enum)\s+(\w+)\s*\{", line)
    if m:
      kind, name = m.groups()
      stack.append((kind, name))
      (messages if kind == "message" else enums).setdefault(name, {})
      if line.rstrip().endswith("}"):
        stack.pop()
      continue
    if re.match(r"^\s*oneof\s+\w+\s*\{", line):
      stack.append(("oneof", None))
      continue
    if line.strip() == "}":
      if stack:
        stack.pop()
      continue
    owner = next((n for k, n in reversed(stack) if k in ("message", "enum")), None)
    kind = next((k for k, n in reversed(stack) if k in ("message", "enum")), None)
    if owner is None:
      continue
    if kind == "enum":
      m = re.match(r"^\s*(\w+)\s*=\s*-?\d+", line)
      if m:
        enums[owner][m.group(1)] = True
      continue
    m = field_re.match(line)
    if m and m.group(2) not in ("option", "reserved", "returns", "rpc"):
      label, ftype, fname = m.group(1) or "", m.group(2), m.group(3)
      messages[owner][fname] = (ftype, label.strip() == "repeated")
  return messages, enums


def camel(snake):
  head, *rest = snake.split("_")
  return head + "".join(p.capitalize() for p in rest)


SCALARS = {"string": str, "bool": bool, "int32": int, "int64": int, "uint32": int,
           "uint64": int, "double": (int, float), "float": (int, float), "bytes": str}


def check_message(value, message, messages, enums, where):
  fields = messages.get(message)
  if fields is None:
    err(where, f"unknown message {message}")
    return
  if not isinstance(value, dict):
    err(where, f"expected a mapping for {message}, got {type(value).__name__}")
    return
  by_json = {}
  for name, spec in fields.items():
    by_json[name] = spec
    by_json[camel(name)] = spec
  for key, item in value.items():
    if key not in by_json:
      err(where, f"'{key}' is not a field of {message} (has: {sorted(camel(f) for f in fields)})")
      continue
    ftype, repeated = by_json[key]
    here = f"{where}.{key}"
    if ftype.startswith("map<"):
      if not isinstance(item, dict):
        err(here, "expected a mapping")
      continue
    if repeated:
      if not isinstance(item, list):
        err(here, f"expected a list of {ftype}")
        continue
      for index, element in enumerate(item):
        check_value(element, ftype, messages, enums, f"{here}[{index}]")
    else:
      check_value(item, ftype, messages, enums, here)


def check_value(item, ftype, messages, enums, where):
  short = ftype.split(".")[-1]
  if ftype in SCALARS:
    if not isinstance(item, SCALARS[ftype]) or (ftype != "bool" and isinstance(item, bool)):
      err(where, f"expected {ftype}, got {type(item).__name__} ({item!r})")
  elif short in enums:
    if item not in enums[short]:
      err(where, f"{item!r} is not a value of enum {short} ({sorted(enums[short])})")
  elif short in messages:
    check_message(item, short, messages, enums, where)
  elif ftype.startswith("google.protobuf."):
    pass
  else:
    err(where, f"unknown type {ftype}")


# ---- CRD openAPI ---------------------------------------------------------
def check_schema(value, schema, where):
  kind = schema.get("type")
  if kind == "object":
    if not isinstance(value, dict):
      err(where, "expected an object")
      return
    properties = schema.get("properties")
    for required in schema.get("required", []):
      if required not in value:
        err(where, f"missing required field '{required}'")
    if properties is None:
      return  # free-form (additionalProperties / preserve-unknown-fields)
    for key, item in value.items():
      if key not in properties:
        if schema.get("additionalProperties") or schema.get("x-kubernetes-preserve-unknown-fields"):
          continue
        err(where, f"'{key}' is not in the CRD schema (has: {sorted(properties)})")
        continue
      check_schema(item, properties[key], f"{where}.{key}")
  elif kind == "array":
    if not isinstance(value, list):
      err(where, "expected a list")
      return
    for index, item in enumerate(value):
      check_schema(item, schema.get("items", {}), f"{where}[{index}]")
  elif kind == "string":
    if not isinstance(value, str):
      err(where, f"expected a string, got {type(value).__name__} ({value!r})")
  elif kind == "integer":
    if not isinstance(value, int) or isinstance(value, bool):
      err(where, f"expected an integer, got {value!r}")
  elif kind == "boolean":
    if not isinstance(value, bool):
      err(where, f"expected a boolean, got {value!r}")
  if "enum" in schema and value not in schema["enum"]:
    err(where, f"{value!r} not in {schema['enum']}")


# ---- generic Kubernetes cross checks -------------------------------------
def pod_template(doc):
  return doc.get("spec", {}).get("template", {})


def check_workloads(docs, where):
  services = {(d["metadata"].get("namespace"), d["metadata"]["name"]): d for d in docs if d.get("kind") == "Service"}
  workloads = [d for d in docs if d.get("kind") in WORKLOADS]
  for doc in docs:
    for field in ("apiVersion", "kind", "metadata"):
      if field not in doc:
        err(where, f"document without {field}: {str(doc)[:80]}")
  for w in workloads:
    name = f"{where}:{w['kind']}/{w['metadata']['name']}"
    template = pod_template(w)
    labels = template.get("metadata", {}).get("labels", {})
    selector = w["spec"].get("selector", {}).get("matchLabels", {})
    if not selector or any(labels.get(k) != v for k, v in selector.items()):
      err(name, f"selector {selector} does not match pod labels {labels}")
    spec = template.get("spec", {})
    volumes = {v["name"] for v in spec.get("volumes", [])}
    volumes |= {v["metadata"]["name"] for v in w["spec"].get("volumeClaimTemplates", [])}
    used = set()
    for container in spec.get("containers", []) + spec.get("initContainers", []):
      if "image" not in container or not container["image"]:
        err(name, f"container {container.get('name')} has no image")
      for mount in container.get("volumeMounts", []):
        used.add(mount["name"])
        if mount["name"] not in volumes:
          err(name, f"volumeMount '{mount['name']}' has no volume")
      for env in container.get("env", []):
        if "value" in env and not isinstance(env["value"], str):
          err(name, f"env {env['name']} value must be a string, got {env['value']!r}")
        if "value" in env and "valueFrom" in env:
          err(name, f"env {env['name']} has both value and valueFrom")
    for volume in volumes - used:
      err(name, f"volume '{volume}' is never mounted")
    for tol in spec.get("tolerations") or []:
      if tol.get("key") == "ate.dev/sandboxClass":
        err(name, "tolerates ate.dev/sandboxClass, which is reserved for sandbox worker pods")
    if w["kind"] == "StatefulSet":
      key = (w["metadata"].get("namespace"), w["spec"].get("serviceName"))
      if key not in services:
        err(name, f"serviceName {key[1]} has no Service")
  for (namespace, sname), service in services.items():
    selector = service["spec"].get("selector", {})
    matched = [w for w in workloads if w["metadata"].get("namespace") == namespace and all(
        pod_template(w).get("metadata", {}).get("labels", {}).get(k) == v for k, v in selector.items())]
    if not matched:
      err(f"{where}:Service/{sname}", f"selector {selector} matches no workload")
      continue
    port_names = {p.get("name") for w in matched for c in pod_template(w)["spec"]["containers"] for p in c.get("ports", [])}
    for port in service["spec"]["ports"]:
      target = port.get("targetPort")
      if isinstance(target, str) and target not in port_names:
        err(f"{where}:Service/{sname}", f"targetPort '{target}' is not a container port name ({port_names})")
  for doc in docs:
    if doc.get("kind") == "Ingress":
      namespace = doc["metadata"].get("namespace")
      for rule in doc["spec"].get("rules", []):
        for path in rule["http"]["paths"]:
          backend = path["backend"]["service"]
          service = services.get((namespace, backend["name"]))
          if service is None:
            err(f"{where}:Ingress/{doc['metadata']['name']}", f"backend service {backend['name']} not found")
          elif backend["port"].get("name") not in {p.get("name") for p in service["spec"]["ports"]}:
            err(f"{where}:Ingress/{doc['metadata']['name']}", f"backend port {backend['port']} not on service {backend['name']}")


# ---- Pod Security, and what the kit asks of its own pods on top ------------
ALLOWED_VOLUMES = {"configMap", "csi", "downwardAPI", "emptyDir", "ephemeral",
                   "persistentVolumeClaim", "projected", "secret"}
BASELINE_CAPABILITIES = {"AUDIT_WRITE", "CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL",
                         "MKNOD", "NET_BIND_SERVICE", "SETFCAP", "SETGID", "SETPCAP",
                         "SETUID", "SYS_CHROOT"}
LEVELS = ("privileged", "baseline", "restricted")
POD_SECURITY_LABELS = tuple(f"pod-security.kubernetes.io/{mode}" for mode in ("enforce", "audit", "warn"))

# Where a container of the kit does without something every other one has,
# and why. Keys are (workload, container, rule); a container of None means the
# pod as a whole.
EXCEPTIONS = {
    ("looker", "looker", "seccomp"):
        "no profile unless LOOKER_SECCOMP_PROFILE names one: Chromium's own sandbox "
        "needs user namespaces, which RuntimeDefault forbids",
    ("looker", "looker", "readOnlyRootFilesystem"):
        "Looker writes under its home directory /app",
    ("looker", "own-shared-files", "runAsNonRoot"):
        "the optional init container changes the owner of an NFS export, which takes root",
    ("looker", "own-shared-files", "capabilities"):
        "the same init container: CHOWN and nothing else",
    ("vertex-token-refresher", None, "automountServiceAccountToken"):
        "it writes the token into a Secret through the Kubernetes API",
}
# Egress rules that name no destination, per policy, and why they may.
OPEN_EGRESS = {
    "looker": "LOOKER_EGRESS_CIDRS contains 0.0.0.0/0 (the default): anywhere, every port",
    "vertex-token-refresher": "TCP 443 and 6443: Google's token service and the Kubernetes API, "
                              "whose address only the cluster knows",
}
DNS_PORTS = {("UDP", 53), ("TCP", 53)}


def containers_of(spec):
  return [(c, True) for c in spec.get("initContainers") or []] + \
         [(c, False) for c in spec.get("containers") or []]


def pod_security_violations(spec):
  """What stands between a pod and the baseline and the restricted level.

  The checks of the Pod Security Standards, for the fields these manifests use.
  """
  baseline, restricted = [], []
  pod_sc = spec.get("securityContext") or {}
  for field in ("hostNetwork", "hostPID", "hostIPC"):
    if spec.get(field):
      baseline.append(f"{field} is set")
  for volume in spec.get("volumes") or []:
    kinds = set(volume) - {"name"}
    if "hostPath" in kinds:
      baseline.append(f"volume {volume['name']} is a hostPath")
    if not kinds <= ALLOWED_VOLUMES:
      restricted.append(f"volume {volume['name']} is of type {sorted(kinds - ALLOWED_VOLUMES)}")
  pod_seccomp = (pod_sc.get("seccompProfile") or {}).get("type")
  for container, _ in containers_of(spec):
    name = container["name"]
    sc = container.get("securityContext") or {}
    capabilities = sc.get("capabilities") or {}
    added = set(capabilities.get("add") or [])
    seccomp = (sc.get("seccompProfile") or {}).get("type") or pod_seccomp
    if sc.get("privileged"):
      baseline.append(f"{name}: privileged")
    if added - BASELINE_CAPABILITIES:
      baseline.append(f"{name}: adds capabilities {sorted(added - BASELINE_CAPABILITIES)}")
    if any(port.get("hostPort") for port in container.get("ports") or []):
      baseline.append(f"{name}: uses a hostPort")
    if seccomp == "Unconfined":
      baseline.append(f"{name}: seccomp profile Unconfined")
    if sc.get("allowPrivilegeEscalation") is not False:
      restricted.append(f"{name}: allowPrivilegeEscalation is not false")
    if "ALL" not in (capabilities.get("drop") or []):
      restricted.append(f"{name}: capabilities.drop lacks ALL")
    if added - {"NET_BIND_SERVICE"}:
      restricted.append(f"{name}: adds capabilities {sorted(added)}")
    if sc.get("runAsNonRoot", pod_sc.get("runAsNonRoot")) is not True:
      restricted.append(f"{name}: runAsNonRoot is not true")
    if sc.get("runAsUser", pod_sc.get("runAsUser")) == 0:
      restricted.append(f"{name}: runs as user 0")
    if seccomp not in ("RuntimeDefault", "Localhost"):
      restricted.append(f"{name}: no seccomp profile")
  return baseline, restricted


def check_namespaces(docs):
  """Every namespace is rendered with its Pod Security level; returns name -> level."""
  levels = {}
  pools = {d["metadata"].get("namespace") for _, d in docs if d.get("kind") == "WorkerPool"}
  workloads = {d["metadata"].get("namespace") for _, d in docs if d.get("kind") in WORKLOADS}
  for where, doc in docs:
    if doc.get("kind") != "Namespace":
      continue
    name = doc["metadata"]["name"]
    labels = doc["metadata"].get("labels") or {}
    for label in POD_SECURITY_LABELS:
      if labels.get(label) not in LEVELS:
        err(f"{where}:Namespace/{name}", f"label {label} is {labels.get(label)!r}, not one of {LEVELS}")
    level = labels.get(POD_SECURITY_LABELS[0])
    levels[name] = level
    if level == "privileged":
      # Substrate's workers need it. Nothing else may share their namespace.
      if name not in pools:
        err(f"{where}:Namespace/{name}", "enforces 'privileged' without holding a WorkerPool")
      if name in workloads:
        err(f"{where}:Namespace/{name}", "holds the kit's own pods beside Substrate's privileged workers")
  for namespace in sorted(n for n in pools | workloads if n not in levels):
    err("namespaces", f"'{namespace}' is used but no Namespace with a Pod Security level is rendered for it")
  return levels


def check_pod_security(docs, levels):
  """Each pod fits what its namespace enforces, and the kit's own rules on top."""
  for where, doc in docs:
    if doc.get("kind") not in WORKLOADS:
      continue
    workload = doc["metadata"]["name"]
    name = f"{where}:{doc['kind']}/{workload}"
    spec = pod_template(doc).get("spec", {})
    pod_sc = spec.get("securityContext") or {}

    def excused(container, rule):
      return (workload, container, rule) in EXCEPTIONS

    baseline, restricted = pod_security_violations(spec)
    level = levels.get(doc["metadata"].get("namespace"))
    refused = {"baseline": baseline, "restricted": baseline + restricted}.get(level, [])
    for violation in refused:
      err(name, f"its namespace enforces '{level}', which refuses: {violation}")

    if spec.get("automountServiceAccountToken") is not False and not excused(None, "automountServiceAccountToken"):
      err(name, "automountServiceAccountToken is not false")
    pod_seccomp = (pod_sc.get("seccompProfile") or {}).get("type")
    for container, is_init in containers_of(spec):
      cname = container["name"]
      here = f"{name}/{cname}"
      sc = container.get("securityContext") or {}
      capabilities = sc.get("capabilities") or {}
      added = sorted(capabilities.get("add") or [])
      if sc.get("allowPrivilegeEscalation") is not False:
        err(here, "allowPrivilegeEscalation is not false")
      if "ALL" not in (capabilities.get("drop") or []):
        err(here, "capabilities.drop lacks ALL")
      if added and not (excused(cname, "capabilities") and added == ["CHOWN"]):
        err(here, f"adds capabilities {added}")
      if sc.get("runAsNonRoot", pod_sc.get("runAsNonRoot")) is not True and not excused(cname, "runAsNonRoot"):
        err(here, "runAsNonRoot is not true")
      seccomp = (sc.get("seccompProfile") or {}).get("type") or pod_seccomp
      if seccomp == "Unconfined":
        err(here, "seccomp profile Unconfined")
      elif seccomp is None and not excused(cname, "seccomp"):
        err(here, "no seccomp profile")
      if sc.get("readOnlyRootFilesystem") is not True and not excused(cname, "readOnlyRootFilesystem"):
        err(here, "readOnlyRootFilesystem is not true")
      resources = container.get("resources") or {}
      requests, limits = resources.get("requests") or {}, resources.get("limits") or {}
      for wanted in ("cpu", "memory"):
        if wanted not in requests:
          err(here, f"no {wanted} request")
      for wanted in ("memory", "ephemeral-storage"):
        if wanted not in limits:
          err(here, f"no {wanted} limit")
      if not is_init and "livenessProbe" not in container:
        err(here, "no livenessProbe")
      for probe in ("startupProbe", "readinessProbe", "livenessProbe"):
        command = ((container.get(probe) or {}).get("exec") or {}).get("command") or []
        text = " ".join(str(part) for part in command)
        if re.search(r"(^|\s)(-p\S|--password)", text) or "PASSWORD" in text:
          err(here, f"{probe} carries a password in its command: {text}")


# ---- NetworkPolicy -----------------------------------------------------------
def selects(selector, labels):
  if selector is None:
    return False
  if selector.get("matchExpressions"):
    return False  # not used by the kit; say "no" rather than guess
  return all(labels.get(k) == v for k, v in (selector.get("matchLabels") or {}).items())


def rule_ports(rule):
  return {(p.get("protocol", "TCP"), p.get("port")) for p in rule.get("ports") or []}


def check_network_policies(docs, strict):
  """Default deny in every namespace with pods of the kit, and narrow allows."""
  policies = [(w, d) for w, d in docs if d.get("kind") == "NetworkPolicy"]
  workloads = [(w, d) for w, d in docs if d.get("kind") in WORKLOADS]
  by_namespace = {}
  for where, policy in policies:
    by_namespace.setdefault(policy["metadata"].get("namespace"), []).append((where, policy))

  def labels_of(workload):
    return pod_template(workload).get("metadata", {}).get("labels", {})

  for namespace in sorted({d["metadata"].get("namespace") for _, d in workloads}):
    here = by_namespace.get(namespace, [])
    deny = [p for _, p in here
            if p["spec"].get("podSelector") == {} and set(p["spec"].get("policyTypes") or []) == {"Ingress", "Egress"}
            and not p["spec"].get("ingress") and not p["spec"].get("egress")]
    if not deny:
      err(f"namespace {namespace}", "no NetworkPolicy that denies everything by default "
                                    "(podSelector {}, both policyTypes, no rules)")

  for where, workload in workloads:
    namespace = workload["metadata"].get("namespace")
    name = f"{where}:{workload['kind']}/{workload['metadata']['name']}"
    own = [p for _, p in by_namespace.get(namespace, [])
           if p["spec"].get("podSelector") and selects(p["spec"]["podSelector"], labels_of(workload))]
    if not own:
      err(name, "no NetworkPolicy of its own selects this pod (only the default deny, if that)")

  for where, policy in policies:
    namespace = policy["metadata"].get("namespace")
    pname = policy["metadata"]["name"]
    name = f"{where}:NetworkPolicy/{namespace}/{pname}"
    spec = policy["spec"]
    selected = [w for _, w in workloads if w["metadata"].get("namespace") == namespace
                and (spec.get("podSelector") == {} or selects(spec.get("podSelector"), labels_of(w)))]
    if spec.get("podSelector") != {} and not selected:
      err(name, f"its podSelector {spec.get('podSelector')} selects no rendered pod")
    if set(spec.get("policyTypes") or []) != {"Ingress", "Egress"}:
      err(name, f"policyTypes are {spec.get('policyTypes')}; both Ingress and Egress are expected, "
                "so that a missing rule list means 'nothing' and not 'everything'")
    container_ports = {p.get("containerPort") for w in selected
                       for c, _ in containers_of(pod_template(w)["spec"]) for p in c.get("ports") or []}

    for index, rule in enumerate(spec.get("ingress") or []):
      rule_name = f"{name} ingress[{index}]"
      if not rule.get("from"):
        err(rule_name, "names no source, so every pod of the cluster may connect")
      if not rule.get("ports"):
        err(rule_name, "names no port")
      for protocol, port in rule_ports(rule):
        if port not in container_ports:
          err(rule_name, f"admits port {port}, which no selected container listens on ({sorted(container_ports)})")
      for peer in rule.get("from") or []:
        check_peer(peer, namespace, workloads, labels_of, rule_name)

    for index, rule in enumerate(spec.get("egress") or []):
      rule_name = f"{name} egress[{index}]"
      ports = rule_ports(rule)
      if not rule.get("to"):
        if ports and ports <= DNS_PORTS:
          continue  # name lookups, to wherever the cluster answers them
        if (pname == "vertex-token-refresher" and ("TCP", 443) in ports
            and all(proto == "TCP" and type(p) is int and 1 <= p <= 65535 for proto, p in ports)):
          continue  # documented exception: cluster API server (KUBE_API_PORTS) and Google token endpoint (443)
        if pname in OPEN_EGRESS and not strict:
          continue
        err(rule_name, f"names no destination (ports {sorted(ports, key=str) or 'all'})"
                       + (": not accepted in strict mode" if pname in OPEN_EGRESS else ""))
        continue
      for peer in rule["to"]:
        check_peer(peer, namespace, workloads, labels_of, rule_name)
        block = (peer.get("ipBlock") or {}).get("cidr")
        if block in ("0.0.0.0/0", "::/0") and not ports:
          err(rule_name, f"reaches every address ({block}) on every port")


def check_peer(peer, namespace, workloads, labels_of, where):
  """A source or destination of a rule names something that exists."""
  if not peer:
    err(where, "has an empty peer, which means every pod of the namespace")
    return
  if "ipBlock" in peer:
    if not re.match(r"^[0-9A-Fa-f:.]+/[0-9]{1,3}$", str(peer["ipBlock"].get("cidr", ""))):
      err(where, f"ipBlock {peer['ipBlock']} is not a CIDR")
    return
  target = namespace
  if "namespaceSelector" in peer:
    labels = (peer["namespaceSelector"] or {}).get("matchLabels") or {}
    if set(labels) != {"kubernetes.io/metadata.name"}:
      err(where, f"namespaceSelector {peer['namespaceSelector']} does not name one namespace "
                 "by kubernetes.io/metadata.name")
      return
    target = labels["kubernetes.io/metadata.name"]
  rendered_here = [w for _, w in workloads if w["metadata"].get("namespace") == target]
  if "podSelector" in peer and rendered_here:
    # The namespace is one of the kit's: the selector has to match a pod in it.
    if not any(selects(peer["podSelector"], labels_of(w)) for w in rendered_here):
      err(where, f"podSelector {peer['podSelector']} matches no rendered pod in namespace {target}")


def check_exposure(docs):
  """Nothing is published by accident, and what is published has a certificate."""
  for where, doc in docs:
    kind = doc.get("kind")
    name = f"{where}:{kind}/{doc['metadata'].get('name')}"
    if kind == "Service" and doc["spec"].get("type", "ClusterIP") != "ClusterIP":
      err(name, f"is of type {doc['spec']['type']}; only ClusterIP is expected")
    if kind == "Ingress":
      covered = {host for entry in doc["spec"].get("tls") or [] if entry.get("secretName")
                 for host in entry.get("hosts") or []}
      for rule in doc["spec"].get("rules") or []:
        if rule.get("host") not in covered:
          err(name, f"host {rule.get('host')} has no TLS certificate")
      annotations = doc["metadata"].get("annotations") or {}
      if annotations.get("nginx.ingress.kubernetes.io/force-ssl-redirect") != "true":
        err(name, "does not force a redirect from http to https")
    if kind in ("Role", "ClusterRole"):
      for rule in doc.get("rules") or []:
        if "*" in (rule.get("verbs") or []) or "*" in (rule.get("resources") or []):
          err(name, f"has a wildcard rule: {rule}")
    if kind in ("ClusterRole", "ClusterRoleBinding"):
      err(name, "is cluster-wide; the kit is expected to need namespaced permissions only")


def check_images(docs, strict):
  """In strict mode every image is named by digest."""
  if not strict:
    return
  for where, doc in docs:
    images = []
    if doc.get("kind") in WORKLOADS:
      images = [(c["name"], c.get("image", "")) for c, _ in containers_of(pod_template(doc)["spec"])]
    elif doc.get("kind") == "WorkerPool":
      images = [("workerImage", doc["spec"].get("workerImage", ""))]
    for cname, image in images:
      if "@sha256:" not in image:
        err(f"{where}:{doc['kind']}/{doc['metadata']['name']}/{cname}", f"image {image} is not named by digest")


def check_placements(docs, worker_selector, pull_secret):
  if worker_selector:
    key, _, value = worker_selector.partition("=")
    pools = [(w, d) for w, d in docs if d.get("kind") == "WorkerPool"]
    for where, pool in pools:
      sel = ((pool.get("spec") or {}).get("template") or {}).get("nodeSelector") or {}
      if sel.get(key) != value:
        err(f"{where}:WorkerPool/{pool['metadata']['name']}", f"nodeSelector {sel} does not have {key}={value}")
  if pull_secret:
    lookers = [(w, d) for w, d in docs if d.get("kind") == "Deployment" and d["metadata"]["name"] == "looker"]
    for where, looker in lookers:
      secrets = [s.get("name") for s in (pod_template(looker).get("spec") or {}).get("imagePullSecrets") or []]
      if pull_secret not in secrets:
        err(f"{where}:Deployment/looker", f"imagePullSecrets {secrets} does not include {pull_secret}")


def main():
  parser = argparse.ArgumentParser(description="Check rendered manifests against Substrate definitions and security rules.")
  parser.add_argument("proto", type=pathlib.Path)
  parser.add_argument("crd", type=pathlib.Path)
  parser.add_argument("rendered", type=pathlib.Path)
  parser.add_argument("--strict", action="store_true")
  parser.add_argument("--no-netpol", action="store_true")
  parser.add_argument("--worker-node-selector", default="")
  parser.add_argument("--image-pull-secret", default="")
  args = parser.parse_args()

  messages, enums = parse_proto(args.proto.read_text())
  crd = next(d for d in yaml.safe_load_all(args.crd.read_text()) if d)
  crd_schema = next(v for v in crd["spec"]["versions"] if v["name"] == "v1")["schema"]["openAPIV3Schema"]
  summary = []
  all_docs = []
  for path in sorted(args.rendered.glob("*.yaml")):
    try:
      docs = [d for d in yaml.safe_load_all(path.read_text()) if d is not None]
    except yaml.YAMLError as error:
      err(path.name, f"YAML error: {error}")
      continue
    summary.append(f"{path.name}: {len(docs)} doc(s)")
    if path.name == "actor-template.yaml":
      check_message(docs[0], "ActorTemplate", messages, enums, path.name)
    elif path.name == "egress-policy.yaml":
      check_message(docs[0], "EgressPolicy", messages, enums, path.name)
    else:
      for doc in docs:
        if doc.get("kind") == "WorkerPool":
          if doc.get("apiVersion") != f"{crd['spec']['group']}/v1":
            err(path.name, f"WorkerPool apiVersion {doc.get('apiVersion')}")
          check_schema(doc, crd_schema, f"{path.name}:WorkerPool")
      check_workloads(docs, path.name)
      all_docs.extend((path.name, doc) for doc in docs)

  levels = check_namespaces(all_docs)
  check_pod_security(all_docs, levels)
  if not args.no_netpol:
    check_network_policies(all_docs, args.strict)
  check_exposure(all_docs)
  check_images(all_docs, args.strict)
  check_placements(all_docs, args.worker_node_selector, args.image_pull_secret)

  print("; ".join(summary))
  if errors:
    print(f"{len(errors)} PROBLEM(S):")
    for line in errors:
      print("  -", line)
    return 1
  print("no problems found")
  return 0


if __name__ == "__main__":
  sys.exit(main())

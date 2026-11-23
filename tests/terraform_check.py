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

"""Checks the Terraform front end (terraform/) against deploy.sh.

Terraform itself is not needed, and is not run: this reads the .tf files as
text. What it shows is that the two halves agree:

  * every setting main.tf passes on is one deploy.sh reads;
  * every variable is declared and used, and none carries a secret;
  * every step main.tf starts is a command deploy.sh has;
  * the example variables file sets only declared variables, with values of
    the declared type;
  * the environment Terraform would build from that example makes
    "deploy.sh render" succeed, and the values arrive in the manifests.

What it does not show: that Terraform accepts the files. "terraform validate"
does that; the repository's workflow has a job for it. If a terraform binary
is on PATH, this script runs "terraform fmt -check" as well.

Run:  python3 tests/terraform_check.py
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TF = os.path.join(KIT, "terraform")

# The secrets deploy.sh takes from the environment. Terraform must have no
# variable for any of them, and extra_settings must refuse their names.
SECRETS = (
    "LOOKER_LICENSE_KEY", "LOOKER_CLIENT_SECRET", "ANTHROPIC_API_KEY",
    "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY", "LOOKER_DB_PASSWORD",
    "GATEWAY_BASIC_AUTH_PASSWORD", "GATEWAY_CHAT_AUTH_PASSWORD",
)

passed = 0
failed = 0


def ok(description):
  global passed
  passed += 1
  print("  ok   " + description)


def bad(description):
  global failed
  failed += 1
  print("  FAIL " + description)


def check(condition, description, detail=""):
  if condition:
    ok(description)
  else:
    bad(description + (" (" + detail + ")" if detail else ""))


def read(*parts):
  with open(os.path.join(*parts), encoding="utf-8") as handle:
    return handle.read()


def without_comments(text):
  return "\n".join(
      line for line in text.splitlines() if not line.lstrip().startswith("#"))


def literal(text):
  """The value of a one-line HCL literal: a string, bool, number, list or {}."""
  text = text.strip()
  if text in ("true", "false"):
    return text == "true"
  if text == "{}":
    return {}
  if re.fullmatch(r"-?[0-9]+", text):
    return int(text)
  if text.startswith('"') or text.startswith("["):
    # A quoted string or a list of quoted strings is also valid JSON.
    return json.loads(text)
  raise ValueError("not a literal this check understands: %r" % text)


def variables(text):
  """{name: {"type": ..., "default": ..., "has_default": bool, "block": text}}"""
  found = {}
  for match in re.finditer(r'(?ms)^variable "([a-z0-9_]+)" \{\n(.*?)^\}', text):
    name, block = match.group(1), match.group(2)
    kind = re.search(r"(?m)^  type\s*=\s*(.+)$", block)
    default = re.search(r"(?m)^  default\s*=\s*(.+)$", block)
    found[name] = {
        "type": kind.group(1).strip() if kind else "",
        "has_default": default is not None,
        "default": literal(default.group(1)) if default else None,
        "block": block,
    }
  return found


def settings_block(main_text):
  """[(SETTING_NAME, expression)] from the settings map in main.tf."""
  match = re.search(r"(?ms)^  settings = merge\(\{\n(.*?)^  \}, var\.extra_settings\)", main_text)
  if not match:
    return None
  pairs = []
  for line in without_comments(match.group(1)).splitlines():
    if not line.strip():
      continue
    name, _, expression = line.partition("=")
    pairs.append((name.strip(), expression.strip()))
  return pairs


def evaluate(expression, values):
  """What Terraform would make of one of the four expression forms used."""
  def to_hcl_string(value):
    if isinstance(value, bool):
      return "true" if value else "false"
    return str(value)

  forms = (
      (r"var\.([a-z0-9_]+)", lambda value: value),
      (r"tostring\(var\.([a-z0-9_]+)\)", to_hcl_string),
      (r"jsonencode\(var\.([a-z0-9_]+)\)", lambda value: json.dumps(value, separators=(",", ":"))),
      (r'join\(",", var\.([a-z0-9_]+)\)', ",".join),
  )
  for pattern, convert in forms:
    match = re.fullmatch(pattern, expression)
    if match:
      return match.group(1), convert(values[match.group(1)])
  raise ValueError("expression form not known to this check: %r" % expression)


def tfvars(text):
  """{name: value} for the lines of a variables file that are not comments."""
  found = {}
  for line in without_comments(text).splitlines():
    if not line.strip():
      continue
    name, _, value = line.partition("=")
    found[name.strip()] = literal(value)
  return found


def matches_type(value, kind):
  if kind == "string":
    return isinstance(value, str)
  if kind == "bool":
    return isinstance(value, bool)
  if kind == "number":
    return isinstance(value, int) and not isinstance(value, bool)
  if kind == "list(string)":
    return isinstance(value, list) and all(isinstance(item, str) for item in value)
  if kind == "map(string)":
    return isinstance(value, dict)
  return False


def deploy_settings(deploy_text):
  """Names deploy.sh gives a default to in load_config: its settings."""
  return set(re.findall(r'(?m)^  : "\$\{([A-Z][A-Z0-9_]*):=', deploy_text))


def deploy_commands(deploy_text):
  """The commands main() of deploy.sh accepts."""
  body = deploy_text[deploy_text.index("\nmain() {"):]
  commands = set()
  for labels in re.findall(r"(?m)^    ([a-z|-]+)\)", body):
    commands.update(labels.split("|"))
  return commands


def main():
  main_text = read(TF, "main.tf")
  variables_text = read(TF, "variables.tf")
  outputs_text = read(TF, "outputs.tf")
  example_text = read(TF, "terraform.tfvars.example")
  deploy_text = read(KIT, "deploy.sh")

  print("== 1. settings main.tf passes on are settings deploy.sh reads")
  declared = variables(variables_text)
  pairs = settings_block(main_text)
  check(pairs is not None and len(pairs) > 20, "the settings map of main.tf was found",
        "found %s entries" % (len(pairs) if pairs else 0))
  pairs = pairs or []
  known = deploy_settings(deploy_text)
  check(len(known) > 60, "deploy.sh's settings were found", "found %d" % len(known))
  unknown = sorted(name for name, _ in pairs if name not in known)
  check(not unknown, "every setting name is one deploy.sh gives a default to", ", ".join(unknown))
  names = [name for name, _ in pairs]
  check(len(names) == len(set(names)), "no setting is passed twice")

  print("== 2. variables")
  used = set(re.findall(r"\bvar\.([a-z0-9_]+)", without_comments(main_text + "\n" + outputs_text)))
  check(not (used - set(declared)), "every variable that is used is declared",
        ", ".join(sorted(used - set(declared))))
  check(not (set(declared) - used), "every declared variable is used",
        ", ".join(sorted(set(declared) - used)))
  undocumented = sorted(name for name, entry in declared.items() if "description" not in entry["block"])
  check(not undocumented, "every variable has a description", ", ".join(undocumented))
  for name, entry in sorted(declared.items()):
    if entry["has_default"] and not matches_type(entry["default"], entry["type"]):
      bad("default of %s is not a %s" % (name, entry["type"]))

  print("== 3. no secret passes through Terraform")
  check("sensitive" not in without_comments(variables_text),
        "no variable is marked sensitive: there is none to mark")
  for secret in SECRETS:
    check(secret in deploy_text, "%s is still a name deploy.sh reads" % secret)
    check(secret.lower() not in declared, "no variable named %s" % secret.lower())
    check(secret not in names, "%s is not in the settings map" % secret)
    check('"%s"' % secret in declared["extra_settings"]["block"],
          "extra_settings refuses %s" % secret)
  check("environment = local.environment" in main_text
        and main_text.count("environment = local.environment")
        == main_text.count('provisioner "local-exec"'),
        "every step gets the same environment, built from the settings alone")

  print("== 4. steps")
  steps = re.findall(r'"bash deploy\.sh ([a-z-]+)"', main_text)
  commands = deploy_commands(deploy_text)
  check(len(steps) >= 10, "the steps of main.tf were found", "found %d" % len(steps))
  missing = sorted(set(steps) - commands)
  check(not missing, "every step is a command of deploy.sh", ", ".join(missing))
  order = [step for step in steps if step not in ("render", "extension-files")]
  check(order == ["preflight", "gke", "looker", "substrate", "image", "agent", "gateway",
                  "verify", "extension"],
        "the steps are in the script's own order", " ".join(order))
  resources = re.findall(r'(?m)^resource "terraform_data" "([a-z_]+)" \{', main_text)
  for previous, current in zip(resources, resources[1:]):
    block = main_text[main_text.index('resource "terraform_data" "%s"' % current):]
    block = block[:block.index("\n}\n") if "\n}\n" in block else len(block)]
    check("depends_on       = [terraform_data.%s]" % previous in block,
          "%s waits for %s" % (current, previous))

  print("== 4b. fileset patterns are valid for Terraform's doublestar v1 globber")
  patterns = re.findall(r'fileset\([^,]+,\s*"([^"]+)"\)', without_comments(main_text))
  check(len(patterns) >= 5, "main.tf uses separate fileset calls", "found %d" % len(patterns))
  for pat in patterns:
    slash_in_braces = bool(re.search(r"\{[^}]*/[^}]*\}", pat))
    check(not slash_in_braces, "fileset pattern %r has no '/' inside braces" % pat)
    matched = [p for p in glob.glob(os.path.join(KIT, pat), recursive=True) if os.path.isfile(p)]
    check(len(matched) > 0, "fileset pattern %r matches at least one file" % pat)

  print("== 5. the example variables file")
  example = tfvars(example_text)
  check(not (set(example) - set(declared)), "it sets only declared variables",
        ", ".join(sorted(set(example) - set(declared))))
  for name, value in sorted(example.items()):
    if name in declared and not matches_type(value, declared[name]["type"]):
      bad("%s in the example is not a %s" % (name, declared[name]["type"]))
  required = sorted(name for name, entry in declared.items() if not entry["has_default"])
  check(not (set(required) - set(example)), "it sets every variable that has no default",
        ", ".join(sorted(set(required) - set(example))))
  for secret in SECRETS:
    check(not re.search(r"(?m)^[^#\n]*" + secret.lower(), example_text),
          "it sets no %s" % secret.lower())

  print("== 6. deploy.sh renders with the environment Terraform would pass")
  values = {name: entry["default"] for name, entry in declared.items()}
  values.update(example)
  with tempfile.TemporaryDirectory() as temp:
    # The example names a key file that does not exist on this machine.
    key_file = os.path.join(temp, "model-caller-key.json")
    with open(key_file, "w", encoding="utf-8") as handle:
      handle.write("{}\n")
    values["gcp_sa_key_file"] = key_file
    environment = {}
    try:
      for name, expression in pairs:
        _, environment[name] = evaluate(expression, values)
      ok("every expression in the settings map is one of the four simple forms")
    except (KeyError, TypeError, ValueError) as error:
      bad("an expression in the settings map could not be worked out (%s)" % error)
    environment.update(values["extra_settings"])
    work = os.path.join(temp, "work")
    environment["CONFIG_FILE"] = os.path.join(TF, "settings-from-terraform.env")
    environment["WORK_DIR"] = work
    config = without_comments(read(TF, "settings-from-terraform.env")).strip()
    check(config == "", "the configuration file Terraform names sets nothing")
    # Only what a shell needs, plus the settings: nothing of this machine's
    # environment may fill a gap that Terraform would leave open.
    base = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR", "LANG") if key in os.environ}
    result = subprocess.run(
        ["bash", os.path.join(KIT, "deploy.sh"), "render"], cwd=KIT, env={**base, **environment},
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120, check=False)
    check(result.returncode == 0, "deploy.sh render succeeds",
          "exit %d: %s" % (result.returncode, result.stdout.strip().splitlines()[-1:] or ""))
    rendered = os.path.join(work, "rendered")
    text = ""
    if os.path.isdir(rendered):
      for name in sorted(os.listdir(rendered)):
        text += read(rendered, name)
    check("looker.corp.example" in text, "looker_host arrives in the manifests")
    check("'[\"thelook\"]'" in text, "looker_models arrives as the JSON list the agent parses")
    check("registry.corp.example/looker-agent" in text, "registry arrives in the manifests")
    check("my-vertex-project" in text, "gcp_project_id arrives in the manifests")

  print("== 7. terraform fmt, when Terraform is installed")
  terraform = shutil.which("terraform")
  if terraform:
    result = subprocess.run(
        [terraform, "fmt", "-check", "-diff", TF], stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, timeout=120, check=False)
    check(result.returncode == 0, "terraform fmt -check", result.stdout.strip()[:300])
  else:
    print("  not run: no terraform on this machine")

  print("\nterraform front end: %d ok, %d FAIL" % (passed, failed))
  return 1 if failed else 0


if __name__ == "__main__":
  sys.exit(main())

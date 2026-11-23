#!/usr/bin/env bash
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

# Exercises deploy.sh's functions with kubectl replaced by shell stubs. No
# cluster is involved: this checks the script's own logic, not the real tools.
#
# Run:  bash tests/deploy_functions_test.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
CONF="$ROOT/config.env"; WORK="$ROOT/work"
sample_config onprem > "$CONF"
ok()  { printf '  ok   %s\n' "$1" | tee -a "$ROOT/results"; }
bad() { printf '  FAIL %s\n' "$1" | tee -a "$ROOT/results"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

# Each scenario runs in a subshell: load the functions (everything but the last
# line, which calls main), load the config, then replace k/kate with stubs.
scenario() { ( set +e; export CONFIG_FILE="$CONF" WORK_DIR="$WORK"; source <(sed '$d' "$KIT/deploy.sh"); set +e; trap - EXIT; load_config >/dev/null; validate_config >/dev/null; CALLS="$WORK/calls.log"; : > "$CALLS"; "$@" ); }

echo "== pure helpers"
t_helpers() {
  check "yaml_sq plain" "$(yaml_sq 'abc')" "'abc'"
  check "yaml_sq doubles a quote" "$(yaml_sq "a'b")" "'a''b'"
  check "yaml_sq json" "$(yaml_sq '["thelook"]')" "'[\"thelook\"]'"
  v="$(gen_alnum 32)"; check "gen_alnum length" "${#v}" "32"
  check "gen_alnum charset" "$(printf '%s' "$v" | tr -d 'A-Za-z0-9')" ""
  is_unset "" && ok "is_unset empty" || bad "is_unset empty"
  is_unset "YOUR_X" && ok "is_unset placeholder" || bad "is_unset placeholder"
  is_unset "real" && bad "is_unset real" || ok "is_unset real value"
  parse_url "https://looker.corp.example"; check "parse_url https default port" "$URL_SCHEME $URL_HOST $URL_PORT" "https looker.corp.example 443"
  parse_url "https://looker.corp.example:19999/"; check "parse_url explicit port" "$URL_HOST $URL_PORT" "looker.corp.example 19999"
  parse_url "http://looker-api.looker.svc.cluster.local"; check "parse_url http" "$URL_SCHEME $URL_PORT" "http 80"
  ( parse_url "https://10.0.0.5:19999" ) >/dev/null 2>&1 && bad "parse_url must refuse an IP" || ok "parse_url refuses an IP address"
  ( parse_url "https://Looker.Corp" ) >/dev/null 2>&1 && bad "parse_url must refuse uppercase" || ok "parse_url refuses uppercase host"
  ( parse_url "looker.corp" ) >/dev/null 2>&1 && bad "parse_url must need a scheme" || ok "parse_url needs a scheme"
  LOOKER_VERSION="26.5"; looker_version_at_least 26 6 && bad "26.5 is below 26.6" || ok "looker_version_at_least 26.5 < 26.6"
  LOOKER_VERSION="26.6"; looker_version_at_least 26 6 && ok "looker_version_at_least 26.6 >= 26.6" || bad "26.6 >= 26.6"
  LOOKER_VERSION="26.10"; looker_version_at_least 26 6 && ok "looker_version_at_least 26.10 >= 26.6" || bad "26.10 >= 26.6"
}
scenario t_helpers

echo "== actor template with a secret that contains quotes (not render mode)"
t_template() {
  RENDER_ONLY=false; AGENT_IMAGE_REF="r.example/a@sha256:$(printf '%064d' 1)"
  LOOKER_CLIENT_ID="id123"; LOOKER_CLIENT_SECRET="pa'ss\"w: #ord"
  render_actor_template >/dev/null
  got="$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); e={x["name"]:x["value"] for x in d["containers"][0]["env"]}; print(e["LOOKERSDK_CLIENT_SECRET"]); print(e["LOOKER_MODELS"]); print(d["metadata"]["name"])' "$ACTOR_TEMPLATE_FILE")"
  check "applied secret round-trips through YAML" "$(printf '%s\n' "$got" | sed -n 1p)" "pa'ss\"w: #ord"
  check "LOOKER_MODELS round-trips" "$(printf '%s\n' "$got" | sed -n 2p)" '["thelook"]'
  redacted="$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); e={x["name"]:x["value"] for x in d["containers"][0]["env"]}; print(e["LOOKERSDK_CLIENT_ID"], e["LOOKERSDK_CLIENT_SECRET"])' "$RENDER_DIR/actor-template.yaml")"
  check "rendered copy redacts Looker key" "$redacted" "REDACTED REDACTED"
  first="$TEMPLATE_NAME"; render_actor_template >/dev/null; check "same input, same template name" "$TEMPLATE_NAME" "$first"
  LOOKER_CLIENT_SECRET="other"; render_actor_template >/dev/null
  [ "$TEMPLATE_NAME" != "$first" ] && ok "changed input, new template name" || bad "template name did not change"
  check "template file is private" "$(stat -c %a "$RENDER_DIR/actor-template.yaml")" "600"
  forget "$ACTOR_TEMPLATE_FILE"
}
scenario t_template

echo "== credential provider namespace policy"
policy_k() { # stub: $POLICY is what the ConfigMap holds
  case "$*" in
    *"get configmap k8s-credential-provider-namespace-policy"*) printf '%s' "$POLICY" ;;
    *"create configmap"*) echo "CREATE $*" >> "$CALLS"; cat "$TMP_DIR/namespace-policy.yaml" > "$WORK/applied-policy.yaml"; echo "apiVersion: v1" ;;
    *) echo "K $*" >> "$CALLS"; cat >/dev/null 2>&1 < /dev/null ;;
  esac
}
t_policy_default() {
  k() { policy_k "$@"; }
  POLICY=$'# No atespace may resolve any Secret until it is listed here, for example:\n#\n#   policies:\n#   - atespace: team-a\npolicies: []\n'
  grant_credential_namespace >/dev/null; rc=$?
  check "empty default policy: succeeds" "$rc" "0"
  want="$(python3 -c 'import yaml,sys; print(yaml.safe_load(open(sys.argv[1])))' "$WORK/applied-policy.yaml")"
  check "empty default policy: writes our grant" "$want" "{'policies': [{'atespace': 'looker-agent', 'allowedNamespaces': ['looker-agent-creds']}]}"
  grep -q "rollout restart deployment/k8s-credential-provider" "$CALLS" && ok "provider restarted to load it" || bad "provider not restarted"
}
t_policy_present() {
  k() { policy_k "$@"; }
  POLICY=$'policies:\n- atespace: looker-agent\n  allowedNamespaces:\n  - looker-agent-creds\n'
  grant_credential_namespace >/dev/null; check "already granted: succeeds" "$?" "0"
  [ -s "$CALLS" ] && bad "already granted: should change nothing ($(cat "$CALLS"))" || ok "already granted: changes nothing"
}
t_policy_foreign() {
  k() { policy_k "$@"; }
  POLICY=$'policies:\n- atespace: team-a\n  allowedNamespaces:\n  - ns1\n'
  ( grant_credential_namespace ) >/dev/null 2>"$WORK/err.txt"; rc=$?
  check "someone else's policies: refuses" "$rc" "1"
  grep -q "atespace: looker-agent" "$WORK/err.txt" && ok "prints the entry to add by hand" || bad "no manual instructions"
  grep -q CREATE "$CALLS" && bad "must not overwrite foreign policies" || ok "does not overwrite foreign policies"
}
scenario t_policy_default; scenario t_policy_present; scenario t_policy_foreign

echo "== golden snapshot wait"
t_golden_ready() {
  TEMPLATE_NAME=looker-agent-abc; GOLDEN_TIMEOUT_SECONDS=5
  kate() { echo '{"metadata":{"name":"looker-agent-abc"},"status":{"goldenSnapshotStatus":{"goldenTag":{"atespace":"looker-agent","name":"tag-uid-1"}}}}'; }
  out="$(wait_for_golden_snapshot 2>&1)"; check "ready (camelCase JSON)" "$?" "0"; printf '%s' "$out" | grep -q "tag-uid-1" && ok "reports the tag" || bad "tag not reported"
  kate() { echo '[{"status":{"golden_snapshot_status":{"golden_tag":{"name":"tag-2"}}}}]'; }
  wait_for_golden_snapshot >/dev/null 2>&1; check "ready (snake_case, list-wrapped JSON)" "$?" "0"
}
t_golden_error() {
  TEMPLATE_NAME=looker-agent-abc; GOLDEN_TIMEOUT_SECONDS=5
  kate() { echo '{"status":{"goldenSnapshotStatus":{"errorMessage":"wakeup probe timed out"}}}'; }
  out="$( (wait_for_golden_snapshot) 2>&1 )"; check "image failed to start: stops" "$?" "1"
  printf '%s' "$out" | grep -q "wakeup probe timed out" && ok "shows Substrate's error" || bad "error not shown"
}
t_golden_timeout() {
  TEMPLATE_NAME=looker-agent-abc; GOLDEN_TIMEOUT_SECONDS=1
  kate() { echo '{"status":{}}'; }
  wait_for_golden_snapshot >/dev/null 2>&1; check "still building at timeout: continues" "$?" "0"
}
scenario t_golden_ready; scenario t_golden_error; scenario t_golden_timeout

echo "== actor create / move between templates"
actor_kate() { # $ACTOR_JSON empty means the actor does not exist
  echo "KATE $*" >> "$CALLS"
  case "$*" in
    "get actor"*"-o json"*) printf '%s' "$ACTOR_JSON" ;;
    "get actor"*) [ -n "$ACTOR_JSON" ] ;;
    *) return 0 ;;
  esac
}
t_actor_new() { TEMPLATE_NAME=t-new; ACTOR_JSON=""; kate() { actor_kate "$@"; }; ensure_actor >/dev/null
  grep -q "KATE create actor looker-agent --template=t-new -a looker-agent" "$CALLS" && ok "missing actor is created from the template" || bad "create not called: $(cat "$CALLS")"; }
t_actor_same() { TEMPLATE_NAME=t-new; ACTOR_JSON='{"actorTemplate":{"name":"t-new"},"status":{"state":"ACTOR_STATE_RUNNING"}}'; kate() { actor_kate "$@"; }; ensure_actor >/dev/null
  grep -Eq "KATE (create|update|suspend|revert)" "$CALLS" && bad "unchanged actor must be left alone: $(cat "$CALLS")" || ok "actor already on the template is left alone"; }
t_actor_running() { TEMPLATE_NAME=t-new; ACTOR_JSON='{"actorTemplate":{"name":"t-old"},"status":{"state":"ACTOR_STATE_RUNNING"}}'; kate() { actor_kate "$@"; }; ensure_actor >/dev/null
  order="$(grep -E 'KATE (suspend|update)' "$CALLS" | awk '{print $2}' | tr '\n' ' ')"; check "running actor: suspend, then update" "$order" "suspend update "
  grep -q "suspend actor looker-agent -a looker-agent --mode=sync" "$CALLS" && ok "suspend waits for the snapshot (--mode=sync)" || bad "suspend not sync"; }
t_actor_suspended() { TEMPLATE_NAME=t-new; ACTOR_JSON='{"actorTemplate":{"name":"t-old"},"status":{"state":"ACTOR_STATE_SUSPENDED"}}'; kate() { actor_kate "$@"; }; ensure_actor >/dev/null
  order="$(grep -E 'KATE (suspend|update|revert)' "$CALLS" | awk '{print $2}' | tr '\n' ' ')"; check "suspended actor: update only" "$order" "update "; }
t_actor_crashed() { TEMPLATE_NAME=t-new; ACTOR_JSON='{"actor_template":{"name":"t-old"},"status":{"state":"ACTOR_STATE_CRASHED"}}'; kate() { actor_kate "$@"; }; ensure_actor >/dev/null
  order="$(grep -E 'KATE (suspend|update|revert)' "$CALLS" | awk '{print $2}' | tr '\n' ' ')"; check "crashed actor: revert, then update" "$order" "revert update "; }
scenario t_actor_new; scenario t_actor_same; scenario t_actor_running; scenario t_actor_suspended; scenario t_actor_crashed

echo "== S3 snapshot store patch"
t_s3() {
  S3_ENDPOINT_URL="https://s3.corp.example"; S3_REGION="eu-west-1"; S3_BUCKET="snapshots"; S3_ACCESS_KEY_ID="AKIA"; S3_SECRET_ACCESS_KEY="shh"
  k() { case "$*" in *" patch "*) echo "$*" | sed 's/.* -p //' >> "$WORK/patches.jsonl"; echo "PATCH $2 $4 $5" >> "$CALLS" ;; *"create secret"*) echo '{"apiVersion":"v1","kind":"Secret","data":{"access-key-id":"QQ=="}}' ;; *"get secret"*) return 1 ;; *) cat >/dev/null 2>&1 </dev/null; echo "K $*" >> "$CALLS" ;; esac; }
  : > "$WORK/patches.jsonl"; configure_s3_snapshot_store >/dev/null
  check "patches both sidecars" "$(grep -c PATCH "$CALLS")" "2"
  grep -q "PATCH ate-system deployment ate-api-server" "$CALLS" && grep -q "PATCH ate-system daemonset atelet" "$CALLS" && ok "ate-api-server and atelet" || bad "wrong targets: $(cat "$CALLS")"
  p="$(head -1 "$WORK/patches.jsonl")"
  check "patch names the sidecar" "$(printf '%s' "$p" | jq -r '.spec.template.spec.initContainers[0].name')" "objectstore-plugin"
  check "endpoint" "$(printf '%s' "$p" | jq -r '.spec.template.spec.initContainers[0].env[] | select(.name=="AWS_ENDPOINT_URL").value')" "https://s3.corp.example"
  check "key comes from a Secret, literal removed" "$(printf '%s' "$p" | jq -c '.spec.template.spec.initContainers[0].env[] | select(.name=="AWS_SECRET_ACCESS_KEY") | [.value, .valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key]')" '[null,"ate-objectstore-s3","secret-access-key"]'
  printf '%s' "$p" | grep -q "shh" && bad "secret value leaked into the patch" || ok "no secret value in the patch"
  grep -q "delete job rustfs-bucket-init" "$CALLS" && ok "deletes rustfs-bucket-init Job" || bad "did not delete rustfs-bucket-init: $(cat "$CALLS")"
}
scenario t_s3

t_s3_extra_ca() {
  printf 'PRIVATE-CA\n' > "$WORK/s3-ca.pem"
  S3_ENDPOINT_URL="https://s3.corp.example"; S3_REGION="eu-west-1"; S3_BUCKET="snapshots"; S3_ACCESS_KEY_ID="AKIA"; S3_SECRET_ACCESS_KEY="shh"; EXTRA_CA_FILE="$WORK/s3-ca.pem"
  k() { case "$*" in *" patch "*) echo "$*" | sed 's/.* -p //' >> "$WORK/patches-ca.jsonl"; echo "PATCH $2 $4 $5" >> "$CALLS" ;; *"create secret"*) echo '{"apiVersion":"v1","kind":"Secret","data":{"access-key-id":"QQ=="}}' ;; *"create configmap ate-objectstore-extra-ca"*) echo "CM $*" >> "$CALLS"; echo "apiVersion: v1" ;; *"get secret"*) return 1 ;; *) cat >/dev/null 2>&1 </dev/null; echo "K $*" >> "$CALLS" ;; esac; }
  : > "$WORK/patches-ca.jsonl"; configure_s3_snapshot_store >/dev/null
  grep -q "CM -n ate-system create configmap ate-objectstore-extra-ca --from-file=ca.crt=" "$CALLS" && ok "creates ate-objectstore-extra-ca ConfigMap" || bad "missing extra-ca ConfigMap: $(cat "$CALLS")"
  p="$(head -1 "$WORK/patches-ca.jsonl")"
  check "sets AWS_CA_BUNDLE in objectstore-plugin" "$(printf '%s' "$p" | jq -r '.spec.template.spec.initContainers[0].env[] | select(.name=="AWS_CA_BUNDLE").value')" "/run/objectstore-ca/ca.crt"
  check "mounts objectstore-extra-ca readOnly" "$(printf '%s' "$p" | jq -c '.spec.template.spec.initContainers[0].volumeMounts[0]')" '{"name":"objectstore-extra-ca","mountPath":"/run/objectstore-ca","readOnly":true}'
  check "declares objectstore-extra-ca ConfigMap volume" "$(printf '%s' "$p" | jq -c '.spec.template.spec.volumes[0]')" '{"name":"objectstore-extra-ca","configMap":{"name":"ate-objectstore-extra-ca"}}'
}
scenario t_s3_extra_ca


echo "== temp directory and build dir cleanup"
t_tmp() {
  ensure_tmp_dir; first="$TMP_DIR"; ensure_tmp_dir; check "one temp dir per run" "$TMP_DIR" "$first"
  check "temp dir is private" "$(stat -c %a "$first")" "700"
  echo secret > "$first/x"
  mkdir -p "$WORK/build-looker-tmp"; echo jar > "$WORK/build-looker-tmp/looker.jar"
  LOOKER_BUILD_DIR="$WORK/build-looker-tmp"
  cleanup
  [ -e "$first" ] && bad "cleanup left the secret files behind" || ok "cleanup removes the temp dir and its files"
  [ -e "$WORK/build-looker-tmp" ] && bad "cleanup left Looker build dir behind" || ok "cleanup removes Looker build dir on exit"
}
scenario t_tmp

echo "== bundled snapshot store login hardening"
t_bundled_store() {
  k() {
    case "$*" in
      *"create secret generic"*"--dry-run=client"*) printf '{"apiVersion":"v1","kind":"Secret","data":{"access-key-id":"QQ==","secret-access-key":"Qg=="}}' ;;
      *"get secret "*) return 1 ;;
      *"create -f -"*) cat >/dev/null; echo "CREATED" >> "$CALLS" ;;
      *" patch "*) echo "$*" | sed 's/.* -p //' >> "$WORK/bundled-patches.jsonl"; echo "PATCH $2 $4 $5" >> "$CALLS" ;;
      *) cat >/dev/null 2>&1 </dev/null; echo "K $*" >> "$CALLS" ;;
    esac
  }
  : > "$WORK/bundled-patches.jsonl"; configure_bundled_snapshot_store >/dev/null
  check "patches rustfs and both sidecars" "$(grep -c PATCH "$CALLS")" "3"
  grep -q "PATCH ate-system deployment rustfs" "$CALLS" && ok "rustfs deployment patched" || bad "rustfs not patched"
  grep -q "wait --for=condition=complete job/rustfs-bucket-init" "$CALLS" && ok "waits for rustfs-bucket-init before rotating credentials" || bad "did not wait for rustfs-bucket-init"
  grep -q "delete job rustfs-bucket-init" "$CALLS" && ok "deletes rustfs-bucket-init after completion" || bad "did not delete rustfs-bucket-init"
  rp="$(head -1 "$WORK/bundled-patches.jsonl")"
  check "rustfs strategy switched to Recreate for RWO PVC" "$(printf '%s' "$rp" | jq -c '[.spec.strategy.type, .spec.strategy.rollingUpdate]')" '["Recreate",null]'
  check "rustfs uses secretKeyRef for access key" "$(printf '%s' "$rp" | jq -c '.spec.template.spec.containers[0].env[] | select(.name=="RUSTFS_ACCESS_KEY") | [.value, .valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key]')" '[null,"ate-objectstore-s3","access-key-id"]'
  check "rustfs uses secretKeyRef for secret key" "$(printf '%s' "$rp" | jq -c '.spec.template.spec.containers[0].env[] | select(.name=="RUSTFS_SECRET_KEY") | [.value, .valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key]')" '[null,"ate-objectstore-s3","secret-access-key"]'
  check "rustfs web console disabled" "$(printf '%s' "$rp" | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="RUSTFS_CONSOLE_ENABLE").value')" "false"
  grep -q "rustfsadmin" "$WORK/bundled-patches.jsonl" && bad "default password present" || ok "no rustfsadmin in patches"
}
scenario t_bundled_store

echo "== gateway_curl does not build a curl config"
t_gateway_curl() {
  local injected=$'x"\nurl = "http://example.invalid/"'
  local b64_pass
  b64_pass="$(printf '%s' "$injected" | base64 | tr -d '\n')"
  k() {
    case "$*" in
      *"get secret"*"data.user"*) printf 'agent' | base64 | tr -d '\n' ;;
      *"get secret"*"data.password"*) printf '%s' "$b64_pass" ;;
    esac
  }
  curl() {
    printf '%s\n' "$@" > "$WORK/curl-args.txt"
    cat > "$WORK/curl-stdin.txt"
    printf '200'
  }
  prepare_gateway_curl
  gateway_curl looker-agent-gateway-chat-auth /readyz >/dev/null
  check "curl gets one header line on stdin" "$(wc -l < "$WORK/curl-stdin.txt" | tr -d ' ')" "1"
  hdr="$(cat "$WORK/curl-stdin.txt")"
  case "$hdr" in
    "Authorization: Basic "*) ok "Authorization header format" ;;
    *) bad "unexpected stdin header: $hdr" ;;
  esac
  decoded="$(printf '%s' "${hdr#Authorization: Basic }" | base64 -d)"
  check "header decodes back to original user:password" "$decoded" "agent:${injected}"
  grep -q "example.invalid" "$WORK/curl-args.txt" && bad "url leaked into curl args" || ok "no injected curl option in argv"
}
scenario t_gateway_curl

echo "== create_or_replace_secret uses replace, not apply"
t_secret_ops() {
  k() {
    case "$*" in
      *"create secret "*"--dry-run=client"*) printf '{"apiVersion":"v1","kind":"Secret","data":{"k":"%s"}}' "$(cat "${WORK}/val" | base64 | tr -d '\n')" ;;
      *"get secret "*) [ -e "${WORK}/cur-secret.json" ] && cat "${WORK}/cur-secret.json" || return 1 ;;
      *"create -f -"*) cat > "${WORK}/cur-secret.json"; echo "CREATE" >> "$CALLS" ;;
      *"replace -f -"*) cat > "${WORK}/cur-secret.json"; echo "REPLACE" >> "$CALLS" ;;
      *"apply"*) echo "APPLY" >> "$CALLS" ;;
    esac
  }
  printf 'v1' > "${WORK}/val"; create_or_replace_secret looker s "k=${WORK}/val"; check "first write is create" "$SECRET_CHANGE" "created"
  create_or_replace_secret looker s "k=${WORK}/val"; check "same value is unchanged" "$SECRET_CHANGE" "unchanged"
  printf 'v2' > "${WORK}/val"; create_or_replace_secret looker s "k=${WORK}/val"; check "new value is replace" "$SECRET_CHANGE" "replaced"
  grep -q "APPLY" "$CALLS" && bad "must never apply Secret" || ok "never calls kubectl apply"
}
scenario t_secret_ops

echo "== private-CA certificate generation and verification"
t_internal_tls() {
  k() {
    local ns=""; if [ "${1:-}" = "-n" ]; then ns="$2"; shift 2; fi
    case "$*" in
      "create secret "*"--dry-run=client"*)
        local st="Opaque" sname="$4" args=("$@") idx=0 kname kpath data='{}'
        while [ $idx -lt ${#args[@]} ]; do
          case "${args[$idx]}" in
            tls) st="kubernetes.io/tls" ;;
            --from-file=*) kname="${args[$idx]#--from-file=}"; kpath="${kname#*=}"; kname="${kname%%=*}"
              data="$(jq -c --arg k "$kname" --arg v "$(base64 < "$kpath" | tr -d '\n')" '. + {($k): $v}' <<< "$data")" ;;
            --cert=*) kpath="${args[$idx]#--cert=}"; data="$(jq -c --arg v "$(base64 < "$kpath" | tr -d '\n')" '. + {"tls.crt": $v}' <<< "$data")" ;;
            --key=*) kpath="${args[$idx]#--key=}"; data="$(jq -c --arg v "$(base64 < "$kpath" | tr -d '\n')" '. + {"tls.key": $v}' <<< "$data")" ;;
          esac
          idx=$((idx+1))
        done
        jq -cn --arg n "$sname" --arg ns "$ns" --argjson d "$data" '{apiVersion:"v1",kind:"Secret",metadata:{name:$n,namespace:$ns},data:$d}' ;;
      "get secret "*jsonpath=*)
        local sn="$3" kflag=""
        for a in "$@"; do case "$a" in jsonpath=*) kflag="${a#jsonpath=\{.data.}"; kflag="${kflag%\}}"; kflag="${kflag//\\./.}" ;; esac; done
        [ -e "${WORK}/sec-${ns}-${sn}" ] || return 1
        jq -r --arg k "$kflag" '.data[$k] // empty' "${WORK}/sec-${ns}-${sn}" ;;
      "get secret "*) [ -e "${WORK}/sec-${ns}-$3" ] && cat "${WORK}/sec-${ns}-$3" || return 1 ;;
      "create -f -"*) local m; m="$(cat)"; printf '%s' "$m" > "${WORK}/sec-${ns}-$(jq -r '.metadata.name' <<< "$m")"; echo "CREATE ${ns}/$(jq -r '.metadata.name' <<< "$m")" >> "$CALLS" ;;
      "replace -f -"*) local m; m="$(cat)"; printf '%s' "$m" > "${WORK}/sec-${ns}-$(jq -r '.metadata.name' <<< "$m")"; echo "REPLACE ${ns}/$(jq -r '.metadata.name' <<< "$m")" >> "$CALLS" ;;
    esac
  }
  INTERNAL_TLS="private-ca"; GATEWAY_TLS_SECRET="looker-agent-gateway-tls"; INTERNAL_MANAGED_GATEWAY_TLS="true"
  ensure_internal_looker_tls
  ensure_internal_gateway_tls
  jq -r '.data["ca.crt"]' "${WORK}/sec-looker-looker-internal-ca" | base64 -d > "${WORK}/ca.crt"
  jq -r '.data["tls.crt"]' "${WORK}/sec-looker-looker-tls" | base64 -d > "${WORK}/looker.crt"
  jq -r '.data["tls.crt"]' "${WORK}/sec-looker-agent-gateway-looker-agent-gateway-tls" | base64 -d > "${WORK}/gw.crt"
  openssl verify -CAfile "${WORK}/ca.crt" "${WORK}/looker.crt" >/dev/null 2>&1 && ok "Looker cert verifies against internal CA" || bad "Looker cert failed CA verify"
  openssl verify -CAfile "${WORK}/ca.crt" "${WORK}/gw.crt" >/dev/null 2>&1 && ok "Gateway cert verifies against internal CA" || bad "Gateway cert failed CA verify"
  san_l="$(openssl x509 -in "${WORK}/looker.crt" -noout -ext subjectAltName)"
  case "$san_l" in *"DNS:looker-api.looker.svc.cluster.local"*"DNS:looker.corp.example"*|*"DNS:looker.corp.example"*"DNS:looker-api.looker.svc.cluster.local"*) ok "Looker cert has service and host SANs" ;; *) bad "Looker SANs missing: $san_l" ;; esac
  san_g="$(openssl x509 -in "${WORK}/gw.crt" -noout -ext subjectAltName)"
  case "$san_g" in *"DNS:looker-agent-gateway.looker-agent-gateway.svc.cluster.local"*) ok "Gateway cert has service SAN" ;; *) bad "Gateway SAN missing: $san_g" ;; esac
  [ "$(find "$TMP_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')" = "0" ] && ok "temporary key/cert files removed immediately" || bad "left temp TLS files: $(ls -la "$TMP_DIR")"
  : > "$CALLS"
  ensure_internal_looker_tls
  ensure_internal_gateway_tls
  [ -s "$CALLS" ] && bad "re-running internal TLS mutated Secrets: $(cat "$CALLS")" || ok "internal TLS generation is idempotent"
  cleanup
}
scenario t_internal_tls

printf '\ndeploy.sh functions: %d ok, %d FAIL\n' "$(grep -c "^  ok" "$ROOT/results")" "$(grep -c "^  FAIL" "$ROOT/results")"
! grep -q "^  FAIL" "$ROOT/results"

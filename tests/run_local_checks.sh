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

# Runs every check that needs no cluster, no Looker license and no model.
#
#   tests/run_local_checks.sh        (or: bash tests/run_local_checks.sh)
#
# Every script is started through bash and every stub tool from a copy, so the
# checks also run from a checkout that lost its executable bits. GitHub's
# "upload files" page drops them, for one.
#
# Needs: bash, python3 (PyYAML for the schema check), openssl, jq, curl, and
# Node.js 18+ for the Looker extension's tests (no npm, no packages).
# README.md, "What was checked and what was not", says what these checks do
# and do not show.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$KIT"
# Do not leave __pycache__ directories in the kit.
export PYTHONDONTWRITEBYTECODE=1

SUBSTRATE_VERSION="${SUBSTRATE_VERSION:-v1.0.0}"
CACHE="${KIT}/tests/.cache/${SUBSTRATE_VERSION}"
failed=()
skipped=()

section() { printf '\n##### %s\n' "$1"; }

# attempt NAME COMMAND...: run a check, show its last lines, record the result.
attempt() {
  local name="$1" log
  shift
  log="$(mktemp)"
  if "$@" > "$log" 2>&1; then
    tail -n 2 "$log" | sed 's/^/      /'
    printf 'PASS  %s\n' "$name"
  else
    tail -n 25 "$log" | sed 's/^/      /'
    printf 'FAIL  %s\n' "$name"
    failed+=("$name")
  fi
  rm -f "$log"
}

py_parse() {
  python3 -c 'import ast, sys
for path in sys.argv[1:]:
    ast.parse(open(path).read(), path)' "$@"
}

node_parse() {
  local path
  for path in "$@"; do
    node --check "$path" || return 1
  done
}

json_parse() {
  python3 -c 'import json, sys
for path in sys.argv[1:]:
    json.load(open(path))' "$@"
}

section "Syntax"
attempt "deploy.sh parses" bash -n deploy.sh
attempt "looker/bin/looker.sh parses" bash -n looker/bin/looker.sh
attempt "Python files parse" py_parse gateway/gateway.py gateway/test_gateway.py \
  agent/server.py agent/test_server.py agent/test_agent_tools.py \
  agent/agents/looker_app/agent.py agent/agents/looker_app/__init__.py \
  tests/check_rendered.py tests/extension_gateway_test.py tests/terraform_check.py
attempt "extension package.json parses" json_parse looker-extension/package.json
attempt "workflow actions are pinned by commit" python3 -c 'import re, sys
for i, line in enumerate(open(sys.argv[1]), 1):
    m = re.search(r"^\s*-?\s*uses:\s*(\S+)", line)
    if m and not re.search(r"@[0-9a-f]{40}$", m.group(1)):
        sys.exit(f"line {i}: action not pinned by commit: {m.group(1)}")' .github/workflows/checks.yml

section "Gateway: real mutual TLS against a stand-in router"
attempt "gateway tests" python3 gateway/test_gateway.py

section "Agent entrypoint and tools: trust bundle, metadata stand-in, validation, event loop"
attempt "agent entrypoint tests" python3 agent/test_server.py
attempt "agent tool wrapper tests" python3 agent/test_agent_tools.py

section "Looker extension: everything around the chat component, against stand-ins"
if command -v node >/dev/null 2>&1; then
  attempt "extension sources parse" node_parse looker-extension/src/*.js \
    looker-extension/test/*.js looker-extension/webpack.config.cjs \
    tests/extension_contract/chat_through_gateway.mjs
  # No npm and no packages: the tests use Node's own test runner and replace
  # Looker, the gateway and the agent with stand-ins (looker-extension/test/fakes.js).
  attempt "extension tests" bash -c 'cd looker-extension && node --test test/*.test.js'
else
  skipped+=("Looker extension tests: Node.js is not installed (version 18 or newer)")
fi

section "Looker extension and gateway together: the extension's code against the real gateway"
if command -v node >/dev/null 2>&1; then
  # Looker's proxies and the agent are stand-ins; the extension code and the
  # gateway are the real ones, talking over HTTP and mutual TLS.
  attempt "extension through the gateway" python3 tests/extension_gateway_test.py
else
  skipped+=("extension-through-gateway test: Node.js is not installed (version 18 or newer)")
fi

section "deploy.sh functions, with kubectl stubbed"
attempt "deploy.sh functions" bash tests/deploy_functions_test.sh

section "deploy.sh from start to finish, against stub tools"
attempt "deploy.sh dry run" bash tests/deploy_dry_run_test.sh

section "Terraform front end: variables, step order, secrets kept out"
attempt "Terraform module checks" python3 tests/terraform_check.py

section "Rendered manifests against the Substrate ${SUBSTRATE_VERSION} API definitions"
fetch_definitions() {
  local base="https://raw.githubusercontent.com/agent-substrate/substrate/${SUBSTRATE_VERSION}"
  mkdir -p "$CACHE"
  [ -s "${CACHE}/ateapi.proto" ] \
    || curl -fsSL -m 60 -o "${CACHE}/ateapi.proto" "${base}/api/ateapi/v1/ateapi.proto" || return 1
  [ -s "${CACHE}/workerpools.yaml" ] \
    || curl -fsSL -m 60 -o "${CACHE}/workerpools.yaml" \
         "${base}/manifests/ate-install/generated/ate.dev_workerpools.yaml" || return 1
}

render_and_check() {
  local sample="$1" work="$2" extra_args=() dig
  if [ "$sample" = "strict" ]; then
    dig="$(printf 'sha256:%064d' 1)"
    sample_config full | sed \
      -e 's|^INTERNAL_TLS=.*|INTERNAL_TLS="private-ca"|' \
      -e 's|^WORKER_NODE_SELECTOR=.*|WORKER_NODE_SELECTOR="ate.dev/sandbox-nodes=true"|' \
      -e 's|^LOOKER_IMAGE_PULL_SECRET=.*|LOOKER_IMAGE_PULL_SECRET="looker-pull"|' \
      -e 's|^SNAPSHOT_STORE=.*|SNAPSHOT_STORE="s3"|' \
      -e 's|^S3_ENDPOINT_URL=.*|S3_ENDPOINT_URL="https://s3.corp.example"|' \
      -e 's|^S3_BUCKET=.*|S3_BUCKET="snap"|' \
      -e 's|^LOOKER_EGRESS_CIDRS=.*|LOOKER_EGRESS_CIDRS="10.20.0.0/16"|' \
      -e 's|^LOOKER_SECCOMP_PROFILE=.*|LOOKER_SECCOMP_PROFILE="RuntimeDefault"|' \
      -e 's|^LOOKER_CHROMIUM_NO_SANDBOX=.*|LOOKER_CHROMIUM_NO_SANDBOX="true"|' \
      -e "s|^GATEWAY_IMAGE=.*|GATEWAY_IMAGE=\"python:3.12-slim@${dig}\"|" \
      -e "s|^AGENT_BASE_IMAGE=.*|AGENT_BASE_IMAGE=\"python:3.12-slim@${dig}\"|" \
      -e "s|^LOOKER_BASE_IMAGE=.*|LOOKER_BASE_IMAGE=\"ubuntu:24.04@${dig}\"|" \
      -e "s|^WORKER_IMAGE=.*|WORKER_IMAGE=\"ghcr.io/agent-substrate/substrate/ateworker-gvisor:v1.0.0@${dig}\"|" \
      -e "s|^LOOKER_MYSQL_IMAGE=.*|LOOKER_MYSQL_IMAGE=\"mysql:8.4@${dig}\"|" \
      -e "s|^BUSYBOX_IMAGE=.*|BUSYBOX_IMAGE=\"busybox:1.36@${dig}\"|" \
      -e "s|^TOKEN_REFRESHER_IMAGE=.*|TOKEN_REFRESHER_IMAGE=\"gcr.io/google.com/cloudsdktool/google-cloud-cli:slim@${dig}\"|" \
      -e 's|^SECURITY_MODE=.*|SECURITY_MODE="strict"|' > "${work}/${sample}.env"
    extra_args=(--strict --worker-node-selector="ate.dev/sandbox-nodes=true" --image-pull-secret="looker-pull")
  else
    sample_config "$sample" > "${work}/${sample}.env"
  fi
  if ! CONFIG_FILE="${work}/${sample}.env" WORK_DIR="${work}/${sample}" LOOKER_LICENSE_KEY=example \
      bash ./deploy.sh render > "${work}/${sample}.log" 2>&1; then
    tail -n 5 "${work}/${sample}.log"
    return 1
  fi
  python3 tests/check_rendered.py ${extra_args[@]+"${extra_args[@]}"} \
    "${CACHE}/ateapi.proto" "${CACHE}/workerpools.yaml" "${work}/${sample}/rendered"
}

if ! python3 -c 'import yaml' 2>/dev/null; then
  skipped+=("schema check: this python3 has no PyYAML (pip install pyyaml)")
elif ! fetch_definitions; then
  skipped+=("schema check: could not download Substrate's API definitions from GitHub")
else
  work="$(mktemp -d)"
  for sample in onprem external gke full strict; do
    attempt "sample '${sample}' renders and matches the API definitions" render_and_check "$sample" "$work"
  done
  rm -rf "$work"
fi

printf '\n===== summary =====\n'
if [ "${#skipped[@]}" -gt 0 ]; then
  for item in "${skipped[@]}"; do printf 'SKIPPED  %s\n' "$item"; done
fi
if [ "${#failed[@]}" -gt 0 ]; then
  for item in "${failed[@]}"; do printf 'FAILED   %s\n' "$item"; done
  exit 1
fi
if [ "${#skipped[@]}" -gt 0 ]; then
  printf 'Everything that ran passed, but some checks were skipped.\n'
  exit 3
fi
printf 'All local checks passed. None of them touch a cluster, Looker or a model.\n'

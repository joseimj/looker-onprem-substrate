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

# Runs deploy.sh from start to finish against stub tools (tests/fakebin). This
# checks the script's own control flow: order of steps, arguments, idempotency,
# exit codes and where secrets end up. It says nothing about how the real
# kubectl, ate-setup, docker, gcloud or Looker behave.
#
# Run:  bash tests/deploy_dry_run_test.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# The stub tools are found through PATH, which wants them executable. They are
# run from a copy with the bits set, so that the test does not depend on how
# the repository was checked out.
BIN="$ROOT/fakebin"; cp -R "$KIT/tests/fakebin" "$BIN"; chmod +x "$BIN"/*
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has()  { if grep -q -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 (no '$2' in $(basename "$3"))"; fi; }
hasnt(){ if grep -q -- "$2" "$3" 2>/dev/null; then bad "$1 (found '$2' in $(basename "$3"))"; else ok "$1"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

run_command() { # run_command NAME COMMAND [VAR=value...]: deploy.sh COMMAND in world $W; prints the exit code
  local name="$1" command="$2"; shift 2
  ( export PATH="$BIN:$PATH" FAKE_STATE="$W/state" FAKE_LOG="$W/calls.log" CONFIG_FILE="$W/config.env" WORK_DIR="$W/work" VERIFY_LOCAL_PORT=18999
    env "$@" bash "$KIT/deploy.sh" "$command" > "$W/out-$name.txt" 2>&1 ); echo $?
}
run() { local name="$1"; shift; run_command "$name" all "$@"; }  # the whole script
new_world() { W="$ROOT/$1"; rm -rf "$W"; mkdir -p "$W/state"; : > "$W/calls.log"; }
# Made-up values that stand in for real secrets. The checks look for them in
# the places where a secret must never show up.
SECRETS=(LICENSE-KEY-1234 L00kerApiSecretValue sk-ant-secret-key S3SecretKeyValue)
no_secret_in_argv() { local s; for s in "${SECRETS[@]}"; do hasnt "$1: '$s' never appears in a command line" "$s" "$W/calls.log"; done; }

echo "== 1. on-prem, brand-new Looker: first run stops for API credentials"
new_world onprem; sample_config onprem > "$W/config.env"; echo "placeholder" > "$W/sa-key.json"; echo 'GCP_SA_KEY_FILE="'"$W"'/sa-key.json"' >> "$W/config.env"
rc="$(run first LOOKER_LICENSE_KEY=LICENSE-KEY-1234)"
eq "exit code says 'paused', not success" "$rc" "2"
has "explains what is needed" "PAUSED: the agent needs Looker API credentials" "$W/out-first.txt"
has "first run tells admin to remove looker-provision" "delete secret looker-provision" "$W/out-first.txt"
hasnt "embed SSO step omitted in plain link mode" "Embed SSO Authentication" "$W/out-first.txt"
has "NetworkPolicy preflight ran" "looker-agent-netpol-check" "$W/calls.log"
has "NetworkPolicy preflight uses python3 probe" "socket.create_server" "$W/state/applied-stdin.log"
hasnt "NetworkPolicy preflight does not rely on BusyBox nc -lk" "nc -lk" "$W/state/applied-stdin.log"
has "Looker manifests applied" "kind: StatefulSet" "$W/state/applied-looker.yaml"
has "Looker MySQL probes enforce TLS" "--ssl-mode=REQUIRED" "$W/state/applied-looker.yaml"
has "Looker mounts DB credentials YAML from Secret" "--internal-db-creds=/run/looker-db/looker-db.yml" "$W/state/applied-looker.yaml"
has "Looker configures heap percentage env" "name: LOOKER_HEAP_PERCENT" "$W/state/applied-looker.yaml"
looker_env="$(python3 -c 'import sys,yaml; d=[x for x in yaml.safe_load_all(open(sys.argv[1])) if x and x.get("kind")=="Deployment" and x["metadata"]["name"]=="looker"][0]; print(",".join(e["name"] for e in d["spec"]["template"]["spec"]["containers"][0]["env"]))' "$W/state/applied-looker.yaml")"
eq "Looker container env holds no DB credentials" "$looker_env" "LKR_MASTER_KEY_ENV,LOOKER_HEAP_PERCENT,POD_IP"
has "Looker default-deny applied" "name: default-deny" "$W/state/applied-looker.yaml"
has "license reaches Looker through a Secret" "created looker/looker-provision" "$W/state/secrets.log"
has "encryption key Secret created" "created looker/looker-secrets" "$W/state/secrets.log"
has "DB credentials Secret created" "created looker/looker-db-creds" "$W/state/secrets.log"
bundled_db="$(jq -r '.data["looker-db.yml"]' "$W/state/secret-looker-looker-db-creds" | base64 -d)"
eq "bundled DB YAML enables ssl without verify_ssl" "$(python3 -c 'import sys,yaml; d=yaml.safe_load(sys.argv[1]); print(d["host"], d.get("ssl"), d.get("verify_ssl"))' "$bundled_db")" "looker-mysql.looker.svc.cluster.local True None"
has "Looker image built from the downloaded JARs" "looker.jar" "$W/state/build-context-looker.txt"
has "Looker build passes BASE_IMAGE" "--build-arg BASE_IMAGE=ubuntu:24.04" "$W/calls.log"
has "chromium sandbox arg passed to Looker build" "CHROMIUM_NO_SANDBOX=false" "$W/calls.log"
eq "download request carries the version" "$(jq -r .specific "$W/state/looker-download-request.json")" "looker-26.6-latest.jar"
[ -e "$W/work/build/looker" ] && bad "licensed JARs left in the work directory" || ok "licensed JARs removed after the build"
has "Substrate installed with the local-cluster profile" " --kind" "$W/state/ate-setup.log"
has "prebuilt release images" "--image-repo ghcr.io/agent-substrate/substrate --image-tag v1.0.0" "$W/state/ate-setup.log"
has "gVisor only" "--sandbox-classes=gvisor" "$W/state/ate-setup.log"
has "credential provider selected" '--credential-provider={"name":"k8s.io"}' "$W/state/ate-setup.log"
has "gateway is on the router allowlist" "--ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/looker-agent-gateway/sa/looker-agent-gateway" "$W/state/ate-setup.log"
hasnt "kubectl ate proxy identity omitted by default" "atenet-client" "$W/state/ate-setup.log"
has "bundled store login replaced" "PATCH ate-system deployment rustfs" "$W/state/patches.log"
has "bundled store Secret created" "created ate-system/ate-objectstore-s3" "$W/state/secrets.log"
has "no Google Cloud settings leak into the on-prem install" "ENV PROJECT_ID=<unset>" "$W/state/ate-setup.log"
hasnt "agent image not built yet" "docker build.*looker-agent:" "$W/calls.log"
hasnt "no actor yet" "create actor" "$W/calls.log"
eq "no temp directories with secrets left behind" "$(find "$W/work" -maxdepth 1 -name 'tmp.*' -o -name 'looker-kit.*' | wc -l | tr -d ' ')" "0"
[ -s "$W/state/environment-leaks.log" ] && bad "secret leaked to tool env: $(cat "$W/state/environment-leaks.log")" || ok "first run: no secret in tool environments"
no_secret_in_argv "first run"

echo "== 2. second run, with Looker API credentials: deploys the agent"
echo 'LOOKER_CLIENT_ID="abcdefghij0123456789"' >> "$W/config.env"; : > "$W/calls.log"
rc="$(run second LOOKER_CLIENT_SECRET=L00kerApiSecretValue)"
eq "exit code 0" "$rc" "0"
hasnt "Substrate is not reinstalled" "go run ./cmd/ate-setup" "$W/calls.log"
hasnt "Looker image is not rebuilt" "docker build.*looker:26.6" "$W/calls.log"
has "agent image built with base image and provider" "docker build --platform linux/amd64 --build-arg BASE_IMAGE=python:3.12-slim --build-arg AGENT_MODEL_PROVIDER=claude" "$W/calls.log"
has "warns when requirements.lock has no pinned packages" "requirements.lock has no pinned packages yet" "$W/out-second.txt"
has "worker pool applied" "kind: WorkerPool" "$W/state/applied-worker-pool.yaml"
has "warns when WORKER_NODE_SELECTOR is empty" "WORKER_NODE_SELECTOR is empty" "$W/out-second.txt"
tmpl="$(ls "$W/state" | grep '^template-' | sed 's/^template-//')"
eq "exactly one template" "$(printf '%s\n' "$tmpl" | wc -l | tr -d ' ')" "1"
has "template pins the image by digest" "image: registry.corp.example/looker-agent/looker-agent@sha256:" "$W/state/template-$tmpl"
has "template drops capabilities" "drop:" "$W/state/template-$tmpl"
has "template carries the Looker secret (Substrate has no Secret refs)" "L00kerApiSecretValue" "$W/state/template-$tmpl"
has "rendered copy in .work redacts Looker secret" "REDACTED" "$W/work/rendered/actor-template.yaml"
hasnt "rendered copy in .work has no Looker secret" "L00kerApiSecretValue" "$W/work/rendered/actor-template.yaml"
has "plain link mode passed to actor" "name: LOOKER_LINK_MODE" "$W/work/rendered/actor-template.yaml"
has "developer UI off in actor" "value: 'false'" "$W/work/rendered/actor-template.yaml"
eq "actor points at that template" "$(cat "$W/state/actor-looker-agent")" "$tmpl"
has "egress policy: Looker passthrough" "looker-api.looker.svc.cluster.local" "$W/state/egress-looker-agent"
has "egress policy: model host" "us-east5-aiplatform.googleapis.com" "$W/state/egress-looker-agent"
has "credentials namespace default-deny applied" "name: default-deny" "$W/state/applied-credentials-namespace.yaml"
has "token refresher applied" "name: vertex-token-refresher" "$W/state/applied-token-refresher.yaml"
has "service account key stored outside the sandbox" "created looker-agent-creds/gcp-service-account-key" "$W/state/secrets.log"
has "gateway applied" "podCertificate" "$W/state/applied-gateway.yaml"
has "gateway passes MAX_RUNNING_JOBS" "name: MAX_RUNNING_JOBS" "$W/state/applied-gateway.yaml"
has "gateway passes JOB_DEADLINE_SECONDS" "name: JOB_DEADLINE_SECONDS" "$W/state/applied-gateway.yaml"
has "gateway default-deny applied" "name: default-deny" "$W/state/applied-gateway.yaml"
has "verification ran" "the agent answered /readyz" "$W/out-second.txt"
has "summary printed" "SETUP COMPLETE" "$W/out-second.txt"
order="$(grep -n -E 'create atespace|create actor-template|create actor looker-agent|create egress-policy' "$W/calls.log" | sed -E 's/.*(create [a-z-]+).*/\1/' | tr '\n' ',')"
eq "atespace, template, actor, then policy" "$order" "create atespace,create actor-template,create actor,create egress-policy,"
eq "rendered template is private" "$(stat -c %a "$W/work/rendered/actor-template.yaml")" "600"
eq "no temp directories with secrets left behind" "$(find "$W/work" -maxdepth 1 -name 'tmp.*' -o -name 'looker-kit.*' | wc -l | tr -d ' ')" "0"
[ -s "$W/state/environment-leaks.log" ] && bad "secret leaked to tool env: $(cat "$W/state/environment-leaks.log")" || ok "second run: no secret in tool environments"
no_secret_in_argv "second run"
hasnt "secret is not printed to the terminal" "L00kerApiSecretValue" "$W/out-second.txt"
has "administrator credential stored" "created looker-agent-gateway/looker-agent-gateway-auth" "$W/state/secrets.log"
has "chat credential stored separately" "created looker-agent-gateway/looker-agent-gateway-chat-auth" "$W/state/secrets.log"
has "gateway mounts the chat credential as a file" "secretName: looker-agent-gateway-chat-auth" "$W/state/applied-gateway.yaml"
has "gateway restarted so that it reads the new credentials" "rollout restart deployment/looker-agent-gateway" "$W/calls.log"
has "verification shows the chat credential is confined" "the chat credential is kept out of the agent's developer API" "$W/out-second.txt"
has "Looker is given the chat credential" "printf '%s:%s'.*get secret looker-agent-gateway-chat-auth .*get secret looker-agent-gateway-chat-auth " "$W/out-second.txt"
hasnt "Looker is not given the administrator's" "printf '%s:%s'.*get secret looker-agent-gateway-auth " "$W/out-second.txt"
hasnt "neither gateway password is printed" "chatpw" "$W/out-second.txt"
has "step 8 prepares the Looker extension" "STEP 8: Prepare the Looker extension" "$W/out-second.txt"
has "the admin is told which user attribute to create" "Name              looker_agent_chat_gateway_credential" "$W/out-second.txt"
has "a deployment does not pretend the bundle exists" "bundle.js is not built yet" "$W/out-second.txt"
hasnt "a deployment does not run npm" "^npm" "$W/calls.log"
has "extension project is ready to build" 'transport: "server"' "$W/work/looker-extension/src/deployment.js"
hasnt "gateway password is not printed" "gatewaypw" "$W/out-second.txt"
eq "no site may call the gateway from a browser by default" "$(grep -A1 'name: CORS_ALLOWED_ORIGINS' "$W/state/applied-gateway.yaml" | tail -1 | tr -d ' ')" 'value:""'

echo "== 3. third run, nothing changed: nothing is recreated"
: > "$W/calls.log"
rc="$(run third LOOKER_CLIENT_SECRET=L00kerApiSecretValue)"
eq "exit code 0" "$rc" "0"
hasnt "template not recreated" "create actor-template" "$W/calls.log"
hasnt "gateway credentials are kept, not regenerated" "create secret generic looker-agent-gateway" "$W/calls.log"
hasnt "gateway is not restarted for nothing" "rollout restart deployment/looker-agent-gateway" "$W/calls.log"
hasnt "actor not recreated" "create actor looker-agent" "$W/calls.log"
hasnt "actor not moved" "update actor" "$W/calls.log"
has "egress policy updated in place on rerun" "update egress-policy looker-agent" "$W/calls.log"
hasnt "egress policy not deleted on rerun" "delete egress-policy looker-agent" "$W/calls.log"
eq "still one template" "$(ls "$W/state" | grep -c '^template-')" "1"

: > "$W/calls.log"
rc="$(run rotate LOOKER_CLIENT_SECRET=L00kerApiSecretValue GATEWAY_CHAT_AUTH_PASSWORD=NewChatPassw0rd16)"
eq "a chat password given by the operator: exit code 0" "$rc" "0"
has "chat credential replaced" "replaced looker-agent-gateway/looker-agent-gateway-chat-auth" "$W/state/secrets.log"
hasnt "administrator credential left alone" "replaced looker-agent-gateway/looker-agent-gateway-auth" "$W/state/secrets.log"
has "gateway restarted for the new password" "rollout restart deployment/looker-agent-gateway" "$W/calls.log"
hasnt "the given password never appears in a command line" "NewChatPassw0rd16" "$W/calls.log"
hasnt "the given password is not printed" "NewChatPassw0rd16" "$W/out-rotate.txt"

: > "$W/calls.log"
echo "rotated-sa-key" > "$W/sa-key.json"
rc="$(run rotatekey LOOKER_CLIENT_SECRET=L00kerApiSecretValue)"
eq "replacing service account key: exit code 0" "$rc" "0"
has "token refresher restarted for the new key" "rollout restart deployment/vertex-token-refresher" "$W/calls.log"

echo "== 4. changed setting: new template, actor moved, superseded template deleted"
: > "$W/calls.log"; sed -i 's|^CLAUDE_MODEL=.*|CLAUDE_MODEL="claude-other"|' "$W/config.env"
rc="$(run fourth LOOKER_CLIENT_SECRET=L00kerApiSecretValue)"
eq "exit code 0" "$rc" "0"
has "old template deleted" "delete actor-template looker-agent-" "$W/calls.log"
eq "only the current template remains" "$(ls "$W/state" | grep -c '^template-')" "1"
has "running actor suspended before the move" "suspend actor looker-agent -a looker-agent --mode=sync" "$W/calls.log"
has "actor moved" "update actor looker-agent --template=looker-agent-" "$W/calls.log"

echo "== 5. on-prem, existing Looker, Anthropic API, own S3 store"
new_world external; sample_config external > "$W/config.env"
rc="$(run only LOOKER_CLIENT_SECRET=L00kerApiSecretValue ANTHROPIC_API_KEY=sk-ant-secret-key S3_ACCESS_KEY_ID=AKIAEXAMPLE S3_SECRET_ACCESS_KEY=S3SecretKeyValue)"
eq "exit code 0 in a single run" "$rc" "0"
[ -e "$W/state/applied-looker.yaml" ] && bad "Looker must not be deployed" || ok "Looker is not deployed"
has "bucket passed to the installer" "--storage-bucket-name=substrate-snapshots" "$W/state/ate-setup.log"
eq "both object-store sidecars repointed" "$(sort "$W/state/patches.log" | tr '\n' ';')" "PATCH ate-system daemonset atelet;PATCH ate-system deployment ate-api-server;"
has "bundled store scaled to zero when S3 is used" "scale deployment/rustfs --replicas=0" "$W/calls.log"
has "egress policy: Looker host" "looker.corp.example" "$W/state/egress-looker-agent"
has "egress policy: Looker port" "19999" "$W/state/egress-looker-agent"
has "egress policy: Anthropic" "api.anthropic.com" "$W/state/egress-looker-agent"
has "API key header" "header: x-api-key" "$W/state/egress-looker-agent"
hasnt "no Bearer prefix for an API key" "prefix:" "$W/state/egress-looker-agent"
[ -e "$W/state/applied-token-refresher.yaml" ] && bad "no token refresher expected" || ok "no token refresher for an API key"
tmpl="$(ls "$W/state" | grep '^template-' | sed 's/^template-//')"
has "agent gets a placeholder, not the key" "placeholder-replaced-by-the-substrate-egress-gateway" "$W/state/template-$tmpl"
hasnt "real model key is not in the template" "sk-ant-secret-key" "$W/state/template-$tmpl"
has "TLS verification on for an external Looker" "name: LOOKERSDK_VERIFY_SSL" "$W/state/template-$tmpl"
eq "LOOKERSDK_VERIFY_SSL value" "$(grep -A1 'name: LOOKERSDK_VERIFY_SSL' "$W/state/template-$tmpl" | tail -1 | tr -d " '")" "value:true"
no_secret_in_argv "external"
eq "no temp directories with secrets left behind" "$(find "$W/work" -maxdepth 1 -name 'tmp.*' -o -name 'looker-kit.*' | wc -l | tr -d ' ')" "0"
has "extension skipped, with the reason, when Looker cannot reach the gateway" "the Looker extension was not prepared" "$W/out-only.txt"
[ -e "$W/work/looker-extension" ] && bad "extension must not be rendered without a gateway address" || ok "nothing rendered for the extension"
rc="$(run_command noaddress extension)"; eq "'extension' refuses to build without a gateway address" "$rc" "1"
has "says which setting is missing" "Set EXTENSION_SERVER_GATEWAY_URL" "$W/out-noaddress.txt"
sed -i 's|^EXTENSION_SERVER_GATEWAY_URL=.*|EXTENSION_SERVER_GATEWAY_URL="https://agent.corp.example/"|' "$W/config.env"
rc="$(run_command extfiles extension-files)"; eq "'extension-files' prepares files without npm" "$rc" "0"
hasnt "extension-files does not run npm" "^npm" "$W/calls.log"
rc="$(run_command address extension)"; eq "with an address it builds" "$rc" "0"
has "address used as given, trailing slash dropped" 'serverGatewayUrl: "https://agent.corp.example",' "$W/work/looker-extension/lookml/bundle.js"
has "user attribute may only be sent to that address" "Domain Allowlist  https://agent.corp.example/\*" "$W/out-address.txt"

echo "== 6. GKE, Gemini on Vertex AI"
new_world gke; sample_config gke > "$W/config.env"
rc="$(run only LOOKER_CLIENT_SECRET=L00kerApiSecretValue LOOKER_LICENSE_KEY=LICENSE-KEY-1234)"
eq "exit code 0" "$rc" "0"
has "cluster bootstrap ran" "ENV CLUSTER_NAME=looker-agent" "$W/state/setup-gcp.log"
has "cluster version 1.37" "ENV CLUSTER_VERSION=1.37" "$W/state/setup-gcp.log"
has "no nested virtualization (gVisor only)" "ENV ENABLE_NESTED_VIRTUALIZATION=false" "$W/state/setup-gcp.log"
has "snapshot bucket named" "ENV BUCKET_NAME=looker-agent-snap-my-vertex-project" "$W/state/setup-gcp.log"
hasnt "GKE install does not use the local-cluster profile" " --kind" "$W/state/ate-setup.log"
has "control plane kept off worker nodes" "--cordon-system-infra-components" "$W/state/ate-setup.log"
has "installer told where snapshots go" "ENV SNAPSHOT_LOCATION=gs://looker-agent-snap-my-vertex-project/" "$W/state/ate-setup.log"
has "installer told the transfer account" "ENV SNAPSHOT_TRANSFER_GSA_NAME=ate-snapshot-transfer" "$W/state/ate-setup.log"
has "context derived from the cluster" "--context=gke_my-vertex-project_us-central1-a_looker-agent" "$W/state/ate-setup.log"
has "atelet may pull the agent image" "subject/ns/ate-system/sa/atelet --role=roles/artifactregistry.reader" "$W/calls.log"
has "custom IAM role created with single permission" "iam roles create lookerAgentModelCalls --project=my-vertex-project .*--permissions=aiplatform.endpoints.predict" "$W/calls.log"
has "token refresher uses Workload Identity with custom role" "subject/ns/looker-agent-creds/sa/vertex-token-refresher --role=projects/my-vertex-project/roles/lookerAgentModelCalls" "$W/calls.log"
hasnt "no broad Vertex role" "roles/aiplatform.user" "$W/calls.log"
hasnt "no service account key on GKE" "gcp-service-account-key" "$W/state/applied-token-refresher.yaml"
has "egress policy: Gemini region host" "us-central1-aiplatform.googleapis.com" "$W/state/egress-looker-agent"
has "kubectl-ate given the kit's kubeconfig" "ate --kubeconfig $W/work/kubeconfig --context gke_my-vertex-project_us-central1-a_looker-agent" "$W/calls.log"
no_secret_in_argv "gke"
# GKE follow-up: separate LOOKER_REGISTRY and soft-deleted custom IAM role.
sed -i 's|^LOOKER_REGISTRY=.*|LOOKER_REGISTRY="us-central1-docker.pkg.dev/my-vertex-project/looker-only"|' "$W/config.env"
: > "$W/state/role-soft-deleted"; : > "$W/calls.log"
rc="$(run gke2 LOOKER_CLIENT_SECRET=L00kerApiSecretValue LOOKER_LICENSE_KEY=LICENSE-KEY-1234)"
eq "GKE rerun with LOOKER_REGISTRY and soft-deleted role: exit code 0" "$rc" "0"
has "separate LOOKER_REGISTRY repo created" "artifacts repositories create looker-only" "$W/calls.log"
has "node SA granted reader on LOOKER_REGISTRY" "add-iam-policy-binding looker-only .*--member=serviceAccount:.*--role=roles/artifactregistry.reader" "$W/calls.log"
hasnt "atelet not granted reader on LOOKER_REGISTRY" "add-iam-policy-binding looker-only .*sa/atelet" "$W/calls.log"
has "soft-deleted IAM role undeleted" "iam roles undelete lookerAgentModelCalls --project=my-vertex-project" "$W/calls.log"
hasnt "soft-deleted IAM role not recreated" "iam roles create lookerAgentModelCalls" "$W/calls.log"

echo "== 7. your own Looker image, own DB, private CA, worker placement, pull secret"
new_world byo; printf 'PRIVATE-CA-CERT\n' > "$W/corp-ca.pem"
sample_config onprem | sed -e 's|^LOOKER_IMAGE=.*|LOOKER_IMAGE="registry.corp.example/looker:26.6"|' \
  -e 's|^LOOKER_DB_HOST=.*|LOOKER_DB_HOST="mysql.corp.example"|' -e 's|^AGENT_MODEL_PROVIDER=.*|AGENT_MODEL_PROVIDER="anthropic"|' \
  -e 's|^LOOKER_CLIENT_ID=.*|LOOKER_CLIENT_ID="abcdefghij0123456789"|' -e "s|^EXTRA_CA_FILE=.*|EXTRA_CA_FILE=\"$W/corp-ca.pem\"|" \
  -e 's|^INTERNAL_TLS=.*|INTERNAL_TLS="private-ca"|' \
  -e 's|^WORKER_NODE_SELECTOR=.*|WORKER_NODE_SELECTOR="ate.dev/sandbox-nodes=true"|' \
  -e 's|^LOOKER_IMAGE_PULL_SECRET=.*|LOOKER_IMAGE_PULL_SECRET="looker-pull"|' > "$W/config.env"
rc="$(run nopass LOOKER_CLIENT_SECRET=L00kerApiSecretValue ANTHROPIC_API_KEY=sk-ant-secret-key)"
eq "external database without its password: stops" "$rc" "1"
has "says which variable is missing" "export LOOKER_DB_PASSWORD" "$W/out-nopass.txt"
rc="$(run only LOOKER_CLIENT_SECRET=L00kerApiSecretValue ANTHROPIC_API_KEY=sk-ant-secret-key LOOKER_DB_PASSWORD='Db&Pass=123!@#')"
eq "exit code 0" "$rc" "0"
hasnt "no Looker download when an image is given" "apidownload.looker.com" "$W/calls.log"
hasnt "no Looker image build" "docker build.*looker:26.6" "$W/calls.log"
has "Looker runs the given image" "image: registry.corp.example/looker:26.6" "$W/state/applied-looker.yaml"
has "Looker uses pull secret" "name: looker-pull" "$W/state/applied-looker.yaml"
has "Looker mounts internal TLS init container" "name: prepare-tls" "$W/state/applied-looker.yaml"
has "prepare-tls mounts writable /tmp" "name: looker-tls-tmp" "$W/state/applied-looker.yaml"
has "Looker uses SSL keystore" "--ssl-keystore=/app/tls/looker.jks" "$W/state/applied-looker.yaml"
has "Looker uses internal truststore" "Djavax.net.ssl.trustStore=/app/tls/cacerts" "$W/state/applied-looker.yaml"
has "internal CA created" "created looker/looker-internal-ca" "$W/state/secrets.log"
has "Looker TLS secret created" "created looker/looker-tls" "$W/state/secrets.log"
has "gateway TLS secret created" "created looker-agent-gateway/looker-agent-gateway-tls" "$W/state/secrets.log"
has "gateway serves on 443" "port: 443" "$W/state/applied-gateway.yaml"
has "extension points at https gateway" 'serverGatewayUrl: "https://looker-agent-gateway.looker-agent-gateway.svc.cluster.local",' "$W/work/looker-extension/src/deployment.js"
has "worker nodeSelector applied" "ate.dev/sandbox-nodes: 'true'" "$W/state/applied-worker-pool.yaml"
hasnt "no warning when WORKER_NODE_SELECTOR is set" "WORKER_NODE_SELECTOR is empty" "$W/out-only.txt"
hasnt "no bundled MySQL when a database is named" "kind: StatefulSet" "$W/state/applied-looker.yaml"
has "Looker points at DB credentials YAML Secret" "--internal-db-creds=/run/looker-db/looker-db.yml" "$W/state/applied-looker.yaml"
hasnt "Looker has no DB password env var" "LOOKER_DB_PASS" "$W/state/applied-looker.yaml"
ext_db="$(jq -r '.data["looker-db.yml"]' "$W/state/secret-looker-looker-db-creds" | base64 -d)"
eq "external DB YAML carries host, special-char password, ssl, verify_ssl" "$(python3 -c 'import sys,yaml; d=yaml.safe_load(sys.argv[1]); print(d["host"], d["password"], d.get("ssl"), d.get("verify_ssl"))' "$ext_db")" "mysql.corp.example Db&Pass=123!@# True True"
has "private CA is merged with EXTRA_CA_FILE in agent image build" "PRIVATE-CA-CERT" "$W/state/extra-ca-agent.pem"
has "agent image trusts Looker CA" "BEGIN CERTIFICATE" "$W/state/extra-ca-agent.pem"
tmpl="$(ls "$W/state" | grep '^template-' | sed 's/^template-//')"
eq "LOOKERSDK_VERIFY_SSL turned on under private-ca" "$(grep -A1 'name: LOOKERSDK_VERIFY_SSL' "$W/state/template-$tmpl" | tail -1 | tr -d " '")" "value:true"
hasnt "database password never in a command line" "Db&Pass=123!@#" "$W/calls.log"
hasnt "database password never in looker.yaml" "Db&Pass=123!@#" "$W/state/applied-looker.yaml"
rc="$(run_command status status)"; eq "'status' runs" "$rc" "0"
rc="$(run_command verify verify)"; eq "'verify' can be rerun on its own" "$rc" "0"
: > "$W/state/chat-not-confined"
rc="$(run_command leaky verify)"; eq "'verify' fails when the chat credential opens the developer API" "$rc" "1"
has "says what it expected" "expected HTTP 403 for the chat credential" "$W/out-leaky.txt"
rm "$W/state/chat-not-confined"
: > "$W/state/netpol-not-enforced"
rc="$(run_command npfail preflight)"; eq "preflight stops when NetworkPolicy is not enforced" "$rc" "1"
has "explains NetworkPolicy failure" "did not enforce a deny-all NetworkPolicy" "$W/out-npfail.txt"
rm "$W/state/netpol-not-enforced"

echo "== 8. configuration mistakes are refused before anything is touched"
refused() { # refused "description" "expected message" sed-expression...
  local description="$1" message="$2"; shift 2
  new_world bad; local args=(); local e; for e in "$@"; do args+=(-e "$e"); done
  sample_config onprem | sed "${args[@]}" > "$W/config.env"
  rc="$(run bad LOOKER_CLIENT_SECRET=x)"
  if [ "$rc" = "1" ] && grep -q -- "$message" "$W/out-bad.txt" && [ ! -s "$W/calls.log" ]; then ok "$description"; else bad "$description (rc=$rc, calls=$(wc -l < "$W/calls.log"), output: $(tail -1 "$W/out-bad.txt"))"; fi
}
refused "placeholder left in config" "'REGISTRY' is not set" 's|^REGISTRY=.*|REGISTRY="YOUR_REGISTRY_PATH"|'
refused "IP address as the Looker API host" "uses an IP address" 's|^LOOKER_API_URL=.*|LOOKER_API_URL="https://10.1.2.3:19999"|'
refused "two Looker replicas without shared storage" "ReadWriteMany" 's|^LOOKER_REPLICAS=.*|LOOKER_REPLICAS="2"|'
refused "unknown model provider" "AGENT_MODEL_PROVIDER must be" 's|^AGENT_MODEL_PROVIDER=.*|AGENT_MODEL_PROVIDER="openai"|'
refused "S3 store without an endpoint" "'S3_ENDPOINT_URL' is not set" 's|^SNAPSHOT_STORE=.*|SNAPSHOT_STORE="s3"|'
refused "plain http S3 store without opt-in" "plain http://" 's|^SNAPSHOT_STORE=.*|SNAPSHOT_STORE="s3"|' 's|^S3_ENDPOINT_URL=.*|S3_ENDPOINT_URL="http://s3.corp.example"|' 's|^S3_BUCKET=.*|S3_BUCKET="snap"|'
refused "uppercase namespace" "lowercase DNS label" 's|^LOOKER_NAMESPACE=.*|LOOKER_NAMESPACE="Looker"|'
refused "gateway and worker in the same namespace" "four different namespaces" 's|^GATEWAY_NAMESPACE=.*|GATEWAY_NAMESPACE="looker-agent"|'
refused "existing Looker without its URL" "needs LOOKER_API_URL" 's|^DEPLOY_LOOKER=.*|DEPLOY_LOOKER="false"|'
refused "private-ca without DEPLOY_LOOKER" "DEPLOY_LOOKER=\"true\"" 's|^INTERNAL_TLS=.*|INTERNAL_TLS="private-ca"|' 's|^DEPLOY_LOOKER=.*|DEPLOY_LOOKER="false"|' 's|^LOOKER_API_URL=.*|LOOKER_API_URL="https://looker.corp.example:19999"|'
refused "bundled MySQL 8.4 with Looker < 26.6" "Looker supports from release 26.6" 's|^LOOKER_VERSION=.*|LOOKER_VERSION="26.4"|'
refused "Looker Ingress without TLS secret" "LOOKER_INGRESS_ENABLED needs LOOKER_TLS_SECRET" 's|^LOOKER_INGRESS_ENABLED=.*|LOOKER_INGRESS_ENABLED="true"|'
refused "gateway Ingress without TLS secret" "AGENT_INGRESS_ENABLED needs AGENT_TLS_SECRET" 's|^AGENT_INGRESS_ENABLED=.*|AGENT_INGRESS_ENABLED="true"|' 's|^AGENT_HOST=.*|AGENT_HOST="agent.corp.example"|'
refused "shell command substitution in LOOKER_STARTUP_FLAGS" "LOOKER_STARTUP_FLAGS" 's|^LOOKER_STARTUP_FLAGS=.*|LOOKER_STARTUP_FLAGS="--x \$(id)"|'
refused "arm64 image build for Looker" "amd64-only" 's|^IMAGE_PLATFORM=.*|IMAGE_PLATFORM="linux/arm64"|'
refused "out-of-range LOOKER_HEAP_PERCENT" "between 10 and 90" 's|^LOOKER_HEAP_PERCENT=.*|LOOKER_HEAP_PERCENT="95"|'
refused "invalid KUBE_API_PORTS entry" "KUBE_API_PORTS" 's|^KUBE_API_PORTS=.*|KUBE_API_PORTS="70000"|'
refused "chat job cap exceeding total job cap" "GATEWAY_MAX_CHAT_RUNNING_JOBS" 's|^GATEWAY_MAX_RUNNING_JOBS=.*|GATEWAY_MAX_RUNNING_JOBS="8"|' 's|^GATEWAY_MAX_CHAT_RUNNING_JOBS=.*|GATEWAY_MAX_CHAT_RUNNING_JOBS="10"|'
refused "plain http EXTENSION_ALLOWED_LINK_ORIGINS" "EXTENSION_ALLOWED_LINK_ORIGINS" 's|^EXTENSION_ALLOWED_LINK_ORIGINS=.*|EXTENSION_ALLOWED_LINK_ORIGINS="http://docs.corp.example"|'
# Separate check for control char in LOOKER_DB_PASSWORD / LOOKER_MYSQL_IMAGE, short gateway password, strict mode
new_world bad; sample_config onprem | sed -e 's|^LOOKER_DB_HOST=.*|LOOKER_DB_HOST="mysql.corp.example"|' > "$W/config.env"
rc="$(run bad LOOKER_CLIENT_SECRET=x LOOKER_DB_PASSWORD=$'line1\nline2')"
[ "$rc" = "1" ] && grep -q "control character" "$W/out-bad.txt" && [ ! -s "$W/calls.log" ] && ok "database password with control char is refused" || bad "db password control char not refused"
new_world bad; sample_config onprem > "$W/config.env"; printf 'LOOKER_MYSQL_IMAGE="mysql:8.4\nprivileged: true"\n' >> "$W/config.env"
rc="$(run bad LOOKER_CLIENT_SECRET=x)"
[ "$rc" = "1" ] && grep -q "control character" "$W/out-bad.txt" && [ ! -s "$W/calls.log" ] && ok "newline inside setting is refused" || bad "newline not refused"
new_world bad; sample_config onprem > "$W/config.env"
rc="$(run bad LOOKER_CLIENT_SECRET=x GATEWAY_CHAT_AUTH_PASSWORD=shortpw)"
[ "$rc" = "1" ] && grep -q "shorter than 16" "$W/out-bad.txt" && [ ! -s "$W/calls.log" ] && ok "short gateway password is refused" || bad "short password not refused"
new_world bad; sample_config onprem | sed -e 's|^SECURITY_MODE=.*|SECURITY_MODE="strict"|' > "$W/config.env"
rc="$(run bad LOOKER_CLIENT_SECRET=x)"
[ "$rc" = "1" ] && grep -q 'SECURITY_MODE="strict"' "$W/out-bad.txt" && grep -q 'LOOKER_VERIFY_SSL="false"' "$W/out-bad.txt" && grep -q 'SNAPSHOT_STORE="bundled"' "$W/out-bad.txt" && grep -q 'LOOKER_BASE_IMAGE=' "$W/out-bad.txt" && grep -q 'AGENT_BASE_IMAGE=' "$W/out-bad.txt" && [ ! -s "$W/calls.log" ] && ok "SECURITY_MODE=strict refuses weak defaults and unpinned base images in one list" || bad "strict mode check failed"
new_world bad; sample_config onprem | sed -e 's|^SECURITY_MODE=.*|SECURITY_MODE="strict"|' -e 's|^LOOKER_DB_HOST=.*|LOOKER_DB_HOST="mysql.corp.example"|' -e 's|^LOOKER_DB_VERIFY_SSL=.*|LOOKER_DB_VERIFY_SSL="false"|' > "$W/config.env"
rc="$(run bad LOOKER_CLIENT_SECRET=x)"
[ "$rc" = "1" ] && grep -q 'LOOKER_DB_VERIFY_SSL="false"' "$W/out-bad.txt" && [ ! -s "$W/calls.log" ] && ok "SECURITY_MODE=strict refuses external DB with LOOKER_DB_VERIFY_SSL=false" || bad "strict mode external DB verify_ssl check failed"

refused "on-prem without accepting the development profile" "ONPREM_DEV_PROFILE_ACCEPTED is not" 's|^ONPREM_DEV_PROFILE_ACCEPTED=.*|ONPREM_DEV_PROFILE_ACCEPTED="false"|'
refused "chat and administrator under one user name" "GATEWAY_CHAT_AUTH_USER must differ" 's|^GATEWAY_CHAT_AUTH_USER=.*|GATEWAY_CHAT_AUTH_USER="agent"|'
refused "unknown extension transport" "EXTENSION_TRANSPORT must be" 's|^EXTENSION_TRANSPORT=.*|EXTENSION_TRANSPORT="websocket"|'
refused "browser transport without an address browsers can reach" "needs the gateway on an https address" 's|^EXTENSION_TRANSPORT=.*|EXTENSION_TRANSPORT="browser"|'
refused "browser transport over plain http" "must start with https://" 's|^EXTENSION_TRANSPORT=.*|EXTENSION_TRANSPORT="browser"|' 's|^EXTENSION_BROWSER_GATEWAY_URL=.*|EXTENSION_BROWSER_GATEWAY_URL="http://agent.corp.example"|'
refused "gateway address with a path" "must look like https://host" 's|^EXTENSION_SERVER_GATEWAY_URL=.*|EXTENSION_SERVER_GATEWAY_URL="https://agent.corp.example/api"|'
refused "label that would break out of the manifest" "EXTENSION_LABEL may hold" 's|^EXTENSION_LABEL=.*|EXTENSION_LABEL="Agent\\" } x {"|'
refused "project name Looker cannot turn into a user attribute" "must start with a lowercase letter" 's|^EXTENSION_PROJECT_NAME=.*|EXTENSION_PROJECT_NAME="looker-agent"|'
refused "any site allowed to call the gateway" "GATEWAY_CORS_ALLOWED_ORIGINS entries must look like" 's|^GATEWAY_CORS_ALLOWED_ORIGINS=.*|GATEWAY_CORS_ALLOWED_ORIGINS="*"|'

echo "== 9. the chat inside Looker: building the extension"
new_world ext; sample_config onprem > "$W/config.env"; E="$W/work/looker-extension"
rc="$(run_command build extension)"; eq "'extension' builds the bundle" "$rc" "0"
hasnt "it touches no cluster" "^kubectl" "$W/calls.log"
eq "install, test, build, in the prepared copy" "$(grep '^npm' "$W/calls.log" | tr '\n' ';')" "npm install --ignore-scripts --no-audit --no-fund [in looker-extension];npm test [in looker-extension];npm run build [in looker-extension];"
has "bundle built with this deployment's gateway address" 'serverGatewayUrl: "http://looker-agent-gateway.looker-agent-gateway.svc.cluster.local",' "$E/lookml/bundle.js"
has "transport defaults to Looker's server" 'transport: "server",' "$E/lookml/bundle.js"
has "manifest names the bundle" 'file: "bundle.js"' "$E/lookml/manifest.lkml"
has "manifest allows the gateway address and nothing else" 'external_api_urls: \["http://looker-agent-gateway.looker-agent-gateway.svc.cluster.local"\]$' "$E/lookml/manifest.lkml"
has "manifest asks for the one Looker API method used" 'core_api_methods: \["me"\]$' "$E/lookml/manifest.lkml"
hasnt "manifest omits use_downloads by default" "use_downloads" "$E/lookml/manifest.lkml"
has "extension id matches the user attribute" 'application: chat {' "$E/lookml/manifest.lkml"
has "project name matches the user attribute" 'project_name: "looker_agent"' "$E/lookml/manifest.lkml"
has "model file decides who sees the extension" 'connection: "YOUR_CONNECTION_NAME"' "$E/lookml/looker_agent.model.lkml"
has "admin told to fill in the connection" "replace YOUR_CONNECTION_NAME" "$W/out-build.txt"
has "admin told the user attribute" "Name              looker_agent_chat_gateway_credential" "$W/out-build.txt"
has "admin told its allowlist" "Domain Allowlist  http://looker-agent-gateway.looker-agent-gateway.svc.cluster.local/\*" "$W/out-build.txt"
has "attribute value is hidden" "Hide Values       Yes" "$W/out-build.txt"
hasnt "no 'not built yet' note after a build" "bundle.js is not built yet" "$W/out-build.txt"
has "how to pin dependency versions" "package-lock.json" "$W/out-build.txt"
left="$(ls "$KIT/looker-extension" | grep -E '^(node_modules|dist|package-lock.json|lookml)$' | tr '\n' ' ')"
eq "the kit's own folder is left alone" "$left" ""
sed -i 's|^EXTENSION_ALLOW_DOWNLOADS=.*|EXTENSION_ALLOW_DOWNLOADS="true"|' "$W/config.env"
rc="$(run_command dl extension-files)"; eq "'extension-files' with downloads opt-in" "$rc" "0"
has "manifest adds use_downloads when opted in" "use_downloads: yes" "$E/lookml/manifest.lkml"
: > "$W/calls.log"; : > "$W/state/npm-test-fails"
rc="$(run_command testfail extension)"; eq "a failing extension test stops the build" "$rc" "1"
hasnt "nothing is built after failing tests" "npm run build" "$W/calls.log"
[ -e "$E/lookml/bundle.js" ] && bad "an old bundle survives a failed build" || ok "no bundle left from before a failed build"
rm "$W/state/npm-test-fails"; : > "$W/state/npm-build-writes-nothing"
rc="$(run_command nobundle extension)"; eq "a build that writes no bundle is a failure" "$rc" "1"
has "says the bundle is missing" "was not produced" "$W/out-nobundle.txt"
rm "$W/state/npm-build-writes-nothing"; : > "$W/calls.log"
rc="$(run_command nonpm extension NPM=no-such-npm-anywhere)"; eq "without npm: stops" "$rc" "1"
has "says how to build it elsewhere" "npm install --ignore-scripts && npm test && npm run build" "$W/out-nonpm.txt"
has "the prepared project is still there to copy" 'transport: "server",' "$E/src/deployment.js"
hasnt "nothing else was run instead" "^npm" "$W/calls.log"
# A kit that carries a lock file. A copy, so the real kit is not written to.
copy="$ROOT/kit-with-lock"; mkdir -p "$copy"; cp "$KIT/deploy.sh" "$copy/"; cp -R "$KIT/looker-extension" "$copy/"
echo '{"lockfileVersion": 3}' > "$copy/looker-extension/package-lock.json"; : > "$W/calls.log"
rc="$( export PATH="$BIN:$PATH" FAKE_STATE="$W/state" FAKE_LOG="$W/calls.log" CONFIG_FILE="$W/config.env" WORK_DIR="$W/work"
       bash "$copy/deploy.sh" extension > "$W/out-locked.txt" 2>&1; echo $? )"
eq "a kit with a lock file builds" "$rc" "0"
has "the lock file makes the install exact" "npm ci --ignore-scripts --no-audit --no-fund" "$W/calls.log"
hasnt "no unpinned install when there is a lock file" "npm install" "$W/calls.log"
hasnt "no hint to keep a lock file that is already kept" "keep the lock file" "$W/out-locked.txt"

echo "== 10. the chat inside Looker: calls from the browser"
new_world extbrowser; E="$W/work/looker-extension"
sample_config full | sed -e 's|^EXTENSION_TRANSPORT=.*|EXTENSION_TRANSPORT="browser"|' \
  -e 's|^EXTENSION_LOOKML_CONNECTION=.*|EXTENSION_LOOKML_CONNECTION="warehouse"|' \
  -e 's|^KUBE_API_PORTS=.*|KUBE_API_PORTS="8443"|' \
  -e 's|^GATEWAY_MAX_RUNNING_JOBS=.*|GATEWAY_MAX_RUNNING_JOBS="12"|' \
  -e 's|^GATEWAY_MAX_CHAT_RUNNING_JOBS=.*|GATEWAY_MAX_CHAT_RUNNING_JOBS="8"|' \
  -e 's|^EXTENSION_ALLOWED_LINK_ORIGINS=.*|EXTENSION_ALLOWED_LINK_ORIGINS="https://docs.corp.example,https://wiki.corp.example"|' > "$W/config.env"
rc="$(run_command render render LOOKER_LICENSE_KEY=LICENSE-KEY-1234)"; eq "renders" "$rc" "0"
hasnt "render builds nothing" "^npm" "$W/calls.log"
has "transport is the browser" 'transport: "browser",' "$E/src/deployment.js"
has "browsers use the https address of the ingress" 'browserGatewayUrl: "https://agent.corp.example",' "$E/src/deployment.js"
has "Looker's server still uses the in-cluster address for the token" 'serverGatewayUrl: "http://looker-agent-gateway.looker-agent-gateway.svc.cluster.local",' "$E/src/deployment.js"
has "allowedLinkOrigins written to deployment.js" 'allowedLinkOrigins: \["https://docs.corp.example", "https://wiki.corp.example"\],' "$E/src/deployment.js"
has "manifest allows both addresses" 'external_api_urls: \["http://looker-agent-gateway.looker-agent-gateway.svc.cluster.local", "https://agent.corp.example"\]$' "$E/lookml/manifest.lkml"
has "manifest allows external link origins" 'new_window_external_urls: \["https://docs.corp.example/\*", "https://wiki.corp.example/\*"\]$' "$E/lookml/manifest.lkml"
has "token refresher includes custom KUBE_API_PORTS" "port: 8443" "$W/work/rendered/token-refresher.yaml"
hasnt "token refresher omits unconfigured 6443" "port: 6443" "$W/work/rendered/token-refresher.yaml"
eq "gateway MAX_RUNNING_JOBS propagated" "$(grep -A1 'name: MAX_RUNNING_JOBS' "$W/work/rendered/gateway.yaml" | tail -1 | tr -d ' ')" 'value:"12"'
eq "gateway MAX_CHAT_RUNNING_JOBS propagated" "$(grep -A1 'name: MAX_CHAT_RUNNING_JOBS' "$W/work/rendered/gateway.yaml" | tail -1 | tr -d ' ')" 'value:"8"'
eq "gateway lets the Looker page, and only it, call from a browser" "$(grep -A1 'name: CORS_ALLOWED_ORIGINS' "$W/work/rendered/gateway.yaml" | tail -1 | tr -d ' ')" 'value:"https://looker.corp.example"'
has "gateway is published for browsers" "host: agent.corp.example" "$W/work/rendered/gateway.yaml"
has "connection written into the model" 'connection: "warehouse"' "$E/lookml/looker_agent.model.lkml"

printf '\ndeploy.sh dry run: %d ok, %d FAIL\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

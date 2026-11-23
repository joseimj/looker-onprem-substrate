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

# Shared by the tests: sample configurations built from config.env.example.
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# sample_config onprem|external|gke|full
sample_config() {
  local base
  base="$(sed -e 's|^KUBE_CONTEXT=.*|KUBE_CONTEXT="onprem-cluster"|' \
      -e 's|^REGISTRY=.*|REGISTRY="registry.corp.example/looker-agent"|' \
      -e 's|^LOOKER_HOST=.*|LOOKER_HOST="looker.corp.example"|' \
      -e 's|^LOOKER_VERSION=.*|LOOKER_VERSION="26.6"|' \
      -e 's|^LOOKER_TECHNICAL_CONTACT_EMAIL=.*|LOOKER_TECHNICAL_CONTACT_EMAIL="ops@corp.example"|' \
      -e 's|^LOOKER_ADMIN_EMAIL=.*|LOOKER_ADMIN_EMAIL="ops@corp.example"|' \
      -e 's|^GCP_PROJECT_ID=.*|GCP_PROJECT_ID="my-vertex-project"|' \
      -e 's|^ONPREM_DEV_PROFILE_ACCEPTED=.*|ONPREM_DEV_PROFILE_ACCEPTED="true"|' "${KIT}/config.env.example")"
  case "$1" in
    onprem)   # new Looker on the cluster, Claude on Vertex AI
      printf '%s\n' "$base" ;;
    external) # Looker already exists, Anthropic API, your own S3 store
      printf '%s\n' "$base" | sed -e 's|^DEPLOY_LOOKER=.*|DEPLOY_LOOKER="false"|' \
        -e 's|^LOOKER_API_URL=.*|LOOKER_API_URL="https://looker.corp.example:19999"|' \
        -e 's|^AGENT_MODEL_PROVIDER=.*|AGENT_MODEL_PROVIDER="anthropic"|' \
        -e 's|^SNAPSHOT_STORE=.*|SNAPSHOT_STORE="s3"|' \
        -e 's|^S3_ENDPOINT_URL=.*|S3_ENDPOINT_URL="https://s3.corp.example"|' \
        -e 's|^S3_BUCKET=.*|S3_BUCKET="substrate-snapshots"|' \
        -e 's|^LOOKER_CLIENT_ID=.*|LOOKER_CLIENT_ID="abcdefghij0123456789"|' \
        -e 's|^GCP_PROJECT_ID=.*|GCP_PROJECT_ID=""|' ;;
    gke)      # GKE, Gemini on Vertex AI
      printf '%s\n' "$base" | sed -e 's|^PLATFORM=.*|PLATFORM="gke"|' -e 's|^KUBE_CONTEXT=.*|KUBE_CONTEXT=""|' \
        -e 's|^REGISTRY=.*|REGISTRY="us-central1-docker.pkg.dev/my-vertex-project/looker-agent"|' \
        -e 's|^AGENT_MODEL_PROVIDER=.*|AGENT_MODEL_PROVIDER="gemini"|' \
        -e 's|^LOOKER_CLIENT_ID=.*|LOOKER_CLIENT_ID="abcdefghij0123456789"|' ;;
    full)     # every optional piece switched on, to render all of it
      printf '%s\n' "$base" | sed -e 's|^LOOKER_REPLICAS=.*|LOOKER_REPLICAS="2"|' \
        -e 's|^LOOKER_STORAGE_CLASS=.*|LOOKER_STORAGE_CLASS="nfs-rwx"|' \
        -e 's|^LOOKER_INGRESS_ENABLED=.*|LOOKER_INGRESS_ENABLED="true"|' \
        -e 's|^LOOKER_TLS_SECRET=.*|LOOKER_TLS_SECRET="looker-tls"|' \
        -e 's|^AGENT_INGRESS_ENABLED=.*|AGENT_INGRESS_ENABLED="true"|' \
        -e 's|^AGENT_HOST=.*|AGENT_HOST="agent.corp.example"|' \
        -e 's|^AGENT_TLS_SECRET=.*|AGENT_TLS_SECRET="agent-tls"|' \
        -e 's|^AGENT_MODEL_PROVIDER=.*|AGENT_MODEL_PROVIDER="claude_native"|' \
        -e 's|^CLAUDE_LOCATION=.*|CLAUDE_LOCATION="global"|' \
        -e 's|^LOOKER_STARTUP_FLAGS=.*|LOOKER_STARTUP_FLAGS="--per-user-query-limit=40"|' ;;
    *) echo "unknown sample '$1'" >&2; return 1 ;;
  esac
}

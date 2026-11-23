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

# =============================================================================
#
#  WHAT THIS PROJECT DOES (read this first)
#  ----------------------------------------
#  This script takes the Looker analytics agent from the Agent Engine setup
#  script and runs it on infrastructure you operate yourself:
#
#      customer-hosted Looker   +   the agent on Agent Substrate (Kubernetes)
#
#  A business user can still ask, in plain language:
#
#      "show me the sales dashboard"   -> the agent renders it as an image
#      "how many orders are complete?" -> the agent answers with the numbers
#      "give me the link to look 9"    -> the agent returns a signed Looker URL
#
#  The script is idempotent. Run it again and it reuses what already exists.
#
#  STATUS: NOT TESTED END TO END. Nothing in here has been run against a real
#  cluster, a real Looker license or a real model endpoint. The gateway, the
#  agent's entrypoint and the Looker extension's logic have local tests
#  (gateway/test_gateway.py, agent/test_server.py, looker-extension/test/).
#  Everything else was written from the Agent Substrate v1.0.0 and Looker
#  documentation and checked only for syntax. README.md lists what to verify
#  first.
#
#  HOW IT WORKS (the end-to-end flow)
#  ----------------------------------
#      a chat inside Looker (an extension), or a browser or API client
#        -> gateway pod            (checks the caller; holds a pod certificate)
#          -> Substrate router     (wakes the agent if it is suspended)
#            -> the ADK agent      (a sandboxed Substrate "actor")
#              -> Substrate egress gateway   (allowlist + credential injection)
#                -> Looker API               (dashboards, Looks, explores, data)
#                -> the model endpoint       (Vertex AI or the Anthropic API)
#
#  What changed from the Agent Engine version, and why:
#    1. Vertex AI Agent Engine is gone. The agent is a container image now, and
#       agent/server.py serves it. Images are still returned as ADK artifacts.
#    2. Gemini Enterprise is not the front door. People chat with the agent
#       inside Looker, through the extension in looker-extension/ (step 8). The
#       ADK web UI is still there for developers, through the gateway.
#       README.md covers registering the agent over A2A later.
#    3. The model credential never enters the agent's sandbox. The agent sends
#       a placeholder and Substrate's egress gateway swaps in the real one.
#    4. The Looker API key DOES enter the sandbox, as it did on Agent Engine.
#       Looker's login takes the key in the request body, which the egress
#       gateway cannot rewrite. Use a least-privilege Looker API user.
#
#  THE STEPS THIS SCRIPT RUNS
#  --------------------------
#    -1  Validate configuration        4  Build and push the agent image
#     0  Preflight (tools, cluster)    5  Run the agent as a Substrate actor
#     1  GKE only: create the cluster  6  Deploy the gateway
#     2  Deploy customer-hosted Looker 7  Verify and print how to connect
#     3  Install Agent Substrate       8  Prepare the Looker extension (chat)
#
#  The first run on a new Looker stops after step 3: the agent needs Looker API
#  credentials, and those can only be created once Looker is up. Create them,
#  put them in config.env, and run the script again.
#
#  USAGE
#  -----
#    ./deploy.sh              run every step
#    ./deploy.sh render       write every manifest to .work/rendered and stop
#                             (touches nothing; secrets are shown as REDACTED)
#    ./deploy.sh <step>       one of: preflight gke looker substrate image
#                             agent gateway verify
#    ./deploy.sh extension    step 8, and also build the extension's bundle
#                             (needs Node.js 18+ and npm; touches no cluster)
#    ./deploy.sh extension-files
#                             step 8 without the build: the project and the
#                             LookML files only (touches no cluster)
#    ./deploy.sh status       show what is running
# =============================================================================

set -euo pipefail
# Let the ERR trap below fire inside functions and subshells too.
set -E
# The work directory holds checkouts, state and every rendered manifest. Keep
# it private.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
RENDER_ONLY="false"

# Pinned upstream sources. ate-setup reads its manifests from a checkout, so
# the checkout has to be the release being installed.
SUBSTRATE_REPO_URL="${SUBSTRATE_REPO_URL:-https://github.com/agent-substrate/substrate.git}"
SUBSTRATE_GKE_REPO_URL="${SUBSTRATE_GKE_REPO_URL:-https://github.com/ai-on-gke/substrate-gke.git}"
SUBSTRATE_GKE_REF="${SUBSTRATE_GKE_REF:-0de82014290a31321a9c9f1f6cde48b1d7f48b66}"
LOOKER_DOWNLOAD_API="https://apidownload.looker.com/download"

# What the agent sends where a credential belongs. The egress gateway discards
# it and injects the real value. It is not a secret.
PLACEHOLDER_CREDENTIAL="placeholder-replaced-by-the-substrate-egress-gateway"
TRUST_BUNDLE_DIR="/run/ate/egress-trust-bundle"
TRUST_BUNDLE_PATH="${TRUST_BUNDLE_DIR}/trust-bundle.pem"
FAKE_METADATA_ADDRESS="127.0.0.1:8087"

TMP_DIR=""
PORT_FORWARD_PID=""
NETPOL_CHECK_NS=""
LOOKER_BUILD_DIR=""

# The settings that hold a secret. They come from the environment (or from
# config.env), are checked like every other setting, are never printed, and
# are kept out of the environment of the tools this script starts.
SECRET_SETTINGS=(
  LOOKER_LICENSE_KEY LOOKER_CLIENT_SECRET LOOKER_DB_PASSWORD ANTHROPIC_API_KEY
  S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
  GATEWAY_BASIC_AUTH_PASSWORD GATEWAY_CHAT_AUTH_PASSWORD
)

# What a value may look like. Each pattern is matched against the whole value.
RE_DNS_LABEL='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
RE_DNS_NAME='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'
RE_LOOKML_NAME='^[a-z][a-z0-9_]{0,60}$'
RE_BASE_URL='^https?://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?$'
RE_NUMBER='^[0-9]+$'
RE_QUANTITY='^[0-9]+(\.[0-9]+)?(m|k|Ki|M|Mi|G|Gi|T|Ti)?$'
RE_IDENTIFIER='^[A-Za-z0-9_]+$'
RE_WORD='^[A-Za-z0-9][A-Za-z0-9._-]*$'
RE_REPOSITORY='^[a-z0-9]([a-z0-9._-]*[a-z0-9])?(:[0-9]+)?(/[a-z0-9]([a-z0-9._-]*[a-z0-9])?)*$'
RE_IMAGE='^[a-z0-9]([a-z0-9._-]*[a-z0-9])?(:[0-9]+)?(/[a-z0-9]([a-z0-9._-]*[a-z0-9])?)*(:[A-Za-z0-9_][A-Za-z0-9._-]*)?(@sha256:[0-9a-f]{64})?$'
RE_EMAIL='^[A-Za-z0-9._%+-]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
RE_CIDR='^(([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}|[0-9A-Fa-f:]+/[0-9]{1,3})$'
RE_COMMIT='^[0-9a-f]{40}$'
RE_NODE_SELECTOR='^([a-z0-9]([a-z0-9.-]*[a-z0-9])?/)?[A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?=[A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?$'

# -----------------------------------------------------------------------------
# Small helpers
# -----------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

step() {
  printf '\n==================================================\n'
  printf ' %s\n' "$*"
  printf '==================================================\n'
}

cleanup() {
  if [ -n "$PORT_FORWARD_PID" ]; then kill "$PORT_FORWARD_PID" 2>/dev/null || true; fi
  if [ -n "$NETPOL_CHECK_NS" ]; then
    k delete namespace "$NETPOL_CHECK_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    NETPOL_CHECK_NS=""
  fi
  if [ -n "$LOOKER_BUILD_DIR" ] && [ -d "$LOOKER_BUILD_DIR" ]; then
    rm -rf "$LOOKER_BUILD_DIR"
    LOOKER_BUILD_DIR=""
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
    rm -f "${STATE_DIR}/tmp-dir"
  fi
}
trap cleanup EXIT
# A command that fails under "set -e" stops the script. Say which one, so a
# failure is never silent. The tool's own message, if any, is just above it.
trap 'printf "ERROR: stopped at %s line %s: %s\n" "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND" >&2' ERR

need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but was not found in PATH."
}

is_true() { [ "$1" = "true" ]; }

# A value is "unset" when it is empty or still the YOUR_... placeholder.
is_unset() {
  case "${1:-}" in
    ""|YOUR_*) return 0 ;;
    *) return 1 ;;
  esac
}

require_var() {
  local name="$1"
  if is_unset "${!name:-}"; then
    die "configuration variable '${name}' is not set (see ${CONFIG_FILE})."
  fi
}

# Kubernetes names used here must be lowercase DNS labels.
require_dns_label() {
  local name="$1" value="${!1}"
  if ! [[ "$value" =~ $RE_DNS_LABEL ]]; then
    die "'${name}' must be a lowercase DNS label (letters, digits, '-'), got '${value}'."
  fi
}

# LookML project and application names. Looker builds the name of the user
# attribute that holds the gateway credential from them, and user attribute
# names are lowercase letters, digits and underscores.
require_lookml_name() {
  local name="$1" value="${!1}"
  if ! [[ "$value" =~ $RE_LOOKML_NAME ]]; then
    die "'${name}' must start with a lowercase letter and hold only lowercase letters, digits and '_', got '${value}'."
  fi
}

# An address of the form scheme://host[:port]. A trailing "/" is dropped; a
# path is refused, because the same value is used as a browser origin and in
# Looker's allowlists.
require_base_url() {
  local name="$1" value="${!1%/}"
  if ! [[ "$value" =~ $RE_BASE_URL ]]; then
    die "'${name}' must look like https://host[:port] (lowercase, no path), got '${!1}'."
  fi
  printf -v "$name" '%s' "$value"
}

# The checks above and below use "[[ =~ ]]", which matches a value as a whole.
# A line-by-line tool such as grep would accept a value as soon as one of its
# lines looked right, and the other lines would then be written into a
# manifest, a LookML file or JavaScript.

# is_secret_setting NAME: whether NAME holds a secret (and so must not be shown).
is_secret_setting() {
  local secret
  for secret in "${SECRET_SETTINGS[@]}"; do
    if [ "$secret" = "$1" ]; then return 0; fi
  done
  return 1
}

# require_match NAME PATTERN DESCRIPTION: the setting NAME must match PATTERN.
# DESCRIPTION completes the sentence "'NAME' must be ...".
require_match() {
  local name="$1" pattern="$2" value="${!1:-}"
  if [[ "$value" =~ $pattern ]]; then return 0; fi
  if is_secret_setting "$name"; then
    die "'${name}' must be ${3}."
  fi
  die "'${name}' must be ${3}, got '${value}'."
}

# The same, for a setting that may be left empty.
require_match_if_set() {
  if [ -n "${!1:-}" ]; then require_match "$@"; fi
}

# require_choice NAME CHOICE...: the setting NAME must be one of the choices.
require_choice() {
  local name="$1" value="${!1:-}" choice
  shift
  for choice in "$@"; do
    if [ "$value" = "$choice" ]; then return 0; fi
  done
  die "${name} must be one of: $*; got '${value}'."
}

# Switches are "true" or "false" and nothing else, so that "True" or "yes" is
# an error and not a silent "false".
require_boolean() {
  require_choice "$1" true false
}

# is_pinned_image REFERENCE: whether an image reference names its content by
# digest. A tag can be pointed at other content later; a digest cannot.
is_pinned_image() {
  [[ "$1" == *@sha256:* ]]
}

# looker_version_at_least MAJOR MINOR: compares LOOKER_VERSION ("26.6").
looker_version_at_least() {
  local major="${LOOKER_VERSION%%.*}" minor="${LOOKER_VERSION#*.}"
  [ "$major" -gt "$1" ] || { [ "$major" -eq "$1" ] && [ "$minor" -ge "$2" ]; }
}

gen_alnum() {
  # openssl output is finite, so this pipeline cannot die of SIGPIPE.
  openssl rand -base64 $(( $1 * 2 )) | tr -dc 'A-Za-z0-9' | cut -c "1-$1"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# Single-quoted YAML scalar: the only character to escape is the quote itself.
yaml_sq() {
  local value="${1//\'/\'\'}"
  printf "'%s'" "$value"
}

# Secret values are written to files here on their way into the cluster. Each
# file is removed as soon as the command that reads it has run (see "forget"),
# and the EXIT trap deletes the directory. Call this directly, never inside
# $(...): a subshell would set TMP_DIR for itself only and the files would be
# left behind.
#
# The directory goes onto memory-backed storage when the machine has some
# (XDG_RUNTIME_DIR, /dev/shm), so that a secret does not reach a disk at all.
# KIT_TMP_BASE in the environment names another place. The work directory is
# the last resort.
ensure_tmp_dir() {
  if [ -n "$TMP_DIR" ]; then return 0; fi
  local base="" candidate
  if [ -n "${KIT_TMP_BASE:-}" ]; then
    if [ ! -d "$KIT_TMP_BASE" ] || [ ! -w "$KIT_TMP_BASE" ]; then
      die "KIT_TMP_BASE '${KIT_TMP_BASE}' is not a directory this user can write to."
    fi
    base="$KIT_TMP_BASE"
  else
    for candidate in "${XDG_RUNTIME_DIR:-}" /dev/shm "$WORK_DIR"; do
      if [ -n "$candidate" ] && [ -d "$candidate" ] && [ -w "$candidate" ]; then
        base="$candidate"
        break
      fi
    done
  fi
  TMP_DIR="$(mktemp -d "${base}/looker-kit.XXXXXX")"
  # Written down, with this run's process id, so that the next run can remove
  # the directory if this one is killed before its EXIT trap runs.
  printf '%s\n%s\n' "$TMP_DIR" "$$" > "${STATE_DIR}/tmp-dir"
}

# forget FILE...: remove files that held a secret, as soon as the command that
# read them has run. The EXIT trap would remove them too, but a run can last
# an hour, and a secret should not lie around that long.
forget() {
  rm -f "$@"
}

# A run that is killed outright (SIGKILL, a crash, the power) never reaches its
# EXIT trap, and its secret files stay. Remove what an earlier run left behind.
remove_leftover_tmp_dirs() {
  local record="${STATE_DIR}/tmp-dir" leftover pid
  local own_name='^/.*/looker-kit\.[A-Za-z0-9]{6}$'
  if [ -f "$record" ]; then
    leftover="$(sed -n 1p "$record")"
    pid="$(sed -n 2p "$record")"
    if [[ "$pid" =~ $RE_NUMBER ]] && kill -0 "$pid" 2>/dev/null; then
      # Another run on this work directory is still going. Leave its files.
      return 0
    fi
    # Only ever a directory this script made: its own naming, owned by this user.
    if [[ "$leftover" =~ $own_name ]] && [ -d "$leftover" ] && [ -O "$leftover" ]; then
      rm -rf "$leftover"
      warn "removed secret files that an interrupted run left in ${leftover}."
    fi
    rm -f "$record"
  fi
  # Earlier versions of this script kept them in the work directory.
  for leftover in "${WORK_DIR}"/tmp.??????; do
    if [ -d "$leftover" ] && [ -O "$leftover" ]; then
      rm -rf "$leftover"
      warn "removed secret files that an interrupted run left in ${leftover}."
    fi
  done
}

k() { kubectl --context "$KUBE_CONTEXT" "$@"; }

kate() {
  # On GKE the kit uses its own kubeconfig; name it for the plugin explicitly.
  if [ -n "${KIT_KUBECONFIG:-}" ]; then
    kubectl ate --kubeconfig "$KIT_KUBECONFIG" --context "$KUBE_CONTEXT" "$@"
  else
    kubectl ate --context "$KUBE_CONTEXT" "$@"
  fi
}

kapply() {
  k apply -f "$1"
}

secret_exists() {
  k -n "$1" get secret "$2" >/dev/null 2>&1
}

# namespace_manifest NAME ENFORCE [REPORT]: a Namespace with its Pod Security
# level. "enforce" refuses pods that ask for more than the level allows.
# "audit" and "warn" only report; they may name a stricter level than the one
# enforced, to show what still stands between the namespace and that level.
namespace_manifest() {
  local name="$1" enforce="$2" report="${3:-$2}"
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${name}
  labels:
    pod-security.kubernetes.io/enforce: ${enforce}
    pod-security.kubernetes.io/audit: ${report}
    pod-security.kubernetes.io/warn: ${report}
EOF
}

# ensure_namespace NAME ENFORCE [REPORT]: Secrets have to exist before the
# manifest that uses them is applied, so the namespace is made first, and
# already with its Pod Security level.
ensure_namespace() {
  namespace_manifest "$@" | k apply -f - >/dev/null
}

# netpol_default_deny NAMESPACE: the policy every namespace of this kit starts
# from. The allow rules are separate policies in the same file, so that the
# deny never arrives without them.
netpol_default_deny() {
  cat <<EOF
---
# Nothing reaches a pod in this namespace, and no pod in it reaches anything,
# unless a policy below says so.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: $1
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
}

# The egress rule for name lookups. It names no destination on purpose: a
# node-local DNS cache answers on an address that no pod label selects.
netpol_dns_egress() {
  cat <<'EOF'
  # Name lookups, wherever the cluster answers them.
  - ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
EOF
}

# apply_secret_manifest NAMESPACE NAME WANTED_JSON: compares data against any
# existing Secret and writes only on change. Sets SECRET_CHANGE to "created",
# "replaced" or "unchanged".
apply_secret_manifest() {
  local namespace="$1" name="$2" wanted="$3" current
  if current="$(k -n "$namespace" get secret "$name" -o json 2>/dev/null)"; then
    if [ "$(printf '%s' "$current" | jq -cS '.data // {}')" = "$(printf '%s' "$wanted" | jq -cS '.data // {}')" ]; then
      SECRET_CHANGE="unchanged"
      return 0
    fi
    # "replace", not "apply": apply would keep a copy of the whole object,
    # values included, in an annotation of the Secret.
    printf '%s' "$wanted" | k -n "$namespace" replace -f - >/dev/null
    SECRET_CHANGE="replaced"
  else
    printf '%s' "$wanted" | k -n "$namespace" create -f - >/dev/null
    SECRET_CHANGE="created"
  fi
}

# create_or_replace_secret NAMESPACE NAME KEY=FILE...
# Leaves a Secret that is already as it should be alone. Sets SECRET_CHANGE to
# "created", "replaced" or "unchanged", so that the caller can restart whatever
# read the old value.
create_or_replace_secret() {
  local namespace="$1" name="$2" args=() pair wanted
  shift 2
  for pair in "$@"; do
    args+=("--from-file=${pair}")
  done
  # The Secret as it should be. kubectl builds it from the files, so no value
  # is ever an argument of a command.
  wanted="$(k -n "$namespace" create secret generic "$name" "${args[@]}" --dry-run=client -o json)"
  apply_secret_manifest "$namespace" "$name" "$wanted"
}

# create_or_replace_tls_secret NAMESPACE NAME CERT_FILE KEY_FILE
create_or_replace_tls_secret() {
  local namespace="$1" name="$2" cert="$3" key="$4" wanted
  wanted="$(k -n "$namespace" create secret tls "$name" "--cert=${cert}" "--key=${key}" --dry-run=client -o json)"
  apply_secret_manifest "$namespace" "$name" "$wanted"
}

# Private CA and server certificates for INTERNAL_TLS="private-ca". The CA key
# stays in Secret ${LOOKER_NAMESPACE}/looker-internal-ca; files exist only in
# TMP_DIR for the commands that read or sign with them.
ensure_internal_ca() {
  if secret_exists "$LOOKER_NAMESPACE" looker-internal-ca; then
    return 0
  fi
  local tmp
  ensure_tmp_dir; tmp="$TMP_DIR"
  cat > "${tmp}/ca.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no

[dn]
CN = looker-kit-internal-ca

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
EOF
  openssl genrsa -out "${tmp}/ca.key" 2048 2>/dev/null
  openssl req -x509 -new -nodes -key "${tmp}/ca.key" -sha256 -days 3650 \
    -config "${tmp}/ca.cnf" -out "${tmp}/ca.crt"
  create_or_replace_secret "$LOOKER_NAMESPACE" looker-internal-ca \
    "ca.crt=${tmp}/ca.crt" "ca.key=${tmp}/ca.key"
  forget "${tmp}/ca.cnf" "${tmp}/ca.key" "${tmp}/ca.crt"
  log "Created private CA in Secret ${LOOKER_NAMESPACE}/looker-internal-ca."
}

read_internal_ca_cert() {
  local cert
  cert="$(k -n "$LOOKER_NAMESPACE" get secret looker-internal-ca -o 'jsonpath={.data.ca\.crt}' 2>/dev/null | base64 -d || true)"
  [ -n "$cert" ] || die "Secret ${LOOKER_NAMESPACE}/looker-internal-ca was not found. Deploy or render Looker first (./deploy.sh looker)."
  printf '%s' "$cert"
}

internal_cert_current() {
  local namespace="$1" secret="$2" tmp existing
  shift 2
  if ! secret_exists "$namespace" "$secret"; then return 1; fi
  ensure_tmp_dir; tmp="$TMP_DIR"
  read_internal_ca_cert > "${tmp}/ca.crt"
  existing="$(k -n "$namespace" get secret "$secret" -o 'jsonpath={.data.tls\.crt}' 2>/dev/null | base64 -d || true)"
  printf '%s' "$existing" > "${tmp}/existing.crt"
  if [ -n "$existing" ] && openssl verify -CAfile "${tmp}/ca.crt" "${tmp}/existing.crt" >/dev/null 2>&1 \
      && cert_has_sans "$existing" "$@"; then
    forget "${tmp}/ca.crt" "${tmp}/existing.crt"
    return 0
  fi
  forget "${tmp}/ca.crt" "${tmp}/existing.crt"
  return 1
}

cert_has_sans() {
  local pem="$1" sans
  shift
  sans=",$(printf '%s' "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr '\n' ',' | tr -d ' '),"
  local host
  for host in "$@"; do
    case "$sans" in
      *",DNS:${host},"*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# issue_internal_cert CN OUT_CRT OUT_KEY APPEND_CA SAN...
# Writes the signed leaf certificate (plus CA chain when APPEND_CA=true) to
# OUT_CRT and the private key to OUT_KEY. The caller removes both and ca.key.
issue_internal_cert() {
  local cn="$1" out_crt="$2" out_key="$3" append_ca="$4" tmp san_list="" host
  shift 4
  ensure_tmp_dir; tmp="$TMP_DIR"
  read_internal_ca_cert > "${tmp}/ca.crt"
  k -n "$LOOKER_NAMESPACE" get secret looker-internal-ca -o 'jsonpath={.data.ca\.key}' | base64 -d > "${tmp}/ca.key"
  for host in "$@"; do
    san_list="${san_list:+${san_list},}DNS:${host}"
  done
  cat > "${tmp}/ext.cnf" <<EOF
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = ${san_list}
EOF
  openssl genrsa -out "$out_key" 2048 2>/dev/null
  openssl req -new -key "$out_key" -subj "/CN=${cn}" -out "${tmp}/leaf.csr"
  openssl x509 -req -in "${tmp}/leaf.csr" -CA "${tmp}/ca.crt" -CAkey "${tmp}/ca.key" \
    -CAserial "${tmp}/ca.srl" -CAcreateserial \
    -out "$out_crt" -days 825 -sha256 -extfile "${tmp}/ext.cnf" 2>/dev/null
  if [ "$append_ca" = "true" ]; then
    printf '\n' >> "$out_crt"
    cat "${tmp}/ca.crt" >> "$out_crt"
  fi
  forget "${tmp}/ca.key" "${tmp}/ext.cnf" "${tmp}/leaf.csr" "${tmp}/ca.srl"
}

# Splits a base URL into URL_SCHEME, URL_HOST and URL_PORT.
parse_url() {
  local url="$1" rest hostport
  case "$url" in
    https://*) URL_SCHEME="https"; rest="${url#https://}" ;;
    http://*)  URL_SCHEME="http";  rest="${url#http://}" ;;
    *) die "'${url}' must start with https:// or http://." ;;
  esac
  hostport="${rest%%/*}"
  case "$hostport" in
    *:*) URL_HOST="${hostport%%:*}"; URL_PORT="${hostport##*:}" ;;
    *)   URL_HOST="$hostport"
         if [ "$URL_SCHEME" = "https" ]; then URL_PORT="443"; else URL_PORT="80"; fi ;;
  esac
  if [[ "$URL_HOST" =~ ^[0-9.]+$ ]]; then
    die "'${url}' uses an IP address. Substrate egress rules match DNS names only; use a hostname."
  fi
  if ! [[ "$URL_HOST" =~ $RE_DNS_NAME ]]; then
    die "the host in '${url}' must be a lowercase DNS name."
  fi
  if ! [[ "$URL_PORT" =~ $RE_NUMBER ]]; then
    die "the port in '${url}' is not a number."
  fi
}

# checkout URL REF DIR [COMMIT]: a shallow checkout of exactly REF (a tag or a
# full commit id).
#
# A tag can be moved by whoever controls the repository, and what is checked
# out here is then built and run on this machine, with its cluster
# credentials. So when COMMIT is given, or REF is itself a full commit id, the
# checkout has to be that commit. If it is not, it is removed and nothing runs.
checkout() {
  local url="$1" ref="$2" dir="$3" commit="${4:-}" marker actual
  if [[ "$ref" =~ $RE_COMMIT ]]; then commit="$ref"; fi
  marker="${url}@${ref}@${commit}"
  if [ -f "${dir}/.kit-ref" ] && [ "$(cat "${dir}/.kit-ref")" = "$marker" ]; then
    return 0
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  git init --quiet "$dir"
  git -C "$dir" remote add origin "$url"
  git -C "$dir" fetch --quiet --depth 1 origin "$ref"
  git -C "$dir" checkout --quiet FETCH_HEAD
  if [ -n "$commit" ]; then
    actual="$(git -C "$dir" rev-parse HEAD)"
    if [ "$actual" != "$commit" ]; then
      rm -rf "$dir"
      die "'${ref}' of ${url} is commit ${actual}, not the expected ${commit}. Nothing from it was run, and the checkout was removed. If the project moved the tag on purpose, check what changed before setting the new commit."
    fi
  fi
  printf '%s' "$marker" > "${dir}/.kit-ref"
}

have_looker_api_credentials() {
  ! is_unset "${LOOKER_CLIENT_ID:-}" && ! is_unset "${LOOKER_CLIENT_SECRET:-}"
}

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
# Every setting this script reads, the secrets apart (those are in
# SECRET_SETTINGS). validate_config goes through both lists, and
# tests/deploy_functions_test.sh checks that no setting is missing here.
SETTINGS=(
  SECURITY_MODE PLATFORM KUBE_CONTEXT REGISTRY CONTAINER_TOOL IMAGE_PLATFORM
  LOOKER_REGISTRY LOOKER_IMAGE_PULL_SECRET INTERNAL_TLS
  DEPLOY_LOOKER LOOKER_HOST LOOKER_VERSION LOOKER_JAVA_PACKAGE
  LOOKER_TECHNICAL_CONTACT_EMAIL LOOKER_ADMIN_EMAIL LOOKER_IMAGE LOOKER_BASE_IMAGE LOOKER_REBUILD LOOKER_NAMESPACE
  LOOKER_REPLICAS LOOKER_STORAGE_CLASS LOOKER_STORAGE_SIZE LOOKER_CPU_REQUEST
  LOOKER_MEMORY LOOKER_HEAP_PERCENT LOOKER_EPHEMERAL_STORAGE_LIMIT LOOKER_STARTUP_FLAGS
  LOOKER_SECCOMP_PROFILE LOOKER_CHROMIUM_NO_SANDBOX LOOKER_CHOWN_SHARED_FILES
  LOOKER_EGRESS_CIDRS
  LOOKER_DB_HOST LOOKER_DB_PORT LOOKER_DB_NAME LOOKER_DB_USER LOOKER_DB_DIALECT
  LOOKER_DB_SSL LOOKER_DB_VERIFY_SSL LOOKER_MYSQL_IMAGE LOOKER_MYSQL_STORAGE_SIZE LOOKER_MYSQL_STORAGE_CLASS
  LOOKER_INGRESS_ENABLED LOOKER_INGRESS_CLASS LOOKER_TLS_SECRET
  INGRESS_CONTROLLER_NAMESPACE KUBE_API_PORTS BUSYBOX_IMAGE
  LOOKER_API_URL LOOKER_VERIFY_SSL EXTRA_CA_FILE LOOKER_CLIENT_ID LOOKER_MODELS
  LOOKER_LINK_MODE
  AGENT_BASE_IMAGE AGENT_MODEL_PROVIDER CLAUDE_MODEL CLAUDE_LOCATION GEMINI_MODEL GEMINI_LOCATION
  GCP_PROJECT_ID GCP_PROJECT_NUMBER GCP_SA_KEY_FILE TOKEN_REFRESHER_IMAGE
  SUBSTRATE_VERSION SUBSTRATE_COMMIT SUBSTRATE_IMAGE_REPO SUBSTRATE_ROLLOUT_TIMEOUT
  SUBSTRATE_POSTGRES_STORAGE_CLASS SUBSTRATE_FORCE_DEPLOY SUBSTRATE_REPO_URL
  SUBSTRATE_GKE_REPO_URL SUBSTRATE_GKE_REF WORKER_IMAGE WORKER_NODE_SELECTOR
  ALLOW_KUBECTL_ATE_PROXY SNAPSHOT_STORE BUNDLED_STORE_GENERATED_LOGIN ONPREM_DEV_PROFILE_ACCEPTED
  S3_ENDPOINT_URL S3_REGION S3_BUCKET S3_USE_PATH_STYLE S3_ALLOW_HTTP
  GCP_REGION GKE_CLUSTER_NAME GKE_CLUSTER_LOCATION GKE_CLUSTER_VERSION
  GKE_RELEASE_CHANNEL GKE_NETWORK GKE_SUBNETWORK GKE_MACHINE_TYPE
  GKE_SEPARATE_SYSTEM_NODES GKE_TRANSFER_GSA_NAME GKE_NODE_GSA_NAME GKE_SNAPSHOT_BUCKET
  AGENT_NAMESPACE ATESPACE ACTOR_NAME CREDS_NAMESPACE NETWORK_POLICIES NETWORK_POLICY_CHECK
  WORKER_REPLICAS WORKER_CPU_LIMIT WORKER_CPU_REQUEST WORKER_MEMORY
  ACTOR_CPU_MILLICORES ACTOR_MEMORY_BYTES GOLDEN_TIMEOUT_SECONDS AGENT_DEV_UI
  GATEWAY_NAMESPACE GATEWAY_IMAGE GATEWAY_BASIC_AUTH_USER GATEWAY_CHAT_AUTH_USER
  GATEWAY_CORS_ALLOWED_ORIGINS GATEWAY_TLS_SECRET
  GATEWAY_MAX_CONNECTIONS GATEWAY_MAX_RUNNING_JOBS GATEWAY_MAX_CHAT_RUNNING_JOBS GATEWAY_JOB_DEADLINE_SECONDS
  AGENT_INGRESS_ENABLED AGENT_HOST AGENT_INGRESS_CLASS AGENT_TLS_SECRET VERIFY_LOCAL_PORT
  EXTENSION_TRANSPORT EXTENSION_SERVER_GATEWAY_URL EXTENSION_BROWSER_GATEWAY_URL
  EXTENSION_PROJECT_NAME EXTENSION_APPLICATION_NAME EXTENSION_LABEL
  EXTENSION_LOOKML_CONNECTION EXTENSION_ALLOW_DOWNLOADS EXTENSION_ALLOWED_LINK_ORIGINS NPM
)

# config.env is run as shell. Whoever can write to it runs commands as the
# person who starts this script, with that person's cluster credentials.
check_config_file() {
  if [ ! -O "$CONFIG_FILE" ]; then
    die "${CONFIG_FILE} belongs to another user. This script runs the file as shell, so it only reads one that is yours."
  fi
  if [ -n "$(find -L "$CONFIG_FILE" -maxdepth 0 -perm -002 2>/dev/null)" ]; then
    die "${CONFIG_FILE} can be written by every user of this machine, and this script runs it as shell. Run: chmod 600 ${CONFIG_FILE}"
  fi
  if [ -n "$(find -L "$CONFIG_FILE" -maxdepth 0 \( -perm -020 -o -perm -040 -o -perm -004 \) 2>/dev/null)" ]; then
    warn "${CONFIG_FILE} can be read or written by other users. Run: chmod 600 ${CONFIG_FILE}"
  fi
}

# The tools this script starts (kubectl, the container tool, go, git, npm,
# curl) have no use for the secrets, and some of them run code that was
# fetched from the internet minutes before. So what the operator exported
# stays readable inside this script and is not passed on to any of them.
# Where one tool needs one secret, that one command is given it.
withhold_secrets_from_tools() {
  local name
  for name in "${SECRET_SETTINGS[@]}"; do
    export -n "$name"
  done
}

load_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    die "${CONFIG_FILE} not found. Copy config.env.example to config.env and edit it."
  fi
  check_config_file
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"

  : "${SECURITY_MODE:=standard}"
  : "${PLATFORM:=onprem}"
  : "${KUBE_CONTEXT:=}"
  : "${REGISTRY:=}"
  : "${CONTAINER_TOOL:=docker}"
  : "${IMAGE_PLATFORM:=linux/amd64}"

  : "${LOOKER_REGISTRY:=}"
  : "${LOOKER_IMAGE_PULL_SECRET:=}"
  : "${INTERNAL_TLS:=off}"
  : "${DEPLOY_LOOKER:=true}"
  : "${LOOKER_HOST:=}"
  : "${LOOKER_VERSION:=}"
  : "${LOOKER_JAVA_PACKAGE:=openjdk-21-jdk-headless}"
  : "${LOOKER_TECHNICAL_CONTACT_EMAIL:=}"
  : "${LOOKER_ADMIN_EMAIL:=}"
  : "${LOOKER_IMAGE:=}"
  : "${LOOKER_BASE_IMAGE:=ubuntu:24.04}"
  : "${LOOKER_REBUILD:=false}"
  : "${LOOKER_NAMESPACE:=looker}"
  : "${LOOKER_REPLICAS:=1}"
  : "${LOOKER_STORAGE_CLASS:=}"
  : "${LOOKER_STORAGE_SIZE:=50Gi}"
  : "${LOOKER_CPU_REQUEST:=2}"
  : "${LOOKER_MEMORY:=8Gi}"
  : "${LOOKER_HEAP_PERCENT:=60}"
  : "${LOOKER_EPHEMERAL_STORAGE_LIMIT:=20Gi}"
  : "${LOOKER_STARTUP_FLAGS:=}"
  : "${LOOKER_SECCOMP_PROFILE:=}"
  : "${LOOKER_CHROMIUM_NO_SANDBOX:=false}"
  : "${LOOKER_CHOWN_SHARED_FILES:=false}"
  : "${LOOKER_EGRESS_CIDRS:=0.0.0.0/0}"
  : "${LOOKER_DB_HOST:=}"
  : "${LOOKER_DB_PORT:=3306}"
  : "${LOOKER_DB_NAME:=looker}"
  : "${LOOKER_DB_USER:=looker}"
  : "${LOOKER_DB_DIALECT:=mysql_8}"
  : "${LOOKER_DB_SSL:=true}"
  : "${LOOKER_DB_VERIFY_SSL:=}"
  : "${LOOKER_MYSQL_IMAGE:=mysql:8.4}"
  : "${LOOKER_MYSQL_STORAGE_SIZE:=20Gi}"
  : "${LOOKER_MYSQL_STORAGE_CLASS:=}"
  : "${LOOKER_INGRESS_ENABLED:=false}"
  : "${LOOKER_INGRESS_CLASS:=nginx}"
  : "${LOOKER_TLS_SECRET:=}"
  : "${INGRESS_CONTROLLER_NAMESPACE:=ingress-nginx}"
  : "${KUBE_API_PORTS:=443,6443}"
  : "${BUSYBOX_IMAGE:=busybox:1.36}"

  : "${LOOKER_API_URL:=}"
  : "${LOOKER_VERIFY_SSL:=}"
  : "${EXTRA_CA_FILE:=}"
  : "${LOOKER_CLIENT_ID:=}"
  : "${LOOKER_MODELS:=[\"thelook\"]}"
  : "${LOOKER_LINK_MODE:=plain}"

  : "${AGENT_BASE_IMAGE:=python:3.12-slim}"
  : "${AGENT_MODEL_PROVIDER:=claude}"
  : "${CLAUDE_MODEL:=claude-sonnet-4-6}"
  : "${CLAUDE_LOCATION:=us-east5}"
  : "${GEMINI_MODEL:=gemini-2.5-flash}"
  : "${GEMINI_LOCATION:=us-central1}"
  : "${GCP_PROJECT_ID:=}"
  : "${GCP_PROJECT_NUMBER:=}"
  : "${GCP_SA_KEY_FILE:=}"
  : "${TOKEN_REFRESHER_IMAGE:=gcr.io/google.com/cloudsdktool/google-cloud-cli:slim}"

  : "${SUBSTRATE_VERSION:=v1.0.0}"
  # The commit that tag has to be (see "checkout"). "=" and not ":=": an empty
  # value is a decision to switch the check off, and it is kept.
  : "${SUBSTRATE_COMMIT=b34fbee742906494b5eb4f1f36987176bf8770a4}"
  : "${SUBSTRATE_IMAGE_REPO:=ghcr.io/agent-substrate/substrate}"
  : "${SUBSTRATE_ROLLOUT_TIMEOUT:=5m}"
  : "${SUBSTRATE_POSTGRES_STORAGE_CLASS:=}"
  : "${SUBSTRATE_FORCE_DEPLOY:=false}"
  : "${WORKER_IMAGE:=${SUBSTRATE_IMAGE_REPO}/ateworker-gvisor:${SUBSTRATE_VERSION}}"
  : "${WORKER_NODE_SELECTOR:=}"
  : "${ALLOW_KUBECTL_ATE_PROXY:=false}"
  : "${SNAPSHOT_STORE:=bundled}"
  : "${BUNDLED_STORE_GENERATED_LOGIN:=true}"
  : "${ONPREM_DEV_PROFILE_ACCEPTED:=false}"
  : "${S3_ENDPOINT_URL:=}"
  : "${S3_REGION:=us-east-1}"
  : "${S3_BUCKET:=}"
  : "${S3_USE_PATH_STYLE:=true}"
  : "${S3_ALLOW_HTTP:=false}"

  : "${GCP_REGION:=us-central1}"
  : "${GKE_CLUSTER_NAME:=looker-agent}"
  : "${GKE_CLUSTER_LOCATION:=us-central1-a}"
  : "${GKE_CLUSTER_VERSION:=1.37}"
  : "${GKE_RELEASE_CHANNEL:=rapid}"
  : "${GKE_NETWORK:=default}"
  : "${GKE_SUBNETWORK:=default}"
  : "${GKE_MACHINE_TYPE:=n2-standard-8}"
  : "${GKE_SEPARATE_SYSTEM_NODES:=true}"
  : "${GKE_TRANSFER_GSA_NAME:=ate-snapshot-transfer}"
  : "${GKE_NODE_GSA_NAME:=ate-gke-node}"
  : "${GKE_SNAPSHOT_BUCKET:=}"

  : "${AGENT_NAMESPACE:=looker-agent}"
  : "${ATESPACE:=looker-agent}"
  : "${ACTOR_NAME:=looker-agent}"
  : "${CREDS_NAMESPACE:=looker-agent-creds}"
  : "${NETWORK_POLICIES:=true}"
  : "${NETWORK_POLICY_CHECK:=true}"
  : "${WORKER_REPLICAS:=1}"
  : "${WORKER_CPU_LIMIT:=2}"
  : "${WORKER_CPU_REQUEST:=500m}"
  : "${WORKER_MEMORY:=4Gi}"
  : "${ACTOR_CPU_MILLICORES:=1000}"
  : "${ACTOR_MEMORY_BYTES:=1610612736}"
  : "${GOLDEN_TIMEOUT_SECONDS:=600}"
  : "${AGENT_DEV_UI:=false}"

  : "${GATEWAY_NAMESPACE:=looker-agent-gateway}"
  : "${GATEWAY_IMAGE:=python:3.12-slim}"
  : "${GATEWAY_BASIC_AUTH_USER:=agent}"
  : "${GATEWAY_CHAT_AUTH_USER:=looker-chat}"
  : "${GATEWAY_CORS_ALLOWED_ORIGINS:=}"
  : "${GATEWAY_TLS_SECRET:=}"
  : "${GATEWAY_MAX_CONNECTIONS:=256}"
  : "${GATEWAY_MAX_RUNNING_JOBS:=32}"
  : "${GATEWAY_MAX_CHAT_RUNNING_JOBS:=24}"
  : "${GATEWAY_JOB_DEADLINE_SECONDS:=600}"
  : "${AGENT_INGRESS_ENABLED:=false}"
  : "${AGENT_HOST:=}"
  : "${AGENT_INGRESS_CLASS:=nginx}"
  : "${AGENT_TLS_SECRET:=}"
  : "${VERIFY_LOCAL_PORT:=18080}"

  : "${EXTENSION_TRANSPORT:=server}"
  : "${EXTENSION_SERVER_GATEWAY_URL:=}"
  : "${EXTENSION_BROWSER_GATEWAY_URL:=}"
  : "${EXTENSION_PROJECT_NAME:=looker_agent}"
  : "${EXTENSION_APPLICATION_NAME:=chat}"
  : "${EXTENSION_LABEL:=Looker Agent}"
  : "${EXTENSION_LOOKML_CONNECTION:=}"
  : "${EXTENSION_ALLOW_DOWNLOADS:=false}"
  : "${EXTENSION_ALLOWED_LINK_ORIGINS:=}"
  : "${NPM:=npm}"

  withhold_secrets_from_tools

  WORK_DIR="${WORK_DIR:-${SCRIPT_DIR}/.work}"
  RENDER_DIR="${WORK_DIR}/rendered"
  STATE_DIR="${WORK_DIR}/state"
  BIN_DIR="${WORK_DIR}/bin"
  EXTENSION_DIR="${WORK_DIR}/looker-extension"
  SUBSTRATE_DIR="${WORK_DIR}/src/substrate"
  SUBSTRATE_GKE_DIR="${WORK_DIR}/src/substrate-gke"
  mkdir -p "$RENDER_DIR" "$STATE_DIR" "$BIN_DIR"
  remove_leftover_tmp_dirs
  # kubectl finds the "ate" plugin through PATH.
  export PATH="${BIN_DIR}:${PATH}"
}

# Everything in the configuration that works but is weaker than it could be.
# It is one list on purpose, so that no protection is switched off without
# somebody seeing it: SECURITY_MODE="strict" refuses to run while the list is
# not empty, and "standard" prints it.
collect_weak_choices() {
  WEAK_CHOICES=()
  local pair name
  if [ "$PLATFORM" = "onprem" ] && [ "$SNAPSHOT_STORE" = "bundled" ]; then
    WEAK_CHOICES+=("SNAPSHOT_STORE=\"bundled\": the agent's snapshots, which hold the Looker API key and the chat sessions, go to the small object store of Substrate's development profile. Use SNAPSHOT_STORE=\"s3\" with a store of your own.")
    if ! is_true "$BUNDLED_STORE_GENERATED_LOGIN"; then
      WEAK_CHOICES+=("BUNDLED_STORE_GENERATED_LOGIN=\"false\": the bundled object store keeps the installer's published login.")
    fi
  fi
  if [ "$PLATFORM" = "onprem" ] && [ "$SNAPSHOT_STORE" = "s3" ] && is_true "$S3_ALLOW_HTTP"; then
    WEAK_CHOICES+=("S3_ALLOW_HTTP=\"true\": S3_ENDPOINT_URL may use plain HTTP, leaving snapshots and the Looker API key unencrypted on the wire.")
  fi

  # An image named by tag is whatever the tag points at on the day a node pulls
  # it. Only the images this configuration actually uses are looked at.
  local images=("GATEWAY_IMAGE" "WORKER_IMAGE" "AGENT_BASE_IMAGE")
  if is_true "$DEPLOY_LOOKER"; then
    if [ -n "$LOOKER_IMAGE" ]; then
      images+=("LOOKER_IMAGE")
    else
      images+=("LOOKER_BASE_IMAGE")
    fi
    if [ -z "$LOOKER_DB_HOST" ]; then images+=("LOOKER_MYSQL_IMAGE"); fi
    if is_true "$LOOKER_CHOWN_SHARED_FILES"; then images+=("BUSYBOX_IMAGE"); fi
  fi
  if [ "$MODEL_AUTH" = "vertex" ]; then images+=("TOKEN_REFRESHER_IMAGE"); fi
  for name in "${images[@]}"; do
    if ! is_pinned_image "${!name}"; then
      WEAK_CHOICES+=("${name}=\"${!name}\": named by tag, not by digest. Write it as name:tag@sha256:<digest>.")
    fi
  done

  if [ "$LOOKER_VERIFY_SSL" = "false" ]; then
    WEAK_CHOICES+=("LOOKER_VERIFY_SSL=\"false\": the agent does not check Looker's certificate on the connection that carries the Looker API key. Give Looker a certificate the agent can verify (EXTRA_CA_FILE for a private CA).")
  fi
  if [[ "$EXTENSION_SERVER_GATEWAY_URL" == http://* ]]; then
    WEAK_CHOICES+=("the address Looker's server uses for the gateway is ${EXTENSION_SERVER_GATEWAY_URL}: the chat password crosses the cluster network unencrypted. Set GATEWAY_TLS_SECRET, or an https address in EXTENSION_SERVER_GATEWAY_URL.")
  fi
  if is_true "$ALLOW_KUBECTL_ATE_PROXY"; then
    WEAK_CHOICES+=("ALLOW_KUBECTL_ATE_PROXY=\"true\": Substrate's router admits a second identity besides the gateway, and whoever obtains it reaches the agent without either gateway password.")
  fi
  if ! is_true "$NETWORK_POLICIES"; then
    WEAK_CHOICES+=("NETWORK_POLICIES=\"false\": every pod in the cluster can connect to Looker, to its database and to the gateway, unless another team's policies say otherwise.")
  fi
  if ! is_true "$NETWORK_POLICY_CHECK"; then
    WEAK_CHOICES+=("NETWORK_POLICY_CHECK=\"false\": preflight does not verify that the cluster enforces NetworkPolicy before installing.")
  fi
  if is_true "$DEPLOY_LOOKER"; then
    if is_true "$NETWORK_POLICIES" && [[ ",${LOOKER_EGRESS_CIDRS}," == *,0.0.0.0/0,* ]]; then
      WEAK_CHOICES+=("LOOKER_EGRESS_CIDRS contains 0.0.0.0/0: Looker may open connections to anywhere. List the networks of its databases, Git and mail instead.")
    fi
    if ! is_true "$LOOKER_DB_SSL"; then
      WEAK_CHOICES+=("LOOKER_DB_SSL=\"false\": Looker talks to its own database without TLS.")
    elif [ -n "$LOOKER_DB_HOST" ] && [ "$LOOKER_DB_VERIFY_SSL" = "false" ]; then
      WEAK_CHOICES+=("LOOKER_DB_VERIFY_SSL=\"false\": Looker encrypts its connection to ${LOOKER_DB_HOST} without verifying the server certificate.")
    fi
    if [ "$LOOKER_SECCOMP_PROFILE" = "Unconfined" ]; then
      WEAK_CHOICES+=("LOOKER_SECCOMP_PROFILE=\"Unconfined\": no system-call filter for Looker, and its namespace has to allow privileged pods for it.")
    fi
  fi
  if is_true "$AGENT_DEV_UI"; then
    WEAK_CHOICES+=("AGENT_DEV_UI=\"true\": the agent serves ADK's developer UI and its extra endpoints (everyone's sessions, traces, evaluations).")
  fi
  if [ "$LOOKER_LINK_MODE" = "signed" ]; then
    WEAK_CHOICES+=("LOOKER_LINK_MODE=\"signed\": the agent hands signed embed links to chat users. Each is a Looker session for whoever holds the link.")
  fi
  if [ -z "$SUBSTRATE_COMMIT" ]; then
    WEAK_CHOICES+=("SUBSTRATE_COMMIT is empty: Substrate ${SUBSTRATE_VERSION} is checked out by tag alone, and what the tag points at is built and run on this machine.")
  fi
}

# Applies SECURITY_MODE to the list above.
report_weak_choices() {
  local choice
  collect_weak_choices
  if [ "${#WEAK_CHOICES[@]}" -eq 0 ]; then
    return 0
  fi
  if [ "$SECURITY_MODE" = "strict" ]; then
    {
      printf 'ERROR: SECURITY_MODE="strict" does not accept this configuration. %d setting(s) are weaker than they could be:\n' "${#WEAK_CHOICES[@]}"
      for choice in "${WEAK_CHOICES[@]}"; do printf '  - %s\n' "$choice"; done
      printf 'Change them, or set SECURITY_MODE="standard" to go ahead as it is.\n'
    } >&2
    exit 1
  fi
  log "NOTICE: ${#WEAK_CHOICES[@]} setting(s) are weaker than they could be. SECURITY_MODE=\"strict\" would refuse them:"
  for choice in "${WEAK_CHOICES[@]}"; do log "  - ${choice}"; done
}

validate_config() {
  step "STEP -1: Validate configuration"
  local name value

  # --- No control character, anywhere ---
  # Settings are written into YAML, into shell that runs inside the cluster,
  # into LookML and into JavaScript. A line break in one of them could add
  # lines of its own there, so no setting may hold a control character.
  for name in "${SETTINGS[@]}" "${SECRET_SETTINGS[@]}"; do
    if [[ "${!name:-}" == *[[:cntrl:]]* ]]; then
      die "'${name}' contains a control character (a line break or a tab, for example). Remove it."
    fi
  done

  # --- Choices and switches ---
  require_choice PLATFORM onprem gke
  require_choice AGENT_MODEL_PROVIDER claude claude_native gemini anthropic
  require_choice SNAPSHOT_STORE bundled s3
  require_choice SECURITY_MODE standard strict
  require_choice EXTENSION_TRANSPORT server browser
  require_choice LOOKER_LINK_MODE plain signed
  require_choice INTERNAL_TLS off private-ca
  case "$LOOKER_SECCOMP_PROFILE" in
    ""|RuntimeDefault|Unconfined) ;;
    *) die "LOOKER_SECCOMP_PROFILE must be empty, 'RuntimeDefault' or 'Unconfined', got '${LOOKER_SECCOMP_PROFILE}'." ;;
  esac
  for name in DEPLOY_LOOKER LOOKER_REBUILD LOOKER_CHROMIUM_NO_SANDBOX LOOKER_CHOWN_SHARED_FILES \
      LOOKER_DB_SSL LOOKER_INGRESS_ENABLED AGENT_INGRESS_ENABLED SUBSTRATE_FORCE_DEPLOY \
      ALLOW_KUBECTL_ATE_PROXY ONPREM_DEV_PROFILE_ACCEPTED BUNDLED_STORE_GENERATED_LOGIN \
      S3_USE_PATH_STYLE S3_ALLOW_HTTP GKE_SEPARATE_SYSTEM_NODES NETWORK_POLICIES \
      NETWORK_POLICY_CHECK AGENT_DEV_UI EXTENSION_ALLOW_DOWNLOADS; do
    require_boolean "$name"
  done

  # --- Tools, registry, names ---
  require_var REGISTRY
  require_match REGISTRY "$RE_REPOSITORY" "a registry path such as registry.example/team (lowercase, without a tag)"
  require_match_if_set LOOKER_REGISTRY "$RE_REPOSITORY" "a registry path such as registry.example/looker (lowercase, without a tag)"
  require_match CONTAINER_TOOL '^[A-Za-z0-9_./-]+$' "the name or path of a command"
  require_match NPM '^[A-Za-z0-9_./-]+$' "the name or path of a command"
  require_match IMAGE_PLATFORM '^[a-z0-9]+/[a-z0-9]+(/[a-z0-9]+)?$' "a platform such as linux/amd64"
  require_match_if_set KUBE_CONTEXT '^[A-Za-z0-9_.:@/=+-]+$' "the name of a kubectl context"
  require_var LOOKER_HOST
  require_match LOOKER_HOST "$RE_DNS_NAME" "a lowercase DNS name"
  for name in LOOKER_NAMESPACE AGENT_NAMESPACE GATEWAY_NAMESPACE CREDS_NAMESPACE \
      INGRESS_CONTROLLER_NAMESPACE ATESPACE ACTOR_NAME; do
    require_dns_label "$name"
  done
  # Each of the kit's namespaces gets its own Pod Security level and its own
  # network rules. So the four have to be four different ones, and none may be
  # a namespace that belongs to the cluster or to Substrate.
  local own=("$LOOKER_NAMESPACE" "$AGENT_NAMESPACE" "$GATEWAY_NAMESPACE" "$CREDS_NAMESPACE") i j
  for ((i = 0; i < ${#own[@]}; i++)); do
    case "${own[i]}" in
      default|kube-system|kube-public|kube-node-lease|ate-system|otel-system|podcertificate-controller-system)
        die "'${own[i]}' belongs to the cluster or to Substrate. LOOKER_NAMESPACE, AGENT_NAMESPACE, GATEWAY_NAMESPACE and CREDS_NAMESPACE each need a namespace of their own." ;;
    esac
    for ((j = i + 1; j < ${#own[@]}; j++)); do
      if [ "${own[i]}" = "${own[j]}" ]; then
        die "LOOKER_NAMESPACE, AGENT_NAMESPACE, GATEWAY_NAMESPACE and CREDS_NAMESPACE must be four different namespaces: '${own[i]}' is used twice. The workers' namespace has to allow privileged pods, and nothing else should live there."
      fi
    done
  done

  # --- Where it runs ---
  if [ "$PLATFORM" = "onprem" ]; then
    require_var KUBE_CONTEXT
    if [ "$SNAPSHOT_STORE" = "s3" ]; then
      require_var S3_ENDPOINT_URL
      require_var S3_BUCKET
      require_match S3_ENDPOINT_URL '^https?://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$' "an address such as https://s3.example[:port]"
      if [[ "$S3_ENDPOINT_URL" == http://* ]] && ! is_true "$S3_ALLOW_HTTP"; then
        die "S3_ENDPOINT_URL '${S3_ENDPOINT_URL}' uses plain http://, which leaves snapshots (and the Looker API key) unencrypted. Use https://, or set S3_ALLOW_HTTP=\"true\"."
      fi
      require_match S3_BUCKET '^[a-z0-9][a-z0-9.-]*[a-z0-9]$' "a bucket name (lowercase letters, digits, '.', '-')"
      require_match S3_REGION '^[a-z0-9-]+$' "a region name"
    fi
  else
    require_var GCP_PROJECT_ID
    GKE_SNAPSHOT_BUCKET="${GKE_SNAPSHOT_BUCKET:-looker-agent-snap-${GCP_PROJECT_ID}}"
    if [ "${#GKE_SNAPSHOT_BUCKET}" -gt 56 ]; then
      die "GKE_SNAPSHOT_BUCKET '${GKE_SNAPSHOT_BUCKET}' is longer than 56 characters; set a shorter one."
    fi
    case "$REGISTRY" in
      *-docker.pkg.dev/*/*) ;;
      *) die "on GKE, REGISTRY must look like REGION-docker.pkg.dev/PROJECT/REPOSITORY." ;;
    esac
    require_match GKE_SNAPSHOT_BUCKET '^[a-z0-9][a-z0-9._-]*[a-z0-9]$' "a bucket name"
    for name in GKE_CLUSTER_NAME GKE_TRANSFER_GSA_NAME GKE_NODE_GSA_NAME; do
      require_match "$name" '^[a-z]([a-z0-9-]*[a-z0-9])?$' "lowercase letters, digits and '-', starting with a letter"
    done
    for name in GCP_REGION GKE_CLUSTER_LOCATION GKE_MACHINE_TYPE GKE_RELEASE_CHANNEL; do
      require_match "$name" '^[a-z][a-z0-9-]*$' "lowercase letters, digits and '-'"
    done
    require_match GKE_CLUSTER_VERSION '^[0-9][A-Za-z0-9.-]*$' "a GKE version such as 1.37"
    for name in GKE_NETWORK GKE_SUBNETWORK; do
      require_match "$name" '^[a-z0-9]([a-z0-9/_.-]*[a-z0-9])?$' "a network name or path"
    done
    require_match_if_set GCP_PROJECT_NUMBER "$RE_NUMBER" "a project number (digits)"
    KIT_KUBECONFIG="${WORK_DIR}/kubeconfig"
    if is_unset "$KUBE_CONTEXT"; then
      KUBE_CONTEXT="gke_${GCP_PROJECT_ID}_${GKE_CLUSTER_LOCATION}_${GKE_CLUSTER_NAME}"
    fi
    # Everything that talks to the cluster uses the kit's own kubeconfig, so
    # your ~/.kube/config and current context are left alone.
    export KUBECONFIG="$KIT_KUBECONFIG"
  fi
  if ! is_unset "$GCP_PROJECT_ID"; then
    require_match GCP_PROJECT_ID '^[a-z][a-z0-9.:-]*[a-z0-9]$' "a Google Cloud project id"
  fi

  # --- Looker ---
  if is_true "$DEPLOY_LOOKER"; then
    if [ -z "$LOOKER_IMAGE" ]; then
      require_var LOOKER_VERSION
      require_var LOOKER_TECHNICAL_CONTACT_EMAIL
      require_match LOOKER_BASE_IMAGE "$RE_IMAGE" "an image reference such as ubuntu:24.04"
      if [ "$IMAGE_PLATFORM" != "linux/amd64" ]; then
        die "building Looker from looker/Dockerfile requires IMAGE_PLATFORM=\"linux/amd64\" (Google Chrome's Linux repository is amd64-only), got '${IMAGE_PLATFORM}'. Use LOOKER_IMAGE to supply a pre-built image for another platform."
      fi
    else
      require_match LOOKER_IMAGE "$RE_IMAGE" "an image reference such as registry.example/looker:26.6"
    fi
    if ! is_unset "$LOOKER_VERSION"; then
      require_match LOOKER_VERSION '^[0-9]+\.[0-9]+$' "a Looker release as major.minor, for example 26.6"
    fi
    for name in LOOKER_TECHNICAL_CONTACT_EMAIL LOOKER_ADMIN_EMAIL; do
      if ! is_unset "${!name}"; then
        require_match "$name" "$RE_EMAIL" "an email address"
      fi
    done
    require_match LOOKER_JAVA_PACKAGE '^[a-z0-9][a-z0-9.+-]*$' "the name of a package"
    require_match LOOKER_REPLICAS '^[1-9][0-9]*$' "a number of replicas, 1 or more"
    if [ "$LOOKER_REPLICAS" != "1" ] && [ -z "$LOOKER_STORAGE_CLASS" ]; then
      die "LOOKER_REPLICAS > 1 needs LOOKER_STORAGE_CLASS set to a ReadWriteMany storage class."
    fi
    for name in LOOKER_STORAGE_SIZE LOOKER_CPU_REQUEST LOOKER_MEMORY LOOKER_EPHEMERAL_STORAGE_LIMIT; do
      require_match "$name" "$RE_QUANTITY" "a Kubernetes quantity such as 2, 500m or 8Gi"
    done
    require_match LOOKER_HEAP_PERCENT "$RE_NUMBER" "a percentage between 10 and 90"
    if [ "$LOOKER_HEAP_PERCENT" -lt 10 ] || [ "$LOOKER_HEAP_PERCENT" -gt 90 ]; then
      die "LOOKER_HEAP_PERCENT must be between 10 and 90, got '${LOOKER_HEAP_PERCENT}'."
    fi
    for name in LOOKER_STORAGE_CLASS LOOKER_MYSQL_STORAGE_CLASS LOOKER_INGRESS_CLASS LOOKER_TLS_SECRET LOOKER_IMAGE_PULL_SECRET; do
      require_match_if_set "$name" "$RE_DNS_NAME" "the name of a Kubernetes object (lowercase letters, digits, '-' and '.')"
    done
    # This one is read by a shell inside the Looker pod, so it is held to the
    # characters start options are made of.
    require_match LOOKER_STARTUP_FLAGS '^[A-Za-z0-9 =_.,:/@+-]*$' "Looker start options made of letters, digits, spaces and = _ . , : / @ + - only"

    # Looker's own database.
    require_match LOOKER_DB_DIALECT '^[a-z0-9_]+$' "the name of a Looker dialect, such as mysql_8"
    require_match LOOKER_DB_NAME "$RE_IDENTIFIER" "letters, digits and '_' only"
    require_match LOOKER_DB_USER "$RE_IDENTIFIER" "letters, digits and '_' only"
    require_match LOOKER_DB_PORT "$RE_NUMBER" "a port number"
    if [ -n "$LOOKER_DB_HOST" ]; then
      require_match LOOKER_DB_HOST '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' "a host name or an address"
      : "${LOOKER_DB_VERIFY_SSL:=true}"
    else
      : "${LOOKER_DB_VERIFY_SSL:=false}"
      require_match LOOKER_MYSQL_IMAGE "$RE_IMAGE" "an image reference such as mysql:8.4"
      require_match LOOKER_MYSQL_STORAGE_SIZE "$RE_QUANTITY" "a Kubernetes quantity such as 20Gi"
      # Looker's guide "Migrating the Looker backend database to MySQL": MySQL
      # 8.4 is supported from Looker 26.6. With an image of your own the
      # version is not known here, and it is yours to check.
      if ! is_unset "$LOOKER_VERSION" && ! looker_version_at_least 26 6; then
        die "the bundled MySQL is version 8.4, which Looker supports from release 26.6, and LOOKER_VERSION is ${LOOKER_VERSION}. Use Looker 26.6 or newer, or give Looker a database of your own with LOOKER_DB_HOST."
      fi
    fi
    require_boolean LOOKER_DB_VERIFY_SSL
    if is_true "$LOOKER_CHOWN_SHARED_FILES"; then
      require_match BUSYBOX_IMAGE "$RE_IMAGE" "an image reference such as busybox:1.36"
    fi
    if is_true "$LOOKER_INGRESS_ENABLED" && [ -z "$LOOKER_TLS_SECRET" ]; then
      die "LOOKER_INGRESS_ENABLED needs LOOKER_TLS_SECRET: an Ingress without a certificate would serve Looker's sign-in page over plain HTTP."
    fi

    # What Looker itself may connect to, besides its database and the gateway.
    LOOKER_EGRESS_CIDRS="${LOOKER_EGRESS_CIDRS// /}"
    local cidrs=() cidr
    IFS=',' read -r -a cidrs <<< "$LOOKER_EGRESS_CIDRS"
    for cidr in ${cidrs[@]+"${cidrs[@]}"}; do
      if ! [[ "$cidr" =~ $RE_CIDR ]]; then
        die "LOOKER_EGRESS_CIDRS entries must look like 10.20.0.0/16, got '${cidr}'."
      fi
    done

    if [ -z "$LOOKER_API_URL" ]; then
      LOOKER_API_URL="https://looker-api.${LOOKER_NAMESPACE}.svc.cluster.local"
      if [ "$INTERNAL_TLS" = "private-ca" ]; then
        : "${LOOKER_VERIFY_SSL:=true}"
      else
        # Looker's built-in certificate is self-signed.
        : "${LOOKER_VERIFY_SSL:=false}"
      fi
    fi
    INTERNAL_MANAGED_GATEWAY_TLS="false"
    if [ "$INTERNAL_TLS" = "private-ca" ] && [ -z "$GATEWAY_TLS_SECRET" ]; then
      GATEWAY_TLS_SECRET="looker-agent-gateway-tls"
      INTERNAL_MANAGED_GATEWAY_TLS="true"
    fi
    # The Pod Security level Looker's namespace enforces. "baseline" is what
    # its pods fit into. An explicit "Unconfined" seccomp profile is the one
    # thing baseline refuses, so that choice costs the namespace its level.
    LOOKER_POD_SECURITY="baseline"
    if [ "$LOOKER_SECCOMP_PROFILE" = "Unconfined" ]; then
      LOOKER_POD_SECURITY="privileged"
    fi
  else
    if [ "$INTERNAL_TLS" = "private-ca" ]; then
      die "INTERNAL_TLS=\"private-ca\" is for Looker deployed by this script (DEPLOY_LOOKER=\"true\"). With an external Looker, set EXTRA_CA_FILE and GATEWAY_TLS_SECRET instead."
    fi
    INTERNAL_MANAGED_GATEWAY_TLS="false"
    if [ -z "$LOOKER_API_URL" ]; then
      die "DEPLOY_LOOKER=false needs LOOKER_API_URL (the base URL of your Looker API)."
    fi
  fi
  : "${LOOKER_VERIFY_SSL:=true}"
  case "$LOOKER_VERIFY_SSL" in
    true|false) ;;
    *) die "LOOKER_VERIFY_SSL must be 'true' or 'false'." ;;
  esac
  LOOKER_PUBLIC_URL="https://${LOOKER_HOST}"

  parse_url "$LOOKER_API_URL"
  LOOKER_API_SCHEME="$URL_SCHEME"
  LOOKER_API_HOST="$URL_HOST"
  LOOKER_API_PORT="$URL_PORT"

  if [ -n "$EXTRA_CA_FILE" ] && [ ! -r "$EXTRA_CA_FILE" ]; then
    die "EXTRA_CA_FILE '${EXTRA_CA_FILE}' is not readable."
  fi
  if ! is_unset "$LOOKER_CLIENT_ID"; then
    require_match LOOKER_CLIENT_ID "$RE_WORD" "the client id of a Looker API key"
  fi
  require_match LOOKER_MODELS '^\[ *"[A-Za-z0-9_]+"( *, *"[A-Za-z0-9_]+")* *\]$' "a JSON list of LookML model names, such as [\"thelook\"]"

  # --- The model ---
  # Where the model lives, and which header carries its credential.
  case "$AGENT_MODEL_PROVIDER" in
    claude|claude_native) MODEL_AUTH="vertex"; MODEL_LOCATION="$CLAUDE_LOCATION" ;;
    gemini)               MODEL_AUTH="vertex"; MODEL_LOCATION="$GEMINI_LOCATION" ;;
    anthropic)            MODEL_AUTH="apikey"; MODEL_LOCATION="" ;;
  esac
  for name in CLAUDE_MODEL GEMINI_MODEL; do
    require_match "$name" '^[A-Za-z0-9][A-Za-z0-9._@:-]*$' "the name of a model"
  done
  for name in CLAUDE_LOCATION GEMINI_LOCATION; do
    require_match "$name" '^[a-z][a-z0-9-]*$' "a region name, or 'global'"
  done
  if [ "$MODEL_AUTH" = "vertex" ]; then
    require_var GCP_PROJECT_ID
    if [ "$MODEL_LOCATION" = "global" ]; then
      MODEL_HOST="aiplatform.googleapis.com"
    else
      MODEL_HOST="${MODEL_LOCATION}-aiplatform.googleapis.com"
    fi
    MODEL_HEADER="Authorization"
    MODEL_PREFIX="Bearer "
    if [ "$PLATFORM" = "onprem" ] && [ -n "$GCP_SA_KEY_FILE" ] && [ ! -r "$GCP_SA_KEY_FILE" ]; then
      die "GCP_SA_KEY_FILE '${GCP_SA_KEY_FILE}' is not readable."
    fi
    require_match TOKEN_REFRESHER_IMAGE "$RE_IMAGE" "an image reference"
  else
    MODEL_HOST="api.anthropic.com"
    MODEL_HEADER="x-api-key"
    MODEL_PREFIX=""
  fi

  # --- Substrate and the agent ---
  require_match AGENT_BASE_IMAGE "$RE_IMAGE" "an image reference such as python:3.12-slim"
  KUBE_API_PORTS="${KUBE_API_PORTS// /}"
  local api_ports=() api_port
  IFS=',' read -r -a api_ports <<< "$KUBE_API_PORTS"
  if [ "${#api_ports[@]}" -eq 0 ]; then
    die "KUBE_API_PORTS must name at least one TCP port (for example 443,6443)."
  fi
  for api_port in "${api_ports[@]}"; do
    if ! [[ "$api_port" =~ $RE_NUMBER ]] || [ "$api_port" -lt 1 ] || [ "$api_port" -gt 65535 ]; then
      die "KUBE_API_PORTS entries must be TCP ports 1..65535, got '${api_port}'."
    fi
  done
  require_match SUBSTRATE_VERSION "$RE_WORD" "a tag such as v1.0.0"
  require_match_if_set SUBSTRATE_COMMIT "$RE_COMMIT" "a full commit id (40 hexadecimal digits), or empty"
  require_match SUBSTRATE_GKE_REF "$RE_WORD" "a tag or a commit id"
  for name in SUBSTRATE_REPO_URL SUBSTRATE_GKE_REPO_URL; do
    require_match "$name" '^[A-Za-z0-9][A-Za-z0-9@:./_~+-]*$' "the address of a Git repository"
  done
  require_match SUBSTRATE_IMAGE_REPO "$RE_REPOSITORY" "a registry path such as ghcr.io/agent-substrate/substrate"
  require_match SUBSTRATE_ROLLOUT_TIMEOUT '^[0-9]+[smh]$' "a duration such as 5m"
  require_match_if_set SUBSTRATE_POSTGRES_STORAGE_CLASS "$RE_DNS_NAME" "the name of a storage class"
  require_match WORKER_IMAGE "$RE_IMAGE" "an image reference"
  require_match_if_set WORKER_NODE_SELECTOR "$RE_NODE_SELECTOR" "a Kubernetes node label as key=value"
  for name in WORKER_REPLICAS ACTOR_CPU_MILLICORES ACTOR_MEMORY_BYTES GOLDEN_TIMEOUT_SECONDS VERIFY_LOCAL_PORT; do
    require_match "$name" "$RE_NUMBER" "a whole number"
  done
  for name in WORKER_CPU_LIMIT WORKER_CPU_REQUEST WORKER_MEMORY; do
    require_match "$name" "$RE_QUANTITY" "a Kubernetes quantity such as 2, 500m or 4Gi"
  done

  # --- The gateway ---
  require_match GATEWAY_IMAGE "$RE_IMAGE" "an image reference such as python:3.12-slim"
  for name in GATEWAY_MAX_CONNECTIONS GATEWAY_MAX_RUNNING_JOBS GATEWAY_MAX_CHAT_RUNNING_JOBS GATEWAY_JOB_DEADLINE_SECONDS; do
    require_match "$name" "$RE_NUMBER" "a positive whole number"
    if [ "${!name}" -lt 1 ]; then
      die "'${name}' must be at least 1, got '${!name}'."
    fi
  done
  if [ "$GATEWAY_MAX_CHAT_RUNNING_JOBS" -gt "$GATEWAY_MAX_RUNNING_JOBS" ]; then
    die "GATEWAY_MAX_CHAT_RUNNING_JOBS (${GATEWAY_MAX_CHAT_RUNNING_JOBS}) cannot exceed GATEWAY_MAX_RUNNING_JOBS (${GATEWAY_MAX_RUNNING_JOBS})."
  fi
  require_match_if_set GATEWAY_TLS_SECRET "$RE_DNS_NAME" "the name of a Secret"
  if is_true "$AGENT_INGRESS_ENABLED"; then
    require_var AGENT_HOST
    require_match AGENT_HOST "$RE_DNS_NAME" "a lowercase DNS name"
    if [ -z "$AGENT_TLS_SECRET" ]; then
      die "AGENT_INGRESS_ENABLED needs AGENT_TLS_SECRET: the gateway takes passwords, and an Ingress without a certificate would serve it over plain HTTP."
    fi
    require_match AGENT_TLS_SECRET "$RE_DNS_NAME" "the name of a Secret"
    require_match AGENT_INGRESS_CLASS "$RE_DNS_NAME" "the name of an ingress class"
  fi
  # With a certificate the gateway serves HTTPS, and its Service moves to 443.
  if [ -n "$GATEWAY_TLS_SECRET" ]; then
    GATEWAY_SCHEME="https"; GATEWAY_SERVICE_PORT="443"
  else
    GATEWAY_SCHEME="http"; GATEWAY_SERVICE_PORT="80"
  fi

  # The gateway's two credentials.
  local user_pattern='^[A-Za-z0-9._-]{1,64}$'
  for name in GATEWAY_BASIC_AUTH_USER GATEWAY_CHAT_AUTH_USER; do
    if ! [[ "${!name}" =~ $user_pattern ]]; then
      die "'${name}' may hold letters, digits and . _ - only, got '${!name}'."
    fi
  done
  if [ "$GATEWAY_CHAT_AUTH_USER" = "$GATEWAY_BASIC_AUTH_USER" ]; then
    # Two credentials that differ only by password are easy to mix up, and the
    # weaker one is the one that is handed to Looker.
    die "GATEWAY_CHAT_AUTH_USER must differ from GATEWAY_BASIC_AUTH_USER ('${GATEWAY_BASIC_AUTH_USER}')."
  fi
  # A password this script generates has 28 characters. One the operator
  # chooses is not checked by anything else, so at least its length is.
  for name in GATEWAY_BASIC_AUTH_PASSWORD GATEWAY_CHAT_AUTH_PASSWORD; do
    value="${!name:-}"
    if [ -n "$value" ] && [ "${#value}" -lt 16 ]; then
      die "'${name}' is shorter than 16 characters. Use a longer one, or leave it unset and one is generated."
    fi
  done

  # --- The chat extension inside Looker (step 8) ---
  require_lookml_name EXTENSION_PROJECT_NAME
  require_lookml_name EXTENSION_APPLICATION_NAME
  local label_pattern='^[A-Za-z0-9 _.()-]{1,60}$' connection_pattern='^[A-Za-z0-9_.-]+$'
  if ! [[ "$EXTENSION_LABEL" =~ $label_pattern ]]; then
    die "EXTENSION_LABEL may hold letters, digits, spaces and _ . ( ) - only, got '${EXTENSION_LABEL}'."
  fi
  if [ -n "$EXTENSION_LOOKML_CONNECTION" ] && ! [[ "$EXTENSION_LOOKML_CONNECTION" =~ $connection_pattern ]]; then
    die "EXTENSION_LOOKML_CONNECTION is not a Looker connection name: '${EXTENSION_LOOKML_CONNECTION}'."
  fi
  if [ -z "$EXTENSION_SERVER_GATEWAY_URL" ]; then
    if is_true "$DEPLOY_LOOKER"; then
      # Looker runs in this cluster, so its server reaches the gateway's Service.
      EXTENSION_SERVER_GATEWAY_URL="${GATEWAY_SCHEME}://looker-agent-gateway.${GATEWAY_NAMESPACE}.svc.cluster.local"
    elif is_true "$AGENT_INGRESS_ENABLED"; then
      EXTENSION_SERVER_GATEWAY_URL="https://${AGENT_HOST}"
    fi
    # Otherwise it stays empty: step 8 says what to set. Nothing else needs it.
  fi
  if [ -n "$EXTENSION_SERVER_GATEWAY_URL" ]; then
    require_base_url EXTENSION_SERVER_GATEWAY_URL
  fi
  if [ "$EXTENSION_TRANSPORT" = "browser" ]; then
    if [ -z "$EXTENSION_BROWSER_GATEWAY_URL" ]; then
      if ! is_true "$AGENT_INGRESS_ENABLED"; then
        die "EXTENSION_TRANSPORT=\"browser\" needs the gateway on an https address that browsers can reach: set AGENT_INGRESS_ENABLED=\"true\" with AGENT_HOST and AGENT_TLS_SECRET, or set EXTENSION_BROWSER_GATEWAY_URL."
      fi
      EXTENSION_BROWSER_GATEWAY_URL="https://${AGENT_HOST}"
    fi
    require_base_url EXTENSION_BROWSER_GATEWAY_URL
    case "$EXTENSION_BROWSER_GATEWAY_URL" in
      https://*) ;;
      *) die "EXTENSION_BROWSER_GATEWAY_URL must start with https://. Looker's fetch proxy only does https, and a browser on an https page refuses plain http." ;;
    esac
    # The call comes from the Looker page in the user's browser, which is
    # another site as far as the gateway is concerned. Allow exactly that one.
    : "${GATEWAY_CORS_ALLOWED_ORIGINS:=${LOOKER_PUBLIC_URL}}"
  else
    EXTENSION_BROWSER_GATEWAY_URL=""
  fi
  local origins=() origin
  GATEWAY_CORS_ALLOWED_ORIGINS="${GATEWAY_CORS_ALLOWED_ORIGINS// /}"
  IFS=',' read -r -a origins <<< "$GATEWAY_CORS_ALLOWED_ORIGINS"
  for origin in ${origins[@]+"${origins[@]}"}; do
    if ! [[ "$origin" =~ $RE_BASE_URL ]]; then
      die "GATEWAY_CORS_ALLOWED_ORIGINS entries must look like https://host[:port] (lowercase, no path), got '${origin}'."
    fi
  done
  local link_origins=() link_origin
  EXTENSION_ALLOWED_LINK_ORIGINS="${EXTENSION_ALLOWED_LINK_ORIGINS// /}"
  IFS=',' read -r -a link_origins <<< "$EXTENSION_ALLOWED_LINK_ORIGINS"
  for link_origin in ${link_origins[@]+"${link_origins[@]}"}; do
    if ! [[ "$link_origin" =~ $RE_BASE_URL ]] || [[ "$link_origin" != https://* ]]; then
      die "EXTENSION_ALLOWED_LINK_ORIGINS entries must look like https://host[:port] (lowercase, https only, no path), got '${link_origin}'."
    fi
  done
  # Looker keeps the gateway credential in a user attribute that it finds by
  # name: <LookML project>_<application>_<key>.
  EXTENSION_SECRET_KEY="gateway_credential"
  EXTENSION_USER_ATTRIBUTE="${EXTENSION_PROJECT_NAME}_${EXTENSION_APPLICATION_NAME}_${EXTENSION_SECRET_KEY}"

  # The gateway's identity, which Substrate's router is told to admit. It is
  # built from the gateway's namespace, so moving the gateway to another
  # namespace means installing the router's allowlist again.
  GATEWAY_SERVICE_ACCOUNT="looker-agent-gateway"
  GATEWAY_SPIFFE_ID="spiffe://cluster.local/ns/${GATEWAY_NAMESPACE}/sa/${GATEWAY_SERVICE_ACCOUNT}"
  INGRESS_ALLOWED_SPIFFE_IDS="$GATEWAY_SPIFFE_ID"
  if is_true "$ALLOW_KUBECTL_ATE_PROXY"; then
    # Lets an administrator use "kubectl ate proxy actor" for debugging. The
    # router has no finer rule than this list: whoever is on it reaches every
    # actor. So this second identity is off unless asked for.
    INGRESS_ALLOWED_SPIFFE_IDS="${INGRESS_ALLOWED_SPIFFE_IDS},spiffe://cluster.local/ns/ate-system/sa/atenet-client"
  fi
  CREDENTIAL_SECRET="model-credential"
  CREDENTIAL_URI="ate-secret://k8s.io/default/${CREDS_NAMESPACE}/${CREDENTIAL_SECRET}/token"

  report_weak_choices

  log "OK: configuration looks complete."
  log "  platform        : ${PLATFORM}"
  log "  cluster context : ${KUBE_CONTEXT}"
  log "  Looker API      : ${LOOKER_API_URL} (verify TLS: ${LOOKER_VERIFY_SSL})"
  log "  model           : ${AGENT_MODEL_PROVIDER} via ${MODEL_HOST}"
  log "  security mode   : ${SECURITY_MODE}"
}

# Installing Substrate outside GKE means running its local-development profile
# on a real cluster. Make that a decision someone took, not a surprise.
require_onprem_acknowledgement() {
  if [ "$PLATFORM" != "onprem" ] || is_true "$RENDER_ONLY" || is_true "$ONPREM_DEV_PROFILE_ACCEPTED"; then
    return 0
  fi
  cat >&2 <<EOF
ERROR: ONPREM_DEV_PROFILE_ACCEPTED is not "true" in ${CONFIG_FILE}.

Agent Substrate ${SUBSTRATE_VERSION} has no supported install outside GKE. On your
cluster this script uses the installer's local-development profile, which
installs cluster-wide:
  - CRDs and RBAC, and an agent on every node that runs as root with host mounts;
  - a database, and an OpenTelemetry collector, Jaeger and Prometheus
    (namespace otel-system);
  - unless SNAPSHOT_STORE="s3", an object store with fixed built-in credentials.
README.md, "Four things that change the plan", has the details. Set
ONPREM_DEV_PROFILE_ACCEPTED="true" once you have read it and want to go ahead.
EOF
  exit 1
}

# -----------------------------------------------------------------------------
# STEP 0: Preflight
# -----------------------------------------------------------------------------
# Confirms that the cluster's CNI plugin really enforces NetworkPolicy, using a
# throwaway restricted namespace removed right afterwards. Untested on a live
# cluster. Switch off with NETWORK_POLICY_CHECK="false" if another control
# checks this.
check_network_policy_enforcement() {
  local ns="looker-agent-netpol-check" server_ip="" status="" attempt
  NETPOL_CHECK_NS="$ns"
  k delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  {
    namespace_manifest "$ns" restricted
    netpol_default_deny "$ns"
    cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: netpol-server
  namespace: ${ns}
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: server
    image: ${GATEWAY_IMAGE}
    command:
    - python3
    - -B
    - -c
    - |
      import socket
      srv = socket.create_server(('0.0.0.0', 8080))
      while True:
          conn, _ = srv.accept()
          conn.close()
    ports:
    - containerPort: 8080
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
EOF
  } | k apply -f - >/dev/null
  if ! k -n "$ns" wait --for=condition=Ready pod/netpol-server --timeout=60s >/dev/null 2>&1; then
    k delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    NETPOL_CHECK_NS=""
    die "NETWORK_POLICY_CHECK failed: probe pod netpol-server did not become Ready. Set NETWORK_POLICY_CHECK=\"false\" to skip this check."
  fi
  server_ip="$(k -n "$ns" get pod netpol-server -o 'jsonpath={.status.podIP}' 2>/dev/null || true)"
  if [ -z "$server_ip" ]; then
    k delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    NETPOL_CHECK_NS=""
    die "NETWORK_POLICY_CHECK failed: netpol-server had no pod IP."
  fi
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: netpol-client
  namespace: ${ns}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: client
    image: ${GATEWAY_IMAGE}
    command:
    - python3
    - -B
    - -c
    - "import socket, sys; socket.create_connection((sys.argv[1], 8080), timeout=3).close()"
    - "${server_ip}"
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
EOF
  for attempt in $(seq 1 30); do
    status="$(k -n "$ns" get pod netpol-client -o 'jsonpath={.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"
    if [ -n "$status" ]; then break; fi
    sleep 1
  done
  k delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  NETPOL_CHECK_NS=""
  if [ "$status" = "0" ]; then
    die "the cluster did not enforce a deny-all NetworkPolicy (a blocked connection inside ${ns} succeeded). Install or enable a CNI plugin that enforces NetworkPolicy before continuing, or set NETWORK_POLICY_CHECK=\"false\"."
  fi
  if [ -z "$status" ]; then
    die "NETWORK_POLICY_CHECK failed: probe pod netpol-client did not finish."
  fi
  log "OK: NetworkPolicy blocks denied connections."
}

preflight_cluster() {
  k version >/dev/null 2>&1 || die "cannot reach the cluster with context '${KUBE_CONTEXT}'."
  if ! k auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then
    warn "this identity is not cluster-admin. Installing Substrate creates CRDs, RBAC and privileged workloads."
  fi

  # Substrate identifies every component, and this kit's gateway, with pod
  # certificates. Without these two APIs nothing in it can start.
  local served missing="" resource
  served="$(k api-resources --api-group=certificates.k8s.io -o name 2>/dev/null || true)"
  for resource in podcertificaterequests clustertrustbundles; do
    if ! printf '%s\n' "$served" | grep -q "^${resource}\."; then
      missing="${missing} ${resource}"
    fi
  done
  if [ -n "$missing" ]; then
    cat >&2 <<EOF
ERROR: this cluster does not serve:${missing} (certificates.k8s.io).
Agent Substrate needs the PodCertificateRequest and ClusterTrustBundle APIs.
  - GKE serves them from version 1.37.
  - On other clusters they are not on by default (as of Kubernetes 1.36). The
    cluster administrator has to start kube-apiserver and the kubelets with
        --feature-gates=ClusterTrustBundle=true,ClusterTrustBundleProjection=true,PodCertificateRequest=true
    and kube-apiserver also with
        --runtime-config=certificates.k8s.io/v1beta1=true
    That is the configuration Substrate's own test clusters use
    (hack/create-kind-cluster.sh in the Substrate repository).
EOF
    exit 1
  fi
  log "OK: PodCertificateRequest and ClusterTrustBundle APIs are served."

  local defaults
  defaults="$(k get storageclass -o json 2>/dev/null \
    | jq '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")] | length' \
    2>/dev/null || echo 0)"
  if [ "$defaults" = "0" ]; then
    warn "no default StorageClass. Substrate's database and the bundled MySQL and object store need one."
  fi

  if is_true "$NETWORK_POLICY_CHECK"; then
    check_network_policy_enforcement
  fi
}

step_preflight() {
  step "STEP 0: Preflight"
  local tool
  for tool in kubectl jq openssl curl git go "$CONTAINER_TOOL"; do
    need "$tool"
  done
  if [ "$PLATFORM" = "gke" ]; then need gcloud; fi
  # Images are built locally, and Substrate's installer checks the daemon too.
  "$CONTAINER_TOOL" info >/dev/null 2>&1 || die "'${CONTAINER_TOOL} info' failed. Start the container daemon first."
  log "go      : $(go version)"
  log "kubectl : $(kubectl version --client 2>/dev/null | head -n 1)"

  if [ "$PLATFORM" = "gke" ] && ! k version >/dev/null 2>&1; then
    log "The GKE cluster is not reachable yet; step 1 creates it and checks it."
    return 0
  fi
  preflight_cluster
}

# -----------------------------------------------------------------------------
# STEP 1 (GKE only): cluster, snapshot buckets, IAM, image repository
# -----------------------------------------------------------------------------
gcp_project_number() {
  if [ -z "${GCP_PROJECT_NUMBER:-}" ]; then
    GCP_PROJECT_NUMBER="$(gcloud projects describe "$GCP_PROJECT_ID" --format='value(projectNumber)')"
  fi
  printf '%s' "$GCP_PROJECT_NUMBER"
}

# The Workload Identity principal of a Kubernetes ServiceAccount.
gke_principal() {
  printf 'principal://iam.googleapis.com/projects/%s/locations/global/workloadIdentityPools/%s.svc.id.goog/subject/ns/%s/sa/%s' \
    "$(gcp_project_number)" "$GCP_PROJECT_ID" "$1" "$2"
}

ensure_gke_artifact_registry() {
  local registry_path="$1" grant_atelet="$2" description="$3"
  local host location path project repository member
  host="${registry_path%%/*}"
  location="${host%-docker.pkg.dev}"
  path="${registry_path#*/}"
  project="${path%%/*}"
  repository="${path#*/}"
  repository="${repository%%/*}"
  if ! gcloud artifacts repositories describe "$repository" --project="$project" \
      --location="$location" >/dev/null 2>&1; then
    gcloud artifacts repositories create "$repository" --repository-format=docker \
      --project="$project" --location="$location" \
      --description="$description"
  fi
  gcloud auth configure-docker "$host" --quiet
  local members=("serviceAccount:${GKE_NODE_GSA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com")
  if is_true "$grant_atelet"; then
    members+=("$(gke_principal ate-system atelet)")
  fi
  for member in "${members[@]}"; do
    gcloud artifacts repositories add-iam-policy-binding "$repository" \
      --project="$project" --location="$location" \
      --member="$member" --role=roles/artifactregistry.reader >/dev/null
  done
}

step_gke() {
  if [ "$PLATFORM" != "gke" ]; then return 0; fi
  step "STEP 1: Create the GKE cluster and Substrate's cloud resources"
  if is_true "$RENDER_ONLY"; then
    log "[render] would run substrate-gke 'setup-gcp bootstrap' for cluster ${GKE_CLUSTER_NAME} in ${GKE_CLUSTER_LOCATION}."
    return 0
  fi
  need gcloud
  local project_number
  project_number="$(gcp_project_number)"

  gcloud services enable container.googleapis.com artifactregistry.googleapis.com \
    aiplatform.googleapis.com iam.googleapis.com --project="$GCP_PROJECT_ID"

  # Substrate's GKE tooling creates the cluster (1.37, Workload Identity, the
  # certificate APIs), the snapshot buckets, the service accounts and the IAM
  # bindings. It is idempotent and never deletes an existing cluster.
  checkout "$SUBSTRATE_GKE_REPO_URL" "$SUBSTRATE_GKE_REF" "$SUBSTRATE_GKE_DIR"
  (
    cd "$SUBSTRATE_GKE_DIR"
    export PROJECT_ID="$GCP_PROJECT_ID" PROJECT_NUMBER="$project_number"
    export GCE_REGION="$GCP_REGION" CLUSTER_LOCATION="$GKE_CLUSTER_LOCATION"
    export NETWORK="$GKE_NETWORK" SUBNETWORK="$GKE_SUBNETWORK"
    export CLUSTER_NAME="$GKE_CLUSTER_NAME" CLUSTER_VERSION="$GKE_CLUSTER_VERSION"
    export RELEASE_CHANNEL="$GKE_RELEASE_CHANNEL" NODE_MACHINE_TYPE="$GKE_MACHINE_TYPE"
    # gVisor sandboxes only, so the nodes do not need nested virtualization.
    export ENABLE_NESTED_VIRTUALIZATION="false"
    export SEPARATE_SYSTEM_NODES="$GKE_SEPARATE_SYSTEM_NODES"
    export BUCKET_NAME="$GKE_SNAPSHOT_BUCKET" SNAPSHOT_LOCATION="gs://${GKE_SNAPSHOT_BUCKET}/"
    export SNAPSHOT_TRANSFER_GSA_NAME="$GKE_TRANSFER_GSA_NAME" NODE_GSA_NAME="$GKE_NODE_GSA_NAME"
    go -C tools/setup-gcp run . bootstrap
  )

  gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" \
    --location "$GKE_CLUSTER_LOCATION" --project "$GCP_PROJECT_ID"
  preflight_cluster

  # Image repository. The nodes pull the Looker image; Substrate's atelet pulls
  # the agent image itself, with its own identity.
  ensure_gke_artifact_registry "$REGISTRY" true "Looker and Looker agent images"
  if [ -n "$LOOKER_REGISTRY" ] && [ "$LOOKER_REGISTRY" != "$REGISTRY" ]; then
    case "$LOOKER_REGISTRY" in
      *-docker.pkg.dev/*/*)
        ensure_gke_artifact_registry "$LOOKER_REGISTRY" false "Looker images" ;;
    esac
  fi
  log "OK: cluster ${GKE_CLUSTER_NAME} is ready (context ${KUBE_CONTEXT})."
}

# -----------------------------------------------------------------------------
# STEP 2: Customer-hosted Looker
# -----------------------------------------------------------------------------
download_looker_jars() {
  local dir="$1" response="$1/download-response.json" url dep_url sha dep_sha link
  [ -n "${LOOKER_LICENSE_KEY:-}" ] || die "export LOOKER_LICENSE_KEY to download Looker (or set LOOKER_IMAGE to an image you already have)."
  log "Requesting Looker ${LOOKER_VERSION} from the Looker download service..."
  # The license key must not show up in the process list, where every user of
  # this machine can read it. jq takes it from its environment, which this one
  # command is given, and curl takes the request body from stdin.
  LOOKER_LICENSE_KEY="$LOOKER_LICENSE_KEY" jq -cn --arg email "$LOOKER_TECHNICAL_CONTACT_EMAIL" \
      --arg jar "looker-${LOOKER_VERSION}-latest.jar" \
      '{lic: env.LOOKER_LICENSE_KEY, email: $email, latest: "specific", specific: $jar}' \
    | curl -fsS --proto '=https' -X POST -H 'Content-Type: application/json' --data @- \
        -o "$response" "$LOOKER_DOWNLOAD_API"
  if jq -e '(.eulaMessage // "") | test("EULA")' "$response" >/dev/null 2>&1; then
    die "the Looker EULA has not been accepted for this license key and email. Accept it at https://download.looker.com/validate and run again."
  fi
  url="$(jq -r '.url // empty' "$response")"
  dep_url="$(jq -r '.depUrl // empty' "$response")"
  sha="$(jq -r '.sha256 // empty' "$response" | tr -d '\n' | tr 'A-F' 'a-f')"
  dep_sha="$(jq -r '.depSha256 // empty' "$response" | tr -d '\n' | tr 'A-F' 'a-f')"
  if [ -z "$url" ] || [ -z "$dep_url" ]; then
    die "the Looker download service did not return download links. Check LOOKER_VERSION, the license key and the email."
  fi
  # The links come out of an answer, so they are held to https, and curl is
  # told to follow nothing else either, not even through a redirect.
  for link in "$url" "$dep_url"; do
    if [[ "$link" != https://* ]]; then
      die "the Looker download service returned a link that is not an https address."
    fi
  done
  curl -fSL --proto '=https' --proto-redir '=https' "$url" -o "${dir}/looker.jar"
  curl -fSL --proto '=https' --proto-redir '=https' "$dep_url" -o "${dir}/looker-dependencies.jar"
  rm -f "$response"
  [ "$(sha256_of "${dir}/looker.jar")" = "$sha" ] || die "checksum mismatch for looker.jar."
  [ "$(sha256_of "${dir}/looker-dependencies.jar")" = "$dep_sha" ] || die "checksum mismatch for looker-dependencies.jar."
  log "OK: Looker JARs downloaded and verified."
}

# pushed_digest REPOSITORY TAG: the digest reference ("repository@sha256:...")
# of an image this machine has just pushed. A tag can be pointed at other
# content later; the digest names exactly what was built here.
pushed_digest() {
  local repository="$1" tag="$2" digest_ref
  digest_ref="$("$CONTAINER_TOOL" inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    "${repository}:${tag}" | grep -F "${repository}@sha256:" | head -n 1 || true)"
  [ -n "$digest_ref" ] || die "could not read the pushed digest of ${repository}:${tag}."
  printf '%s' "$digest_ref"
}

resolve_looker_image() {
  if [ -n "$LOOKER_IMAGE" ]; then
    LOOKER_IMAGE_REF="$LOOKER_IMAGE"
    return 0
  fi
  local repository="${LOOKER_REGISTRY:-$REGISTRY}/looker" state="${STATE_DIR}/looker-image" built digest_ref
  if is_true "$RENDER_ONLY"; then
    LOOKER_IMAGE_REF="${repository}@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    return 0
  fi
  # What the state file remembers: what was built (first line) and the digest
  # it was pushed as (second line).
  built="${repository}:${LOOKER_VERSION} base=${LOOKER_BASE_IMAGE} java=${LOOKER_JAVA_PACKAGE} chromium-no-sandbox=${LOOKER_CHROMIUM_NO_SANDBOX}"
  if [ -f "$state" ] && [ "$(sed -n 1p "$state")" = "$built" ] && ! is_true "$LOOKER_REBUILD"; then
    digest_ref="$(sed -n 2p "$state")"
    if is_pinned_image "$digest_ref"; then
      LOOKER_IMAGE_REF="$digest_ref"
      log "Looker image already built and pushed: ${digest_ref} (LOOKER_REBUILD=true rebuilds)."
      return 0
    fi
  fi
  local context="${WORK_DIR}/build/looker"
  rm -rf "$context"
  mkdir -p "$context"
  LOOKER_BUILD_DIR="$context"
  cp -R "${SCRIPT_DIR}/looker/." "$context/"
  download_looker_jars "$context"
  "$CONTAINER_TOOL" build --platform "$IMAGE_PLATFORM" \
    --build-arg "BASE_IMAGE=${LOOKER_BASE_IMAGE}" \
    --build-arg "JAVA_PACKAGE=${LOOKER_JAVA_PACKAGE}" \
    --build-arg "CHROMIUM_NO_SANDBOX=${LOOKER_CHROMIUM_NO_SANDBOX}" \
    -t "${repository}:${LOOKER_VERSION}" "$context"
  "$CONTAINER_TOOL" push "${repository}:${LOOKER_VERSION}"
  # The JARs are licensed software. Do not leave copies in the work directory.
  rm -rf "$context"
  LOOKER_BUILD_DIR=""
  # Looker is deployed by the digest of what was just pushed, like the agent.
  digest_ref="$(pushed_digest "$repository" "$LOOKER_VERSION")"
  printf '%s\n%s\n' "$built" "$digest_ref" > "$state"
  LOOKER_IMAGE_REF="$digest_ref"
}

ensure_looker_secrets() {
  local tmp fresh="false" password db_host db_pass
  LOOKER_DB_CREDS_CHANGED="false"
  if ! secret_exists "$LOOKER_NAMESPACE" looker-secrets; then
    fresh="true"
  fi
  # For step_looker: whether this run is the one that sets Looker up.
  LOOKER_FRESH_INSTALL="$fresh"

  # On a brand-new instance Looker reads provision.yml once, to install the
  # license and create the first admin user. The Secret is made only together
  # with a new instance: the next steps ask the operator to delete it once it
  # has done its work, and a later run must not bring it back. It is made
  # before looker-secrets, so that a run that stops in between starts over here.
  if is_true "$fresh" && [ -n "${LOOKER_LICENSE_KEY:-}" ] \
      && ! secret_exists "$LOOKER_NAMESPACE" looker-provision; then
    require_var LOOKER_ADMIN_EMAIL
    ensure_tmp_dir; tmp="$TMP_DIR"
    password="$(gen_alnum 20)-Lk9"
    {
      printf 'license_key: %s\n' "$(yaml_sq "$LOOKER_LICENSE_KEY")"
      printf 'host_url: %s\n' "$(yaml_sq "$LOOKER_PUBLIC_URL")"
      printf 'user:\n'
      printf '  first_name: "Looker"\n'
      printf '  last_name: "Admin"\n'
      printf '  email: %s\n' "$(yaml_sq "$LOOKER_ADMIN_EMAIL")"
      printf '  password: %s\n' "$(yaml_sq "$password")"
    } > "${tmp}/provision.yml"
    printf '%s' "$password" > "${tmp}/admin-password"
    k -n "$LOOKER_NAMESPACE" create secret generic looker-provision \
      --from-file=provision.yml="${tmp}/provision.yml" \
      --from-file=admin-password="${tmp}/admin-password" >/dev/null
    forget "${tmp}/provision.yml" "${tmp}/admin-password"
    log "Created Secret ${LOOKER_NAMESPACE}/looker-provision (license and first admin user)."
  fi

  if is_true "$fresh"; then
    ensure_tmp_dir; tmp="$TMP_DIR"
    # The GCM key encrypts Looker's internal database. It is created once and
    # never regenerated: lose it and that database cannot be read again.
    openssl rand -base64 32 | tr -d '\n' > "${tmp}/gcm-key"
    if [ -n "$LOOKER_DB_HOST" ]; then
      [ -n "${LOOKER_DB_PASSWORD:-}" ] || die "export LOOKER_DB_PASSWORD (the password of ${LOOKER_DB_USER} on ${LOOKER_DB_HOST})."
      db_pass="$LOOKER_DB_PASSWORD"
    else
      db_pass="$(gen_alnum 32 | tr -d '\n')"
    fi
    printf '%s' "$db_pass" > "${tmp}/db-pass"
    gen_alnum 32 | tr -d '\n' > "${tmp}/mysql-root-pass"
    k -n "$LOOKER_NAMESPACE" create secret generic looker-secrets \
      --from-file=gcm-key="${tmp}/gcm-key" --from-file=db-pass="${tmp}/db-pass" \
      --from-file=mysql-root-pass="${tmp}/mysql-root-pass" >/dev/null
    forget "${tmp}/gcm-key" "${tmp}/db-pass" "${tmp}/mysql-root-pass"
    warn "created Secret ${LOOKER_NAMESPACE}/looker-secrets. BACK UP its gcm-key: without it Looker's database cannot be decrypted."
  else
    if [ -n "$LOOKER_DB_HOST" ] && [ -n "${LOOKER_DB_PASSWORD:-}" ]; then
      db_pass="$LOOKER_DB_PASSWORD"
    else
      db_pass="$(k -n "$LOOKER_NAMESPACE" get secret looker-secrets -o 'jsonpath={.data.db-pass}' | base64 -d)"
    fi
  fi

  db_host="$LOOKER_DB_HOST"
  if [ -z "$db_host" ]; then
    db_host="looker-mysql.${LOOKER_NAMESPACE}.svc.cluster.local"
  fi
  ensure_tmp_dir; tmp="$TMP_DIR"
  {
    printf 'dialect: %s\n' "$(yaml_sq "$LOOKER_DB_DIALECT")"
    printf 'host: %s\n' "$(yaml_sq "$db_host")"
    printf 'username: %s\n' "$(yaml_sq "$LOOKER_DB_USER")"
    printf 'password: %s\n' "$(yaml_sq "$db_pass")"
    printf 'database: %s\n' "$(yaml_sq "$LOOKER_DB_NAME")"
    printf 'port: %s\n' "$LOOKER_DB_PORT"
    if is_true "$LOOKER_DB_SSL"; then
      printf 'ssl: true\n'
      if is_true "$LOOKER_DB_VERIFY_SSL"; then
        printf 'verify_ssl: true\n'
      fi
    fi
  } > "${tmp}/looker-db.yml"
  create_or_replace_secret "$LOOKER_NAMESPACE" looker-db-creds \
    "looker-db.yml=${tmp}/looker-db.yml"
  forget "${tmp}/looker-db.yml"
  if [ "$SECRET_CHANGE" = "replaced" ]; then
    LOOKER_DB_CREDS_CHANGED="true"
  fi
}

render_looker() {
  local out="${RENDER_DIR}/looker.yaml" db_host access_mode storage_class_line="" mysql_storage_class_line=""
  local provision="$1" bundled_mysql="false" several_nodes="false" cidr cidrs=() mysql_probe_cmd
  db_host="$LOOKER_DB_HOST"
  if [ -z "$db_host" ]; then
    bundled_mysql="true"
    db_host="looker-mysql.${LOOKER_NAMESPACE}.svc.cluster.local"
  fi
  if [ "$LOOKER_REPLICAS" = "1" ]; then access_mode="ReadWriteOnce"; else access_mode="ReadWriteMany"; several_nodes="true"; fi
  if [ -n "$LOOKER_STORAGE_CLASS" ]; then storage_class_line="  storageClassName: ${LOOKER_STORAGE_CLASS}"; fi
  # The database gets its own setting: the shared-files class is often NFS,
  # which is the wrong place for MySQL data.
  if [ -n "$LOOKER_MYSQL_STORAGE_CLASS" ]; then mysql_storage_class_line="  storageClassName: ${LOOKER_MYSQL_STORAGE_CLASS}"; fi
  if is_true "$LOOKER_DB_SSL"; then
    mysql_probe_cmd='["mysqladmin", "ping", "-h", "127.0.0.1", "--ssl-mode=REQUIRED", "--silent"]'
  else
    mysql_probe_cmd='["mysqladmin", "ping", "-h", "127.0.0.1", "--silent"]'
  fi
  IFS=',' read -r -a cidrs <<< "$LOOKER_EGRESS_CIDRS"

  {
    cat <<EOF
# Customer-hosted Looker. Rendered by deploy.sh; edit config.env, not this file.
# Derived from the Helm chart in GoogleCloudPlatform/looker-hosting-reference-implementations
# (builders/helm), with its Google Cloud pieces replaced by plain Kubernetes ones:
# a Secret instead of Secret Manager, a database host instead of the Cloud SQL
# proxy, and a PersistentVolumeClaim instead of a Filestore address.
#
# Pod Security: Looker's and MySQL's pods fit the "baseline" level. What still
# separates them from "restricted" is reported by audit and warn: Looker's
# container has no seccomp profile unless LOOKER_SECCOMP_PROFILE names one.
$(namespace_manifest "$LOOKER_NAMESPACE" "$LOOKER_POD_SECURITY" restricted)
EOF

    if is_true "$NETWORK_POLICIES"; then
      netpol_default_deny "$LOOKER_NAMESPACE"
      if is_true "$bundled_mysql"; then
        cat <<EOF
---
# MySQL: Looker's pods may connect, and nobody else. MySQL opens no connection
# of its own, so it gets no way out at all.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: looker-mysql
  namespace: ${LOOKER_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: looker-mysql
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: looker
    ports:
    - protocol: TCP
      port: 3306
EOF
      fi
      cat <<EOF
---
# Looker: who may connect to it, and what it may connect to. The UI is reached
# through "kubectl port-forward" (which these rules do not filter) or through
# the Ingress.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: looker
  namespace: ${LOOKER_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: looker
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # The agent. Its calls arrive through Substrate's egress gateway, and only
  # the API port is for it.
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ate-system
      podSelector:
        matchLabels:
          app: atenet-egress
    ports:
    - protocol: TCP
      port: 19999
EOF
      if is_true "$several_nodes"; then
        cat <<EOF
  # The other Looker nodes, on Looker's two cluster ports.
  - from:
    - podSelector:
        matchLabels:
          app: looker
    ports:
    - protocol: TCP
      port: 1551
    - protocol: TCP
      port: 61616
EOF
      fi
      if is_true "$LOOKER_INGRESS_ENABLED"; then
        cat <<EOF
  # The ingress controller.
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${INGRESS_CONTROLLER_NAMESPACE}
    ports:
    - protocol: TCP
      port: 9999
    - protocol: TCP
      port: 19999
EOF
      fi
      printf '  egress:\n'
      netpol_dns_egress
      if is_true "$bundled_mysql"; then
        cat <<EOF
  # Its own database.
  - to:
    - podSelector:
        matchLabels:
          app: looker-mysql
    ports:
    - protocol: TCP
      port: 3306
EOF
      fi
      if is_true "$several_nodes"; then
        cat <<EOF
  # The other Looker nodes.
  - to:
    - podSelector:
        matchLabels:
          app: looker
    ports:
    - protocol: TCP
      port: 1551
    - protocol: TCP
      port: 61616
EOF
      fi
      cat <<EOF
  # The chat: Looker's server calls the gateway for the extension.
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${GATEWAY_NAMESPACE}
      podSelector:
        matchLabels:
          app: looker-agent-gateway
    ports:
    - protocol: TCP
      port: 8080
  # LOOKER_EGRESS_CIDRS: what Looker itself has to reach, such as the
  # databases it queries, Git and mail.
EOF
      if [[ ",${LOOKER_EGRESS_CIDRS}," == *,0.0.0.0/0,* ]]; then
        # "Anywhere" is written as a rule without a destination. An address
        # block would not, with every network plugin, cover the pods and
        # services of this cluster, and "anywhere" includes them.
        cat <<EOF
  # 0.0.0.0/0: anywhere, pods of this cluster included, on every port.
  - {}
EOF
      else
        for cidr in ${cidrs[@]+"${cidrs[@]}"}; do
          cat <<EOF
  - to:
    - ipBlock:
        cidr: ${cidr}
EOF
        done
      fi
    fi

    if is_true "$bundled_mysql"; then
      cat <<EOF
---
# Bundled MySQL for Looker's own database. Trial use only: one replica, no backups.
apiVersion: v1
kind: ConfigMap
metadata:
  name: looker-mysql-init
  namespace: ${LOOKER_NAMESPACE}
data:
EOF
      # Static: every \${...} below is expanded inside the MySQL container.
      cat <<'EOF'
  01-looker-database.sh: |
    #!/bin/bash
    # Runs once, when MySQL initialises an empty data directory.
    # Settings follow Looker's "Migrating the Looker backend database to MySQL"
    # guide for MySQL 8.4: utf8mb4 with the utf8mb4_general_ci collation, a
    # user that signs in with caching_sha2_password (MySQL 8.4's own default,
    # which Looker supports from release 26.6), and a grant on looker_tmp.
    set -euo pipefail
    # The root password reaches the client through a file descriptor, the way
    # the image's own entrypoint passes it, and so is not in the process list.
    mysql --defaults-extra-file=<(printf '[client]\npassword="%s"\n' "${MYSQL_ROOT_PASSWORD}") \
      --protocol=socket -uroot <<SQL
    CREATE DATABASE IF NOT EXISTS \`${LOOKER_DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_general_ci;
    CREATE USER IF NOT EXISTS '${LOOKER_DB_USER}'@'%' IDENTIFIED WITH caching_sha2_password BY '${LOOKER_DB_PASS}';
    GRANT ALL ON \`${LOOKER_DB_NAME}\`.* TO '${LOOKER_DB_USER}'@'%';
    GRANT ALL ON \`looker_tmp\`.* TO '${LOOKER_DB_USER}'@'%';
    FLUSH PRIVILEGES;
    SQL
EOF
      cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: looker-mysql
  namespace: ${LOOKER_NAMESPACE}
spec:
  clusterIP: None
  selector:
    app: looker-mysql
  ports:
  - name: mysql
    port: 3306
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: looker-mysql
  namespace: ${LOOKER_NAMESPACE}
spec:
  serviceName: looker-mysql
  replicas: 1
  selector:
    matchLabels:
      app: looker-mysql
  template:
    metadata:
      labels:
        app: looker-mysql
    spec:
      # MySQL never calls the Kubernetes API, so it gets no token for it.
      automountServiceAccountToken: false
      securityContext:
        # The image's own "mysql" user. Started as root the image would switch
        # to it by itself; started as this user it never holds root at all.
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: mysql
        image: ${LOOKER_MYSQL_IMAGE}
        args:
        - --character-set-server=utf8mb4
        - --collation-server=utf8mb4_general_ci
        - --max-allowed-packet=1073741824
        - --internal-tmp-mem-storage-engine=MEMORY
EOF
      if is_true "$LOOKER_DB_SSL"; then
        cat <<EOF
        # Connections over the network have to be encrypted. MySQL makes its
        # own certificate on first start; Looker encrypts but does not verify it.
        - --require-secure-transport=ON
EOF
      fi
      cat <<EOF
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: looker-secrets
              key: mysql-root-pass
        # Without this the image also creates a root account that can sign in
        # from any address. Root is only ever needed over the local socket.
        - name: MYSQL_ROOT_HOST
          value: localhost
        - name: LOOKER_DB_PASS
          valueFrom:
            secretKeyRef:
              name: looker-secrets
              key: db-pass
        - name: LOOKER_DB_NAME
          value: $(yaml_sq "$LOOKER_DB_NAME")
        - name: LOOKER_DB_USER
          value: $(yaml_sq "$LOOKER_DB_USER")
        ports:
        - name: mysql
          containerPort: 3306
        # The three probes ask "does the server answer?" and sign in as nobody:
        # mysqladmin reports a running server even when it is refused. So no
        # password is part of a command that runs every few seconds.
        # The first start creates the data directory, without listening on the
        # network. The startup probe gives that time (15 minutes) before the
        # liveness probe may restart anything.
        startupProbe:
          exec:
            command: ${mysql_probe_cmd}
          periodSeconds: 10
          failureThreshold: 90
        readinessProbe:
          exec:
            command: ${mysql_probe_cmd}
          periodSeconds: 10
        livenessProbe:
          exec:
            command: ${mysql_probe_cmd}
          periodSeconds: 20
          failureThreshold: 6
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            memory: 2Gi
            ephemeral-storage: 10Gi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
        - name: init
          mountPath: /docker-entrypoint-initdb.d
          readOnly: true
        # The image is read-only. These two are what MySQL writes besides its data.
        - name: run
          mountPath: /var/run/mysqld
        - name: tmp
          mountPath: /tmp
      volumes:
      - name: init
        configMap:
          name: looker-mysql-init
          defaultMode: 493
      - name: run
        emptyDir:
          sizeLimit: 16Mi
      - name: tmp
        emptyDir:
          sizeLimit: 8Gi
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
      - ReadWriteOnce
${mysql_storage_class_line:+    ${mysql_storage_class_line}
}      resources:
        requests:
          storage: ${LOOKER_MYSQL_STORAGE_SIZE}
EOF
    fi

    cat <<EOF
---
# Models, deploy keys and other files Looker shares between nodes.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: looker-files
  namespace: ${LOOKER_NAMESPACE}
spec:
  accessModes:
  - ${access_mode}
${storage_class_line:+${storage_class_line}
}  resources:
    requests:
      storage: ${LOOKER_STORAGE_SIZE}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: looker-startup-options
  namespace: ${LOOKER_NAMESPACE}
data:
  # Sourced by /app/bin/looker.sh. POD_IP is expanded in the container.
  lookerstart.cfg: |
EOF
    if [ "$INTERNAL_TLS" = "private-ca" ]; then
      cat <<EOF
    JAVAARGS="-Djavax.net.ssl.trustStore=/app/tls/cacerts"
    LOOKERARGS="--internal-db-creds=/run/looker-db/looker-db.yml --shared-storage-dir=/mnt/lookerfiles --clustered -H \$POD_IP --ssl-keystore=/app/tls/looker.jks --ssl-keystore-pass-file=/app/tls/.keystorepass ${LOOKER_STARTUP_FLAGS}"
EOF
    else
      cat <<EOF
    LOOKERARGS="--internal-db-creds=/run/looker-db/looker-db.yml --shared-storage-dir=/mnt/lookerfiles --clustered -H \$POD_IP ${LOOKER_STARTUP_FLAGS}"
EOF
    fi
    cat <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: looker
  namespace: ${LOOKER_NAMESPACE}
  labels:
    app: looker
spec:
  replicas: ${LOOKER_REPLICAS}
  selector:
    matchLabels:
      app: looker
  strategy:
EOF
    if [ "$LOOKER_REPLICAS" = "1" ]; then
      # One replica on a ReadWriteOnce volume: the old pod must release the
      # volume before the new one can start.
      printf '    type: Recreate\n'
    else
      printf '    type: RollingUpdate\n    rollingUpdate:\n      maxSurge: 1\n      maxUnavailable: 0\n'
    fi
    cat <<EOF
  template:
    metadata:
      labels:
        app: looker
    spec:
      # Looker never calls the Kubernetes API, so it gets no token for it.
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 9999
        runAsGroup: 9999
        fsGroup: 9999
        fsGroupChangePolicy: OnRootMismatch
EOF
    if [ -n "$LOOKER_IMAGE_PULL_SECRET" ]; then
      cat <<EOF
      imagePullSecrets:
      - name: ${LOOKER_IMAGE_PULL_SECRET}
EOF
    fi
    if is_true "$LOOKER_CHOWN_SHARED_FILES" || [ "$INTERNAL_TLS" = "private-ca" ]; then
      printf '      initContainers:\n'
    fi
    if is_true "$LOOKER_CHOWN_SHARED_FILES"; then
      cat <<EOF
      # Some NFS exports ignore fsGroup. This hands the top of the share to
      # Looker's user, and does nothing when it already belongs to it. It is
      # the one container of this kit that runs as root, and the right to
      # change a file's owner is the only capability it holds.
      - name: own-shared-files
        image: ${BUSYBOX_IMAGE}
        command:
        - sh
        - -c
        - '[ "\$(stat -c %u /mnt/lookerfiles)" = 9999 ] || chown 9999:9999 /mnt/lookerfiles'
        securityContext:
          runAsUser: 0
          runAsNonRoot: false
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
            add: ["CHOWN"]
          seccompProfile:
            type: RuntimeDefault
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            memory: 64Mi
            ephemeral-storage: 16Mi
        volumeMounts:
        - name: lookerfiles
          mountPath: /mnt/lookerfiles
EOF
    fi
    if [ "$INTERNAL_TLS" = "private-ca" ]; then
      cat <<'EOF'
      # Converts the certificate Secret into a Java keystore and adds the
      # private CA to a copy of the JDK truststore, all in memory.
      - name: prepare-tls
EOF
      cat <<EOF
        image: ${LOOKER_IMAGE_REF}
        command:
        - sh
        - -c
        - |
          set -eu
          umask 077
          cp /run/looker-tls/tls.crt /app/tls/looker.pem
          printf '\n' >> /app/tls/looker.pem
          cat /run/looker-tls/ca.crt >> /app/tls/looker.pem
          cp /run/looker-tls/keystore-pass /app/tls/.keystorepass
          openssl pkcs12 -export -name 1 \
            -in /app/tls/looker.pem \
            -inkey /run/looker-tls/tls.key \
            -passout file:/app/tls/.keystorepass \
            -out /app/tls/importme.p12
          keytool -importkeystore -noprompt \
            -srckeystore /app/tls/importme.p12 \
            -srcstoretype pkcs12 \
            -srcstorepass:file /app/tls/.keystorepass \
            -destkeystore /app/tls/looker.jks \
            -deststorepass:file /app/tls/.keystorepass \
            -alias 1
          rm -f /app/tls/importme.p12 /app/tls/looker.pem
          cacerts=/etc/ssl/certs/java/cacerts
          [ -r "\$cacerts" ] || cacerts="\$(dirname "\$(dirname "\$(readlink -f "\$(command -v keytool)")")")/lib/security/cacerts"
          cp "\$cacerts" /app/tls/cacerts
          chmod 0600 /app/tls/cacerts
          keytool -importcert -noprompt -trustcacerts \
            -alias looker-kit-internal-ca \
            -file /run/looker-tls/ca.crt \
            -keystore /app/tls/cacerts \
            -storepass changeit
        securityContext:
          runAsNonRoot: true
          runAsUser: 9999
          runAsGroup: 9999
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
          seccompProfile:
            type: RuntimeDefault
        resources:
          requests:
            cpu: 10m
            memory: 64Mi
          limits:
            memory: 256Mi
            ephemeral-storage: 64Mi
        volumeMounts:
        - name: looker-tls
          mountPath: /run/looker-tls
          readOnly: true
        - name: looker-tls-work
          mountPath: /app/tls
        - name: looker-tls-tmp
          mountPath: /tmp
EOF
    fi
    cat <<EOF
      containers:
      - name: looker
        image: ${LOOKER_IMAGE_REF}
        env:
        - name: LKR_MASTER_KEY_ENV
          valueFrom:
            secretKeyRef:
              name: looker-secrets
              key: gcm-key
        - name: LOOKER_HEAP_PERCENT
          value: "${LOOKER_HEAP_PERCENT}"
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        ports:
        - name: looker-web
          containerPort: 9999
        - name: looker-api
          containerPort: 19999
EOF
    if is_true "$several_nodes"; then
      cat <<EOF
        - name: looker-cluster
          containerPort: 1551
        - name: looker-broker
          containerPort: 61616
EOF
    fi
    cat <<EOF
        # The first start runs database migrations and can take several minutes.
        startupProbe:
          httpGet:
            path: /alive
            port: 9999
            scheme: HTTPS
          periodSeconds: 10
          failureThreshold: 120
        readinessProbe:
          httpGet:
            path: /alive
            port: 9999
            scheme: HTTPS
          periodSeconds: 5
          successThreshold: 2
        livenessProbe:
          httpGet:
            path: /availability?mode=pod-liveness
            port: 9999
            scheme: HTTPS
          periodSeconds: 30
        resources:
          requests:
            cpu: ${LOOKER_CPU_REQUEST}
            memory: ${LOOKER_MEMORY}
          limits:
            memory: ${LOOKER_MEMORY}
            # What Looker may write outside its volumes (its home directory,
            # temporary files of renders) before the node evicts the pod.
            ephemeral-storage: ${LOOKER_EPHEMERAL_STORAGE_LIMIT}
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
EOF
    if [ -n "$LOOKER_SECCOMP_PROFILE" ]; then
      cat <<EOF
          seccompProfile:
            type: ${LOOKER_SECCOMP_PROFILE}
EOF
    else
      cat <<EOF
          # No seccomp profile is named here, on purpose: Looker renders
          # dashboards with Chromium, Chromium's own sandbox needs to create
          # user namespaces, and the RuntimeDefault profile forbids that. To
          # run under RuntimeDefault, set LOOKER_SECCOMP_PROFILE together with
          # LOOKER_CHROMIUM_NO_SANDBOX="true".
EOF
    fi
    cat <<EOF
        volumeMounts:
        - name: lookerfiles
          mountPath: /mnt/lookerfiles
        - name: looker-db-creds
          mountPath: /run/looker-db
          readOnly: true
        - name: startup-options
          mountPath: /app/lookerstart.cfg
          subPath: lookerstart.cfg
EOF
    if [ "$INTERNAL_TLS" = "private-ca" ]; then
      cat <<EOF
        - name: looker-tls-work
          mountPath: /app/tls
          readOnly: true
        - name: looker-tls-work
          mountPath: /etc/ssl/certs/java/cacerts
          subPath: cacerts
          readOnly: true
EOF
    fi
    if is_true "$provision"; then
      cat <<EOF
        - name: provision
          mountPath: /app/provision.yml
          subPath: provision.yml
          readOnly: true
EOF
    fi
    cat <<EOF
      volumes:
      - name: lookerfiles
        persistentVolumeClaim:
          claimName: looker-files
      - name: looker-db-creds
        secret:
          secretName: looker-db-creds
          defaultMode: 288
      - name: startup-options
        configMap:
          name: looker-startup-options
EOF
    if [ "$INTERNAL_TLS" = "private-ca" ]; then
      cat <<EOF
      - name: looker-tls
        secret:
          secretName: looker-tls
          defaultMode: 288
      - name: looker-tls-work
        emptyDir:
          medium: Memory
          sizeLimit: 32Mi
      - name: looker-tls-tmp
        emptyDir:
          medium: Memory
          sizeLimit: 16Mi
EOF
    fi
    if is_true "$provision"; then
      cat <<EOF
      - name: provision
        secret:
          secretName: looker-provision
          items:
          - key: provision.yml
            path: provision.yml
EOF
    fi
    cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: looker-web
  namespace: ${LOOKER_NAMESPACE}
spec:
  selector:
    app: looker
  ports:
  - name: looker-web
    port: 443
    targetPort: looker-web
---
# The agent calls this one. Looker serves it over HTTPS with its own
# self-signed certificate.
apiVersion: v1
kind: Service
metadata:
  name: looker-api
  namespace: ${LOOKER_NAMESPACE}
spec:
  selector:
    app: looker
  ports:
  - name: looker-api
    port: 443
    targetPort: looker-api
EOF

    if is_true "$LOOKER_INGRESS_ENABLED"; then
      cat <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: looker
  namespace: ${LOOKER_NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    # Plain HTTP is answered with a redirect to HTTPS, never with Looker.
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: 100m
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "120"
spec:
  ingressClassName: ${LOOKER_INGRESS_CLASS}
  tls:
  - hosts:
    - ${LOOKER_HOST}
    secretName: ${LOOKER_TLS_SECRET}
  rules:
  - host: ${LOOKER_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: looker-web
            port:
              name: looker-web
      - path: /api/
        pathType: Prefix
        backend:
          service:
            name: looker-api
            port:
              name: looker-api
      - path: /api-docs/
        pathType: Prefix
        backend:
          service:
            name: looker-api
            port:
              name: looker-api
      - path: /versions
        pathType: Prefix
        backend:
          service:
            name: looker-api
            port:
              name: looker-api
      - path: /api/internal/
        pathType: Prefix
        backend:
          service:
            name: looker-web
            port:
              name: looker-web
EOF
    fi
  } > "$out"
  log "Rendered ${out}"
}

print_looker_next_steps() {
  local embed_step=""
  if [ "$LOOKER_LINK_MODE" = "signed" ]; then
    embed_step="
  5. Admin > Embed: enable \"Embed SSO Authentication\". The signed links that
     LOOKER_LINK_MODE=\"signed\" makes the agent return need it."
  fi
  cat <<EOF

Looker is running. Before the agent can use it:

  1. Open the UI. Without an Ingress:
       kubectl --context ${KUBE_CONTEXT} -n ${LOOKER_NAMESPACE} port-forward svc/looker-web 9999:443
       https://localhost:9999   (the certificate is Looker's self-signed one)
     First admin user: ${LOOKER_ADMIN_EMAIL:-<the one you provisioned>}
     Its password:
       kubectl --context ${KUBE_CONTEXT} -n ${LOOKER_NAMESPACE} get secret looker-provision -o jsonpath='{.data.admin-password}' | base64 -d
  2. Change that password right away (your account menu > Account), then
     delete the Secret that holds it and the license key. Looker read it once
     and has no further use for it:
       kubectl --context ${KUBE_CONTEXT} -n ${LOOKER_NAMESPACE} delete secret looker-provision
     The next run of this script then stops mounting it into the Looker pod.
  3. Add a database connection and a LookML project. A new instance has no
     models, so the agent has nothing to query until you do.
  4. Create a dedicated, least-privilege user for the agent, and an API key for
     it (Admin > Users > Edit > API keys). Put the key in config.env:
       LOOKER_CLIENT_ID=...      and      export LOOKER_CLIENT_SECRET=...${embed_step}
EOF
}

ensure_internal_looker_tls() {
  local tmp
  local sans=("looker-api" "looker-api.${LOOKER_NAMESPACE}" "looker-api.${LOOKER_NAMESPACE}.svc" "looker-api.${LOOKER_NAMESPACE}.svc.cluster.local"
              "looker-web" "looker-web.${LOOKER_NAMESPACE}" "looker-web.${LOOKER_NAMESPACE}.svc" "looker-web.${LOOKER_NAMESPACE}.svc.cluster.local"
              "${LOOKER_HOST}")
  LOOKER_TLS_CHANGED="false"
  ensure_internal_ca
  if internal_cert_current "$LOOKER_NAMESPACE" looker-tls "${sans[@]}"; then
    return 0
  fi
  ensure_tmp_dir; tmp="$TMP_DIR"
  issue_internal_cert "looker-api.${LOOKER_NAMESPACE}.svc.cluster.local" \
    "${tmp}/looker-tls.crt" "${tmp}/looker-tls.key" false "${sans[@]}"
  gen_alnum 28 > "${tmp}/keystore-pass"
  create_or_replace_secret "$LOOKER_NAMESPACE" looker-tls \
    "tls.crt=${tmp}/looker-tls.crt" "tls.key=${tmp}/looker-tls.key" \
    "ca.crt=${tmp}/ca.crt" "keystore-pass=${tmp}/keystore-pass"
  forget "${tmp}/ca.crt" "${tmp}/looker-tls.crt" "${tmp}/looker-tls.key" "${tmp}/keystore-pass"
  if [ "$SECRET_CHANGE" = "replaced" ]; then
    LOOKER_TLS_CHANGED="true"
  fi
}

step_looker() {
  if ! is_true "$DEPLOY_LOOKER"; then
    step "STEP 2: Customer-hosted Looker (skipped: DEPLOY_LOOKER=false)"
    return 0
  fi
  step "STEP 2: Customer-hosted Looker"
  resolve_looker_image

  if is_true "$RENDER_ONLY"; then
    local provision="false"
    if [ -n "${LOOKER_LICENSE_KEY:-}" ]; then provision="true"; fi
    render_looker "$provision"
    return 0
  fi

  ensure_namespace "$LOOKER_NAMESPACE" "$LOOKER_POD_SECURITY" restricted
  ensure_looker_secrets
  LOOKER_TLS_CHANGED="false"
  if [ "$INTERNAL_TLS" = "private-ca" ]; then
    ensure_internal_looker_tls
  fi
  local provision="false"
  if secret_exists "$LOOKER_NAMESPACE" looker-provision; then provision="true"; fi
  if ! is_true "$provision" && is_true "$LOOKER_FRESH_INSTALL"; then
    warn "no LOOKER_LICENSE_KEY was given, so Looker starts unlicensed and asks for the key in its setup page."
  fi
  render_looker "$provision"
  kapply "${RENDER_DIR}/looker.yaml"
  if is_true "$LOOKER_TLS_CHANGED" || is_true "$LOOKER_DB_CREDS_CHANGED"; then
    k -n "$LOOKER_NAMESPACE" rollout restart deployment/looker >/dev/null
  fi

  if [ -z "$LOOKER_DB_HOST" ]; then
    k -n "$LOOKER_NAMESPACE" rollout status statefulset/looker-mysql --timeout=20m
  fi
  log "Waiting for Looker. The first start migrates its database and can take several minutes..."
  k -n "$LOOKER_NAMESPACE" rollout status deployment/looker --timeout=30m
  log "OK: Looker is ready."
}

# -----------------------------------------------------------------------------
# STEP 3: Agent Substrate
# -----------------------------------------------------------------------------
ensure_substrate_tools() {
  # The tag, and the commit the tag has to be: see "checkout".
  checkout "$SUBSTRATE_REPO_URL" "$SUBSTRATE_VERSION" "$SUBSTRATE_DIR" "$SUBSTRATE_COMMIT"
  local built="${SUBSTRATE_VERSION}@${SUBSTRATE_COMMIT}"
  if [ ! -x "${BIN_DIR}/kubectl-ate" ] || [ "$(cat "${STATE_DIR}/kubectl-ate-version" 2>/dev/null || true)" != "$built" ]; then
    log "Building kubectl-ate ${SUBSTRATE_VERSION}..."
    (cd "$SUBSTRATE_DIR" && go build -o "${BIN_DIR}/kubectl-ate" ./cmd/kubectl-ate)
    printf '%s' "$built" > "${STATE_DIR}/kubectl-ate-version"
  fi
}

install_substrate() {
  local args=(
    deploy ate-system
    "--context=${KUBE_CONTEXT}"
    --image-repo "$SUBSTRATE_IMAGE_REPO"
    --image-tag "$SUBSTRATE_VERSION"
    # gVisor needs nothing from the nodes. The microVM class needs /dev/kvm.
    --sandbox-classes=gvisor
    # The bundled provider resolves credentials from Kubernetes Secrets.
    '--credential-provider={"name":"k8s.io"}'
    "--ingress-allowed-spiffe-ids=${INGRESS_ALLOWED_SPIFFE_IDS}"
    "--rollout-timeout=${SUBSTRATE_ROLLOUT_TIMEOUT}"
  )
  if [ -n "$SUBSTRATE_POSTGRES_STORAGE_CLASS" ]; then
    args+=("--ateapi-postgres-storage-class=${SUBSTRATE_POSTGRES_STORAGE_CLASS}")
  fi
  # ate-setup records what it installed here. Keep it: upgrades start from it.
  export ATE_RECORD_DIR="${WORK_DIR}/ate-records"

  if [ "$PLATFORM" = "onprem" ]; then
    # ate-setup has two profiles. The default one is for GKE: it stores
    # snapshots in GCS and will not run without a Google service account.
    # "--kind" is its local-cluster profile, the only one that uses an
    # S3-compatible store and a database with no cloud dependency. It is meant
    # for development clusters; this script points it at your cluster.
    args+=(--kind)
    if [ "$SNAPSHOT_STORE" = "s3" ]; then
      args+=("--storage-bucket-name=${S3_BUCKET}")
    fi
    (
      cd "$SUBSTRATE_DIR"
      unset PROJECT_ID CLUSTER_NAME CLUSTER_LOCATION BUCKET_NAME SNAPSHOT_LOCATION SNAPSHOT_TRANSFER_GSA_NAME
      go run ./cmd/ate-setup "${args[@]}"
    )
  else
    if is_true "$GKE_SEPARATE_SYSTEM_NODES"; then
      args+=(--cordon-system-infra-components)
    fi
    (
      cd "$SUBSTRATE_DIR"
      export PROJECT_ID="$GCP_PROJECT_ID" CLUSTER_NAME="$GKE_CLUSTER_NAME"
      export CLUSTER_LOCATION="$GKE_CLUSTER_LOCATION" BUCKET_NAME="$GKE_SNAPSHOT_BUCKET"
      export SNAPSHOT_LOCATION="gs://${GKE_SNAPSHOT_BUCKET}/"
      export SNAPSHOT_TRANSFER_GSA_NAME="$GKE_TRANSFER_GSA_NAME"
      go run ./cmd/ate-setup "${args[@]}"
    )
  fi
}

# Points both Substrate object-store sidecars at ENDPOINT using Secret
# ate-system/ate-objectstore-s3. When USE_EXTRA_CA="true", mounts ConfigMap
# ate-system/ate-objectstore-extra-ca and sets AWS_CA_BUNDLE for aws-sdk-go-v2.
patch_snapshot_sidecars() {
  local endpoint="$1" region="$2" path_style="$3" change="$4" use_extra_ca="${5:-false}" patch
  # A strategic merge patch: containers and env entries merge by name, and
  # "value": null removes the literal the profile put there.
  patch="$(jq -cn --arg endpoint "$endpoint" --arg region "$region" \
      --arg path_style "$path_style" --arg use_ca "$use_extra_ca" '
    {spec: {template: {spec: (
      {initContainers: [({
        name: "objectstore-plugin",
        env: ([
          {name: "ATE_STORAGE_BACKEND", value: "s3"},
          {name: "AWS_REGION", value: $region},
          {name: "AWS_ENDPOINT_URL", value: $endpoint},
          {name: "AWS_S3_USE_PATH_STYLE", value: $path_style},
          {name: "AWS_ACCESS_KEY_ID", value: null,
           valueFrom: {secretKeyRef: {name: "ate-objectstore-s3", key: "access-key-id"}}},
          {name: "AWS_SECRET_ACCESS_KEY", value: null,
           valueFrom: {secretKeyRef: {name: "ate-objectstore-s3", key: "secret-access-key"}}}
        ] + (if $use_ca == "true" then [{name: "AWS_CA_BUNDLE", value: "/run/objectstore-ca/ca.crt"}] else [] end))
      } + (if $use_ca == "true" then {
        volumeMounts: [{name: "objectstore-extra-ca", mountPath: "/run/objectstore-ca", readOnly: true}]
      } else {} end))]}
      + (if $use_ca == "true" then {
        volumes: [{name: "objectstore-extra-ca", configMap: {name: "ate-objectstore-extra-ca"}}]
      } else {} end)
    )}}}')"
  k -n ate-system patch deployment ate-api-server --type=strategic -p "$patch"
  k -n ate-system patch daemonset atelet --type=strategic -p "$patch"
  # A pod reads these keys once, when it starts, and a patch that changes
  # nothing starts no rollout. So when the keys in the Secret were replaced,
  # the two workloads are restarted, or they would go on with the old keys.
  if [ "$change" = "replaced" ]; then
    k -n ate-system rollout restart deployment/ate-api-server >/dev/null
    k -n ate-system rollout restart daemonset/atelet >/dev/null
  fi
  k -n ate-system rollout status deployment/ate-api-server --timeout="$SUBSTRATE_ROLLOUT_TIMEOUT"
  k -n ate-system rollout status daemonset/atelet --timeout="$SUBSTRATE_ROLLOUT_TIMEOUT"
}

# On-prem with your own S3-compatible store: repoint the object-store sidecars
# that the local-cluster profile aimed at its bundled store, and stop the
# bundled store so it is not left running with its built-in login.
configure_s3_snapshot_store() {
  [ -n "${S3_ACCESS_KEY_ID:-}" ] && [ -n "${S3_SECRET_ACCESS_KEY:-}" ] \
    || die "export S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY for SNAPSHOT_STORE=s3."
  local tmp change use_extra_ca="false"
  ensure_tmp_dir; tmp="$TMP_DIR"
  printf '%s' "$S3_ACCESS_KEY_ID" > "${tmp}/access-key-id"
  printf '%s' "$S3_SECRET_ACCESS_KEY" > "${tmp}/secret-access-key"
  create_or_replace_secret ate-system ate-objectstore-s3 \
    "access-key-id=${tmp}/access-key-id" "secret-access-key=${tmp}/secret-access-key"
  forget "${tmp}/access-key-id" "${tmp}/secret-access-key"
  change="$SECRET_CHANGE"
  if [ -n "$EXTRA_CA_FILE" ]; then
    k -n ate-system create configmap ate-objectstore-extra-ca \
      "--from-file=ca.crt=${EXTRA_CA_FILE}" --dry-run=client -o yaml | k apply -f - >/dev/null
    use_extra_ca="true"
  fi
  patch_snapshot_sidecars "$S3_ENDPOINT_URL" "$S3_REGION" "$S3_USE_PATH_STYLE" "$change" "$use_extra_ca"
  k -n ate-system delete job rustfs-bucket-init --ignore-not-found >/dev/null 2>&1 || true
  k -n ate-system scale deployment/rustfs --replicas=0 >/dev/null 2>&1 || true
  log "OK: snapshots go to bucket '${S3_BUCKET}' at ${S3_ENDPOINT_URL}."
}

# On-prem with the bundled store: replace its published credentials and switch
# off its web console. Untested against Substrate's rustfs deployment.
configure_bundled_snapshot_store() {
  local tmp change="unchanged" patch
  # Let the installer's bucket-init Job finish creating ate-snapshots before
  # changing rustfs credentials, then delete the Job (it hardcodes rustfsadmin).
  k -n ate-system wait --for=condition=complete job/rustfs-bucket-init \
    --timeout="$SUBSTRATE_ROLLOUT_TIMEOUT" >/dev/null 2>&1 || true
  k -n ate-system delete job rustfs-bucket-init --ignore-not-found >/dev/null 2>&1 || true
  if ! secret_exists ate-system ate-objectstore-s3; then
    ensure_tmp_dir; tmp="$TMP_DIR"
    gen_alnum 20 > "${tmp}/access-key-id"
    gen_alnum 40 > "${tmp}/secret-access-key"
    create_or_replace_secret ate-system ate-objectstore-s3 \
      "access-key-id=${tmp}/access-key-id" "secret-access-key=${tmp}/secret-access-key"
    forget "${tmp}/access-key-id" "${tmp}/secret-access-key"
    change="$SECRET_CHANGE"
  fi
  # rustfs mounts a ReadWriteOnce PVC; Recreate prevents multi-attach deadlocks
  # on multi-node block storage when the deployment restarts.
  patch='{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null},"template":{"spec":{"containers":[{"name":"rustfs","env":[{"name":"RUSTFS_ACCESS_KEY","value":null,"valueFrom":{"secretKeyRef":{"name":"ate-objectstore-s3","key":"access-key-id"}}},{"name":"RUSTFS_SECRET_KEY","value":null,"valueFrom":{"secretKeyRef":{"name":"ate-objectstore-s3","key":"secret-access-key"}}},{"name":"RUSTFS_CONSOLE_ENABLE","value":"false"}]}]}}}}'
  k -n ate-system patch deployment rustfs --type=strategic -p "$patch"
  if ! k -n ate-system rollout status deployment/rustfs --timeout="$SUBSTRATE_ROLLOUT_TIMEOUT"; then
    die "rustfs failed to restart after replacing its credentials. If its existing PVC refused new root credentials, use SNAPSHOT_STORE=\"s3\" (recommended) or set BUNDLED_STORE_GENERATED_LOGIN=\"false\"."
  fi
  patch_snapshot_sidecars "http://rustfs.ate-system.svc:9000" "us-east-1" "true" "$change" false
}

step_substrate() {
  step "STEP 3: Agent Substrate ${SUBSTRATE_VERSION}"
  if is_true "$RENDER_ONLY"; then
    log "[render] would install Substrate with ate-setup, admitting these router clients:"
    log "         ${INGRESS_ALLOWED_SPIFFE_IDS}"
    return 0
  fi
  ensure_substrate_tools

  if k -n ate-system get deployment ate-controller >/dev/null 2>&1 && ! is_true "$SUBSTRATE_FORCE_DEPLOY"; then
    log "Substrate is already installed (SUBSTRATE_FORCE_DEPLOY=true runs ate-setup again)."
    log "The router only admits the clients it was installed with. If the gateway is"
    log "refused later, add its identity and redeploy the router from ${SUBSTRATE_DIR}:"
    log "  go run ./cmd/ate-setup deploy atenet --ingress-allowed-spiffe-ids=<every client, comma-separated>"
    log "  this kit's gateway: ${GATEWAY_SPIFFE_ID}"
  else
    install_substrate
  fi

  if [ "$PLATFORM" = "onprem" ]; then
    if [ "$SNAPSHOT_STORE" = "s3" ]; then
      configure_s3_snapshot_store
    else
      if is_true "$BUNDLED_STORE_GENERATED_LOGIN"; then
        configure_bundled_snapshot_store
      fi
      warn "snapshots use the installer's bundled object store: 1Gi, over plain HTTP inside ate-system. Use SNAPSHOT_STORE=s3 with HTTPS and server-side encryption for anything you want to keep."
    fi
  fi

  local deployment
  for deployment in ate-api-server ate-controller atenet-router atenet-egress k8s-credential-provider; do
    k -n ate-system rollout status "deployment/${deployment}" --timeout="$SUBSTRATE_ROLLOUT_TIMEOUT"
  done
  log "OK: Substrate control plane is ready."
}

# -----------------------------------------------------------------------------
# STEP 4: Agent image
# -----------------------------------------------------------------------------
step_image() {
  step "STEP 4: Build and push the agent image"
  local repository="${REGISTRY}/looker-agent"
  if is_true "$RENDER_ONLY"; then
    AGENT_IMAGE_REF="${repository}@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    log "[render] would build ${repository} from ${SCRIPT_DIR}/agent"
    return 0
  fi

  local context="${WORK_DIR}/build/agent" tag
  rm -rf "$context"
  mkdir -p "$context"
  cp -R "${SCRIPT_DIR}/agent/." "$context/"
  find "$context" -name '*.metadata.json' -delete
  if [ -n "$EXTRA_CA_FILE" ] || [ "$INTERNAL_TLS" = "private-ca" ]; then
    : > "${context}/extra-ca.pem"
    if [ -n "$EXTRA_CA_FILE" ]; then
      cat "$EXTRA_CA_FILE" >> "${context}/extra-ca.pem"
      printf '\n' >> "${context}/extra-ca.pem"
    fi
    if [ "$INTERNAL_TLS" = "private-ca" ]; then
      read_internal_ca_cert >> "${context}/extra-ca.pem"
      printf '\n' >> "${context}/extra-ca.pem"
    fi
  fi
  if ! grep -Eqv '^[[:space:]]*(#|$)' "${context}/requirements.lock"; then
    warn "agent/requirements.lock has no pinned packages yet; building from unpinned requirements.txt (see comments in agent/requirements.lock)."
  fi
  # Tag by content, so an unchanged agent is not rebuilt into a new template.
  tag="$( (cd "$context" && find . -type f | LC_ALL=C sort | while IFS= read -r file; do
            printf '%s  %s\n' "$(sha256_of "$file")" "$file"
          done; printf 'base=%s provider=%s\n' "$AGENT_BASE_IMAGE" "$AGENT_MODEL_PROVIDER") | openssl dgst -sha256 | awk '{print $NF}' | cut -c 1-12)"

  "$CONTAINER_TOOL" build --platform "$IMAGE_PLATFORM" \
    --build-arg "BASE_IMAGE=${AGENT_BASE_IMAGE}" \
    --build-arg "AGENT_MODEL_PROVIDER=${AGENT_MODEL_PROVIDER}" \
    -t "${repository}:${tag}" "$context"
  "$CONTAINER_TOOL" push "${repository}:${tag}"

  # Substrate only accepts images pinned by digest.
  AGENT_IMAGE_REF="$(pushed_digest "$repository" "$tag")"
  printf '%s' "$AGENT_IMAGE_REF" > "${STATE_DIR}/agent-image"
  log "OK: ${AGENT_IMAGE_REF}"
}

load_agent_image_ref() {
  if [ -z "${AGENT_IMAGE_REF:-}" ]; then
    [ -f "${STATE_DIR}/agent-image" ] || die "no agent image yet. Run './deploy.sh image' first."
    AGENT_IMAGE_REF="$(cat "${STATE_DIR}/agent-image")"
  fi
}

# -----------------------------------------------------------------------------
# STEP 5: The agent as a Substrate actor
# -----------------------------------------------------------------------------
render_worker_pool() {
  local out="${RENDER_DIR}/worker-pool.yaml" node_key node_value
  {
    cat <<EOF
# The warm capacity the agent runs on. Rendered by deploy.sh.
#
# Worker pods keep SYS_ADMIN and NET_ADMIN and run with seccomp unconfined,
# which the baseline and restricted Pod Security levels reject. That is
# Substrate's requirement, and it is why this namespace holds the workers and
# nothing else: whoever may create a pod here may create a privileged one.
$(namespace_manifest "$AGENT_NAMESPACE" privileged)
---
apiVersion: ate.dev/v1
kind: WorkerPool
metadata:
  name: looker-agent
  namespace: ${AGENT_NAMESPACE}
  labels:
    workload: looker-agent
spec:
  replicas: ${WORKER_REPLICAS}
  workerImage: ${WORKER_IMAGE}
  sandboxClasses:
  - name: gvisor
  template:
EOF
    if [ -n "$WORKER_NODE_SELECTOR" ]; then
      node_key="${WORKER_NODE_SELECTOR%%=*}"
      node_value="${WORKER_NODE_SELECTOR#*=}"
      cat <<EOF
    nodeSelector:
      ${node_key}: $(yaml_sq "$node_value")
EOF
    fi
    cat <<EOF
    resources:
      # The limits are the capacity actors are packed into.
      limits:
        cpu: "${WORKER_CPU_LIMIT}"
        memory: ${WORKER_MEMORY}
      requests:
        cpu: ${WORKER_CPU_REQUEST}
        memory: ${WORKER_MEMORY}
EOF
  } > "$out"
  log "Rendered ${out}"
}

# One "- name / value" pair of the actor's environment.
env_entry() {
  printf '  - name: %s\n    value: %s\n' "$1" "$(yaml_sq "$2")"
}

# actor_template_body CLIENT_ID CLIENT_SECRET: the template without its
# metadata, holding the given Looker API key.
actor_template_body() {
  cat <<EOF
workerSelector:
  matchLabels:
    workload: looker-agent
containers:
- name: agent
  image: ${AGENT_IMAGE_REF}
  # The agent runs as the image's own unprivileged user and needs no Linux
  # capability. Dropping them all also takes them away from any setuid
  # program inside the sandbox.
  securityContext:
    capabilities:
      drop: ["ALL"]
  # Substrate takes literal values only: no Secret references. The Looker key
  # is therefore stored in this template and in the actor's snapshots.
  env:
EOF
  env_entry LOOKERSDK_BASE_URL "$LOOKER_API_URL"
  env_entry LOOKERSDK_CLIENT_ID "$1"
  env_entry LOOKERSDK_CLIENT_SECRET "$2"
  env_entry LOOKERSDK_VERIFY_SSL "$LOOKER_VERIFY_SSL"
  env_entry LOOKER_PUBLIC_URL "$LOOKER_PUBLIC_URL"
  # The LookML models the agent's tools may use, and nothing beyond them.
  env_entry LOOKER_MODELS "$LOOKER_MODELS"
  # "plain": a link in an answer is the ordinary address of the Looker page,
  # which opens with the reader's own Looker session. "signed": the agent asks
  # Looker for signed embed links, each of which is a session for its holder.
  env_entry LOOKER_LINK_MODE "$LOOKER_LINK_MODE"
  # ADK's developer UI and its extra endpoints. Off unless asked for.
  env_entry ADK_WEB_UI "$AGENT_DEV_UI"
  env_entry AGENT_MODEL_PROVIDER "$AGENT_MODEL_PROVIDER"
  env_entry CLAUDE_MODEL "$CLAUDE_MODEL"
  env_entry GEMINI_MODEL "$GEMINI_MODEL"
  # Trust the egress gateway's CA (it re-signs HTTPS it inspects) and the
  # public roots, both from the projected bundle below.
  env_entry SSL_CERT_FILE "$TRUST_BUNDLE_PATH"
  env_entry REQUESTS_CA_BUNDLE "$TRUST_BUNDLE_PATH"
  env_entry CURL_CA_BUNDLE "$TRUST_BUNDLE_PATH"
  # Stay alive on SIGTERM so the actor can be suspended before its worker goes.
  env_entry IGNORE_SIGTERM "1"
  if [ "$MODEL_AUTH" = "vertex" ]; then
    env_entry VERTEXAI_PROJECT "$GCP_PROJECT_ID"
    env_entry VERTEXAI_LOCATION "$MODEL_LOCATION"
    env_entry GOOGLE_CLOUD_PROJECT "$GCP_PROJECT_ID"
    env_entry GOOGLE_CLOUD_LOCATION "$MODEL_LOCATION"
    env_entry GOOGLE_GENAI_USE_VERTEXAI "true"
    # Google client libraries get a placeholder token from a stand-in
    # metadata server inside the actor; the egress gateway injects the real one.
    env_entry FAKE_GCE_METADATA "1"
    env_entry GCE_METADATA_HOST "$FAKE_METADATA_ADDRESS"
    env_entry GCE_METADATA_IP "$FAKE_METADATA_ADDRESS"
  else
    env_entry ANTHROPIC_API_KEY "$PLACEHOLDER_CREDENTIAL"
  fi
  cat <<EOF
  # ResumeActor returns only once the server answers, so the first request
  # after a wake-up is never sent to a process that is still starting.
  wakeupProbe:
    httpGet:
      path: /readyz
      port: 80
    timeoutSeconds: 120
  volumeMounts:
  - name: system-info
    mountPath: /run/ate
volumes:
- name: system-info
  systemInfo:
    dataSources:
    - trustBundle:
        names:
        - egress-mitm.ate.dev
        - system-roots.ate.dev
        path: egress-trust-bundle/trust-bundle.pem
resources:
  limits:
    cpuMillicores: ${ACTOR_CPU_MILLICORES}
    memoryBytes: ${ACTOR_MEMORY_BYTES}
snapshotConfig:
  # Memory fidelity keeps the running process, and with it the chat sessions.
  preferredFidelity: SNAPSHOT_FIDELITY_MEMORY
EOF
}

# Writes two files. rendered/actor-template.yaml is for reading: the Looker API
# key in it is replaced by REDACTED, so that the key does not stay in the work
# directory. The template that is really applied holds the key; it is written
# to the temporary directory (ACTOR_TEMPLATE_FILE) and removed by step_agent as
# soon as Substrate has it. "render" writes the first file only.
render_actor_template() {
  local out="${RENDER_DIR}/actor-template.yaml"
  local client_id="$LOOKER_CLIENT_ID" client_secret="${LOOKER_CLIENT_SECRET:-}" hash
  if is_true "$RENDER_ONLY"; then
    client_id="REDACTED"
    client_secret="REDACTED"
  fi

  # Templates are immutable, so the name carries a hash of the content: a
  # changed image, setting or Looker key becomes a new template. The content
  # goes to the hash through a pipe, never into a file.
  hash="$(actor_template_body "$client_id" "$client_secret" | openssl dgst -sha256 | awk '{print $NF}' | cut -c 1-10)"
  TEMPLATE_NAME="looker-agent-${hash}"
  {
    printf '# Substrate ActorTemplate (created with "kubectl ate create actor-template").\n'
    printf '# Rendered by deploy.sh. The Looker API key is not in this copy: the template\n'
    printf '# that is applied is written to a temporary file and removed again.\n'
    printf 'metadata:\n  atespace: %s\n  name: %s\n' "$ATESPACE" "$TEMPLATE_NAME"
    actor_template_body REDACTED REDACTED
  } > "$out"
  log "Rendered ${out} (template ${TEMPLATE_NAME})"

  if ! is_true "$RENDER_ONLY"; then
    ensure_tmp_dir
    ACTOR_TEMPLATE_FILE="${TMP_DIR}/actor-template.yaml"
    {
      printf '# Substrate ActorTemplate. It contains the Looker API key.\n'
      printf 'metadata:\n  atespace: %s\n  name: %s\n' "$ATESPACE" "$TEMPLATE_NAME"
      actor_template_body "$client_id" "$client_secret"
    } > "$ACTOR_TEMPLATE_FILE"
  fi
}

render_egress_policy() {
  local out="${RENDER_DIR}/egress-policy.yaml"
  {
    cat <<EOF
# Everything the agent may reach. Anything else is refused, and names that are
# not listed here do not even resolve inside the sandbox.
rules:
EOF
    if [ "$LOOKER_API_SCHEME" = "https" ]; then
      cat <<EOF
# Looker API. Passed through without decryption: the agent holds the Looker key
# itself, so there is nothing for the gateway to inject, and Looker's own
# certificate stays between Looker and the agent.
- tlsPassthrough:
    hostnames:
    - ${LOOKER_API_HOST}
    ports:
      numbers:
      - ${LOOKER_API_PORT}
EOF
    else
      cat <<EOF
# Looker API over cleartext HTTP.
- http:
    hostnames:
    - ${LOOKER_API_HOST}
    ports:
      numbers:
      - ${LOOKER_API_PORT}
EOF
    fi
    cat <<EOF
# The model endpoint. The gateway terminates this TLS and replaces the
# placeholder header with the real credential, which the agent never sees.
- https:
    hostnames:
    - ${MODEL_HOST}
    effects:
      replaceHeaders:
      - header: ${MODEL_HEADER}
EOF
    if [ -n "$MODEL_PREFIX" ]; then
      printf '        prefix: "%s"\n' "$MODEL_PREFIX"
    fi
    printf '        credentialUri: %s\n' "$CREDENTIAL_URI"
  } > "$out"
  log "Rendered ${out}"
}

# The namespace that holds what Substrate's egress gateway injects for the
# agent. It exists for every model provider (with the Anthropic API there is
# no token refresher, but there is still the key), so it has a file of its own.
render_credentials_namespace() {
  local out="${RENDER_DIR}/credentials-namespace.yaml"
  {
    cat <<EOF
# The namespace of the model credential. Rendered by deploy.sh.
# Nothing in it needs more than the "restricted" Pod Security level.
$(namespace_manifest "$CREDS_NAMESPACE" restricted)
EOF
    if is_true "$NETWORK_POLICIES"; then
      netpol_default_deny "$CREDS_NAMESPACE"
    fi
  } > "$out"
  log "Rendered ${out}"
}

render_token_refresher() {
  local out="${RENDER_DIR}/token-refresher.yaml"
  {
    cat <<EOF
# Keeps a short-lived Vertex AI access token in a Secret that only Substrate's
# credential provider reads. This runs OUTSIDE the agent's sandbox.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vertex-token-refresher
  namespace: ${CREDS_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: vertex-token-refresher
  namespace: ${CREDS_NAMESPACE}
rules:
# The refresher writes the token and never reads it back, so it may patch
# this one Secret and do nothing else.
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["${CREDENTIAL_SECRET}"]
  verbs: ["patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: vertex-token-refresher
  namespace: ${CREDS_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: vertex-token-refresher
subjects:
- kind: ServiceAccount
  name: vertex-token-refresher
  namespace: ${CREDS_NAMESPACE}
EOF
    if is_true "$NETWORK_POLICIES"; then
      cat <<EOF
---
# The refresher: nothing connects to it, and it calls two things.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vertex-token-refresher
  namespace: ${CREDS_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: vertex-token-refresher
  policyTypes:
  - Ingress
  - Egress
  egress:
EOF
      netpol_dns_egress
      local api_ports=() api_port seen_ports=",443,"
      IFS=',' read -r -a api_ports <<< "$KUBE_API_PORTS"
      cat <<EOF
  # Google's token service (443) and the Kubernetes API (KUBE_API_PORTS). No
  # destination is named: where the API server answers is the cluster's to
  # know, and differs from one cluster to the next.
  - ports:
    - protocol: TCP
      port: 443
EOF
      for api_port in "${api_ports[@]}"; do
        case "$seen_ports" in
          *",${api_port},"*) continue ;;
        esac
        seen_ports="${seen_ports}${api_port},"
        cat <<EOF
    - protocol: TCP
      port: ${api_port}
EOF
      done
      if [ "$PLATFORM" = "gke" ]; then
        cat <<EOF
  # Workload Identity: the metadata server GKE runs on every node.
  - to:
    - ipBlock:
        cidr: 169.254.169.254/32
    ports:
    - protocol: TCP
      port: 80
  - to:
    - ipBlock:
        cidr: 169.254.169.252/32
    ports:
    - protocol: TCP
      port: 988
EOF
      fi
    fi
    cat <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vertex-token-refresher
  namespace: ${CREDS_NAMESPACE}
data:
EOF
    # Static: every \$... below is expanded inside the refresher container.
    cat <<'EOF'
  refresh.sh: |
    #!/bin/bash
    # Mints an access token and writes it into the Secret, forever.
    set -uo pipefail
    # Everything this script writes holds a credential.
    umask 077
    account=/var/run/secrets/kubernetes.io/serviceaccount
    target="https://kubernetes.default.svc/api/v1/namespaces/${NAMESPACE}/secrets/${SECRET_NAME}"
    # The liveness probe looks at the age of this file. Starting counts as the
    # first sign of life.
    touch /tmp/last-success
    if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
      gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" --quiet
    fi
    while true; do
      if token="$(gcloud auth print-access-token --quiet 2>/tmp/token-error)"; then
        # This pod's own token for the Kubernetes API goes to curl in a file.
        # As an argument, every process in the container could read it. The
        # file is written again each time: Kubernetes replaces the token
        # regularly.
        printf 'Authorization: Bearer %s\n' "$(cat "${account}/token")" > /tmp/api-authorization
        # Access tokens are URL-safe text, so they need no JSON escaping.
        status="$(printf '{"stringData":{"token":"%s"}}' "${token}" \
          | curl -sS -o /tmp/patch-response -w '%{http_code}' \
              --cacert "${account}/ca.crt" \
              -H @/tmp/api-authorization \
              -H 'Content-Type: application/merge-patch+json' \
              -X PATCH --data @- "${target}")"
        if [ "${status}" = "200" ]; then
          touch /tmp/last-success
          echo "$(date -u +%FT%TZ) token refreshed"
          sleep "${REFRESH_SECONDS}"
          continue
        fi
        echo "$(date -u +%FT%TZ) could not update the Secret (HTTP ${status})"
        cat /tmp/patch-response; echo
      else
        echo "$(date -u +%FT%TZ) could not get an access token:"
        cat /tmp/token-error
      fi
      sleep 30
    done
EOF
    cat <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vertex-token-refresher
  namespace: ${CREDS_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vertex-token-refresher
  template:
    metadata:
      labels:
        app: vertex-token-refresher
    spec:
      # The one pod of this kit that talks to the Kubernetes API, with the one
      # permission above.
      serviceAccountName: vertex-token-refresher
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        # The group the mounted key file is given, so that this user, and
        # nobody else in the container, can read it.
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: refresher
        image: ${TOKEN_REFRESHER_IMAGE}
        command: ["/bin/bash", "/scripts/refresh.sh"]
        env:
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: SECRET_NAME
          value: ${CREDENTIAL_SECRET}
        # Tokens last an hour. Refresh three times within that.
        - name: REFRESH_SECONDS
          value: "1200"
        - name: HOME
          value: /tmp
        - name: CLOUDSDK_CONFIG
          value: /tmp/gcloud
        # gcloud would write a log file for every call. /tmp is memory.
        - name: CLOUDSDK_CORE_DISABLE_FILE_LOGGING
          value: "true"
EOF
    if [ "$PLATFORM" = "onprem" ]; then
      cat <<EOF
        - name: GOOGLE_APPLICATION_CREDENTIALS
          value: /var/secrets/google/key.json
EOF
    fi
    cat <<EOF
        # A token lives an hour and is renewed every 20 minutes. 45 minutes
        # without a success mean the loop is stuck or the credential no longer
        # works. The restart makes that visible before the token runs out.
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - '[ -n "\$(find /tmp/last-success -mmin -45)" ]'
          periodSeconds: 60
          failureThreshold: 3
        resources:
          requests:
            cpu: 20m
            memory: 128Mi
          limits:
            memory: 512Mi
            ephemeral-storage: 256Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: tmp
          mountPath: /tmp
EOF
    if [ "$PLATFORM" = "onprem" ]; then
      cat <<EOF
        - name: google-key
          mountPath: /var/secrets/google
          readOnly: true
EOF
    fi
    cat <<EOF
      volumes:
      - name: scripts
        configMap:
          name: vertex-token-refresher
      # gcloud keeps a copy of the service account key and its tokens under
      # /tmp. Memory-backed, so that none of it is written to the node's disk.
      - name: tmp
        emptyDir:
          medium: Memory
          sizeLimit: 64Mi
EOF
    if [ "$PLATFORM" = "onprem" ]; then
      cat <<EOF
      - name: google-key
        secret:
          secretName: gcp-service-account-key
          defaultMode: 288
EOF
    fi
  } > "$out"
  log "Rendered ${out}"
}

# Lets the agent's atespace use Secrets in the credentials namespace. Substrate's
# credential provider denies everything that is not listed.
grant_credential_namespace() {
  local configmap="k8s-credential-provider-namespace-policy" current stripped tmp
  current="$(k -n ate-system get configmap "$configmap" -o jsonpath='{.data.namespace-policy\.yaml}' 2>/dev/null || true)"
  if printf '%s\n' "$current" | grep -Eq "atespace:[[:space:]]*${ATESPACE}[[:space:]]*\$" \
      && printf '%s\n' "$current" | grep -Eq -- "-[[:space:]]*${CREDS_NAMESPACE}[[:space:]]*\$"; then
    log "Credential provider already grants atespace '${ATESPACE}' the namespace '${CREDS_NAMESPACE}'."
    return 0
  fi
  stripped="$(printf '%s\n' "$current" | sed -e 's/#.*$//' -e '/^[[:space:]]*$/d')"
  if [ -n "$stripped" ] && ! printf '%s' "$stripped" | grep -Eq '^policies:[[:space:]]*\[\][[:space:]]*$'; then
    cat >&2 <<EOF
ERROR: ConfigMap ate-system/${configmap} already has policies and this script
will not rewrite a file it did not create. Add this entry under "policies:"
yourself, then run the script again:

  - atespace: ${ATESPACE}
    allowedNamespaces:
    - ${CREDS_NAMESPACE}

  kubectl --context ${KUBE_CONTEXT} -n ate-system edit configmap ${configmap}
  kubectl --context ${KUBE_CONTEXT} -n ate-system rollout restart deployment/k8s-credential-provider
EOF
    exit 1
  fi
  ensure_tmp_dir; tmp="$TMP_DIR"
  cat > "${tmp}/namespace-policy.yaml" <<EOF
# Which Kubernetes namespaces each atespace may resolve credentials from.
policies:
- atespace: ${ATESPACE}
  allowedNamespaces:
  - ${CREDS_NAMESPACE}
EOF
  k -n ate-system create configmap "$configmap" \
    --from-file=namespace-policy.yaml="${tmp}/namespace-policy.yaml" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  # The provider reads the policy once, at start.
  k -n ate-system rollout restart deployment/k8s-credential-provider >/dev/null
  k -n ate-system rollout status deployment/k8s-credential-provider --timeout="$SUBSTRATE_ROLLOUT_TIMEOUT"
  log "OK: atespace '${ATESPACE}' may use credentials in namespace '${CREDS_NAMESPACE}'."
}

setup_model_credential() {
  local tmp key_change="unchanged"

  if [ "$MODEL_AUTH" = "apikey" ]; then
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      ensure_tmp_dir; tmp="$TMP_DIR"
      printf '%s' "$ANTHROPIC_API_KEY" > "${tmp}/token"
      create_or_replace_secret "$CREDS_NAMESPACE" "$CREDENTIAL_SECRET" "token=${tmp}/token"
      forget "${tmp}/token"
    elif ! secret_exists "$CREDS_NAMESPACE" "$CREDENTIAL_SECRET"; then
      die "export ANTHROPIC_API_KEY for AGENT_MODEL_PROVIDER=anthropic."
    fi
    grant_credential_namespace
    return 0
  fi

  # Vertex AI. The Secret must exist before the refresher can patch it.
  if ! secret_exists "$CREDS_NAMESPACE" "$CREDENTIAL_SECRET"; then
    ensure_tmp_dir; tmp="$TMP_DIR"
    printf 'pending' > "${tmp}/token"
    create_or_replace_secret "$CREDS_NAMESPACE" "$CREDENTIAL_SECRET" "token=${tmp}/token"
    forget "${tmp}/token"
  fi
  if [ "$PLATFORM" = "onprem" ]; then
    if [ -n "$GCP_SA_KEY_FILE" ]; then
      create_or_replace_secret "$CREDS_NAMESPACE" gcp-service-account-key "key.json=${GCP_SA_KEY_FILE}"
      key_change="$SECRET_CHANGE"
    elif ! secret_exists "$CREDS_NAMESPACE" gcp-service-account-key; then
      die "set GCP_SA_KEY_FILE to the key of a service account allowed aiplatform.endpoints.predict on ${GCP_PROJECT_ID}."
    fi
  else
    # Workload Identity: grant only the one prediction permission the agent
    # needs, so a sandbox escape cannot manage models, datasets or jobs.
    local role_deleted
    if role_deleted="$(gcloud iam roles describe lookerAgentModelCalls --project="$GCP_PROJECT_ID" --format='value(deleted)' 2>/dev/null)"; then
      if [ "$role_deleted" = "True" ] || [ "$role_deleted" = "true" ]; then
        gcloud iam roles undelete lookerAgentModelCalls --project="$GCP_PROJECT_ID" >/dev/null
      fi
    else
      gcloud iam roles create lookerAgentModelCalls --project="$GCP_PROJECT_ID" \
        --title="Looker agent: model calls only" \
        --permissions="aiplatform.endpoints.predict" --stage=GA >/dev/null
    fi
    gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
      --member="$(gke_principal "$CREDS_NAMESPACE" vertex-token-refresher)" \
      --role="projects/${GCP_PROJECT_ID}/roles/lookerAgentModelCalls" --condition=None >/dev/null
  fi
  kapply "${RENDER_DIR}/token-refresher.yaml"
  # The refresher signs in with the key once, when it starts. After a new key
  # it has to start again, or it would go on using the one it knows.
  if [ "$key_change" = "replaced" ]; then
    k -n "$CREDS_NAMESPACE" rollout restart deployment/vertex-token-refresher >/dev/null
  fi
  k -n "$CREDS_NAMESPACE" rollout status deployment/vertex-token-refresher --timeout=5m

  log "Waiting for the first Vertex AI token..."
  local attempt length
  for attempt in $(seq 1 36); do
    length="$(k -n "$CREDS_NAMESPACE" get secret "$CREDENTIAL_SECRET" -o jsonpath='{.data.token}' | wc -c | tr -d ' ')"
    # "pending" is 8 characters once base64-encoded. A real token is far longer.
    if [ "$length" -gt 100 ]; then
      log "OK: token present."
      grant_credential_namespace
      return 0
    fi
    sleep 5
  done
  k -n "$CREDS_NAMESPACE" logs deployment/vertex-token-refresher --tail=20 >&2 || true
  die "the token refresher did not produce a token (attempt ${attempt}). Its last log lines are above."
}

# The JSON kubectl-ate prints may be one object, a list, or wrapped in "items".
JQ_ONE='(if type == "array" then .[0] elif (type == "object" and has("items")) then .items[0] else . end)'

wait_for_golden_snapshot() {
  local deadline json tag error
  deadline=$(( $(date +%s) + GOLDEN_TIMEOUT_SECONDS ))
  log "Waiting for the template's first (golden) snapshot. Substrate boots the image once to take it..."
  while [ "$(date +%s)" -lt "$deadline" ]; do
    json="$(kate get actor-template "$TEMPLATE_NAME" -a "$ATESPACE" -o json 2>/dev/null || true)"
    if [ -n "$json" ]; then
      tag="$(printf '%s' "$json" | jq -r "${JQ_ONE} | (.status.goldenSnapshotStatus // .status.golden_snapshot_status // {}) | (.goldenTag.name // .golden_tag.name // \"\")" 2>/dev/null || true)"
      error="$(printf '%s' "$json" | jq -r "${JQ_ONE} | (.status.goldenSnapshotStatus // .status.golden_snapshot_status // {}) | (.errorMessage // .error_message // \"\")" 2>/dev/null || true)"
      if [ -n "$error" ]; then
        die "the agent image did not start inside Substrate: ${error}"
      fi
      if [ -n "$tag" ]; then
        log "OK: golden snapshot ${tag}."
        return 0
      fi
    fi
    sleep 10
  done
  warn "no golden snapshot after ${GOLDEN_TIMEOUT_SECONDS}s. Continuing: the actor will cold-boot instead."
  warn "inspect it with: kubectl ate --context ${KUBE_CONTEXT} get actor-template ${TEMPLATE_NAME} -a ${ATESPACE} -o yaml"
}

ensure_actor() {
  local json current state
  if ! kate get actor "$ACTOR_NAME" -a "$ATESPACE" >/dev/null 2>&1; then
    kate create actor "$ACTOR_NAME" "--template=${TEMPLATE_NAME}" -a "$ATESPACE"
    log "Created actor ${ATESPACE}/${ACTOR_NAME}."
    return 0
  fi
  json="$(kate get actor "$ACTOR_NAME" -a "$ATESPACE" -o json)"
  current="$(printf '%s' "$json" | jq -r "${JQ_ONE} | (.actorTemplate.name // .actor_template.name // \"\")")"
  state="$(printf '%s' "$json" | jq -r "${JQ_ONE} | (.status.state // \"\")")"
  if [ "$current" = "$TEMPLATE_NAME" ]; then
    log "Actor ${ATESPACE}/${ACTOR_NAME} already uses template ${TEMPLATE_NAME} (${state})."
    return 0
  fi
  log "Moving actor ${ATESPACE}/${ACTOR_NAME} from template '${current}' to '${TEMPLATE_NAME}'."
  log "It cold-boots on the new template, so open chat sessions are lost."
  case "$state" in
    *CRASHED*) kate revert actor "$ACTOR_NAME" -a "$ATESPACE" ;;
    *SUSPENDED*) ;;
    # An actor can only change template while suspended.
    *) kate suspend actor "$ACTOR_NAME" -a "$ATESPACE" --mode=sync ;;
  esac
  kate update actor "$ACTOR_NAME" "--template=${TEMPLATE_NAME}" -a "$ATESPACE"
}

# The names in a list that kubectl-ate prints, whatever its wrapping.
JQ_NAMES='(if type == "array" then . elif (type == "object" and has("items")) then .items else [.] end) | .[] | (.metadata.name // empty)'

# Templates cannot be changed, so every changed setting and every new Looker
# key leaves the previous template behind: with the previous key in it, and
# with its first snapshot in the object store. Once the actor runs on the new
# template the older ones have no use. Deleting a template also deletes its
# snapshot. Only templates with this script's own naming are touched.
delete_superseded_templates() {
  local json names name own_name='^looker-agent-[0-9a-f]{10}$'
  json="$(kate get actor-templates -a "$ATESPACE" -o json 2>/dev/null || true)"
  if [ -z "$json" ]; then return 0; fi
  names="$(printf '%s' "$json" | jq -r "$JQ_NAMES" 2>/dev/null || true)"
  while IFS= read -r name; do
    if [ "$name" = "$TEMPLATE_NAME" ] || ! [[ "$name" =~ $own_name ]]; then
      continue
    fi
    if kate delete actor-template "$name" -a "$ATESPACE" >/dev/null 2>&1; then
      log "Deleted the superseded template ${name}, which held the previous settings and Looker key."
    else
      warn "could not delete the superseded template ${name}. It still holds the previous Looker key. Try: kubectl ate --context ${KUBE_CONTEXT} delete actor-template ${name} -a ${ATESPACE}"
    fi
  done <<< "$names"
}

apply_egress_policy() {
  local existing uid version tmp
  existing="$(kate get egress-policy "$ACTOR_NAME" -a "$ATESPACE" -o json 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    uid="$(printf '%s' "$existing" | jq -r "${JQ_ONE} | (.metadata.uid // \"\")" 2>/dev/null || true)"
    version="$(printf '%s' "$existing" | jq -r "${JQ_ONE} | (.metadata.version // \"\")" 2>/dev/null || true)"
    if [ -n "$uid" ] && [ -n "$version" ] && [ "$version" != "0" ]; then
      ensure_tmp_dir; tmp="$TMP_DIR"
      {
        printf 'metadata:\n  atespace: %s\n  uid: %s\n  version: %s\n' \
          "$(yaml_sq "$ATESPACE")" "$(yaml_sq "$uid")" "$version"
        cat "${RENDER_DIR}/egress-policy.yaml"
      } > "${tmp}/egress-policy-update.yaml"
      if kate update egress-policy "$ACTOR_NAME" -a "$ATESPACE" -f "${tmp}/egress-policy-update.yaml"; then
        forget "${tmp}/egress-policy-update.yaml"
        return 0
      fi
      forget "${tmp}/egress-policy-update.yaml"
      warn "in-place egress policy update failed; falling back to replace."
    fi
    kate delete egress-policy "$ACTOR_NAME" -a "$ATESPACE" >/dev/null 2>&1 || true
  fi
  kate create egress-policy "$ACTOR_NAME" -a "$ATESPACE" -f "${RENDER_DIR}/egress-policy.yaml"
}

step_agent() {
  step "STEP 5: Run the agent as a Substrate actor"
  if is_true "$RENDER_ONLY"; then
    : "${AGENT_IMAGE_REF:=${REGISTRY}/looker-agent@sha256:0000000000000000000000000000000000000000000000000000000000000000}"
  else
    have_looker_api_credentials || die "LOOKER_CLIENT_ID and LOOKER_CLIENT_SECRET are needed for this step."
    load_agent_image_ref
  fi

  if [ -z "$WORKER_NODE_SELECTOR" ]; then
    warn "WORKER_NODE_SELECTOR is empty: sandbox worker pods may share cluster nodes with Looker, MySQL, the gateway and the token refresher."
  fi
  render_worker_pool
  render_credentials_namespace
  render_egress_policy
  if [ "$MODEL_AUTH" = "vertex" ]; then render_token_refresher; fi
  if is_true "$RENDER_ONLY"; then
    render_actor_template
    return 0
  fi

  kapply "${RENDER_DIR}/worker-pool.yaml"
  kapply "${RENDER_DIR}/credentials-namespace.yaml"
  setup_model_credential

  # An atespace is the isolation boundary actors, templates and policies live in.
  if ! kate get atespace "$ATESPACE" >/dev/null 2>&1; then
    kate create atespace "$ATESPACE"
  fi
  # The template is written only now, so that the copy with the Looker API key
  # exists for seconds, and it is removed as soon as Substrate has it.
  render_actor_template
  if ! kate get actor-template "$TEMPLATE_NAME" -a "$ATESPACE" >/dev/null 2>&1; then
    kate create actor-template -f "$ACTOR_TEMPLATE_FILE"
  fi
  forget "$ACTOR_TEMPLATE_FILE"
  wait_for_golden_snapshot
  ensure_actor
  delete_superseded_templates

  # An actor without a policy has no network at all. Update in place when a
  # policy already exists so live traffic sees no egress outage window.
  apply_egress_policy
  log "OK: actor ${ATESPACE}/${ACTOR_NAME} is defined. It wakes on its first request."
}

# -----------------------------------------------------------------------------
# STEP 6: Gateway
# -----------------------------------------------------------------------------
render_gateway() {
  local out="${RENDER_DIR}/gateway.yaml" code="${SCRIPT_DIR}/gateway/gateway.py" port_name="http"
  if [ -n "$GATEWAY_TLS_SECRET" ]; then port_name="https"; fi
  # The code is mounted from a ConfigMap whose name carries a hash of it.
  GATEWAY_CODE_CONFIGMAP="looker-agent-gateway-code-$(sha256_of "$code" | cut -c 1-10)"
  {
    cat <<EOF
# The door into the agent. Substrate's router only admits clients that present
# an allow-listed pod certificate; this pod has one, callers do not need one.
#
# The gateway has a namespace of its own. It holds both passwords and the
# certificate the router admits, so it stays away from the sandbox workers,
# whose namespace has to allow privileged pods. Everything here fits the
# "restricted" Pod Security level, and the namespace enforces it.
$(namespace_manifest "$GATEWAY_NAMESPACE" restricted)
EOF

    if is_true "$NETWORK_POLICIES"; then
      netpol_default_deny "$GATEWAY_NAMESPACE"
      cat <<EOF
---
# The gateway: who may call it, and the one thing it calls. The administrator
# reaches it with "kubectl port-forward", which these rules do not filter.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: looker-agent-gateway
  namespace: ${GATEWAY_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: looker-agent-gateway
  policyTypes:
  - Ingress
  - Egress
EOF
      if is_true "$DEPLOY_LOOKER" || is_true "$AGENT_INGRESS_ENABLED"; then
        printf '  ingress:\n'
      fi
      if is_true "$DEPLOY_LOOKER"; then
        cat <<EOF
  # Looker's server, which makes the chat's calls.
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${LOOKER_NAMESPACE}
      podSelector:
        matchLabels:
          app: looker
    ports:
    - protocol: TCP
      port: 8080
EOF
      fi
      if is_true "$AGENT_INGRESS_ENABLED"; then
        cat <<EOF
  # The ingress controller.
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${INGRESS_CONTROLLER_NAMESPACE}
    ports:
    - protocol: TCP
      port: 8080
EOF
      fi
      printf '  egress:\n'
      netpol_dns_egress
      cat <<EOF
  # Substrate's router, and nothing else. 8443 is the port the router's pods
  # listen on behind their Service's port 443. It is written here as a number
  # because Substrate is pinned to one commit (SUBSTRATE_COMMIT); check it
  # again when that commit changes.
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ate-system
      podSelector:
        matchLabels:
          app: atenet-router
    ports:
    - protocol: TCP
      port: 8443
EOF
    fi

    cat <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  # The router allowlist names this account:
  # ${GATEWAY_SPIFFE_ID}
  name: ${GATEWAY_SERVICE_ACCOUNT}
  namespace: ${GATEWAY_NAMESPACE}
# The gateway never calls the Kubernetes API.
automountServiceAccountToken: false
---
# The gateway's code. This ConfigMap cannot be changed once it exists, and its
# name carries a hash of the code, so other code is another ConfigMap that the
# Deployment has to be pointed at. What runs in the pod that holds the
# passwords is what this file shows.
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${GATEWAY_CODE_CONFIGMAP}
  namespace: ${GATEWAY_NAMESPACE}
  labels:
    app.kubernetes.io/name: looker-agent-gateway
    app.kubernetes.io/component: code
immutable: true
data:
  gateway.py: |2
EOF
    sed 's/^/    /' "$code"
    printf '\n'
    cat <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: looker-agent-gateway
  namespace: ${GATEWAY_NAMESPACE}
spec:
  # One replica, on purpose: background jobs and bearer tokens live in the
  # gateway's memory, and a second replica would not know the first one's.
  replicas: 1
  # For the same reason the old pod is stopped before the new one starts. A
  # rolling update would run two for a while, each with half of the answers.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: looker-agent-gateway
  template:
    metadata:
      labels:
        app: looker-agent-gateway
    spec:
      serviceAccountName: ${GATEWAY_SERVICE_ACCOUNT}
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        # The group the mounted credential files are given, so that this user,
        # and nobody else in the container, can read them.
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: gateway
        image: ${GATEWAY_IMAGE}
        command: ["python", "/gateway/gateway.py"]
        env:
        - name: TARGET_ACTOR
          value: ${ATESPACE}/${ACTOR_NAME}
        - name: ROUTER_HOST
          value: atenet-router.ate-system.svc
        - name: ROUTER_PORT
          value: "443"
        - name: ROUTER_SERVER_NAME
          value: atenet-router.ate-system.svc
        - name: ROUTER_CA_FILE
          value: /run/router-client/router-ca.pem
        - name: CLIENT_CRED_BUNDLE
          value: /run/router-client/credential-bundle.pem
        - name: LISTEN_PORT
          value: "8080"
        # A second listener that answers only GET /healthz, in plain HTTP, for
        # the kubelet's probes. They keep working when the main listener
        # serves HTTPS or is busy.
        - name: HEALTH_PORT
          value: "8081"
        - name: MAX_CONNECTIONS
          value: "${GATEWAY_MAX_CONNECTIONS}"
        - name: MAX_RUNNING_JOBS
          value: "${GATEWAY_MAX_RUNNING_JOBS}"
        - name: MAX_CHAT_RUNNING_JOBS
          value: "${GATEWAY_MAX_CHAT_RUNNING_JOBS}"
        - name: JOB_DEADLINE_SECONDS
          value: "${GATEWAY_JOB_DEADLINE_SECONDS}"
        # Sites whose pages may call the gateway from a browser. Empty: none.
        # Set for the Looker extension's "browser" transport.
        - name: CORS_ALLOWED_ORIGINS
          value: "${GATEWAY_CORS_ALLOWED_ORIGINS}"
        # The two credentials are files, not environment variables: a file is
        # not inherited by child processes, and is not part of anything that
        # prints a process's environment.
        - name: BASIC_AUTH_USER_FILE
          value: /run/gateway-credentials/admin/user
        - name: BASIC_AUTH_PASSWORD_FILE
          value: /run/gateway-credentials/admin/password
        # The chat's credential: it can start and poll agent turns and fetch
        # their artifacts, and nothing else. This is the one Looker is given.
        - name: CHAT_AUTH_USER_FILE
          value: /run/gateway-credentials/chat/user
        - name: CHAT_AUTH_PASSWORD_FILE
          value: /run/gateway-credentials/chat/password
EOF
    if [ -n "$GATEWAY_TLS_SECRET" ]; then
      cat <<EOF
        # With these two the main listener serves HTTPS. The gateway reads the
        # files again when they change, so a renewed certificate needs no restart.
        - name: TLS_CERT_FILE
          value: /run/gateway-tls/tls.crt
        - name: TLS_KEY_FILE
          value: /run/gateway-tls/tls.key
EOF
    fi
    cat <<EOF
        ports:
        - name: ${port_name}
          containerPort: 8080
        - name: health
          containerPort: 8081
        readinessProbe:
          httpGet:
            path: /healthz
            port: health
        livenessProbe:
          httpGet:
            path: /healthz
            port: health
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            # Room for the answers it keeps for the chat to collect (64 MiB at
            # most by default) and for the requests it is passing on.
            memory: 512Mi
            # It writes nothing but its log.
            ephemeral-storage: 256Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: gateway-code
          mountPath: /gateway
          readOnly: true
        - name: router-client
          mountPath: /run/router-client
          readOnly: true
        - name: admin-credential
          mountPath: /run/gateway-credentials/admin
          readOnly: true
        - name: chat-credential
          mountPath: /run/gateway-credentials/chat
          readOnly: true
EOF
    if [ -n "$GATEWAY_TLS_SECRET" ]; then
      cat <<EOF
        - name: tls
          mountPath: /run/gateway-tls
          readOnly: true
EOF
    fi
    cat <<EOF
      volumes:
      - name: gateway-code
        configMap:
          name: ${GATEWAY_CODE_CONFIGMAP}
      - name: router-client
        projected:
          sources:
          # This pod's certificate, issued by Substrate's pod identity signer.
          - podCertificate:
              signerName: podidentity.podcert.ate.dev/identity
              keyType: ECDSAP256
              credentialBundlePath: credential-bundle.pem
          # The CA that signed the router's serving certificate.
          - clusterTrustBundle:
              signerName: servicedns.podcert.ate.dev/identity
              labelSelector:
                matchLabels:
                  podcert.ate.dev/canarying: live
              path: router-ca.pem
      # 288 is mode 0440: the owner and the pod's group may read, nobody else.
      - name: admin-credential
        secret:
          secretName: looker-agent-gateway-auth
          defaultMode: 288
      - name: chat-credential
        secret:
          secretName: looker-agent-gateway-chat-auth
          defaultMode: 288
EOF
    if [ -n "$GATEWAY_TLS_SECRET" ]; then
      cat <<EOF
      - name: tls
        secret:
          secretName: ${GATEWAY_TLS_SECRET}
          defaultMode: 288
EOF
    fi
    cat <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: looker-agent-gateway
  namespace: ${GATEWAY_NAMESPACE}
spec:
  selector:
    app: looker-agent-gateway
  ports:
  - name: ${port_name}
    port: ${GATEWAY_SERVICE_PORT}
    targetPort: ${port_name}
EOF
    if is_true "$AGENT_INGRESS_ENABLED"; then
      cat <<EOF
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: looker-agent
  namespace: ${GATEWAY_NAMESPACE}
  annotations:
    # Plain HTTP is answered with a redirect to HTTPS, never with the gateway.
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    # Model answers stream; do not buffer them, and allow slow renders.
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-body-size: 64m
EOF
      if [ -n "$GATEWAY_TLS_SECRET" ]; then
        cat <<EOF
    # The gateway itself serves HTTPS.
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
EOF
      fi
      cat <<EOF
spec:
  ingressClassName: ${AGENT_INGRESS_CLASS}
  tls:
  - hosts:
    - ${AGENT_HOST}
    secretName: ${AGENT_TLS_SECRET}
  rules:
  - host: ${AGENT_HOST}
    http:
      paths:
      # Only what the chat needs is published: its own endpoints and the
      # images of answers. ADK's developer API stays off the Ingress; the
      # administrator reaches it with "kubectl port-forward".
      - path: /_gateway/
        pathType: Prefix
        backend:
          service:
            name: looker-agent-gateway
            port:
              name: ${port_name}
      - path: /apps/
        pathType: Prefix
        backend:
          service:
            name: looker-agent-gateway
            port:
              name: ${port_name}
EOF
    fi
  } > "$out"
  log "Rendered ${out}"
}

# ensure_gateway_credential SECRET USER [PASSWORD]
# Creates the Secret with a generated password when it does not exist, and
# replaces it when a password is given. Sets CREDENTIAL_CHANGED when it wrote.
ensure_gateway_credential() {
  local secret="$1" user="$2" given="${3:-}" tmp password
  if [ -z "$given" ] && secret_exists "$GATEWAY_NAMESPACE" "$secret"; then
    return 0
  fi
  ensure_tmp_dir; tmp="$TMP_DIR"
  password="${given:-$(gen_alnum 28)}"
  printf '%s' "$user" > "${tmp}/user"
  printf '%s' "$password" > "${tmp}/password"
  create_or_replace_secret "$GATEWAY_NAMESPACE" "$secret" \
    "user=${tmp}/user" "password=${tmp}/password"
  forget "${tmp}/user" "${tmp}/password"
  if [ "$SECRET_CHANGE" != "unchanged" ]; then
    CREDENTIAL_CHANGED="true"
  fi
}

# Every change to the gateway's code makes a new ConfigMap (its name carries a
# hash of the code). Once the gateway runs on the current one, the earlier
# ones have no use and are removed.
remove_old_gateway_code() {
  local name
  k -n "$GATEWAY_NAMESPACE" get configmap \
      -l app.kubernetes.io/name=looker-agent-gateway,app.kubernetes.io/component=code \
      -o name 2>/dev/null \
    | while IFS= read -r name; do
        if [ -n "$name" ] && [ "$name" != "configmap/${GATEWAY_CODE_CONFIGMAP}" ]; then
          k -n "$GATEWAY_NAMESPACE" delete "$name" >/dev/null || true
        fi
      done || true
}

ensure_internal_gateway_tls() {
  local tmp
  local sans=("looker-agent-gateway" "looker-agent-gateway.${GATEWAY_NAMESPACE}" "looker-agent-gateway.${GATEWAY_NAMESPACE}.svc" "looker-agent-gateway.${GATEWAY_NAMESPACE}.svc.cluster.local")
  if is_true "$AGENT_INGRESS_ENABLED" && [ -n "$AGENT_HOST" ]; then
    sans+=("$AGENT_HOST")
  fi
  if internal_cert_current "$GATEWAY_NAMESPACE" "$GATEWAY_TLS_SECRET" "${sans[@]}"; then
    return 0
  fi
  ensure_tmp_dir; tmp="$TMP_DIR"
  issue_internal_cert "looker-agent-gateway.${GATEWAY_NAMESPACE}.svc.cluster.local" \
    "${tmp}/gw-tls.crt" "${tmp}/gw-tls.key" true "${sans[@]}"
  create_or_replace_tls_secret "$GATEWAY_NAMESPACE" "$GATEWAY_TLS_SECRET" \
    "${tmp}/gw-tls.crt" "${tmp}/gw-tls.key"
  forget "${tmp}/ca.crt" "${tmp}/gw-tls.crt" "${tmp}/gw-tls.key"
}

step_gateway() {
  step "STEP 6: Deploy the gateway"
  render_gateway
  if is_true "$RENDER_ONLY"; then return 0; fi

  ensure_namespace "$GATEWAY_NAMESPACE" restricted
  # Two credentials. The administrator's opens everything the agent's server
  # offers, including its developer API. The chat's is the one stored in Looker
  # and so within reach of every chat user: the gateway confines it to chat.
  CREDENTIAL_CHANGED="false"
  ensure_gateway_credential looker-agent-gateway-auth \
    "$GATEWAY_BASIC_AUTH_USER" "${GATEWAY_BASIC_AUTH_PASSWORD:-}"
  ensure_gateway_credential looker-agent-gateway-chat-auth \
    "$GATEWAY_CHAT_AUTH_USER" "${GATEWAY_CHAT_AUTH_PASSWORD:-}"
  if is_true "$INTERNAL_MANAGED_GATEWAY_TLS"; then
    ensure_internal_gateway_tls
  fi
  if [ -n "$GATEWAY_TLS_SECRET" ] && ! secret_exists "$GATEWAY_NAMESPACE" "$GATEWAY_TLS_SECRET"; then
    die "GATEWAY_TLS_SECRET names Secret ${GATEWAY_NAMESPACE}/${GATEWAY_TLS_SECRET}, which does not exist. Create it, then run again: kubectl --context ${KUBE_CONTEXT} -n ${GATEWAY_NAMESPACE} create secret tls ${GATEWAY_TLS_SECRET} --cert=<certificate file> --key=<key file>"
  fi
  kapply "${RENDER_DIR}/gateway.yaml"
  if is_true "$CREDENTIAL_CHANGED"; then
    # The gateway reads its passwords once, at start.
    k -n "$GATEWAY_NAMESPACE" rollout restart deployment/looker-agent-gateway >/dev/null
  fi
  k -n "$GATEWAY_NAMESPACE" rollout status deployment/looker-agent-gateway --timeout=5m
  remove_old_gateway_code
  log "OK: gateway is running."
}

# -----------------------------------------------------------------------------
# STEP 7: Verify
# -----------------------------------------------------------------------------
# gateway_secret SECRET KEY
gateway_secret() {
  k -n "$GATEWAY_NAMESPACE" get secret "$1" -o "jsonpath={.data.$2}" | base64 -d
}

# How this machine reaches the gateway through the port-forward: the address,
# and the options every curl call to it gets.
prepare_gateway_curl() {
  GATEWAY_LOCAL_URL="${GATEWAY_SCHEME}://127.0.0.1:${VERIFY_LOCAL_PORT}"
  GATEWAY_CURL_OPTIONS=(--proto "=${GATEWAY_SCHEME}")
  if [ "$GATEWAY_SCHEME" = "https" ]; then
    # The gateway's certificate names its Service, not 127.0.0.1, and its
    # issuer may be a CA this machine does not know. So curl is given the one
    # public key to accept, taken from the Secret the gateway serves with.
    # That is a stricter check than a name and a chain of issuers, and those
    # two are all that "--insecure" switches off here.
    local pin
    pin="$(k -n "$GATEWAY_NAMESPACE" get secret "$GATEWAY_TLS_SECRET" -o 'jsonpath={.data.tls\.crt}' \
      | base64 -d | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
      | openssl dgst -sha256 -binary | base64)"
    GATEWAY_CURL_OPTIONS+=(--insecure --pinnedpubkey "sha256//${pin}")
  fi
}

# gateway_curl SECRET PATH [curl options]: curl through the port-forward with
# the credential in SECRET.
gateway_curl() {
  local secret="$1" path="$2" user password
  shift 2
  user="$(gateway_secret "$secret" user)"
  password="$(gateway_secret "$secret" password)"
  # The credential goes to curl on stdin, as one header, so it is not in the
  # process list. By then it is base64, which has no character that means
  # anything to curl. So a value that was read back from the cluster cannot
  # add an option or a header of its own, whatever it contains.
  printf 'Authorization: Basic %s\n' "$(printf '%s:%s' "$user" "$password" | base64 | tr -d '\n')" \
    | curl -sS -H @- "${GATEWAY_CURL_OPTIONS[@]}" "$@" "${GATEWAY_LOCAL_URL}${path}"
}

step_verify() {
  step "STEP 7: Verify"
  if is_true "$RENDER_ONLY"; then
    log "[render] nothing to verify."
    return 0
  fi
  k -n "$GATEWAY_NAMESPACE" port-forward svc/looker-agent-gateway "${VERIFY_LOCAL_PORT}:${GATEWAY_SERVICE_PORT}" >/dev/null 2>&1 &
  PORT_FORWARD_PID=$!
  prepare_gateway_curl
  local attempt code apps failed="false"
  for attempt in $(seq 1 20); do
    if curl -fsS --max-time 2 "${GATEWAY_CURL_OPTIONS[@]}" "${GATEWAY_LOCAL_URL}/healthz" >/dev/null 2>&1; then break; fi
    sleep 1
  done

  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${GATEWAY_CURL_OPTIONS[@]}" "${GATEWAY_LOCAL_URL}/readyz" || true)"
  if [ "$code" = "401" ]; then
    log "[OK]   the gateway refuses callers without a password (HTTP 401)"
  else
    log "[FAIL] expected HTTP 401 without a password, got ${code}"
    failed="true"
  fi

  # The first authenticated request wakes the actor, so allow it time.
  code="$(gateway_curl looker-agent-gateway-auth /readyz -o /dev/null -w '%{http_code}' --max-time 180 || true)"
  if [ "$code" = "200" ]; then
    log "[OK]   gateway -> router -> actor: the agent answered /readyz"
  else
    log "[FAIL] the agent did not answer through the router (HTTP ${code})"
    failed="true"
  fi

  apps="$(gateway_curl looker-agent-gateway-auth /list-apps --max-time 60 || true)"
  if [[ "$apps" == *looker_app* ]]; then
    # The answer comes from the agent. Only its printable characters are shown.
    log "[OK]   ADK lists the agent: $(printf '%s' "$apps" | tr -cd '[:print:]' | cut -c 1-200)"
  else
    log "[FAIL] ADK did not list looker_app (got: $(printf '%s' "$apps" | tr -cd '[:print:]' | cut -c 1-200))"
    failed="true"
  fi

  # /list-apps is part of the developer API. The credential that goes into
  # Looker must not open it.
  code="$(gateway_curl looker-agent-gateway-chat-auth /list-apps -o /dev/null -w '%{http_code}' --max-time 60 || true)"
  if [ "$code" = "403" ]; then
    log "[OK]   the chat credential is kept out of the agent's developer API (HTTP 403)"
  else
    log "[FAIL] expected HTTP 403 for the chat credential on /list-apps, got ${code}"
    failed="true"
  fi

  kill "$PORT_FORWARD_PID" 2>/dev/null || true
  PORT_FORWARD_PID=""

  if is_true "$failed"; then
    cat >&2 <<EOF

Something on the path did not work. Where to look:
  kubectl ate --context ${KUBE_CONTEXT} get actor ${ACTOR_NAME} -a ${ATESPACE}
  kubectl ate --context ${KUBE_CONTEXT} logs actor ${ACTOR_NAME} -a ${ATESPACE}
  kubectl --context ${KUBE_CONTEXT} -n ${GATEWAY_NAMESPACE} logs deployment/looker-agent-gateway
  kubectl --context ${KUBE_CONTEXT} -n ate-system logs deployment/atenet-router --all-containers --tail=50
A 502 from the gateway with a TLS or 403 error in its log usually means the
router was installed without this gateway on its allowlist (see step 3). The
allowlist names the gateway's namespace: ${GATEWAY_SPIFFE_ID}
EOF
    exit 1
  fi
  log ""
  log "These checks do not call Looker or the model. Ask the agent a question to test those."
}

# -----------------------------------------------------------------------------
# STEP 8: The chat inside Looker (a Looker extension)
# -----------------------------------------------------------------------------
# People use the agent from a chat that runs inside Looker. Looker calls that an
# extension: one JavaScript file, kept in a LookML project, that Looker loads
# into a sandboxed frame. The chat itself is an existing component (deep-chat);
# looker-extension/ only connects it to the gateway.
#
# This step copies looker-extension/ to ${WORK_DIR}/looker-extension and writes
# the addresses from config.env into it:
#     src/deployment.js             the settings the bundle is built with
#     lookml/manifest.lkml          the extension, and what Looker lets it do
#     lookml/<project>.model.lkml   the model that decides who sees it
# "./deploy.sh extension" then builds lookml/bundle.js with npm. Nothing here
# touches the cluster or Looker: adding the files to Looker is a manual step.
render_extension() {
  local source="${SCRIPT_DIR}/looker-extension" out="$EXTENSION_DIR"
  local urls connection="${EXTENSION_LOOKML_CONNECTION:-YOUR_CONNECTION_NAME}" downloads=""
  local allowed_links_js="" allowed_links_lkml="" link_origins=() link_origin
  # Saving a file from the chat is something Looker has to permit the
  # extension to do. It is asked for only when the operator wants it: without
  # it, nothing an answer contains can be written to a user's disk.
  if is_true "$EXTENSION_ALLOW_DOWNLOADS"; then
    downloads="
    # Lets people save a rendered chart by clicking it (EXTENSION_ALLOW_DOWNLOADS).
    use_downloads: yes"
  fi
  if [ -n "$EXTENSION_ALLOWED_LINK_ORIGINS" ]; then
    IFS=',' read -r -a link_origins <<< "$EXTENSION_ALLOWED_LINK_ORIGINS"
    local js_items="" lkml_items=""
    for link_origin in "${link_origins[@]}"; do
      js_items="${js_items:+${js_items}, }\"${link_origin}\""
      lkml_items="${lkml_items:+${lkml_items}, }\"${link_origin}/*\""
    done
    allowed_links_js="
  allowedLinkOrigins: [${js_items}],"
    allowed_links_lkml="
    # Additional external origins permitted for chat links (EXTENSION_ALLOWED_LINK_ORIGINS).
    new_window_external_urls: [${lkml_items}]"
  fi

  mkdir -p "$out"
  rm -rf "${out}/src" "${out}/test" "${out}/lookml" "${out}/dist"
  cp -R "${source}/src" "${source}/test" "$out/"
  cp "${source}/package.json" "${source}/webpack.config.cjs" "$out/"
  # A lock file pins every dependency to the versions of an earlier build.
  if [ -f "${source}/package-lock.json" ]; then
    cp "${source}/package-lock.json" "$out/"
  fi
  find "$out" -name '*.metadata.json' -delete
  mkdir -p "${out}/lookml"

  # Every value below was checked in validate_config: none can break out of
  # the quotes it is written into.
  cat > "${out}/src/deployment.js" <<EOF
// Written by ./deploy.sh from config.env. Do not edit: change config.env and
// run "./deploy.sh extension" again. These values replace the defaults in
// config.js.

export const deployment = {
  transport: "${EXTENSION_TRANSPORT}",
  serverGatewayUrl: "${EXTENSION_SERVER_GATEWAY_URL}",
  browserGatewayUrl: "${EXTENSION_BROWSER_GATEWAY_URL}",
  secretKeyName: "${EXTENSION_SECRET_KEY}",
  userAttributeName: "${EXTENSION_USER_ATTRIBUTE}",${allowed_links_js}
};
EOF

  urls="\"${EXTENSION_SERVER_GATEWAY_URL}\""
  if [ -n "$EXTENSION_BROWSER_GATEWAY_URL" ] \
      && [ "$EXTENSION_BROWSER_GATEWAY_URL" != "$EXTENSION_SERVER_GATEWAY_URL" ]; then
    urls="${urls}, \"${EXTENSION_BROWSER_GATEWAY_URL}\""
  fi
  cat > "${out}/lookml/manifest.lkml" <<EOF
# LookML project "${EXTENSION_PROJECT_NAME}": the chat with the Looker agent.
# Written by ./deploy.sh from config.env.

project_name: "${EXTENSION_PROJECT_NAME}"

application: ${EXTENSION_APPLICATION_NAME} {
  label: "${EXTENSION_LABEL}"
  # The bundle built from looker-extension/. It sits next to this file.
  file: "bundle.js"
  mount_points: {
    standalone: yes
  }
  entitlements: {
    # The one Looker API call the chat makes: "who is the user?"
    core_api_methods: ["me"]
    # The only addresses it may call: the agent gateway.
    external_api_urls: [${urls}]
    # Links in an answer open in a new tab, which Looker has to do for it.
    new_window: yes${downloads}${allowed_links_lkml}
  }
}
EOF

  cat > "${out}/lookml/${EXTENSION_PROJECT_NAME}.model.lkml" <<EOF
# Looker shows an extension to the people whose role includes a model of the
# extension's project. This model exists for that only: it has no explores.
# Any existing connection will do; none is queried.
connection: "${connection}"
EOF
  log "Rendered ${out}"
}

build_extension() {
  local out="$EXTENSION_DIR"
  if ! command -v "$NPM" >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: '${NPM}' was not found, so the extension's bundle was not built.
The project is ready in ${out}. On a machine with Node.js 18 or newer:
  cd ${out}
  npm install --ignore-scripts && npm test && npm run build
  cp dist/bundle.js lookml/bundle.js
EOF
    exit 1
  fi
  log "Building the bundle with npm (downloads the Looker Extension SDK, deep-chat and webpack)..."
  (
    cd "$out"
    # A package may bring a script that npm runs while installing it. None of
    # the packages this project names needs one, and such a script would run
    # on this machine, as you. So npm installs without running any. (The
    # secrets you exported are not in npm's environment either: see
    # withhold_secrets_from_tools.)
    if [ -f package-lock.json ]; then
      "$NPM" ci --ignore-scripts --no-audit --no-fund
    else
      "$NPM" install --ignore-scripts --no-audit --no-fund
    fi
    # The extension's own tests, against the settings just written.
    "$NPM" test
    "$NPM" run build
  )
  if [ ! -s "${out}/dist/bundle.js" ]; then
    die "npm finished, but ${out}/dist/bundle.js was not produced."
  fi
  cp "${out}/dist/bundle.js" "${out}/lookml/bundle.js"
  log "OK: built ${out}/lookml/bundle.js ($(wc -c < "${out}/lookml/bundle.js" | tr -d ' ') bytes)."
  if [ ! -f "${SCRIPT_DIR}/looker-extension/package-lock.json" ] && [ -f "${out}/package-lock.json" ]; then
    log "To make later builds use exactly these dependency versions, keep the lock file:"
    log "  cp ${out}/package-lock.json ${SCRIPT_DIR}/looker-extension/"
  fi
}

print_extension_next_steps() {
  local out="$EXTENSION_DIR" bundle_note="" connection_note=""
  if [ ! -s "${out}/lookml/bundle.js" ]; then
    bundle_note="
     bundle.js is not built yet: run ./deploy.sh extension (needs Node.js 18+ and npm)."
  fi
  if [ -z "$EXTENSION_LOOKML_CONNECTION" ]; then
    connection_note="
     In ${EXTENSION_PROJECT_NAME}.model.lkml, replace YOUR_CONNECTION_NAME with any connection
     that exists in Looker (or set EXTENSION_LOOKML_CONNECTION in config.env)."
  fi
  cat <<EOF

To put the chat into Looker (a Looker admin, once):

  1. Develop > Projects > New LookML Project
       name "${EXTENSION_PROJECT_NAME}", starting point "Blank Project".
  2. Add the three files in ${out}/lookml/ to the project:
       manifest.lkml   ${EXTENSION_PROJECT_NAME}.model.lkml   bundle.js${bundle_note}${connection_note}
  3. In the project: configure Git, commit, and deploy to production. Under
     Develop > Projects, configure the model "${EXTENSION_PROJECT_NAME}" to allow its connection.
  4. Admin > Users > User Attributes > Create User Attribute. This is how Looker's
     server gets the chat's gateway password without any browser seeing it:
       Name              ${EXTENSION_USER_ATTRIBUTE}
       Data Type         String
       User Access       None
       Hide Values       Yes
       Domain Allowlist  ${EXTENSION_SERVER_GATEWAY_URL}/*
       Default Value     the output of this command ("user:password" in base64).
                         It reads the CHAT credential. Do not use the administrator's
                         (looker-agent-gateway-auth): every chat user could then reach
                         the agent's developer API.
         printf '%s:%s' "\$(kubectl --context ${KUBE_CONTEXT} -n ${GATEWAY_NAMESPACE} get secret looker-agent-gateway-chat-auth -o jsonpath='{.data.user}' | base64 -d)" "\$(kubectl --context ${KUBE_CONTEXT} -n ${GATEWAY_NAMESPACE} get secret looker-agent-gateway-chat-auth -o jsonpath='{.data.password}' | base64 -d)" | base64 | tr -d '\\n'
  5. Give people a role whose model set includes "${EXTENSION_PROJECT_NAME}".
  6. They open it from Looker's main menu, under Applications: "${EXTENSION_LABEL}".

The extension uses the "${EXTENSION_TRANSPORT}" transport: looker-extension/README.md
explains the two, what to check first, and what has not been tested.
EOF
}

# step_extension [build]
step_extension() {
  local build="${1:-}"
  step "STEP 8: Prepare the Looker extension (chat inside Looker)"
  if [ -z "$EXTENSION_SERVER_GATEWAY_URL" ]; then
    local reason="Looker is not deployed by this script and the gateway has no ingress, so there is no address at which your Looker server could reach the gateway. Set EXTENSION_SERVER_GATEWAY_URL in ${CONFIG_FILE} (or AGENT_INGRESS_ENABLED with AGENT_HOST)"
    if [ "$build" = "build" ]; then
      die "${reason}."
    fi
    warn "the Looker extension was not prepared. ${reason}, then run ./deploy.sh extension."
    return 0
  fi
  render_extension
  if is_true "$RENDER_ONLY"; then return 0; fi
  if [ "$build" = "build" ]; then
    build_extension
  fi
  print_extension_next_steps
}

print_summary() {
  step "SETUP COMPLETE"
  local forward admin_access link_note
  forward="kubectl --context ${KUBE_CONTEXT} -n ${GATEWAY_NAMESPACE} port-forward svc/looker-agent-gateway 8080:${GATEWAY_SERVICE_PORT}"
  if is_true "$AGENT_DEV_UI"; then
    admin_access="Developer UI (ADK web, shows tool calls and traces; not meant for end users):
  ${forward}
  ${GATEWAY_SCHEME}://localhost:8080/dev-ui/"
  else
    admin_access="The agent's API, for the administrator. ADK's developer UI is switched off;
AGENT_DEV_UI=\"true\" in config.env turns it on.
  ${forward}
  ${GATEWAY_SCHEME}://localhost:8080/list-apps"
  fi
  if [ "$GATEWAY_SCHEME" = "https" ]; then
    admin_access="${admin_access}
  (the certificate names the gateway's Service, so a browser warns about \"localhost\")"
  fi
  if [ "$LOOKER_LINK_MODE" = "signed" ]; then
    link_note="  - In Looker Admin > Embed, enable 'Embed SSO Authentication' for the signed links.
  - In the Looker chat, a signed link opens the dashboard or Look itself, as the
    person who clicked. Opened as it is, it would sign them out of Looker."
  else
    link_note="  - A link in an answer is the ordinary address of the dashboard or Look. It
    opens with the reader's own Looker session, and shows what that person may see."
  fi
  cat <<EOF

  Actor            : ${ATESPACE}/${ACTOR_NAME}   (template ${TEMPLATE_NAME:-?})
  Agent image      : ${AGENT_IMAGE_REF:-?}
  Looker API       : ${LOOKER_API_URL}
  Model            : ${AGENT_MODEL_PROVIDER} via ${MODEL_HOST}

Chat inside Looker:
  Step 8 above lists what a Looker admin does once. The bundle is built by
    ./deploy.sh extension

${admin_access}
  user     : ${GATEWAY_BASIC_AUTH_USER}
  password : kubectl --context ${KUBE_CONTEXT} -n ${GATEWAY_NAMESPACE} get secret looker-agent-gateway-auth -o jsonpath='{.data.password}' | base64 -d

Try:
  - 'Show me dashboard 1'
  - 'Show me look 5'
  - 'Chart orders by status as a bar chart'
  - 'How many orders are there per status?'  (data answer, no image)
  - 'Give me the link to dashboard 1'

Good to know:
  - The actor keeps running until someone suspends it. To free its worker:
      kubectl ate --context ${KUBE_CONTEXT} suspend actor ${ACTOR_NAME} -a ${ATESPACE} --mode=sync
    The next request wakes it with its sessions intact.
  - Before draining a node, suspend the actor the same way. An actor that is
    still running when its worker pod is removed loses what happened since its
    last snapshot.
${link_note}
  - Whoever may create pods or PodCertificateRequests in namespace
    ${GATEWAY_NAMESPACE} can obtain the gateway's identity, and with it reach the
    agent without either password. Give that right to nobody who should not
    have the administrator's password.
EOF
}

print_pause_for_credentials() {
  step "PAUSED: the agent needs Looker API credentials"
  if is_true "$DEPLOY_LOOKER"; then
    print_looker_next_steps
  else
    cat <<EOF

Set LOOKER_CLIENT_ID in config.env and export LOOKER_CLIENT_SECRET, the API key
of a least-privilege Looker user.
EOF
  fi
  cat <<EOF

Then run ./deploy.sh again. Looker and Substrate are left as they are, and the
script continues with the agent image, the actor and the gateway.
EOF
}

show_status() {
  step "Status"
  log "--- Substrate control plane (ate-system)"
  k -n ate-system get pods 2>&1 || true
  if is_true "$DEPLOY_LOOKER"; then
    log "--- Looker (${LOOKER_NAMESPACE})"
    k -n "$LOOKER_NAMESPACE" get pods 2>&1 || true
  fi
  log "--- Workers (${AGENT_NAMESPACE})"
  k -n "$AGENT_NAMESPACE" get workerpools,pods 2>&1 || true
  log "--- Gateway (${GATEWAY_NAMESPACE})"
  k -n "$GATEWAY_NAMESPACE" get pods 2>&1 || true
  log "--- Model credential (${CREDS_NAMESPACE})"
  k -n "$CREDS_NAMESPACE" get pods 2>&1 || true
  log "--- Actors"
  kate get actors -A 2>&1 || true
  log "--- Egress policy"
  kate get egress-policy "$ACTOR_NAME" -a "$ATESPACE" 2>&1 || true
}

usage() {
  sed -n '/^#  USAGE/,/^# ====/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,2\}//' -e '/^====/d'
}

main() {
  local command="${1:-all}"
  case "$command" in
    -h|--help|help) usage; exit 0 ;;
  esac
  load_config
  if [ "$command" = "render" ]; then RENDER_ONLY="true"; fi
  validate_config

  case "$command" in
    render)
      step_gke; step_looker; step_substrate; step_image; step_agent; step_gateway; step_extension
      step "Rendered manifests are in ${RENDER_DIR}"
      ls -1 "$RENDER_DIR"
      ;;
    all)
      require_onprem_acknowledgement
      step_preflight
      step_gke
      step_looker
      step_substrate
      if ! have_looker_api_credentials; then
        print_pause_for_credentials
        # Not a failure, but not a finished deployment either.
        exit 2
      fi
      step_image
      step_agent
      step_gateway
      step_verify
      step_extension
      print_summary
      ;;
    preflight) step_preflight ;;
    gke)       step_gke ;;
    looker)    step_looker; print_looker_next_steps ;;
    substrate) require_onprem_acknowledgement; step_substrate ;;
    image)     step_image ;;
    agent)     ensure_substrate_tools; step_agent ;;
    gateway)   step_gateway ;;
    verify)    step_verify ;;
    # Step 8 as the full run does it: the project and the LookML files, without
    # the npm build. For callers that build the bundle as a stage of their own.
    extension-files) step_extension ;;
    extension) step_extension build ;;
    status)    ensure_substrate_tools; show_status ;;
    *) usage; die "unknown command '${command}'." ;;
  esac
}

main "$@"

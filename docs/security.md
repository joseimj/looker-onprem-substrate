# Security model and controls

This document describes how the kit isolates components, what each boundary enforces, what `SECURITY_MODE="strict"` checks, and which risks remain open or depend on Agent Substrate or live-cluster behavior that has not been tested here.

See [architecture.png](architecture.png) for the end-to-end request and egress paths.

## Trust boundaries and namespaces

The kit separates workloads into four distinct Kubernetes namespaces (enforced in `deploy.sh` `validate_config`):

| Namespace setting | Default | Pod Security level (`enforce` / `audit` / `warn`) | Holds |
| :--- | :--- | :--- | :--- |
| `GATEWAY_NAMESPACE` | `looker-agent-gateway` | `restricted` / `restricted` / `restricted` | Gateway pod, gateway auth and TLS Secrets, Service, optional gateway Ingress |
| `CREDS_NAMESPACE` | `looker-agent-creds` | `restricted` / `restricted` / `restricted` | `vertex-token-refresher` and the short-lived `model-credential` Secret |
| `LOOKER_NAMESPACE` | `looker` | `baseline` / `restricted` / `restricted` | Customer-hosted Looker, optional bundled MySQL 8.4, Looker Secrets and PVC |
| `AGENT_NAMESPACE` | `looker-agent` | `privileged` / `privileged` / `privileged` | Substrate `WorkerPool` sandbox worker pods only |

Because Substrate's gVisor worker pods require `SYS_ADMIN`, `NET_ADMIN`, and an unconfined seccomp profile, `AGENT_NAMESPACE` must permit `privileged` pods and hosts nothing else. Anyone able to create pods in `GATEWAY_NAMESPACE` (or `PodCertificateRequest` objects there) can obtain the gateway's SPIFFE identity, which admits direct requests through Substrate's router (`atenet-router`); restrict RBAC on `GATEWAY_NAMESPACE` accordingly.

## Controls built into the kit

### Network isolation and TLS

- **Default-deny `NetworkPolicy` manifests** (`NETWORK_POLICIES="true"`): `LOOKER_NAMESPACE`, `GATEWAY_NAMESPACE`, and `CREDS_NAMESPACE` each receive a `default-deny` policy blocking all ingress and egress, plus narrow allow policies:
  - MySQL accepts TCP 3306 from Looker pods only and has no egress rules.
  - Looker accepts TCP 19999 from `ate-system/atenet-egress`, optional TCP 9999/19999 from `INGRESS_CONTROLLER_NAMESPACE` when `LOOKER_INGRESS_ENABLED="true"`, and intra-cluster ports 1551/61616 only when `LOOKER_REPLICAS > 1`. Looker egress is restricted to DNS (53 UDP/TCP), MySQL 3306, gateway 8080, and `LOOKER_EGRESS_CIDRS`.
  - The gateway accepts TCP 8080 only from Looker pods and `INGRESS_CONTROLLER_NAMESPACE` when `AGENT_INGRESS_ENABLED="true"`, and opens egress only to DNS and `ate-system/atenet-router` port 8443.
  - `vertex-token-refresher` has no ingress and opens egress only to DNS, TCP 443 and `KUBE_API_PORTS` (default `443,6443`, for Google's token service and the Kubernetes API server), and GKE metadata addresses on GKE.
- **Preflight CNI check** (`NETWORK_POLICY_CHECK="true"`): creates a temporary `restricted` namespace with `default-deny` before installing anything (cleaned up via trap on exit), runs a Python TCP listener and client (`GATEWAY_IMAGE`), and fails if the probe connects across the deny rule.
- **Database TLS and credentials (`LOOKER_DB_SSL="true"`, `LOOKER_DB_VERIFY_SSL`)**: Looker receives database connection settings and credentials via Secret `looker-db-creds` mounted `0440` at `/run/looker-db/looker-db.yml` (`--internal-db-creds=/run/looker-db/looker-db.yml`, no database password in Looker container `env`), enabling `ssl: true` and (by default for an external `LOOKER_DB_HOST`) `verify_ssl: true`. Bundled MySQL 8.4 starts with `--require-secure-transport=ON`, `caching_sha2_password`, `MYSQL_ROOT_HOST=localhost`, and passwordless `mysqladmin ping --ssl-mode=REQUIRED` probes.
- **Gateway, Looker, and S3 internal TLS** (`GATEWAY_TLS_SECRET`, `INTERNAL_TLS="private-ca"`, `EXTRA_CA_FILE`):
  - When `GATEWAY_TLS_SECRET` is set, `gateway/gateway.py` serves TLS 1.2+ in per-connection worker threads, reloads rotated certificates automatically, adds `Strict-Transport-Security`, and switches the Service to port 443.
  - When `INTERNAL_TLS="private-ca"`, `deploy.sh` generates a private CA and server certificates with `openssl`, builds Looker's Java keystore (`pkcs12` + `keytool`) and updated JDK `cacerts` truststore in an init container on memory-backed `/app/tls` and `/tmp` volumes, compiles the CA into the agent's `extra-ca.pem`, and enables `LOOKER_VERIFY_SSL="true"`. **Untested against a live Looker or cluster.**
  - When `SNAPSHOT_STORE="s3"` and `EXTRA_CA_FILE` is set, `deploy.sh` creates ConfigMap `ate-system/ate-objectstore-extra-ca`, mounts it read-only into `objectstore-plugin` on `ate-api-server` and `atelet`, and sets `AWS_CA_BUNDLE=/run/objectstore-ca/ca.crt` so `aws-sdk-go-v2` trusts private CAs.
- **Ingress and Substrate rollout hygiene**: an enabled Ingress requires a TLS Secret and sets `nginx.ingress.kubernetes.io/force-ssl-redirect: "true"`. The gateway Ingress exposes `/_gateway/` and `/apps/` only; ADK's developer UI stays on `kubectl port-forward`. On reruns, `apply_egress_policy` updates existing actor egress policies in place via `kubectl ate update egress-policy` (avoiding a delete-then-create egress outage window), and `configure_bundled_snapshot_store` waits for and deletes `job/rustfs-bucket-init` and switches `deployment/rustfs` to a `Recreate` rollout strategy.

### Gateway request confinement and limits

- **Fail-closed authentication**: `gateway/gateway.py` refuses to start without credentials unless `ALLOW_UNAUTHENTICATED="true"`. Credentials are mounted as read-only files (`*_FILE`, mode `0440`) rather than environment variables. Passwords shorter than `MIN_PASSWORD_LENGTH` (default `16`) are rejected. Auth failures are logged at `WARNING` rate-limited to avoid log floods and without IP lockout (since server-transport traffic shares Looker's IP).
- **Separate admin and chat credentials**: HTTP Basic credentials and bearer tokens for chat callers are strictly confined (`chat_may` and `chat_run_request`):
  - Only `POST /_gateway/token` (Basic only, empty body), `POST /_gateway/jobs/apps/<ADK_APP_NAME>/users/looker-<id>/sessions` (`{}` or empty), `POST /_gateway/jobs/run` (`Content-Type: application/json`, validated object keys, `{"role": "user", "parts": [{"text": <=16000}]}`, rebuilt JSON rejecting duplicate keys), `GET /_gateway/jobs/<id>` (only jobs started by confined callers), and `GET /apps/<ADK_APP_NAME>/users/looker-<id>/sessions/<session>/artifacts/<name>` (1–4 safe path segments, no `.` or `..` or `%`).
  - Any request body carrying the raw chat password or its base64-encoded Basic credential is rejected before forwarding so Looker user-attribute substitution cannot echo the credential back to the browser.
- **Smuggling and CSRF resistance**: malformed request heads (control characters, obs-fold, invalid framing/chunk sizes) are rejected before forwarding; cross-site requests (`Origin` / `Sec-Fetch-Site`) not listed in `CORS_ALLOWED_ORIGINS` are rejected before auth evaluation; every job `POST` requires `Content-Type: application/json` (`415` otherwise); `Authorization` and spoofing/routing headers (`ate-*`, `x-envoy-*`, `x-forwarded-*`, `forwarded`, `x-real-ip`, `host`, `cookie`) are stripped and replaced by the gateway.
- **DoS bounds and probe isolation**: listen backlog `128`, `MAX_CONNECTIONS` (`256`), total head/idle deadline (`HEAD_TIMEOUT_SECONDS=30`), `MAX_HEAD_BYTES` (`32768`, returning `431`), reserved admin job slots (`MAX_CHAT_RUNNING_JOBS=24` of `32`), per-job total deadline (`JOB_DEADLINE_SECONDS=600`), pre-serialized job answer bytes, and an independent HTTP `/healthz` listener on `HEALTH_PORT` (`8081`).

### Agent and Looker extension controls

- **Read-only agent code (`agent/Dockerfile`)**: `/app` is owned by `root` and mode `a+rX,go-w`; uid `10001` cannot modify `server.py` or `agent.py` or persist altered code inside a Substrate memory snapshot. `ADK_WEB_UI` defaults to `false`, access logging is disabled (`access_log=False`), and ADK loggers stay at `WARNING` so conversation and artifact IDs do not accumulate in logs.
- **Agent tool hardening (`agent/agents/looker_app/agent.py`)**:
  - `LOOKER_LINK_MODE="plain"` (default) returns regular Looker page URLs and never calls `create_sso_embed_url`.
  - `_guarded` enforces `LOOKER_MODELS` on every tool accepting a model, validates `dashboard_id`, `look_id`, `model`, and `explore` formats, clamps query row `limit` to `1..500`, runs synchronous SDK calls via `asyncio.to_thread` / `asyncio.sleep`, and summarizes tool exceptions to one line (`<=200` chars) with the internal Looker API host redacted.
- **Extension browser hardening (`looker-extension/src/`)**:
  - `markdown.js` registers a `window.remarkable_plugins` hook (verified against `deep-chat` 2.5.1 source, not yet run in a browser) that blocks remote markdown `<img>` rendering and gates link `href` values through `resolveLink`.
  - `links.js` allows only `/dashboards`, `/looks`, and `/explore` pages on the configured Looker host (also inspecting inner targets of signed links), strips `/embed`, rejects login/embed-sign-in paths and control characters, and leaves all non-allowlisted origins blocked unless explicitly configured in `config.js` (`allowedLinkOrigins: []` by default). Capture-phase `click` and `auxclick` listeners intercept navigation in the page.
  - `adk.js` and `client.js` accept only `image/png` and `image/jpeg` artifacts within byte (`MAX_IMAGE_BYTES`) and count (`MAX_ARTIFACTS_PER_ANSWER`) limits and safe artifact path segments. `manifest.lkml` omits `use_downloads: yes` unless `EXTENSION_ALLOW_DOWNLOADS="true"`.

### Supply chain and secrets handling

- `deploy.sh` verifies `SUBSTRATE_COMMIT` against `SUBSTRATE_VERSION` (`v1.0.0`) after checkout and removes mismatched checkouts, deploys Looker and agent images by pushed `@sha256:` digest, pins GitHub workflow actions by full 40-character commit SHA with `persist-credentials: false`, installs Looker's Chrome package from Google's signed apt repository (`looker/Dockerfile`), and passes `--ignore-scripts` and scrubbed environments (`withhold_secrets_from_tools`) to external build tools.
- Secrets never pass via `SECRET_SETTINGS` to subtools (except `LOOKER_LICENSE_KEY` passed once via environment to `jq`), Secret objects use `create`/`replace` rather than `apply` (avoiding `last-applied-configuration` annotations), temporary files live under memory-backed `$XDG_RUNTIME_DIR`/`/dev/shm` when available and are deleted immediately after reading, and `.work/rendered/actor-template.yaml` stores `REDACTED` instead of the raw Looker API secret.

## Requirements enforced by `SECURITY_MODE="strict"`

In `SECURITY_MODE="standard"` (the default), `deploy.sh` prints notices for any weak setting in use. In `SECURITY_MODE="strict"`, `deploy.sh` refuses to run while any of these conditions holds (`collect_weak_choices` in `deploy.sh`):

1. `PLATFORM="onprem"` with `SNAPSHOT_STORE="bundled"`.
2. `PLATFORM="onprem"`, `SNAPSHOT_STORE="bundled"`, and `BUNDLED_STORE_GENERATED_LOGIN="false"`.
3. `PLATFORM="onprem"`, `SNAPSHOT_STORE="s3"`, and `S3_ALLOW_HTTP="true"`.
4. Any active image variable (`GATEWAY_IMAGE`, `WORKER_IMAGE`, `AGENT_BASE_IMAGE`, and when enabled `LOOKER_IMAGE` or `LOOKER_BASE_IMAGE`, `LOOKER_MYSQL_IMAGE`, `BUSYBOX_IMAGE` for `LOOKER_CHOWN_SHARED_FILES`, `TOKEN_REFRESHER_IMAGE`) lacking an `@sha256:` digest.
5. `LOOKER_VERIFY_SSL="false"`.
6. `EXTENSION_SERVER_GATEWAY_URL` starting with `http://`.
7. `ALLOW_KUBECTL_ATE_PROXY="true"`.
8. `NETWORK_POLICIES="false"`.
9. `NETWORK_POLICY_CHECK="false"`.
10. `DEPLOY_LOOKER="true"`, `NETWORK_POLICIES="true"`, and `LOOKER_EGRESS_CIDRS` containing `0.0.0.0/0`.
11. `DEPLOY_LOOKER="true"` and `LOOKER_DB_SSL="false"`, or external `LOOKER_DB_HOST` with `LOOKER_DB_VERIFY_SSL="false"`.
12. `DEPLOY_LOOKER="true"` and `LOOKER_SECCOMP_PROFILE="Unconfined"`.
13. `AGENT_DEV_UI="true"`.
14. `LOOKER_LINK_MODE="signed"`.
15. Empty `SUBSTRATE_COMMIT`.

Always refused in both `standard` and `strict` modes: Ingress enabled without its TLS Secret; gateway passwords shorter than 16 characters; control characters in any setting; non-`linux/amd64` `IMAGE_PLATFORM` when building Looker from `looker/Dockerfile`; `GATEWAY_MAX_CHAT_RUNNING_JOBS` greater than `GATEWAY_MAX_RUNNING_JOBS`; non-`https://` `EXTENSION_ALLOWED_LINK_ORIGINS`; bundled MySQL 8.4 paired with `LOOKER_VERSION` below `26.6`; plain `http://` `S3_ENDPOINT_URL` unless `S3_ALLOW_HTTP="true"`.

## Dedicated Looker API user

Create a dedicated non-admin Looker service account for `LOOKER_CLIENT_ID` / `LOOKER_CLIENT_SECRET`:

- Restrict its Looker model set exclusively to the LookML models listed in `LOOKER_MODELS`. While `agent.py` checks `LOOKER_MODELS` for model-taking tools, `show_dashboard_inline` and `show_look_inline` query dashboards and Looks by ID, so Looker's own content-access and model permissions are the boundary for dashboards and Looks.
- Grant only the permissions needed for the tools you expose (`access_data`, `see_lookml_dashboards`, `see_user_dashboards`, `see_looks`, `download_with_limit` / render permissions). Do not grant `admin` or embed-user management unless `LOOKER_LINK_MODE="signed"` requires it.
- Treat rotating `LOOKER_CLIENT_SECRET` as two actions: run `deploy.sh` so the new template is applied and superseded templates are deleted, and also disable or delete the old API key inside Looker because snapshots in object storage retain historical state unless purged.

## Known limitations and inherited Agent Substrate risks

- **Shared Looker identity for all chat users**: the agent logs in to Looker with one API key, so every user allowed into the extension sees whatever data that API user can query. User attribution (`userId`) sent by the browser extension is not verified by Looker or the gateway; conversation privacy between users relies on random ADK session IDs.
- **Looker API key inside the sandbox**: Looker's API login carries `client_secret` in the POST form body, so Substrate's header-rewriting egress gateway cannot inject it. The key therefore lives in the `ActorTemplate`, inside sandbox memory, and in snapshots. Use an encrypted external S3 bucket (`SNAPSHOT_STORE="s3"` over HTTPS) or GKE GCS bucket, isolate sandbox nodes (`WORKER_NODE_SELECTOR`), and restrict access to `ate-system` and storage backends. Keeping the Looker secret out of the sandbox altogether would require an external token-broker service outside the sandbox plus Looker TLS verification.
- **Privileged worker pods and node sharing**: gVisor worker pods run with privileged container rights (`SYS_ADMIN`, `NET_ADMIN`). If `WORKER_NODE_SELECTOR` is left empty, worker pods can be scheduled onto nodes alongside Looker, MySQL, the gateway, or the token refresher. Set `WORKER_NODE_SELECTOR` paired with Substrate's `ate.dev/sandboxClass=gvisor:NoSchedule` taint on sandbox nodes so non-sandbox pods stay off them.
- **Inherited Substrate v1.0.0 behavior outside this kit**:
  - `WORKER_IMAGE` / worker pod egress is not confined by a kit `NetworkPolicy`; outside the gVisor network namespace (`ate-system`), verify worker pod egress policies according to your cluster posture.
  - `ate-setup`'s `--kind` on-prem profile deploys an unauthenticated observability stack in `otel-system` (OpenTelemetry collector, Prometheus, Jaeger) and a development-grade `rustfs` store; keep `SNAPSHOT_STORE="s3"` with your own store and restrict or disable `otel-system` in shared clusters.
  - Substrate's `k8s-credential-provider` holds a cluster-wide `ClusterRoleBinding` to read Secrets across namespaces (gated at lookup time by `k8s-credential-provider-namespace-policy` in `ate-system`). Clusters requiring stricter Kubernetes RBAC can replace that binding with a namespaced `RoleBinding` limited to `CREDS_NAMESPACE`, and optionally separate the refresher pod + long-lived GCP SA key into its own namespace holding only a `RoleBinding` to patch `model-credential` in `CREDS_NAMESPACE`.
  - Substrate's egress gateway matches destination hostnames rather than HTTP paths or methods, so this kit pairs that host rule with a narrow Vertex IAM custom role (`aiplatform.endpoints.predict` on GKE; recommended on-prem too) or a dedicated, spend-capped Anthropic workspace key.
  - On-prem Substrate v1.0.0 does not configure node-independent registry pull credentials for actor images (`AGENT_NAMESPACE`); the agent repository must be reachable by `atelet` without per-namespace `imagePullSecrets`, so keep Looker's licensed image in a separate `LOOKER_REGISTRY` with `LOOKER_IMAGE_PULL_SECRET`.

## Live-cluster verification checklist

None of the runtime controls below could be verified locally because no Kubernetes cluster, Docker daemon, Looker instance, npm registry, or Terraform binary was present here. Verify these explicitly on your target cluster:

1. Preflight `NETWORK_POLICY_CHECK` blocks cross-pod traffic when `default-deny` is applied.
2. `SECURITY_MODE="strict"` succeeds with pinned `@sha256:` image digests, S3 HTTPS snapshots, non-`0.0.0.0/0` `LOOKER_EGRESS_CIDRS`, and TLS enabled.
3. If enabling `LOOKER_SECCOMP_PROFILE="RuntimeDefault"` together with `LOOKER_CHROMIUM_NO_SANDBOX="true"`, confirm dashboard and Look PNG rendering works inside Looker.
4. If enabling `INTERNAL_TLS="private-ca"`, confirm the Looker `prepare-tls` init container completes `openssl pkcs12` and `keytool`, Looker serves `looker-api` and `looker-web` with the issued cert, Looker trusts calls to the HTTPS gateway via `/app/tls/cacerts`, and the agent container verifies Looker's cert with `LOOKERSDK_VERIFY_SSL="true"`.
5. If using on-prem `BUNDLED_STORE_GENERATED_LOGIN="true"`, confirm Substrate's `rustfs` deployment accepts replaced `RUSTFS_ACCESS_KEY`/`RUSTFS_SECRET_KEY` credentials on restart.
6. Confirm Looker loads `looker-extension/dist/bundle.js` under Looker's CSP, plain links open as the signed-in reader, and blocked links/markdown images remain inert in `deep-chat`.

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

# Every variable here is a setting of ../deploy.sh, under the same name in
# lower case. ../config.env.example explains each one at length.
#
# There is no variable for a secret, on purpose. Terraform writes what it knows
# into its state, so it is never told one. Export secrets in the shell that
# runs Terraform, exactly as for deploy.sh (see README.md in this directory):
#
#   LOOKER_LICENSE_KEY  LOOKER_CLIENT_SECRET  ANTHROPIC_API_KEY
#   S3_ACCESS_KEY_ID  S3_SECRET_ACCESS_KEY  LOOKER_DB_PASSWORD
#   GATEWAY_BASIC_AUTH_PASSWORD  GATEWAY_CHAT_AUTH_PASSWORD

# --- Where it runs -------------------------------------------------------------

variable "platform" {
  description = "\"onprem\": a Kubernetes cluster outside Google Cloud that already exists. \"gke\": Google Kubernetes Engine; the cluster is created."
  type        = string
  default     = "onprem"

  validation {
    condition     = contains(["onprem", "gke"], var.platform)
    error_message = "platform must be \"onprem\" or \"gke\"."
  }
}

variable "kube_context" {
  description = "kubectl context of the target cluster. Required on-prem. Leave empty on GKE."
  type        = string
  default     = ""
}

variable "registry" {
  description = "Registry path the images are pushed under. On GKE: REGION-docker.pkg.dev/PROJECT/REPOSITORY."
  type        = string
}

# --- Security ------------------------------------------------------------------

variable "security_mode" {
  description = "\"strict\" refuses to deploy while a known-weak choice is configured and names each one. \"standard\" deploys and prints the same list."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "strict"], var.security_mode)
    error_message = "security_mode must be \"standard\" or \"strict\"."
  }
}

variable "network_policies" {
  description = "Apply the kit's NetworkPolicies. false is for clusters where another team owns them."
  type        = bool
  default     = true
}

variable "kube_api_ports" {
  description = "TCP ports where the cluster's Kubernetes API server endpoints listen (post-DNAT). Allowed from vertex-token-refresher alongside 443."
  type        = list(string)
  default     = ["443", "6443"]
}

variable "internal_tls" {
  description = "\"private-ca\": create a private CA, give Looker and the gateway certificates from it, and have the agent verify Looker. \"off\": Looker keeps its self-signed certificate and the gateway serves plain HTTP inside the cluster."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "private-ca"], var.internal_tls)
    error_message = "internal_tls must be \"off\" or \"private-ca\"."
  }
}

variable "gateway_tls_secret" {
  description = "Name of a kubernetes.io/tls Secret in the gateway's namespace. When set, the gateway serves HTTPS with it."
  type        = string
  default     = ""
}

variable "looker_egress_cidrs" {
  description = "Networks Looker may open connections to: its databases, Git, mail. [\"0.0.0.0/0\"] means anywhere."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "worker_node_selector" {
  description = "key=value label of the nodes the sandbox workers run on. Empty: any node."
  type        = string
  default     = ""
}

variable "agent_dev_ui" {
  description = "Serve ADK's developer UI and its extra endpoints through the gateway, for the administrator credential."
  type        = bool
  default     = false
}

variable "looker_link_mode" {
  description = "\"plain\": the agent returns ordinary Looker page addresses. \"signed\": signed embed links, for a chat outside Looker; needs Embed SSO in Looker."
  type        = string
  default     = "plain"

  validation {
    condition     = contains(["plain", "signed"], var.looker_link_mode)
    error_message = "looker_link_mode must be \"plain\" or \"signed\"."
  }
}

variable "extra_ca_file" {
  description = "Optional PEM file of a private CA trusted by the agent (for an external Looker) and by Substrate's S3 snapshot sidecars."
  type        = string
  default     = ""
}

# --- Looker --------------------------------------------------------------------

variable "deploy_looker" {
  description = "true: build and deploy customer-hosted Looker on this cluster. false: Looker already runs; set looker_api_url."
  type        = bool
  default     = true
}

variable "looker_host" {
  description = "Host name people type into a browser to reach Looker."
  type        = string
}

variable "looker_version" {
  description = "Looker release to download and build, as major.minor (for example 26.6). Not needed with looker_image."
  type        = string
  default     = ""
}

variable "looker_technical_contact_email" {
  description = "Email registered with Looker's download service for this license."
  type        = string
  default     = ""
}

variable "looker_admin_email" {
  description = "Email of the first admin account created on a brand-new Looker."
  type        = string
  default     = ""
}

variable "looker_registry" {
  description = "Separate registry path for the licensed Looker image. Empty reuses registry."
  type        = string
  default     = ""
}

variable "looker_image_pull_secret" {
  description = "Name of a docker-registry Secret in LOOKER_NAMESPACE used to pull the Looker image."
  type        = string
  default     = ""
}

variable "looker_image" {
  description = "A Looker image that already exists, instead of building one."
  type        = string
  default     = ""
}

variable "looker_base_image" {
  description = "Base image passed to looker/Dockerfile when building Looker. Pin by @sha256: digest for strict mode."
  type        = string
  default     = "ubuntu:24.04"
}

variable "looker_replicas" {
  description = "Number of Looker pods. Values above 1 require LOOKER_STORAGE_CLASS set to a ReadWriteMany storage class."
  type        = number
  default     = 1

  validation {
    condition     = var.looker_replicas >= 1 && floor(var.looker_replicas) == var.looker_replicas
    error_message = "looker_replicas must be a whole number of 1 or more."
  }
}

variable "looker_memory" {
  description = "Memory request and limit for each Looker pod (Kubernetes quantity, for example 8Gi)."
  type        = string
  default     = "8Gi"
}

variable "looker_db_host" {
  description = "Host of Looker's own MySQL database. Empty deploys MySQL in the cluster, which is for trials only."
  type        = string
  default     = ""
}

variable "looker_db_ssl" {
  description = "Encrypt Looker's connection to its internal MySQL database with TLS."
  type        = bool
  default     = true
}

variable "looker_db_verify_ssl" {
  description = "Verify the MySQL server certificate (\"true\", \"false\", or \"\" to default to false for bundled MySQL and true for an external looker_db_host)."
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "true", "false"], var.looker_db_verify_ssl)
    error_message = "looker_db_verify_ssl must be empty, \"true\" or \"false\"."
  }
}

variable "looker_ingress_enabled" {
  description = "Create an Ingress for the Looker UI. Needs looker_tls_secret."
  type        = bool
  default     = false
}

variable "looker_tls_secret" {
  description = "Name of the kubernetes.io/tls Secret for the Looker Ingress."
  type        = string
  default     = ""
}

variable "looker_api_url" {
  description = "Base URL of the Looker API as the agent reaches it. Empty when deploy_looker is true."
  type        = string
  default     = ""
}

variable "looker_client_id" {
  description = "Client id of the agent's Looker API key. It cannot exist before Looker runs: leave it empty for the first apply, then set it (and export LOOKER_CLIENT_SECRET) and apply again."
  type        = string
  default     = ""
}

variable "looker_models" {
  description = "LookML models the agent may use."
  type        = list(string)
  default     = ["thelook"]
}

# --- Reasoning model -----------------------------------------------------------

variable "agent_base_image" {
  description = "Base image passed to agent/Dockerfile when building the agent. Pin by @sha256: digest for strict mode."
  type        = string
  default     = "python:3.12-slim"
}

variable "agent_model_provider" {
  description = "\"claude\" or \"claude_native\" (Claude on Vertex AI), \"gemini\" (Gemini on Vertex AI), or \"anthropic\" (the Anthropic API)."
  type        = string
  default     = "claude"

  validation {
    condition     = contains(["claude", "claude_native", "gemini", "anthropic"], var.agent_model_provider)
    error_message = "agent_model_provider must be claude, claude_native, gemini or anthropic."
  }
}

variable "claude_model" {
  description = "Claude model id when agent_model_provider is claude, claude_native, or anthropic."
  type        = string
  default     = "claude-sonnet-4-6"
}

variable "claude_location" {
  description = "Vertex AI region serving the Claude model (or \"global\")."
  type        = string
  default     = "us-east5"
}

variable "gemini_model" {
  description = "Gemini model id when agent_model_provider is gemini."
  type        = string
  default     = "gemini-2.5-flash"
}

variable "gemini_location" {
  description = "Vertex AI region serving the Gemini model (or \"global\")."
  type        = string
  default     = "us-central1"
}

variable "gcp_project_id" {
  description = "Google Cloud project billed for Vertex AI. Needed for every provider except \"anthropic\", and always on GKE."
  type        = string
  default     = ""
}

variable "gcp_sa_key_file" {
  description = "On-prem with Vertex AI only: path of the key file of a service account that may call the model. The path is not a secret; the file is read by deploy.sh, not by Terraform."
  type        = string
  default     = ""
}

variable "gcp_region" {
  description = "GKE only: Google Cloud region for regional resources."
  type        = string
  default     = "us-central1"
}

variable "gke_cluster_name" {
  description = "GKE only: name of the GKE cluster to create or reuse."
  type        = string
  default     = "looker-agent"
}

variable "gke_cluster_location" {
  description = "GKE only: zone or region of the GKE cluster."
  type        = string
  default     = "us-central1-a"
}

# --- Agent Substrate -----------------------------------------------------------

variable "onprem_dev_profile_accepted" {
  description = "On-prem only. Agent Substrate has no supported install outside GKE; the kit runs its installer's local-development profile. Set true once you have read what that installs (../README.md)."
  type        = bool
  default     = false
}

variable "snapshot_store" {
  description = "On-prem only: \"bundled\" (the installer's small in-cluster object store) or \"s3\" (an S3-compatible store you run)."
  type        = string
  default     = "bundled"

  validation {
    condition     = contains(["bundled", "s3"], var.snapshot_store)
    error_message = "snapshot_store must be \"bundled\" or \"s3\"."
  }
}

variable "s3_endpoint_url" {
  description = "Endpoint of your S3-compatible store, for snapshot_store = \"s3\"."
  type        = string
  default     = ""
}

variable "s3_bucket" {
  description = "Bucket for snapshots, for snapshot_store = \"s3\". It must exist."
  type        = string
  default     = ""
}

# --- Agent endpoint and the chat inside Looker ----------------------------------

variable "agent_ingress_enabled" {
  description = "Create an Ingress for the gateway. Needed for extension_transport = \"browser\". Needs agent_host and agent_tls_secret."
  type        = bool
  default     = false
}

variable "agent_host" {
  description = "Host name of the gateway's Ingress."
  type        = string
  default     = ""
}

variable "agent_tls_secret" {
  description = "Name of the kubernetes.io/tls Secret for the gateway's Ingress."
  type        = string
  default     = ""
}

variable "extension_transport" {
  description = "\"server\": Looker's server makes every call to the gateway. \"browser\": Looker's server only fetches a short-lived token and the calls go from the user's browser."
  type        = string
  default     = "server"

  validation {
    condition     = contains(["server", "browser"], var.extension_transport)
    error_message = "extension_transport must be \"server\" or \"browser\"."
  }
}

variable "extension_lookml_connection" {
  description = "Any existing Looker connection, for the model file that decides who sees the extension."
  type        = string
  default     = ""
}

# --- Everything else -----------------------------------------------------------

variable "extra_settings" {
  description = "Any other setting of config.env.example, by its name there, for example { LOOKER_MEMORY = \"16Gi\" }. Never put a secret here."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for name in keys(var.extra_settings) :
      can(regex("^[A-Z][A-Z0-9_]*$", name)) && !contains([
        "LOOKER_LICENSE_KEY", "LOOKER_CLIENT_SECRET", "ANTHROPIC_API_KEY",
        "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY", "LOOKER_DB_PASSWORD",
        "GATEWAY_BASIC_AUTH_PASSWORD", "GATEWAY_CHAT_AUTH_PASSWORD",
      ], name)
    ])
    error_message = "extra_settings takes setting names in upper case, and none of the secrets: export those in the shell instead."
  }
}

# --- How Terraform drives the script -------------------------------------------

variable "render_only" {
  description = "true: only write every manifest to the work directory and touch nothing, so the manifests can be reviewed first. Apply again with false to deploy."
  type        = bool
  default     = false
}

variable "build_extension" {
  description = "Build the chat extension's bundle with npm (needs Node.js 18 or newer). false only prepares the project to be built elsewhere."
  type        = bool
  default     = true
}

variable "secrets_revision" {
  description = "Terraform cannot see when a secret in the environment has changed. Change this value (any text) to make every stage run again after rotating one."
  type        = string
  default     = "1"
}

variable "work_dir" {
  description = "Where deploy.sh keeps rendered manifests, checkouts and build state. Empty: ../.work"
  type        = string
  default     = ""
}

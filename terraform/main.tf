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
#  A Terraform front end for ../deploy.sh.
#
#  What it is: typed, validated variables in place of config.env, and one
#  Terraform resource per step of the script, run in the script's own order.
#  "terraform plan" shows which steps would run; "terraform apply" runs them.
#
#  What it is not: the Kubernetes objects are not Terraform resources. Agent
#  Substrate is installed by its own installer and its actors are created with
#  its own command-line tool, neither of which Terraform can stand in for, so
#  the script stays the one place that knows how to deploy. Terraform therefore
#  does not detect drift in the cluster, and "terraform destroy" removes
#  nothing from it. README.md in this directory says more.
#
#  Secrets never pass through Terraform. The script reads them from the
#  environment Terraform runs in, so none can reach the state file.
# =============================================================================

locals {
  module_dir = abspath(path.module)
  kit_dir    = abspath("${path.module}/..")
  work_dir   = var.work_dir != "" ? abspath(var.work_dir) : "${local.kit_dir}/.work"

  # Each setting under the name deploy.sh knows it by.
  settings = merge({
    PLATFORM      = var.platform
    KUBE_CONTEXT  = var.kube_context
    REGISTRY      = var.registry
    SECURITY_MODE = var.security_mode

    NETWORK_POLICIES     = tostring(var.network_policies)
    KUBE_API_PORTS       = join(",", var.kube_api_ports)
    INTERNAL_TLS         = var.internal_tls
    GATEWAY_TLS_SECRET   = var.gateway_tls_secret
    LOOKER_EGRESS_CIDRS  = join(",", var.looker_egress_cidrs)
    WORKER_NODE_SELECTOR = var.worker_node_selector
    AGENT_DEV_UI         = tostring(var.agent_dev_ui)
    LOOKER_LINK_MODE     = var.looker_link_mode
    EXTRA_CA_FILE        = var.extra_ca_file

    DEPLOY_LOOKER                  = tostring(var.deploy_looker)
    LOOKER_HOST                    = var.looker_host
    LOOKER_VERSION                 = var.looker_version
    LOOKER_TECHNICAL_CONTACT_EMAIL = var.looker_technical_contact_email
    LOOKER_ADMIN_EMAIL             = var.looker_admin_email
    LOOKER_REGISTRY                = var.looker_registry
    LOOKER_IMAGE_PULL_SECRET       = var.looker_image_pull_secret
    LOOKER_IMAGE                   = var.looker_image
    LOOKER_BASE_IMAGE              = var.looker_base_image
    LOOKER_REPLICAS                = tostring(var.looker_replicas)
    LOOKER_MEMORY                  = var.looker_memory
    LOOKER_DB_HOST                 = var.looker_db_host
    LOOKER_DB_SSL                  = tostring(var.looker_db_ssl)
    LOOKER_DB_VERIFY_SSL           = var.looker_db_verify_ssl
    LOOKER_INGRESS_ENABLED         = tostring(var.looker_ingress_enabled)
    LOOKER_TLS_SECRET              = var.looker_tls_secret
    LOOKER_API_URL                 = var.looker_api_url
    LOOKER_CLIENT_ID               = var.looker_client_id
    LOOKER_MODELS                  = jsonencode(var.looker_models)

    AGENT_BASE_IMAGE     = var.agent_base_image
    AGENT_MODEL_PROVIDER = var.agent_model_provider
    CLAUDE_MODEL         = var.claude_model
    CLAUDE_LOCATION      = var.claude_location
    GEMINI_MODEL         = var.gemini_model
    GEMINI_LOCATION      = var.gemini_location
    GCP_PROJECT_ID       = var.gcp_project_id
    GCP_SA_KEY_FILE      = var.gcp_sa_key_file
    GCP_REGION           = var.gcp_region
    GKE_CLUSTER_NAME     = var.gke_cluster_name
    GKE_CLUSTER_LOCATION = var.gke_cluster_location

    ONPREM_DEV_PROFILE_ACCEPTED = tostring(var.onprem_dev_profile_accepted)
    SNAPSHOT_STORE              = var.snapshot_store
    S3_ENDPOINT_URL             = var.s3_endpoint_url
    S3_BUCKET                   = var.s3_bucket

    AGENT_INGRESS_ENABLED       = tostring(var.agent_ingress_enabled)
    AGENT_HOST                  = var.agent_host
    AGENT_TLS_SECRET            = var.agent_tls_secret
    EXTENSION_TRANSPORT         = var.extension_transport
    EXTENSION_LOOKML_CONNECTION = var.extension_lookml_connection
  }, var.extra_settings)

  # What every step is started with. CONFIG_FILE names a file that sets
  # nothing, so these values are the configuration.
  environment = merge(local.settings, {
    CONFIG_FILE = "${local.module_dir}/settings-from-terraform.env"
    WORK_DIR    = local.work_dir
  })

  # A step runs again when a setting, a file of the kit or secrets_revision
  # changes. Every step of the script is safe to run again: it reuses what
  # already exists.
  # Individual fileset calls joined with setunion: Terraform's fileset uses
  # doublestar v1, which splits on "/" before matching "{...}", so a single
  # brace pattern containing "/" fails at plan time.
  raw_kit_files = setunion(
    fileset(local.kit_dir, "deploy.sh"),
    fileset(local.kit_dir, "agent/Dockerfile"),
    fileset(local.kit_dir, "agent/.dockerignore"),
    fileset(local.kit_dir, "agent/server.py"),
    fileset(local.kit_dir, "agent/extra-ca.pem"),
    fileset(local.kit_dir, "agent/requirements.txt"),
    fileset(local.kit_dir, "agent/requirements.lock"),
    fileset(local.kit_dir, "agent/agents/**"),
    fileset(local.kit_dir, "gateway/gateway.py"),
    fileset(local.kit_dir, "looker/**"),
    fileset(local.kit_dir, "looker-extension/src/**"),
    fileset(local.kit_dir, "looker-extension/package.json"),
    fileset(local.kit_dir, "looker-extension/webpack.config.cjs"),
  )
  kit_files = sort([
    for file in local.raw_kit_files : file
    if !can(regex("(^|/)__pycache__/|\\.pyc$|\\.metadata\\.json$", file))
  ])
  revision = sha256(join("\n", concat(
    [jsonencode(local.settings), var.secrets_revision],
    [for file in local.kit_files : "${file} ${filesha256("${local.kit_dir}/${file}")}"],
  )))

  deploying = !var.render_only
  # The agent needs Looker API credentials, and those can only be created once
  # Looker is up. Until looker_client_id is set, the steps after Substrate wait.
  have_looker_credentials = var.looker_client_id != ""
  deploying_agent         = local.deploying && local.have_looker_credentials
}

# Writes every manifest to <work_dir>/rendered and touches nothing. Runs first,
# so a configuration mistake stops the apply before anything is changed.
resource "terraform_data" "render" {
  triggers_replace = [local.revision]

  provisioner "local-exec" {
    command     = "bash deploy.sh render"
    working_dir = local.kit_dir
    environment = local.environment
  }
}

# STEP 0: tools on this machine, and what the cluster must offer.
resource "terraform_data" "preflight" {
  count            = local.deploying ? 1 : 0
  triggers_replace = [local.revision]
  depends_on       = [terraform_data.render]

  provisioner "local-exec" {
    command     = "bash deploy.sh preflight"
    working_dir = local.kit_dir
    environment = local.environment
  }
}

# STEP 1 (GKE only): the cluster and Substrate's cloud resources.
resource "terraform_data" "gke" {
  count            = local.deploying && var.platform == "gke" ? 1 : 0
  triggers_replace = [local.revision]
  depends_on       = [terraform_data.preflight]

  provisioner "local-exec" {
    command     = "bash deploy.sh gke"
    working_dir = local.kit_dir
    environment = local.environment
  }
}

# STEP 2: customer-hosted Looker.
resource "terraform_data" "looker" {
  count            = local.deploying && var.deploy_looker ? 1 : 0
  triggers_replace = [local.revision]
  depends_on       = [terraform_data.gke]

  provisioner "local-exec" {
    command     = "bash deploy.sh looker"
    working_dir = local.kit_dir
    environment = local.environment
  }
}

# STEP 3: Agent Substrate.
resource "terraform_data" "substrate" {
  count            = local.deploying ? 1 : 0
  triggers_replace = [local.revision]
  depends_on       = [terraform_data.looker]

  provisioner "local-exec" {
    command     = "bash deploy.sh substrate"
    working_dir = local.kit_dir
    environment = local.environment
  }
}

# STEP 4: build and push the agent image.
resource "terraform_data" "image" {
  count            = local.deploying_agent ? 1 : 0
  triggers_replace = [local.revision]
  depends_on       = [terraform_data.substrate]

  provisioner "local-exec" {
    command     = "bash deploy.sh image"
    working_dir = local.kit_dir
    environment = local.environment
  }
}

# STEP 5: the agent as a Substrate actor, with its egress policy.
resource "terraform_data" "agent" {
  count            = local.deploying_agent ? 1 : 0
  triggers_replace = [local.revision]
  depends_on       = [terraform_data.image]

  provisioner "local-exec" {
    command     = "bash deploy.sh agent"
    working_dir = local.kit_dir
    environment = local.environment
  }
}

# STEP 6: the gateway in front of the agent.
resource "terraform_data" "gateway" {
  count            = local.deploying_agent ? 1 : 0
  triggers_replace = [local.revision]
  depends_on       = [terraform_data.agent]

  provisioner "local-exec" {
    command     = "bash deploy.sh gateway"
    working_dir = local.kit_dir
    environment = local.environment
  }
}

# STEP 7: check the path from the gateway to the agent.
resource "terraform_data" "verify" {
  count            = local.deploying_agent ? 1 : 0
  triggers_replace = [local.revision]
  depends_on       = [terraform_data.gateway]

  provisioner "local-exec" {
    command     = "bash deploy.sh verify"
    working_dir = local.kit_dir
    environment = local.environment
  }
}

# STEP 8: the chat inside Looker. Touches neither the cluster nor Looker.
resource "terraform_data" "extension" {
  count            = local.deploying_agent ? 1 : 0
  triggers_replace = [local.revision]
  depends_on       = [terraform_data.verify]

  provisioner "local-exec" {
    command     = var.build_extension ? "bash deploy.sh extension" : "bash deploy.sh extension-files"
    working_dir = local.kit_dir
    environment = local.environment
  }
}

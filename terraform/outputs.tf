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

output "phase" {
  description = "How far this configuration takes the deployment."
  value = (
    var.render_only ? "manifests rendered, nothing deployed" :
    !local.have_looker_credentials ? "waiting for Looker API credentials" :
    "deployed"
  )
}

output "next_steps" {
  description = "What to do after this apply."
  value = (
    var.render_only ?
    "Every manifest is in ${local.work_dir}/rendered, with secrets shown as REDACTED. Review them, then set render_only = false and apply again." :
    !local.have_looker_credentials ?
    "The agent needs a Looker API key, which can only be created once Looker is up. In Looker: connect a database and a LookML project, create a dedicated user for the agent with the narrowest role that works, and create an API key for it (Admin > Users > Edit > API keys). Then set looker_client_id, export LOOKER_CLIENT_SECRET in this shell, and apply again." :
    "The agent runs and the path from the gateway to it was checked. The chat extension's project is in ${local.work_dir}/looker-extension; ../looker-extension/README.md lists what a Looker admin does once to add it."
  )
}

output "work_dir" {
  description = "Where deploy.sh keeps rendered manifests, checkouts and build state. It can hold secrets: keep it private."
  value       = local.work_dir
}

output "rendered_manifests" {
  description = "Every manifest the last run wrote."
  value       = "${local.work_dir}/rendered"
}

output "extension_project" {
  description = "The Looker extension, prepared with this deployment's addresses."
  value       = "${local.work_dir}/looker-extension"
}

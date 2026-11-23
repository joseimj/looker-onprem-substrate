# Deploying with Terraform

This directory lets you run the deployment with `terraform apply` instead of `./deploy.sh`. It asks for the same settings as typed, validated variables, and runs the same steps in the same order.

> [!CAUTION]
> **Terraform has not been run on this configuration.** It was written on a machine without Terraform. The files were checked for syntax and format, and the settings they pass on were checked against `deploy.sh` (see [What was checked](#what-was-checked-and-what-was-not)). The first `terraform validate` will be yours.

## What it is and what it is not

Terraform is the front door here, not the engine. Each step of `deploy.sh` is one Terraform resource (`terraform_data` with a `local-exec` provisioner), so `terraform plan` shows which steps will run and `terraform apply` runs them. The script stays the one place that knows how to deploy, and its steps are the ones the kit's tests cover.

The Kubernetes objects are **not** individual Terraform resources. Two things in this architecture cannot be: Agent Substrate is installed by its own installer, and its actors, templates and egress policies are created with its own command-line tool, not as Kubernetes objects. Splitting the rest between Terraform and the script would leave two owners for one deployment.

What follows from that:

| | With this module |
| :--- | :--- |
| Typed, validated inputs | Yes |
| A plan before anything runs | Yes: which steps will run. For the manifests themselves, use `render_only`. |
| Secrets in the state file | None. Terraform is never given one. |
| Drift detection in the cluster | No. Terraform does not look at the cluster. |
| `terraform destroy` | Forgets the steps. It removes nothing from the cluster. |
| Providers to download | None |

## Before you start

The same tools as for `deploy.sh` (see the [main README](../README.md#before-you-start)), plus Terraform 1.5 or newer. The module uses no provider, so `terraform init` works without network access.

## Secrets

There is no variable for a secret, and `extra_settings` refuses the names of the secret settings. Export them in the shell that runs Terraform. The script reads them from there, and puts them into the cluster through files, never through a command line.

| Variable | When |
| :--- | :--- |
| `LOOKER_LICENSE_KEY` | First apply, to download Looker and license a new instance |
| `LOOKER_CLIENT_SECRET` | Second apply, once Looker has an API key for the agent |
| `ANTHROPIC_API_KEY` | `agent_model_provider = "anthropic"` |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | `snapshot_store = "s3"` |
| `LOOKER_DB_PASSWORD` | `looker_db_host` is set |
| `GATEWAY_BASIC_AUTH_PASSWORD`, `GATEWAY_CHAT_AUTH_PASSWORD` | Only to choose the gateway passwords yourself. Otherwise they are generated. |

Terraform cannot see when one of these changes. After rotating a secret, change `secrets_revision` to any other text so that the steps run again.

The state file holds the settings and a checksum per step, nothing secret. The work directory (`../.work` unless you set `work_dir`) is different: it can hold the Looker API key while a run is in progress. Keep it private and off shared disks.

## Use it

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars     # then edit it
terraform init
```

**Review first.** With `render_only = true`, an apply writes every manifest to `../.work/rendered` and touches nothing. Secrets appear as `REDACTED`.

```bash
terraform apply -var render_only=true
```

**First apply.** On a new Looker this installs Looker and Agent Substrate and then stops, because the agent needs a Looker API key and Looker has to be running before one can exist. `terraform output next_steps` says what to do.

```bash
export LOOKER_LICENSE_KEY=...
terraform apply
```

**Second apply.** Create the key in Looker, for a dedicated user with the narrowest role that works. Put its client id into `terraform.tfvars` as `looker_client_id`, and:

```bash
export LOOKER_CLIENT_SECRET=...
terraform apply
```

This builds the agent image, creates the agent and its egress policy, deploys the gateway, checks the path from the gateway to the agent, and prepares the chat extension. If Looker already exists (`deploy_looker = false`), one apply does everything.

## Settings

`variables.tf` declares 57 typed, validated variables covering the settings most deployments touch (platform, registry/pull secret, Looker sizing/DB TLS, base images, model/region selection, `kube_api_ports`, `extra_ca_file`, and GKE cluster settings). Any remaining setting of [`config.env.example`](../config.env.example) goes into `extra_settings` under its name there:

```hcl
extra_settings = {
  GATEWAY_MAX_RUNNING_JOBS = "64"
  GATEWAY_NAMESPACE        = "looker-agent-gateway"
}
```

`security_mode = "strict"` makes the script refuse to deploy while a known-weak choice is configured, and name each one. [docs/security.md](../docs/security.md) lists them.

## What runs again, and when

Every step runs again when a setting, a file of the kit, or `secrets_revision` changes. That is safe: each step of the script reuses what already exists, and the kit's tests check that a rerun with nothing changed recreates nothing. It does mean that a change to one setting starts all steps, not only the one it concerns.

If a step fails, Terraform marks it as tainted and the next apply starts again from that step.

## Removing the deployment

`terraform destroy` only empties the state. Removing the deployment is not scripted, deliberately: deleting the Looker manifests deletes Looker's file volume. The main README says what to remove by hand.

## What was checked and what was not

| What | How | Result |
| :--- | :--- | :--- |
| Syntax and format of the `.tf` files | An HCL formatter (`hclfmt -require-no-change`) | Pass |
| Every setting name passed to the script | `tests/terraform_check.py` (97 checks) compares them with the settings `deploy.sh` reads | Pass |
| Every variable is declared and used; no variable for a secret | The same test | Pass |
| `fileset()` patterns in `main.tf` avoid `/` inside `{...}` and match real kit files | The same test (`raw_kit_files` uses `setunion` of individual `fileset()` calls) | Pass |
| The step commands exist in the script | The same test | Pass |
| The settings of the example file make the script render its manifests | The same test builds the environment Terraform would pass and runs `deploy.sh render` | Pass |

**Not checked:** `terraform validate`, `plan` and `apply`. No Terraform binary was available where this was written. The GitHub workflow in this repository has a job that runs `terraform fmt -check` and `terraform validate`; it starts by hand and has not run yet.

# platform-infra

Terraform for the PayrollFuturistic platform on Azure Container Apps. One root
module, no click-ops.

> **Dev only, applied by the pipeline.** The dev environment lives in
> `rg-ftpay-dev` (uksouth), and every push to `dev` plans and applies it.
> Staging and production configs exist under `envs/` and are not wired into the
> pipeline.

## What it builds

| Resource | Purpose |
|---|---|
| Container Apps environment | VNet-integrated, one Consumption workload profile |
| `ca-…-payroll-api` | FastAPI, port 8000, **external** ingress |
| `ca-…-hmrc-rti` | .NET 10, port 8080 — the only service that talks to HMRC. Internal by default; **public in dev** (`expose_dotnet_services = true`) so its Swagger UI opens in a browser |
| `ca-…-integration-hub` | .NET 10, port 8080, `min_replicas = 1`. Internal by default; public in dev, as above |
| `ca-…-frontend` | nginx serving the Angular bundle, port 80, **external** ingress — a container app, not Static Web Apps (see `apps.tf`) |
| `caj-…-migrate` | Alembic, manually triggered |
| PostgreSQL Flexible Server 16 | VNet-integrated, no public endpoint, optional zone-redundant HA |
| Redis | Rate limiting and background jobs (PLAT-01) |
| Service Bus queue | Outbox delivery — duplicate detection, dead-lettering, 6 delivery attempts |
| Storage account | Evidence archive with a 7-year immutability policy |
| Key Vault | Every secret; apps read via managed identity |
| Container Registry | Images; pulled with the workload identity, admin user disabled |
| Log Analytics + App Insights | Metrics, traces and alerting (PLAT-02) |
| NAT Gateway + static IP | One stable egress address — the one HMRC would allowlist |

Ports, environment variable names and health paths come from
`docker-compose.platform.yml` and the services' own code, so the cloud contract
matches the one the team runs locally. Nothing is set that the applications do
not read.

## Working on it from your machine

Terraform runs for real in GitHub Actions. A laptop is for writing a change,
checking it and reading a plan — not for applying it (see
[How changes reach Azure](#how-changes-reach-azure)).

### Prerequisites

| Tool | Version | What it is for |
|---|---|---|
| Terraform | **1.15.8** — what both workflows install (`TF_VERSION` in `terraform.yml`, pinned in `terraform-apply.yml`). `versions.tf` only requires `>= 1.9.0`; there is no `.terraform-version` file | Everything below |
| azurerm provider | **4.81.0**, pinned by the committed `.terraform.lock.hcl` (`versions.tf` and the module only ask for `~> 4.0`) | Installed by `terraform init`, not by hand |
| random provider | **3.9.1**, pinned by the same lock file (`~> 3.6` in `versions.tf`) | Generated Postgres password and JWT key; installed by `terraform init` |
| Azure CLI (`az`) | Not pinned; any current 2.x | `az login` for local credentials, the bootstrap scripts, `az containerapp` commands (the extension installs itself on first use) |
| Git | Any | Clone and branch |
| Bash | Git Bash on Windows | Running `bootstrap/*.sh`. They set `MSYS_NO_PATHCONV` themselves, so Git Bash does not mangle `/subscriptions/...` arguments |
| GitHub CLI (`gh`) | Optional; any | The bootstrap scripts use it, when signed in, to read repository ids and register the id-form OIDC subjects — without it they register only the name form. Also `gh workflow run` |
| TFLint | Optional; CI installs the latest | Reproduces the pipeline's lint step |

`jq` appears only in the apply workflow's output step, on the runner — you do
not need it locally. On Windows, `winget install Hashicorp.Terraform`,
`winget install Microsoft.AzureCLI` and `winget install GitHub.cli` cover the
tools; check `terraform version` reports 1.15.8.

**Provider versions are locked.** `.terraform.lock.hcl` is committed, with
hashes for `linux_amd64` (the CI runners) and `windows_amd64`, so a plan on a
laptop and in CI use the same providers. Upgrading one is a reviewed change:
`terraform init -upgrade -backend=false`, then
`terraform providers lock -platform=linux_amd64 -platform=windows_amd64`, and
commit the lock file — the pull request's plan shows what the new version does.
On another platform, `init` adds its own hash to the lock file; commit that too.

**Access.** Tools are the easy half. To go further than `validate` you need:

| Access | Why |
|---|---|
| A role on the FT-DEV subscription, in its Entra tenant | `az login` and `az account set` |
| **Storage Blob Data Contributor** on `stftpaytfstate` (resource group `rg-ftpay-tfstate`) | `terraform init` and `plan` against the dev state. Shared-key access is disabled on the account, so a management role alone cannot read the blob, and a plan takes a lease on it (the state lock), which is a write. `bootstrap.sh` grants this only to whoever ran it and to the pipeline principal — everyone else is added by hand |
| **Contributor** on `rg-ftpay-dev` | A plan refreshes resources whose keys are read back — the Managed Redis access key behind `redis-url`, for one — and Reader cannot list keys |
| **Key Vault Secrets User** on the dev vault (`kv-ftpaydev<suffix>`) | The plan refreshes every `azurerm_key_vault_secret`. The vault uses RBAC authorisation, so no subscription or resource-group role reads secrets |
| **Owner** on the subscription, and rights to create Entra app registrations | Only for the bootstrap scripts |
| Write access to `FuturisticTechnologies/platform-infra` | Branches and pull requests. Environment secrets need repository admin |

### Get the code

```bash
git clone https://github.com/FuturisticTechnologies/platform-infra.git
cd platform-infra
git checkout dev
```

| Branch | What a push does |
|---|---|
| `dev` | Integration branch. Plans **and applies** the dev environment, with no approval gate |
| `main` | Plans against dev; applies nothing. `dev` is merged into it |
| `stage` | Nothing — no workflow triggers on it |

Branch from `dev` (`infra/<topic>` is the convention), open a pull request into
`dev` and read the plan the pipeline comments on it. Merging is the deployment.
Once dev is healthy, `dev` is merged into `main`.

### Authenticate

```bash
az login
az account set --subscription <subscription-id>
az account show --query "{name:name, id:id, tenant:tenantId}" -o table

export TF_VAR_subscription_id=$(az account show --query id -o tsv)
```

In PowerShell the last line is
`$env:TF_VAR_subscription_id = az account show --query id -o tsv`.

Locally the provider and the backend both use that Azure CLI sign-in:
`use_oidc` defaults to `false`, and `envs/backend-dev.hcl` sets
`use_azuread_auth = true`, so the state blob is read with your Entra identity
rather than an account key. CI signs in differently — `ARM_USE_OIDC`,
`ARM_USE_AZUREAD`, `ARM_CLIENT_ID`, `ARM_TENANT_ID` and `ARM_SUBSCRIPTION_ID`
from the `dev` environment secrets, plus `TF_VAR_use_oidc=true`. Leave all of
those unset on a laptop: there is no GitHub token for OIDC to exchange.

`subscription_id` has no default and is in no tfvars file; CI passes it as
`TF_VAR_subscription_id`, and so should you (or `-var subscription_id=<id>`).
It also seeds the six-character suffix in the registry, Key Vault and evidence
storage account names (`locals.tf`), so it has to be the dev subscription's id.

### Init, validate and plan

Without Azure access — this is what the pipeline's `validate` job runs:

```bash
terraform fmt -check -recursive      # `terraform fmt -recursive` fixes what it reports
terraform init -backend=false
terraform validate
tflint --init && tflint --recursive --minimum-failure-severity=error   # optional
```

Against the dev state:

```bash
terraform init -backend-config=envs/backend-dev.hcl
terraform plan -var-file=envs/dev.tfvars
```

The state is `platform-dev.tfstate` in the `tfstate` container of
`stftpaytfstate`. `envs/backend-staging.hcl` and `envs/backend-prod.hcl` point
at the same account under their own keys; add `-reconfigure` to `init` when
switching between them. Nothing plans staging or prod today.

A plan takes the state lock — the same one the pipeline uses — and a plan from
a laptop is never quite clean:

- `azurerm_role_assignment.kv_deployer` and
  `azurerm_role_assignment.evidence_deployer` are granted to whoever runs
  Terraform (`data.azurerm_client_config.current`), so from your machine they
  show as replacements pointing at your object id.
- After 17:00 on a weekday the integration hub's `min_replicas` shows 0 → 1.
  That is the nightly stop, not drift anyone introduced.

Anything else in the plan is a real difference between the branch and dev.

### How changes reach Azure

| Event | What `terraform.yml` runs |
|---|---|
| Pull request into `dev` or `main` | validate → plan against dev, posted as a comment and uploaded as `tfplan-dev` |
| Push to `dev` | validate → plan → **apply-dev** |
| Push to `main` | validate → plan; nothing applies |
| **Run workflow** | validate → plan → **apply-manual** for the chosen environment, from the branch picked in *Use workflow from* |

The apply lives in `terraform-apply.yml`: it re-initialises, re-plans, runs
`terraform apply -auto-approve -var-file=envs/<env>.tfvars` and writes the
non-sensitive outputs to the run summary. Runs queue one at a time per
environment (`concurrency: terraform-<env>`) and are never cancelled mid-apply.
From a terminal: `gh workflow run terraform.yml --ref dev -f environment=dev`.
Staging and prod fail the identity check, by design.

`use_placeholder_images` defaults to `true` and `dev.tfvars` leaves it alone.
It only decides the image a container app is *created* with — the image is in
the module's `ignore_changes` — so it does nothing to apps that already exist.

> **Do not run `terraform apply` from a laptop.** `bootstrap.sh` is the last
> thing a human runs: "everything after this is done by the pipeline". A local
> apply sits outside the pipeline's queue, applies a plan nobody saw on a pull
> request, and re-grants the two deployer role assignments above to you —
> taking Key Vault Secrets Officer away from the pipeline principal, which its
> next run needs to refresh the vault's secrets. If the pipeline is broken,
> fix the pipeline.

### Day-to-day operations

**Stopping and starting dev.** `start-or-stop.yml` (the *start or stop*
workflow) stops dev at 17:00 London, Monday to Friday: Postgres is stopped and
every container app is set to `min_replicas = 0`. To bring it back, Actions ▸
**start or stop** ▸ Run workflow ▸ environment `dev`, action `start`, or:

```bash
gh workflow run start-or-stop.yml -f environment=dev -f action=start
```

`start` starts Postgres and puts the integration hub back to one replica. A
`terraform apply` restores the replica counts too, but whether the Postgres
server is running is not something this configuration sets, so only `start`
brings the database back. More in [Nightly stop and start](#nightly-stop-and-start).

**Reading outputs.** After `init` against the backend, `terraform output`
lists the URLs, registry, Key Vault, egress IP and migration job. It only reads
state.

**Running the migration by hand.** The `national-insurance` deploy normally
does it; outside a release:
`az containerapp job start -n caj-ftpay-dev-migrate -g rg-ftpay-dev`.

**A new subscription or environment.** From Git Bash, as subscription Owner:

1. `./bootstrap/bootstrap.sh <subscription-id> FuturisticTechnologies/platform-infra`
   registers the resource providers; creates `rg-ftpay-tfstate`,
   `stftpaytfstate` and its `tfstate` container (versioning on, 30-day delete
   retention, shared keys off); grants you Storage Blob Data Contributor on it;
   creates the `ftpay-platform-infra` app registration with Owner on the
   subscription and its federated credentials; and prints `AZURE_CLIENT_ID`,
   `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`. It reuses what already
   exists. Set `STATE_SA` if the storage account name is taken, and change
   `envs/backend-*.hcl` to match.
2. Add those three as secrets on the GitHub environment of the same name
   (Settings ▸ Environments ▸ `<env>` ▸ Environment secrets).
3. `./bootstrap/app-deploy-identity.sh <subscription-id> <org/repo>...` for the
   application repositories — see [Deploying the applications](#deploying-the-applications)
   — and put the `deploy_principal_object_id` it prints into `envs/<env>.tfvars`.

Both scripts register federated credentials for `environment:dev` only
(`bootstrap.sh` adds the `main`, `dev` and `pull_request` subjects), so
a staging or prod environment needs `environment:<env>` added to their
`SUBJECT_SUFFIXES` first. Run `gh auth login` beforehand so the id-form
subjects are registered as well.

### Troubleshooting

- **`Error acquiring the state lock` / "state blob is already locked".** A
  pipeline run or somebody's plan holds the lease; the Lock Info says which
  operation and who. Wait for the run in Actions. Only when nothing is running
  — a cancelled run can orphan a lease — use `terraform force-unlock <lock-id>`.
- **403 / `AuthorizationPermissionMismatch` on `terraform init`.** No
  data-plane role on `stftpaytfstate`. Shared keys are off, so Owner or
  Contributor on the account is not enough; it takes Storage Blob Data
  Contributor, and a new assignment can take a minute or two to apply.
- **403 during the plan, on Key Vault secrets or listing keys.** Missing Key
  Vault Secrets User on the vault, or Contributor on `rg-ftpay-dev` — see
  **Access** above.
- **The plan wants to create or replace the registry, Key Vault and storage
  account.** Either `subscription_id` is not the dev subscription (it feeds the
  name suffix), or `init` pointed at the wrong state key — re-run
  `terraform init -reconfigure -backend-config=envs/backend-dev.hcl`.
- **`MissingSubscription`, or `C:/Program Files/Git/subscriptions/...` in an
  error.** Git Bash rewrote a `/subscriptions/...` argument. The bootstrap
  scripts guard against it; for `az` commands typed by hand,
  `export MSYS_NO_PATHCONV=1` first.
- **`prefix must be 3-5 lowercase alphanumerics`.** Names are
  `ca-<prefix>-<env>-<service>`, and Azure caps a container app name at 32
  characters. Changing `prefix` at all also breaks `start-or-stop.yml` and the
  application deploys, which hard-code `PREFIX: ftpay`.

## Decisions worth knowing

**Terraform owns the shape, pipelines own the contents.** The container app
module ignores changes to `image` and `traffic_weight`. Without that, every
infra apply would roll every service back to whatever tag was last committed
here, and cancel an in-flight blue/green shift.

**Revision mode is Multiple.** A new revision takes 0% of traffic until it is
shifted deliberately — the release procedure in the M5-18 runbook, rather than
a different one bolted on.

**Migrations are a job, not a start-up command.** `docker-compose` runs
`alembic upgrade head && uvicorn`; in Azure that would race across every
replica that starts. The deployment policy already says schema changes are
gated and run once, so they get their own manually triggered job with
`replica_retry_limit = 0` — a half-applied migration should not be retried
blindly.

**The hub cannot scale to zero.** It runs its own interval dispatcher. A
scaled-to-zero replica delivers nothing and nothing wakes it up.

**Live HMRC filing is refused outside production** by a precondition, not by a
convention — as is production without database HA. Both fail at plan time.

**Secrets are Key Vault references, versionless.** Rotating a secret does not
need a deployment. HMRC's client id and secret are created as placeholder
slots (`set-out-of-band`) with `ignore_changes` on the value, so an operator
setting the real credential is not reverted by the next apply.

**Immutability is left Unlocked.** Locking the 7-year policy is irreversible —
not undoable by Terraform, a support ticket, or Microsoft. It should be a
deliberate manual step once the retention period is signed off, and the
`allow_protected_append_writes` flag is what lets an append-only ledger keep
appending under it.

## Environments

| | dev | staging | prod |
|---|---|---|---|
| Postgres | B1ms, no HA | D2ds_v5, no HA | D4ds_v5, **zone-redundant HA** |
| Backups | 7 days | 7 days | 35 days, geo-redundant |
| Container Apps | scale to zero | scale to zero | min 2, zone-redundant |
| HMRC | sandbox | sandbox | **live filing enabled** |
| Storage | LRS | LRS | GZRS |

Staging deliberately matches production's server family so query plans are
comparable — it does not need HA, it needs to behave like production.

## Pipeline

`terraform.yml` runs fmt, validate and tflint, then plans and comments the plan
on the pull request. Applying is either a push to `dev`, or the manual
**Run workflow** button. Apply re-plans rather than replaying the artifact,
because a run may have been sitting for hours.

**The environment is a dropdown**, not a hardcoded value. One choice drives the
Azure identity, the state file, the tfvars and the sizing:

```
Run workflow ▸ Environment: [ dev ▾ ]   → envs/backend-dev.hcl
                             staging       envs/dev.tfvars
                             prod          dev environment secrets
```

`pull_request` and `push` have no dropdown to read, so they default to `dev`.
Only dev is configured today: choosing staging or prod fails the identity
check, which reports the missing environment secrets by name rather than
failing somewhere less obvious.

There is no approval gate, and that is not an oversight: required reviewers on
an environment need Pro/Team/Enterprise on a private repository, and this one
is on Free — the API refuses to create the protection rule, so a GitHub
environment here is only a label. The gate is the manual dispatch itself. It is
an acceptable answer for dev and would not be for production, which is one
reason staging and prod are not wired in.

Authentication is a federated credential — OIDC, no client secret exists to
rotate or leak. `bootstrap.sh` creates it and prints three values, held as
**environment** secrets on `dev`:

| Secret | Scope |
|---|---|
| `AZURE_CLIENT_ID` | environment `dev` |
| `AZURE_TENANT_ID` | environment `dev` |
| `AZURE_SUBSCRIPTION_ID` | environment `dev` |

Environment-scoped rather than repository-scoped so staging and production can
carry their own subscription and app registration without any workflow change —
add the environment, add its three secrets, point a job at it.

Two consequences of that choice. A job only sees an environment's secrets if it
declares `environment:`, which is why the `plan` job names `dev` despite having
no other reason to. And an approval rule on an environment would gate its plans
as well as its applies, so a higher environment that needs both wants a separate
plan-only environment.

The values are identifiers rather than credentials, but as secrets they are
masked in logs — which makes an OIDC subject mismatch harder to read when one
happens. `az ad app federated-credential list --id <app>` shows the other side
of that comparison.

## Deploying the applications

Terraform builds the environment; the application repositories put code into
it. Each has a `deploy.yml` that runs on a push to `main` and can be dispatched
by hand.

| Repository | Deploys | Into |
|---|---|---|
| `national-insurance` | API image, Alembic migration, front end image | `ca-…-payroll-api`, `caj-…-migrate`, `ca-…-frontend` |
| `hmrc-rti-service` | .NET image | `ca-…-hmrc-rti` |
| `integration-hub` | .NET image | `ca-…-integration-hub` |

The four snapshot repositories — `foundation-core`, `core-data-model`,
`payroll-engine`, `paye-tax-engine` — deploy nowhere. They are cumulative
milestone snapshots of the same codebase, and only the newest is live.

Each deploy builds the image on the runner and pushes it to ACR — ACR Tasks
(`az acr build`) is not permitted on this subscription — then creates a
revision, waits for it to report Running and Healthy, and only then shifts
traffic to it. Because the apps run in Multiple revision mode, a revision that
never becomes healthy never receives traffic: the failure mode is "nothing
changed", not "the service is down". A manual run with `cutover=false` leaves
the new revision at 0% to shift by hand.

For the payroll API the migration runs **before** the revision takes traffic,
because the code being deployed expects the schema it produces. The job has
`replica_retry_limit = 0`, so a half-applied migration stops the deployment
rather than being retried into a worse state.

Nothing that Terraform owns is hardcoded in a deploy pipeline. The registry
name carries a hash suffix only Terraform knows, so the pipelines read the
registry, app and job names out of the resource group at deploy time — a
rename in Terraform cannot turn a deployment into a no-op that reports success.

**Identity.** The application repositories authenticate as `ftpay-app-deploy`,
which holds AcrPush on the registry and Contributor on the environment's
resource group — not the subscription Owner the Terraform principal needs.
Its object id goes in `deploy_principal_object_id`; leave it null and both role
assignments are simply omitted.

Create or repair it with:

```bash
./bootstrap/app-deploy-identity.sh <subscription-id> \
  FuturisticTechnologies/national-insurance \
  FuturisticTechnologies/hmrc-rti-service \
  FuturisticTechnologies/integration-hub
```

Re-running is safe — existing credentials are reported and skipped.

If a deploy fails at sign-in with **AADSTS700213**, this is the fix. The error
names the subject GitHub presented, and it will carry numeric ids:

```
repo:Org@316165782/national-insurance@1334283527:environment:dev
```

That is the immutable subject form, which this organisation issues. A
credential registered only as `repo:Org/repo:environment:dev` does not match
it. The script registers both forms for every repository, so whichever the
organisation is set to emit will match.

## Nightly stop and start

`start-or-stop.yml` stops what can be stopped at **17:00 London**, Monday to
Friday, and `Run workflow ▸ start` puts it back. Nothing it does touches data
or Terraform state.

It is named for the choice rather than for one direction of it. It was called
`shutdown`, which meant a run that started the environment finished as a green
tick labelled "shutdown". The run title now says which way it went — `start -
dev` or `stop - dev`.

| Resource | Overnight |
|---|---|
| PostgreSQL Flexible Server | **stopped** — compute charge ends, storage still billed |
| Integration hub replica | **scaled to 0** |
| Payroll API, RTI service | already scale to zero when idle |
| Redis, NAT Gateway, public IP, ACR, Log Analytics | **still billing** |

That last row is the honest part: those bill by the hour whether or not
anything uses them, and Azure has no way to stop them — only to delete them.
If the idle cost still looks wrong after this, deleting them nightly is the
next step, and it is a bigger decision than a scheduled job should take on its
own: the NAT Gateway's public IP is the address HMRC would allowlist, and it
changes when it is recreated.

GitHub cron is UTC and does not observe daylight saving, so the workflow
carries two entries — 16:00 and 17:00 UTC — and a guard step drops whichever
one is not 17:00 in London today. One fires, one exits immediately.

Two things to know. Scheduled workflows only run from the **default branch**,
so a change to the schedule does nothing until it is merged there. And
Terraform still owns the replica
counts: the next `terraform apply` after a shutdown will set the hub back to
one replica, which is drift by design rather than a bug.

## Known gaps

- **No private endpoints yet.** The subnet is reserved. Key Vault, Redis and
  Storage are still on public endpoints with Entra auth. Putting Key Vault
  behind a private endpoint breaks CI's ability to write secrets from a
  GitHub-hosted runner, so it needs a self-hosted runner or a deployment
  script that runs inside the VNet — a decision, not an oversight.
- **Service Bus is provisioned but not wired in.** The hub currently runs its
  own interval dispatcher (INT-03). The queue is there for when that moves to
  a real broker; no application config points at it, because the application
  does not read any yet.
- **No WAF.** Application Gateway or Front Door in front of the payroll API is
  the next step before anything faces the public internet for real.
- **No alert rules.** App Insights collects; nothing pages anyone yet. That is
  PLAT-02, and it needs the team to agree what is worth waking up for.
- **No CDN in front of the Angular app.** It is served by nginx from
  `ca-…-frontend` because Static Web Apps is not offered in a UK region, which
  also costs the free certificates and per-pull-request previews — see
  `apps.tf`.

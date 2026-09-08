# platform-infra

Terraform for the PayrollFuturistic platform on Azure Container Apps. One root
module, no click-ops.

> **Dev only, and not applied yet.** `terraform validate` passes against
> azurerm 4.81, and `terraform plan` against the FT-DEV subscription reports
> **50 to add, 0 to change, 0 to destroy** — so the graph is real, but nothing
> has been created. Staging and production configs exist under `envs/` and are
> not wired into the pipeline.

## What it builds

| Resource | Purpose |
|---|---|
| Container Apps environment | VNet-integrated, one Consumption workload profile |
| `ca-…-payroll-api` | FastAPI, port 8000, **external** ingress |
| `ca-…-hmrc-rti` | .NET 10, port 8080, internal only — the only service that talks to HMRC |
| `ca-…-integration-hub` | .NET 10, port 8080, internal only, `min_replicas = 1` |
| `caj-…-migrate` | Alembic, manually triggered |
| PostgreSQL Flexible Server 16 | VNet-integrated, no public endpoint, optional zone-redundant HA |
| Redis | Rate limiting and background jobs (PLAT-01) |
| Service Bus queue | Outbox delivery — duplicate detection, dead-lettering, 6 delivery attempts |
| Storage account | Evidence archive with a 7-year immutability policy |
| Key Vault | Every secret; apps read via managed identity |
| Container Registry | Images; pulled with the workload identity, admin user disabled |
| Log Analytics + App Insights | Metrics, traces and alerting (PLAT-02) |
| NAT Gateway + static IP | One stable egress address — the one HMRC would allowlist |
| Static Web App | Angular frontend |

Ports, environment variable names and health paths come from
`docker-compose.platform.yml` and the services' own code, so the cloud contract
matches the one the team runs locally. Nothing is set that the applications do
not read.

## First run

```bash
# Once per subscription, by a human with Owner rights.
./bootstrap/bootstrap.sh <subscription-id> FuturisticTechnologies/platform-infra

terraform init -backend-config=envs/backend-dev.hcl
terraform plan  -var-file=envs/dev.tfvars -var subscription_id=<id>
terraform apply -var-file=envs/dev.tfvars -var subscription_id=<id>
```

The first apply deploys a placeholder image to every app
(`use_placeholder_images = true`), so it succeeds against an empty registry.
Once the application pipelines have pushed real images, flip it to `false`.

Then, per release:

```bash
az containerapp job start -n caj-ftpay-dev-migrate -g rg-ftpay-dev   # migrate
az containerapp update -n ca-ftpay-dev-payroll-api -g rg-ftpay-dev \
  --image acrftpaydev…/payroll-backend:<sha>                        # deploy
```

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
need a deployment. HMRC's client id and secret are created as empty slots with
`ignore_changes` on the value, so an operator setting the real credential is
not reverted by the next apply.

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
on the pull request. Applying is either a push to `development`, or the manual
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
| `national-insurance` | API image, Alembic migration, Angular bundle | `ca-…-payroll-api`, `caj-…-migrate`, the Static Web App |
| `hmrc-rti-service` | .NET image | `ca-…-hmrc-rti` |
| `integration-hub` | .NET image | `ca-…-integration-hub` |

The four snapshot repositories — `foundation-core`, `core-data-model`,
`payroll-engine`, `paye-tax-engine` — deploy nowhere. They are cumulative
milestone snapshots of the same codebase, and only the newest is live.

Each deploy builds the image **in ACR** rather than on the runner, creates a
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
so this does nothing until it is merged. And Terraform still owns the replica
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
- **Front-end deployment is not wired.** The Static Web App exists; its
  deployment token and build pipeline live with the Angular repo.

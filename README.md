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

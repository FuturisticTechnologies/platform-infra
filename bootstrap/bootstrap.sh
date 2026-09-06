#!/usr/bin/env bash
# Creates the Terraform state backend and the identity the pipeline uses.
#
# Run once per subscription, by a human with Owner rights. Everything after
# this is done by the pipeline.
#
#   ./bootstrap/bootstrap.sh <subscription-id> <github-org/repo>
#
# Deliberately not Terraform: the state backend cannot be stored in the state
# it is holding, and the federated credential is what lets CI authenticate at
# all. Chicken and egg, solved with twenty lines of shell.

set -euo pipefail

# Git Bash / MSYS rewrites any argument that looks like a Unix path, so
# `--scope /subscriptions/...` reaches Azure as `C:/Program Files/Git/subscriptions/...`
# and comes back as MissingSubscription - an error that says nothing about the
# cause. Harmless no-ops on Linux, so the CI runner is unaffected.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SUBSCRIPTION_ID="${1:?usage: bootstrap.sh <subscription-id> <github-org/repo>}"
GITHUB_REPO="${2:?usage: bootstrap.sh <subscription-id> <github-org/repo>}"

LOCATION="uksouth"
STATE_RG="rg-ftpay-tfstate"
# Storage account names are globally unique. Override if this one is taken -
# and change envs/backend-*.hcl to match.
STATE_SA="${STATE_SA:-stftpaytfstate}"
STATE_CONTAINER="tfstate"
APP_NAME="ftpay-platform-infra"

az account set --subscription "$SUBSCRIPTION_ID"

# Every subscription-scoped call carries --subscription explicitly. Relying on
# the CLI's default context failed here with MissingSubscription even though
# `az account show` reported the right subscription, and an explicit flag costs
# nothing.
SUB=(--subscription "$SUBSCRIPTION_ID")

# Subscriptions do not have every resource provider registered by default, and
# an unregistered provider fails at apply time rather than at plan time - an
# hour into the work rather than at the start.
echo "==> Resource providers"
for NS in Microsoft.App Microsoft.ContainerRegistry Microsoft.DBforPostgreSQL \
          Microsoft.Cache Microsoft.ServiceBus Microsoft.KeyVault \
          Microsoft.Storage Microsoft.Network Microsoft.OperationalInsights \
          Microsoft.Insights Microsoft.ManagedIdentity Microsoft.Web
do
  STATE=$(az provider show --namespace "$NS" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
  if [ "$STATE" != "Registered" ]; then
    echo "    registering $NS"
    az provider register --namespace "$NS" --output none
  fi
done

echo "==> State storage"
az group create "${SUB[@]}" --name "$STATE_RG" --location "$LOCATION" --output none

# Only create if it is absent. Re-running `storage account create` against an
# existing account puts the CLI into an update path that fails here with
# MissingSubscription, which says nothing useful about the cause.
if az storage account show "${SUB[@]}" -n "$STATE_SA" -g "$STATE_RG" --output none 2>/dev/null; then
  echo "    storage account $STATE_SA already exists"
else
  az storage account create "${SUB[@]}" \
    --name "$STATE_SA" --resource-group "$STATE_RG" --location "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    --min-tls-version TLS1_2 \
    --output none
  echo "    created storage account $STATE_SA"
fi

# Versioning turns "somebody applied over the state" into a recoverable event.
az storage account blob-service-properties update "${SUB[@]}" \
  --account-name "$STATE_SA" --resource-group "$STATE_RG" \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30 \
  --output none

CALLER_OID=$(az ad signed-in-user show --query id -o tsv)
SA_ID=$(az storage account show "${SUB[@]}" -n "$STATE_SA" -g "$STATE_RG" --query id -o tsv)

az role assignment create "${SUB[@]}" \
  --assignee-object-id "$CALLER_OID" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" --scope "$SA_ID" --output none

# Role assignments take up to a minute to propagate, and the container create
# fails with AuthorizationPermissionMismatch until it has. Retry rather than
# leaving the operator to guess whether it is broken or just slow.
echo "==> State container (waiting for the role assignment to propagate)"
for ATTEMPT in $(seq 1 12); do
  if az storage container create "${SUB[@]}" \
      --name "$STATE_CONTAINER" --account-name "$STATE_SA" \
      --auth-mode login --output none 2>/dev/null; then
    echo "    created on attempt $ATTEMPT"
    break
  fi
  if [ "$ATTEMPT" = "12" ]; then
    echo "    still failing after 12 attempts - check the role assignment on $STATE_SA" >&2
    exit 1
  fi
  sleep 10
done

echo "==> Pipeline identity"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
  echo "    created app registration $APP_ID"
else
  echo "    reusing existing app registration $APP_ID"
fi
az ad sp create --id "$APP_ID" --output none 2>/dev/null || true
SP_OID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

# Owner rather than Contributor: the deployment creates role assignments
# (AcrPull, Key Vault Secrets User, Storage Blob Data Contributor), and
# Contributor cannot grant roles.
az role assignment create "${SUB[@]}" \
  --assignee-object-id "$SP_OID" --assignee-principal-type ServicePrincipal \
  --role Owner --scope "/subscriptions/$SUBSCRIPTION_ID" --output none

az role assignment create "${SUB[@]}" \
  --assignee-object-id "$SP_OID" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "$SA_ID" --output none

# Federated credentials - no client secret is ever created, so there is no
# secret to rotate, leak or expire.
for SUBJECT in \
  "repo:${GITHUB_REPO}:ref:refs/heads/main" \
  "repo:${GITHUB_REPO}:pull_request" \
  "repo:${GITHUB_REPO}:environment:dev" \
  "repo:${GITHUB_REPO}:environment:staging" \
  "repo:${GITHUB_REPO}:environment:prod"
do
  NAME=$(echo "$SUBJECT" | tr ':/' '--')
  NAME="${NAME:0:120}"
  EXISTING=$(az ad app federated-credential list --id "$APP_ID" --query "[?subject=='${SUBJECT}'] | [0].id" -o tsv)
  if [ -n "$EXISTING" ]; then
    echo "    exists: $SUBJECT"
    continue
  fi
  # One line on purpose - a multi-line JSON argument is fragile across shells.
  az ad app federated-credential create --id "$APP_ID" --parameters "{\"name\":\"${NAME}\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"${SUBJECT}\",\"audiences\":[\"api://AzureADTokenExchange\"]}" --output none
  echo "    added: $SUBJECT"
done

TENANT_ID=$(az account show --query tenantId -o tsv)

cat <<EOF

Done. Add these as GitHub repository variables (not secrets - none of them
are sensitive, and there is no client secret to store):

  AZURE_CLIENT_ID        ${APP_ID}
  AZURE_TENANT_ID        ${TENANT_ID}
  AZURE_SUBSCRIPTION_ID  ${SUBSCRIPTION_ID}

Then create the dev, staging and prod GitHub environments, with required
reviewers on staging and prod.
EOF

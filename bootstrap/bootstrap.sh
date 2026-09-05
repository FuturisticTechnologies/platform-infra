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

SUBSCRIPTION_ID="${1:?usage: bootstrap.sh <subscription-id> <github-org/repo>}"
GITHUB_REPO="${2:?usage: bootstrap.sh <subscription-id> <github-org/repo>}"

LOCATION="uksouth"
STATE_RG="rg-ftpay-tfstate"
STATE_SA="stftpaytfstate"        # must match envs/backend-*.hcl
STATE_CONTAINER="tfstate"
APP_NAME="ftpay-platform-infra"

az account set --subscription "$SUBSCRIPTION_ID"

echo "==> State storage"
az group create --name "$STATE_RG" --location "$LOCATION" --output none

az storage account create \
  --name "$STATE_SA" --resource-group "$STATE_RG" --location "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --min-tls-version TLS1_2 \
  --output none

# Versioning turns "somebody applied over the state" into a recoverable event.
az storage account blob-service-properties update \
  --account-name "$STATE_SA" --resource-group "$STATE_RG" \
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30 \
  --output none

CALLER_OID=$(az ad signed-in-user show --query id -o tsv)
SA_ID=$(az storage account show -n "$STATE_SA" -g "$STATE_RG" --query id -o tsv)

az role assignment create \
  --assignee-object-id "$CALLER_OID" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" --scope "$SA_ID" --output none

az storage container create \
  --name "$STATE_CONTAINER" --account-name "$STATE_SA" --auth-mode login --output none

echo "==> Pipeline identity"
APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
az ad sp create --id "$APP_ID" --output none 2>/dev/null || true
SP_OID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

# Owner rather than Contributor: the deployment creates role assignments
# (AcrPull, Key Vault Secrets User, Storage Blob Data Contributor), and
# Contributor cannot grant roles.
az role assignment create \
  --assignee-object-id "$SP_OID" --assignee-principal-type ServicePrincipal \
  --role Owner --scope "/subscriptions/$SUBSCRIPTION_ID" --output none

az role assignment create \
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
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"${NAME:0:120}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${SUBJECT}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none
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

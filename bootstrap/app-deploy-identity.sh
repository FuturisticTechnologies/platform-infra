#!/usr/bin/env bash
# Creates, or repairs, the identity the application repositories deploy with.
#
#   ./bootstrap/app-deploy-identity.sh <subscription-id> <github-org/repo>...
#
# Separate from bootstrap.sh on purpose. That one creates the Terraform
# principal, which is subscription Owner because it writes role assignments. A
# pipeline that pushes an image and moves a revision has no business holding
# that, so the application repositories authenticate as this one instead:
# AcrPush on the registry and Contributor on the environment's resource group,
# both granted by Terraform from `deploy_principal_object_id`.
#
# This script only manages the app registration and its federated credentials.
# The role assignments stay in Terraform where they can be reviewed.
#
# Written after the first deploy of all three services failed at sign-in with
# AADSTS700213. The identity had been created by hand and carried only
# name-form subjects; this organisation issues immutable ones. Doing it by hand
# is what made that possible, so it is a script now.

set -euo pipefail

# Git Bash / MSYS rewrites any argument that looks like a Unix path, so
# `--scope /subscriptions/...` reaches Azure as `C:/Program Files/Git/...`.
# Harmless no-ops on Linux, so the CI runner is unaffected.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SUBSCRIPTION_ID="${1:?usage: app-deploy-identity.sh <subscription-id> <org/repo>...}"
shift
if [ "$#" -eq 0 ]; then
  echo "usage: app-deploy-identity.sh <subscription-id> <org/repo>..." >&2
  exit 1
fi

APP_NAME="${APP_NAME:-ftpay-app-deploy}"

# The environments a deploy can target. dev only today: staging and prod have
# no Azure identity yet, and adding a credential for an environment that does
# not exist would be the kind of thing nobody notices until it matters.
SUBJECT_SUFFIXES=(
  "environment:dev"
  "ref:refs/heads/main"
)

az account set --subscription "$SUBSCRIPTION_ID"

echo "==> Application registration"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
  echo "    created $APP_NAME ($APP_ID)"
else
  echo "    exists  $APP_NAME ($APP_ID)"
fi
APP_OBJECT_ID=$(az ad app list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)

SP_OID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)
if [ -z "$SP_OID" ]; then
  SP_OID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
  echo "    created service principal ($SP_OID)"
else
  echo "    exists  service principal ($SP_OID)"
fi

# Federated credentials - no client secret is ever created, so there is no
# secret to rotate, leak or expire.
#
# Two forms of every subject, exactly as bootstrap.sh does. GitHub can be
# configured to put immutable numeric ids in the OIDC subject claim, so the
# token presents
#   repo:Org@123/repo@456:environment:dev
# rather than
#   repo:Org/repo:environment:dev
# and a credential matching only the second is refused with AADSTS700213 -
# an error that names the subject it wanted but not why it differs.
#
# Which form arrives is an organisation setting that can change without us,
# so create both and let the token match whichever applies.
INDEX=0
for GITHUB_REPO in "$@"; do
  echo "==> $GITHUB_REPO"
  OWNER="${GITHUB_REPO%%/*}"
  NAME_ONLY="${GITHUB_REPO##*/}"

  SUBJECTS=()
  for SUFFIX in "${SUBJECT_SUFFIXES[@]}"; do
    SUBJECTS+=("repo:${GITHUB_REPO}:${SUFFIX}")
  done

  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    REPO_ID=$(gh api "repos/${GITHUB_REPO}" -q .id 2>/dev/null || true)
    OWNER_ID=$(gh api "repos/${GITHUB_REPO}" -q .owner.id 2>/dev/null || true)
    if [ -n "$REPO_ID" ] && [ -n "$OWNER_ID" ]; then
      for SUFFIX in "${SUBJECT_SUFFIXES[@]}"; do
        SUBJECTS+=("repo:${OWNER}@${OWNER_ID}/${NAME_ONLY}@${REPO_ID}:${SUFFIX}")
      done
    else
      echo "    could not read repository ids - only name-based subjects created."
    fi
  else
    echo "    gh not available - only name-based subjects created."
    echo "    If a run fails with AADSTS700213, this organisation uses immutable"
    echo "    subject claims and the id-based credentials must be added."
  fi

  for SUBJECT in "${SUBJECTS[@]}"; do
    INDEX=$((INDEX + 1))
    EXISTING=$(az ad app federated-credential list --id "$APP_OBJECT_ID" \
      --query "[?subject=='${SUBJECT}'] | [0].id" -o tsv)
    if [ -n "$EXISTING" ]; then
      echo "    exists: $SUBJECT"
      continue
    fi
    # One line on purpose - a multi-line JSON argument is fragile across shells.
    az ad app federated-credential create --id "$APP_OBJECT_ID" --parameters "{\"name\":\"gh-${INDEX}\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"${SUBJECT}\",\"audiences\":[\"api://AzureADTokenExchange\"]}" --output none
    echo "    added : $SUBJECT"
  done
done

cat <<EOF

==> Done.

Put these in each application repository, under
Settings > Environments > dev > Environment secrets:

  AZURE_CLIENT_ID        $APP_ID
  AZURE_TENANT_ID        $(az account show --query tenantId -o tsv)
  AZURE_SUBSCRIPTION_ID  $SUBSCRIPTION_ID

And set this in envs/<env>.tfvars so Terraform grants it AcrPush and
Contributor - the roles are not created here:

  deploy_principal_object_id = "$SP_OID"
EOF

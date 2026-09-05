provider "azurerm" {
  features {
    key_vault {
      # A destroyed vault must be recoverable - payroll secrets are not
      # something to lose to a bad plan.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      # Refuse to delete a resource group that still holds resources
      # Terraform does not know about.
      prevent_deletion_if_contains_resources = true
    }
  }

  # CI authenticates with a federated credential (OIDC); no client secret
  # exists anywhere. Locally, `az login` is used instead.
  use_oidc        = var.use_oidc
  subscription_id = var.subscription_id

  # The evidence account has shared access keys disabled, so the provider has
  # to talk to it as a principal rather than with an account key.
  storage_use_azuread = true
}

data "azurerm_client_config" "current" {}

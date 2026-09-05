terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State lives in the storage account created by bootstrap/bootstrap.sh.
  # Values come from envs/backend-<env>.hcl:
  #   terraform init -backend-config=envs/backend-dev.hcl
  backend "azurerm" {}
}

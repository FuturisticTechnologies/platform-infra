variable "subscription_id" {
  description = "Azure subscription to deploy into."
  type        = string
}

variable "use_oidc" {
  description = "True in CI (federated credential), false when running locally after az login."
  type        = bool
  default     = false
}

variable "environment" {
  description = "Environment name. Drives naming, sizing and the HMRC gating rules."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "prefix" {
  description = "Short resource name prefix."
  type        = string
  default     = "ftpay"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,9}$", var.prefix))
    error_message = "prefix must be 3-10 lowercase alphanumerics - it seeds globally unique names."
  }
}

variable "location" {
  description = "Azure region. UK payroll data stays in the UK."
  type        = string
  default     = "uksouth"
}

variable "vnet_cidr" {
  description = "Address space for the platform VNet."
  type        = string
  default     = "10.60.0.0/16"
}

# --------------------------------------------------------------- sizing

variable "postgres_sku" {
  description = "PostgreSQL Flexible Server SKU."
  type        = string
  default     = "GP_Standard_D2ds_v5"
}

variable "postgres_storage_mb" {
  type    = number
  default = 65536
}

variable "postgres_ha_enabled" {
  description = "Zone-redundant HA. Gives RPO 0 in-region; roughly doubles the database cost."
  type        = bool
  default     = false
}

variable "postgres_backup_retention_days" {
  description = "Point-in-time restore window. The 7-year audit obligation is met by the evidence archive, not by database backups."
  type        = number
  default     = 7
}

# Azure Managed Redis names size and family in one string - Balanced_B0,
# MemoryOptimized_M10, ComputeOptimized_X3 and so on. The classic pairing of a
# tier with a numeric capacity is gone, so redis_capacity went with it.
variable "redis_sku" {
  type    = string
  default = "Balanced_B0"

  validation {
    condition     = can(regex("^(Balanced|MemoryOptimized|ComputeOptimized|FlashOptimized)_[A-Z][0-9]+$", var.redis_sku))
    error_message = "redis_sku must be an Azure Managed Redis SKU such as Balanced_B0. Azure Cache for Redis tiers (Basic, Standard, Premium) are retired and cannot be created."
  }
}

variable "aca_min_replicas" {
  type    = number
  default = 0
}

variable "aca_max_replicas" {
  type    = number
  default = 3
}

variable "aca_zone_redundant" {
  description = "Zone-redundant Container Apps environment. Needs a subnet in a region with availability zones."
  type        = bool
  default     = false
}

# --------------------------------------------------------------- images

variable "image_tag" {
  description = "Image tag deployed by Terraform on first create. Application pipelines move revisions afterwards; Terraform ignores image drift."
  type        = string
  default     = "bootstrap"
}

variable "use_placeholder_images" {
  description = "True until the application pipelines have pushed real images to ACR. Keeps the first apply green on an empty registry."
  type        = bool
  default     = true
}

# --------------------------------------------------------------- application

variable "cors_origins" {
  description = "Allowed browser origins for the payroll API."
  type        = list(string)
  default     = []
}

variable "hmrc_base_url" {
  description = "HMRC API base. The sandbox everywhere except production."
  type        = string
  default     = "https://test-api.service.hmrc.gov.uk"
}

variable "hmrc_allow_live_submission" {
  description = "SOW gating rule 3 - live filing requires this true AND the production environment. Terraform refuses the combination anywhere else."
  type        = bool
  default     = false
}

variable "expose_dotnet_services" {
  description = "Gives the RTI service and the integration hub public ingress so their Swagger UI is reachable from a browser. Off by default and refused in production: these are internal services, and turning it on publishes their whole API surface - /swagger and /openapi.json answer anonymously, so the schema becomes readable by anyone even though the operations themselves stay bearer-gated."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "deploy_principal_object_id" {
  description = "Object id of the service principal the application repositories deploy with. Granted AcrPush and Contributor on this environment's resource group - deliberately not the Owner rights the Terraform principal needs. Null leaves both role assignments out."
  type        = string
  default     = null
}

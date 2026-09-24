variable "subscription_id" {
  description = "Azure subscription to deploy into."
  type        = string

  # CI fills this from the AZURE_SUBSCRIPTION_ID secret. An unset secret arrives
  # as an empty string, and the provider's own complaint about that says
  # nothing about which secret is missing.
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a subscription GUID. In CI it comes from the AZURE_SUBSCRIPTION_ID environment secret - an empty value means that secret is not set."
  }
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
    # Capped by the longest name built from it: ca-<prefix>-staging-integration-hub
    # is 27 characters plus the prefix, and Azure allows a container app 32.
    condition     = can(regex("^[a-z][a-z0-9]{2,4}$", var.prefix))
    error_message = "prefix must be 3-5 lowercase alphanumerics - it seeds globally unique names, and anything longer pushes ca-<prefix>-staging-integration-hub past Azure's 32 character limit for a container app."
  }
}

variable "location" {
  description = "Azure region. UK payroll data stays in the UK."
  type        = string
  default     = "uksouth"

  validation {
    condition     = contains(["uksouth", "ukwest"], var.location)
    error_message = "location must be uksouth or ukwest - payroll personal data stays in the UK. Use the lowercase region name, not the display name."
  }
}

variable "vnet_cidr" {
  description = "Address space for the platform VNet."
  type        = string
  default     = "10.60.0.0/16"

  # locals.tf carves fixed offsets out of this: a /23 for Container Apps and two
  # /24s. From anything smaller than a /16 those come out as /31s and /32s,
  # which plan cleanly and which Azure then refuses at apply.
  validation {
    condition = can(regex("^[0-9.]+/[0-9]+$", var.vnet_cidr)) && try(
      tonumber(split("/", var.vnet_cidr)[1]) <= 16 && cidrsubnet(var.vnet_cidr, 0, 0) == var.vnet_cidr,
      false,
    )
    error_message = "vnet_cidr must be an IPv4 network address of /16 or larger, written with its host bits zero - for example 10.60.0.0/16."
  }
}

# --------------------------------------------------------------- sizing

variable "postgres_sku" {
  description = "PostgreSQL Flexible Server SKU."
  type        = string
  default     = "GP_Standard_D2ds_v5"

  # Flexible Server SKUs are <tier>_<size>, and the tier prefix has to agree
  # with the size family: B with the burstable B series, GP with D, MO with E.
  # A mismatch - or a Single Server name such as GP_Gen5_2 - plans cleanly and
  # fails at apply.
  validation {
    condition     = can(regex("^(B_Standard_B[0-9]+m?s|GP_Standard_D[0-9]+(s|ds|ads)_v[0-9]+|MO_Standard_E[0-9]+(s|ds|ads)_v[0-9]+)$", var.postgres_sku))
    error_message = "postgres_sku must be a Flexible Server SKU such as B_Standard_B1ms, GP_Standard_D2ds_v5 or MO_Standard_E4ds_v5, with the tier prefix matching the size family."
  }
}

variable "postgres_storage_mb" {
  description = "Flexible Server storage. Only the fixed sizes Azure offers are accepted, and it can grow but never shrink."
  type        = number
  default     = 65536

  validation {
    condition     = contains([32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4193280, 4194304, 8388608, 16777216, 33553408], var.postgres_storage_mb)
    error_message = "postgres_storage_mb must be one of the Flexible Server storage sizes: 32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4193280, 4194304, 8388608, 16777216 or 33553408."
  }
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

  validation {
    condition     = var.postgres_backup_retention_days >= 7 && var.postgres_backup_retention_days <= 35 && floor(var.postgres_backup_retention_days) == var.postgres_backup_retention_days
    error_message = "postgres_backup_retention_days must be a whole number of days from 7 to 35 - the range Flexible Server accepts."
  }
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

  validation {
    condition     = var.aca_min_replicas >= 0 && floor(var.aca_min_replicas) == var.aca_min_replicas
    error_message = "aca_min_replicas must be a whole number, 0 or more."
  }
}

variable "aca_max_replicas" {
  type    = number
  default = 3

  validation {
    condition     = var.aca_max_replicas >= 1 && var.aca_max_replicas <= 300 && floor(var.aca_max_replicas) == var.aca_max_replicas
    error_message = "aca_max_replicas must be a whole number from 1 to 300, the Container Apps limit."
  }

  # The module precondition catches this too, but once per app and only after
  # the environment and registry are already in the plan. Here it is one error
  # naming the two variables somebody actually edits.
  validation {
    condition     = var.aca_max_replicas >= var.aca_min_replicas
    error_message = "aca_max_replicas must be at least aca_min_replicas."
  }
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

  # Docker's own tag grammar. "latest" is refused because a revision pinned to
  # it cannot be told apart from the one before it, which is the whole point
  # of a tag here.
  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.image_tag)) && var.image_tag != "latest"
    error_message = "image_tag must be a valid image tag - letters, digits, _ . and -, at most 128 characters, not starting with . or - - and must not be latest."
  }
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

  # apps.tf joins these with commas into one environment variable, and an
  # entry with a path or a trailing slash never matches the Origin header the
  # browser sends. Plain http is only for a developer's own machine.
  validation {
    condition = alltrue([
      for o in var.cors_origins :
      can(regex("^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$", o)) ||
      can(regex("^http://(localhost|127\\.0\\.0\\.1)(:[0-9]{1,5})?$", o))
    ])
    error_message = "cors_origins entries must be bare lowercase origins - scheme, host and optional port, with no path, trailing slash or wildcard - using https, or http only for localhost."
  }
}

variable "hmrc_base_url" {
  description = "HMRC API base. The sandbox everywhere except production."
  type        = string
  default     = "https://test-api.service.hmrc.gov.uk"

  validation {
    condition     = contains(["https://test-api.service.hmrc.gov.uk", "https://api.service.hmrc.gov.uk"], var.hmrc_base_url)
    error_message = "hmrc_base_url must be https://test-api.service.hmrc.gov.uk (sandbox) or https://api.service.hmrc.gov.uk (live), with no trailing slash."
  }
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

  # locals.tf merges these over the standard set, so without this a stray
  # environment or data_class tag would quietly relabel every resource - and
  # data_class is what the data-protection reporting filters on.
  validation {
    condition     = length(setintersection(keys(var.tags), ["project", "environment", "managed_by", "repository", "data_class"])) == 0
    error_message = "tags may not override project, environment, managed_by, repository or data_class - those are set in locals.tf."
  }

  validation {
    condition = alltrue([
      for k, v in var.tags :
      length(k) >= 1 && length(k) <= 512 && length(v) <= 256 && !can(regex("[<>%&?/\\\\]", k))
    ])
    error_message = "tags must follow Azure's rules: names of 1-512 characters without < > % & ? / or backslash, and values of at most 256 characters."
  }
}

variable "deploy_principal_object_id" {
  description = "Object id of the service principal the application repositories deploy with. Granted AcrPush and Contributor on this environment's resource group - deliberately not the Owner rights the Terraform principal needs. Null leaves both role assignments out."
  type        = string
  default     = null

  validation {
    condition     = var.deploy_principal_object_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.deploy_principal_object_id))
    error_message = "deploy_principal_object_id must be null or the service principal's object id, a GUID."
  }
}

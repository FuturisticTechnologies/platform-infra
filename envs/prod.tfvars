environment = "prod"
location    = "uksouth"

# Always warm. A cold start in front of a payroll run is not acceptable.
aca_min_replicas   = 2
aca_max_replicas   = 10
aca_zone_redundant = true

postgres_sku                   = "GP_Standard_D4ds_v5"
postgres_storage_mb            = 262144
postgres_ha_enabled            = true
postgres_backup_retention_days = 35

redis_sku      = "Standard"
redis_capacity = 1

# Live filing is enabled here and nowhere else. The precondition in locals.tf
# refuses this combination in any other environment.
hmrc_base_url              = "https://api.service.hmrc.gov.uk"
hmrc_allow_live_submission = true

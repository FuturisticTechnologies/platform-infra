environment = "staging"
location    = "uksouth"

aca_min_replicas = 0
aca_max_replicas = 3

# Same server family as production so query plans are comparable, but a single
# zone - staging does not need HA, it needs to behave like production.
postgres_sku                   = "GP_Standard_D2ds_v5"
postgres_storage_mb            = 65536
postgres_ha_enabled            = false
postgres_backup_retention_days = 7

redis_sku = "Balanced_B1"

hmrc_base_url              = "https://test-api.service.hmrc.gov.uk"
hmrc_allow_live_submission = false

environment = "dev"
location    = "uksouth"

# Everything scales to zero when idle - a dev environment costing money
# overnight is a dev environment somebody deletes.
aca_min_replicas = 0
aca_max_replicas = 2

postgres_sku                   = "B_Standard_B1ms"
postgres_storage_mb            = 32768
postgres_ha_enabled            = false
postgres_backup_retention_days = 7

redis_sku      = "Basic"
redis_capacity = 0

hmrc_base_url              = "https://test-api.service.hmrc.gov.uk"
hmrc_allow_live_submission = false

cors_origins               = ["http://localhost:4200"]
deploy_principal_object_id = "619fb10a-4a93-4795-a7d0-2ccdd76c7362"

# Database, cache, message bus and the immutable evidence archive.

resource "azurerm_postgresql_flexible_server" "pg" {
  name                = "psql-${local.name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  version             = "16"

  administrator_login    = local.pg_admin
  administrator_password = random_password.postgres.result

  sku_name   = var.postgres_sku
  storage_mb = var.postgres_storage_mb

  # No public endpoint. Reachable only from the VNet.
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  backup_retention_days        = var.postgres_backup_retention_days
  geo_redundant_backup_enabled = local.is_production

  # Zone-redundant HA gives RPO 0 within the region, comfortably inside the
  # 15 minute target in the NFRs. Point-in-time restore covers the
  # restore-and-replay recovery path in the release runbook.
  dynamic "high_availability" {
    for_each = var.postgres_ha_enabled ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  tags = local.tags

  lifecycle {
    # Rotating the admin password is an operational task, not a plan diff, and
    # Azure picks the availability zone itself.
    #
    # Deliberately not ignoring high_availability[0].standby_availability_zone:
    # the block is absent whenever postgres_ha_enabled is false, and indexing
    # into a block that does not exist is a plan-time error.
    ignore_changes = [administrator_password, zone]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

resource "azurerm_postgresql_flexible_server_database" "payroll" {
  name      = "payroll"
  server_id = azurerm_postgresql_flexible_server.pg.id
  collation = "en_US.utf8"
  charset   = "UTF8"

  lifecycle {
    prevent_destroy = true
  }
}

# Row-level security is enforced in the schema, but FORCE only bites for
# non-superusers - the application must never connect as the admin login.
# The migration job creates that role; this documents why it exists.
resource "azurerm_postgresql_flexible_server_configuration" "log_min_duration" {
  name      = "log_min_duration_statement"
  server_id = azurerm_postgresql_flexible_server.pg.id
  value     = "1000"
}

resource "azurerm_postgresql_flexible_server_configuration" "connection_throttling" {
  name      = "connection_throttle.enable"
  server_id = azurerm_postgresql_flexible_server.pg.id
  value     = "on"
}

# --- Redis ---------------------------------------------------------------
# Rate limiting and background job coordination (PLAT-01).
#
# Azure Managed Redis (Microsoft.Cache/redisEnterprise), not Azure Cache for
# Redis. The classic service is retiring and the API now refuses new instances
# outright - a create returns 400 with "Azure Cache for Redis is retiring,
# create Azure Managed Redis instead", so azurerm_redis_cache is not a thing
# that can be provisioned any more, at any SKU.
#
# Managed Redis is offered in UK South, so this stays in region.
#
# It has no Basic tier and no scale-to-zero: the smallest SKU bills around the
# clock. That is not a new cost so much as a larger one - the shutdown job
# already notes Redis cannot be stopped, only deleted - but dev is now roughly
# £40/month for this resource rather than £12.

resource "azurerm_managed_redis" "redis" {
  name                = "redis-${local.name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = var.redis_sku

  # Balanced_B0 is a single node. High availability is a production concern and
  # doubles the bill, so it follows the environment rather than being on.
  high_availability_enabled = local.is_production

  default_database {
    client_protocol = "Encrypted" # TLS only, as the classic cache was

    # EnterpriseCluster, not OSSCluster: the proxy presents a single endpoint
    # so ordinary non-cluster-aware clients keep working. redis-py and
    # StackExchange.Redis are both configured here as if this were one node,
    # and OSSCluster would mean changing both.
    clustering_policy = "EnterpriseCluster"

    eviction_policy = "VolatileLRU"
  }

  tags = local.tags
}

# --- Service Bus ---------------------------------------------------------
# The integration hub's outbox. Chosen over a Redis list because the design
# already has dedupe keys, delivery attempts and permanent-failure
# classification - which is a queue with duplicate detection and a dead-letter
# path, not a cache.

resource "azurerm_servicebus_namespace" "sb" {
  name                = "sb-${local.name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = local.is_production ? "Standard" : "Basic"
  tags                = local.tags
}

resource "azurerm_servicebus_queue" "outbox" {
  name         = "integration-outbox"
  namespace_id = azurerm_servicebus_namespace.sb.id

  requires_duplicate_detection            = local.is_production
  duplicate_detection_history_time_window = "PT30M"
  dead_lettering_on_message_expiration    = true
  max_delivery_count                      = 6 # matches the six-attempt backoff curve
  default_message_ttl                     = "P14D"
}

resource "azurerm_role_assignment" "sb_app" {
  scope                = azurerm_servicebus_namespace.sb.id
  role_definition_name = "Azure Service Bus Data Owner"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# --- Evidence archive ----------------------------------------------------
# The audit obligation is 7 years and the ledger is append-only by design.
# Immutable blob storage makes that enforceable rather than conventional:
# with a locked time-based policy, nobody can delete an evidence record early
# - including whoever holds the subscription owner role.

resource "azurerm_storage_account" "evidence" {
  name                     = "st${local.compact_name}"
  location                 = azurerm_resource_group.rg.location
  resource_group_name      = azurerm_resource_group.rg.name
  account_tier             = "Standard"
  account_replication_type = local.is_production ? "GZRS" : "LRS"
  account_kind             = "StorageV2"
  min_tls_version          = "TLS1_2"

  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # identity-based access only

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }
  }

  # State stays Unlocked here on purpose. Locking is irreversible and cannot be
  # undone by Terraform, a support ticket or Microsoft - it is a deliberate,
  # manual step once the retention period has been signed off.
  immutability_policy {
    allow_protected_append_writes = true
    state                         = "Unlocked"
    period_since_creation_in_days = 2557 # 7 years
  }

  tags = local.tags
}

# Creating a container over Entra auth needs the data-plane role, not just
# Contributor on the account.
resource "azurerm_role_assignment" "evidence_deployer" {
  scope                = azurerm_storage_account.evidence.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_storage_container" "evidence" {
  name                  = "evidence"
  storage_account_id    = azurerm_storage_account.evidence.id
  container_access_type = "private"

  depends_on = [azurerm_role_assignment.evidence_deployer]
}

resource "azurerm_storage_management_policy" "evidence" {
  storage_account_id = azurerm_storage_account.evidence.id

  rule {
    name    = "tier-then-archive"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["evidence/"]
    }

    actions {
      base_blob {
        # Queried often in the first quarter, rarely after a tax year closes,
        # and essentially never after that - but still legally required.
        tier_to_cool_after_days_since_modification_greater_than    = 90
        tier_to_archive_after_days_since_modification_greater_than = 730
      }
    }
  }
}

resource "azurerm_role_assignment" "evidence_writer" {
  scope                = azurerm_storage_account.evidence.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

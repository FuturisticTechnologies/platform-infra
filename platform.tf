# Observability, registry, identity, secrets and the Container Apps environment.

resource "azurerm_log_analytics_workspace" "law" {
  name                = "log-${local.name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = local.is_production ? 90 : 30
  tags                = local.tags
}

resource "azurerm_application_insights" "appi" {
  name                = "appi-${local.name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
  tags                = local.tags
}

resource "azurerm_container_registry" "acr" {
  name                = "acr${local.compact_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = local.is_production ? "Premium" : "Standard"
  admin_enabled       = false # pulls use the managed identity, never a password
  tags                = local.tags
}

# One identity for the workloads. It pulls images, reads secrets, and is what
# the applications present to Azure - no connection strings in the pipeline.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${local.name}-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# --- Application deployment identity -------------------------------------
# The application repositories deploy with their own principal, not the one
# that runs Terraform. That one is subscription Owner because it creates role
# assignments; a pipeline that only pushes an image and moves a revision has
# no business holding it.
#
# Push images, and change things inside this environment's resource group.
# Nothing outside it, and no ability to grant itself anything.

resource "azurerm_role_assignment" "deploy_acr_push" {
  count                = var.deploy_principal_object_id == null ? 0 : 1
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPush"
  principal_id         = var.deploy_principal_object_id
}

resource "azurerm_role_assignment" "deploy_rg_contributor" {
  count                = var.deploy_principal_object_id == null ? 0 : 1
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Contributor"
  principal_id         = var.deploy_principal_object_id
}

# --- Key Vault -----------------------------------------------------------

resource "azurerm_key_vault" "kv" {
  name                       = "kv-${local.compact_name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = local.is_production
  soft_delete_retention_days = 30
  tags                       = local.tags
}

resource "azurerm_role_assignment" "kv_app_read" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# The deploying principal needs to write the secrets it generates below.
resource "azurerm_role_assignment" "kv_deployer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# --- Generated secrets ---------------------------------------------------

resource "random_password" "postgres" {
  length           = 40
  special          = true
  override_special = "!#%*-_=+"
}

# Shared across all three services on purpose: one login at the payroll API
# produces a token the .NET services accept. They must agree byte for byte.
resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "azurerm_key_vault_secret" "postgres_password" {
  name         = "postgres-admin-password"
  value        = random_password.postgres.result
  key_vault_id = azurerm_key_vault.kv.id
  content_type = "password"
  tags         = local.tags

  depends_on = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "app_secret_key" {
  name         = "app-secret-key"
  value        = random_password.jwt.result
  key_vault_id = azurerm_key_vault.kv.id
  content_type = "jwt-signing-key"
  tags         = local.tags

  depends_on = [azurerm_role_assignment.kv_deployer]
}

# HMRC credentials are issued by HMRC, not by us. Terraform creates the slots
# and never looks at the values again, so a real credential set by an operator
# is not reverted by the next apply.
resource "azurerm_key_vault_secret" "hmrc_client_id" {
  name         = "hmrc-client-id"
  value        = "set-out-of-band"
  key_vault_id = azurerm_key_vault.kv.id
  tags         = local.tags

  lifecycle {
    ignore_changes = [value, tags]
  }

  depends_on = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "hmrc_client_secret" {
  name         = "hmrc-client-secret"
  value        = "set-out-of-band"
  key_vault_id = azurerm_key_vault.kv.id
  tags         = local.tags

  lifecycle {
    ignore_changes = [value, tags]
  }

  depends_on = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "database_url" {
  name         = "database-url"
  value        = "postgresql+asyncpg://${local.pg_admin}:${urlencode(random_password.postgres.result)}@${azurerm_postgresql_flexible_server.pg.fqdn}:5432/${azurerm_postgresql_flexible_server_database.payroll.name}"
  key_vault_id = azurerm_key_vault.kv.id
  content_type = "connection-string"
  tags         = local.tags

  depends_on = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "database_url_sync" {
  name         = "database-url-sync"
  value        = "postgresql+psycopg2://${local.pg_admin}:${urlencode(random_password.postgres.result)}@${azurerm_postgresql_flexible_server.pg.fqdn}:5432/${azurerm_postgresql_flexible_server_database.payroll.name}"
  key_vault_id = azurerm_key_vault.kv.id
  content_type = "connection-string"
  tags         = local.tags

  depends_on = [azurerm_role_assignment.kv_deployer]
}

# The .NET services take an ADO.NET style string, not a URL.
resource "azurerm_key_vault_secret" "postgres_connection" {
  name         = "postgres-connection"
  value        = "Host=${azurerm_postgresql_flexible_server.pg.fqdn};Port=5432;Database=${azurerm_postgresql_flexible_server_database.payroll.name};Username=${local.pg_admin};Password=${random_password.postgres.result};SSL Mode=Require;Trust Server Certificate=true"
  key_vault_id = azurerm_key_vault.kv.id
  content_type = "connection-string"
  tags         = local.tags

  depends_on = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "redis_url" {
  name         = "redis-url"
  value        = "rediss://:${azurerm_redis_cache.redis.primary_access_key}@${azurerm_redis_cache.redis.hostname}:${azurerm_redis_cache.redis.ssl_port}/0"
  key_vault_id = azurerm_key_vault.kv.id
  content_type = "connection-string"
  tags         = local.tags

  depends_on = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_secret" "appinsights" {
  name         = "appinsights-connection-string"
  value        = azurerm_application_insights.appi.connection_string
  key_vault_id = azurerm_key_vault.kv.id
  content_type = "connection-string"
  tags         = local.tags

  depends_on = [azurerm_role_assignment.kv_deployer]
}

# --- Container Apps environment -----------------------------------------

resource "azurerm_container_app_environment" "cae" {
  name                       = "cae-${local.name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
  infrastructure_subnet_id   = azurerm_subnet.apps.id
  zone_redundancy_enabled    = var.aca_zone_redundant
  tags                       = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

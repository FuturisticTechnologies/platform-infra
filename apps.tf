# The three services, plus the migration job.
#
# Env var names and ports are taken from docker-compose.platform.yml so the
# cloud contract matches the one the team runs locally. Nothing is invented:
# if a key is not read by the application, it is not set here.

locals {
  # The application's own vocabulary, not Azure's.
  app_env = {
    dev     = "development"
    staging = "staging"
    prod    = "production"
  }[var.environment]

  dotnet_env = {
    dev     = "Development"
    staging = "Staging"
    prod    = "Production"
  }[var.environment]

  # Versionless secret ids: the app picks up a rotated secret without a deploy.
  kv_secrets = {
    app-secret-key      = azurerm_key_vault_secret.app_secret_key.versionless_id
    database-url        = azurerm_key_vault_secret.database_url.versionless_id
    database-url-sync   = azurerm_key_vault_secret.database_url_sync.versionless_id
    postgres-connection = azurerm_key_vault_secret.postgres_connection.versionless_id
    redis-url           = azurerm_key_vault_secret.redis_url.versionless_id
    hmrc-client-id      = azurerm_key_vault_secret.hmrc_client_id.versionless_id
    hmrc-client-secret  = azurerm_key_vault_secret.hmrc_client_secret.versionless_id
    appinsights         = azurerm_key_vault_secret.appinsights.versionless_id
  }

  # Telemetry goes in as a secret rather than a plain variable. It carries an
  # ingestion key, and a sensitive value cannot drive a dynamic block anyway.
  telemetry_env = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = "appinsights"
  }
}

# --- Payroll API (Python / FastAPI, M1-M5) -------------------------------

module "backend" {
  source = "./modules/container-app"

  name                         = "ca-${local.name}-payroll-api"
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  identity_id                  = azurerm_user_assigned_identity.app.id
  registry_server              = azurerm_container_registry.acr.login_server
  image                        = local.images.backend

  target_port      = local.ports.backend
  external_ingress = true
  health_path      = "/api/v1/health"

  min_replicas = max(var.aca_min_replicas, local.is_production ? 2 : 0)
  max_replicas = var.aca_max_replicas
  cpu          = 1.0
  memory       = "2Gi"

  secrets = local.kv_secrets

  env = {
    APP_ENV   = local.app_env
    APP_DEBUG = "false"
    # The front end is a separate container app, so it is a different origin
    # to the API and the browser will say so. Terraform knows the hostname, so
    # nobody has to paste it in after the fact.
    APP_CORS_ORIGINS = join(",", concat(
      var.cors_origins,
      ["https://${module.frontend.fqdn}"],
    ))
    JWT_ALGORITHM                   = "HS256"
    JWT_ACCESS_TOKEN_EXPIRE_MINUTES = "30"
  }

  secret_env = merge(local.telemetry_env, {
    APP_SECRET_KEY    = "app-secret-key"
    DATABASE_URL      = "database-url"
    DATABASE_URL_SYNC = "database-url-sync"
    REDIS_URL         = "redis-url"
  })

  tags = local.tags
}

# --- HMRC RTI submissions (.NET 10, M6-M7) -------------------------------
# Internal ingress: nothing outside the environment calls this directly, and
# it is the only service that talks to HMRC.

module "rti" {
  source = "./modules/container-app"

  name                         = "ca-${local.name}-hmrc-rti"
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  identity_id                  = azurerm_user_assigned_identity.app.id
  registry_server              = azurerm_container_registry.acr.login_server
  image                        = local.images.rti

  target_port      = local.ports.dotnet
  external_ingress = false
  health_path      = "/api/v1/health"
  ready_path       = "/api/v1/health/ready"

  min_replicas = local.is_production ? 1 : 0
  max_replicas = var.aca_max_replicas

  secrets = local.kv_secrets

  env = {
    ASPNETCORE_ENVIRONMENT = local.dotnet_env
    ASPNETCORE_HTTP_PORTS  = tostring(local.ports.dotnet)
    PayrollApi__BaseUrl    = module.backend.url

    Hmrc__BaseUrl = var.hmrc_base_url

    # Gating rule 3: live filing needs this true *and* Production. The
    # precondition in locals.tf refuses the combination anywhere else.
    Hmrc__AllowLiveSubmission = tostring(var.hmrc_allow_live_submission)
  }

  secret_env = merge(local.telemetry_env, {
    ConnectionStrings__Postgres = "postgres-connection"
    PlatformAuth__SecretKey     = "app-secret-key"
    Hmrc__ClientId              = "hmrc-client-id"
    Hmrc__ClientSecret          = "hmrc-client-secret"
  })

  tags = local.tags
}

# --- Integration hub (.NET 10, INT) --------------------------------------

module "hub" {
  source = "./modules/container-app"

  name                         = "ca-${local.name}-integration-hub"
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  identity_id                  = azurerm_user_assigned_identity.app.id
  registry_server              = azurerm_container_registry.acr.login_server
  image                        = local.images.hub

  target_port      = local.ports.dotnet
  external_ingress = false
  health_path      = "/api/v1/health"
  ready_path       = "/api/v1/health/ready"

  # The hub runs its own interval dispatcher, so it must not scale to zero -
  # a scaled-to-zero replica delivers nothing and nothing wakes it.
  min_replicas = 1
  max_replicas = local.is_production ? 3 : 1

  secrets = local.kv_secrets

  env = {
    ASPNETCORE_ENVIRONMENT               = local.dotnet_env
    ASPNETCORE_HTTP_PORTS                = tostring(local.ports.dotnet)
    Connectors__SimulateWhenUnconfigured = local.is_production ? "false" : "true"
    Connectors__DispatchIntervalSeconds  = "15"
  }

  secret_env = merge(local.telemetry_env, {
    ConnectionStrings__Postgres = "postgres-connection"
    PlatformAuth__SecretKey     = "app-secret-key"
  })

  tags = local.tags
}

# --- Alembic migrations --------------------------------------------------
# A manually triggered job, not a step in the container's start-up command.
# The deployment policy is that schema changes are gated and run once - not
# raced by every replica that happens to start.
#
#   az containerapp job start -n <job> -g <rg>

resource "azurerm_container_app_job" "migrate" {
  name                         = "caj-${local.name}-migrate"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  workload_profile_name        = "Consumption"

  replica_timeout_in_seconds = 1800
  replica_retry_limit        = 0 # a half-applied migration should not be retried blindly

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  secret {
    name                = "database-url-sync"
    key_vault_secret_id = azurerm_key_vault_secret.database_url_sync.versionless_id
    identity            = azurerm_user_assigned_identity.app.id
  }

  template {
    container {
      name    = "migrate"
      image   = local.images.backend
      cpu     = 0.5
      memory  = "1Gi"
      command = ["alembic", "upgrade", "head"]

      env {
        name        = "DATABASE_URL_SYNC"
        secret_name = "database-url-sync"
      }

      env {
        name  = "APP_ENV"
        value = local.app_env
      }
    }
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}

# --- Angular frontend ----------------------------------------------------
# A container in the same environment as the services, not Static Web Apps.
#
# Static Web Apps would have been the better fit for a built SPA - CDN, free
# certificates, a preview environment per pull request - but it exists in only
# five regions: Central US, East US 2, West US 2, West Europe and East Asia.
# West Europe, the nearest one and the one this used, now refuses new resources
# with "the selected region is currently not accepting new customers". The four
# that remain are all outside the UK and the EU.
#
# docs/04-security-gdpr.md commits to a UK region or equivalent customer-
# approved hosting. Serving the bundle from a container here keeps that promise
# without needing an exception, and reuses the environment already running in
# UK South. It scales to zero like everything else.
#
# What it costs: no built-in CDN, no per-pull-request previews, and certificates
# come from the Container Apps environment rather than free from the platform.
# If Static Web Apps opens up in a UK region, this is worth revisiting.

module "frontend" {
  source = "./modules/container-app"

  name                         = "ca-${local.name}-frontend"
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  identity_id                  = azurerm_user_assigned_identity.app.id
  registry_server              = azurerm_container_registry.acr.login_server
  image                        = local.images.frontend

  target_port      = local.ports.frontend
  external_ingress = true

  # A static bundle behind nginx: index.html is the readiness signal, because
  # there is no application to be unready.
  health_path = "/"

  min_replicas = max(var.aca_min_replicas, local.is_production ? 2 : 0)
  max_replicas = var.aca_max_replicas
  cpu          = 0.25
  memory       = "0.5Gi"

  tags = local.tags
}

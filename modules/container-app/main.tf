terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

resource "azurerm_container_app" "this" {
  name                         = var.name
  resource_group_name          = var.resource_group_name
  container_app_environment_id = var.container_app_environment_id
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  # Multiple revisions is what makes blue/green possible: a new revision takes
  # 0% of traffic until it is shifted deliberately, which is the release
  # procedure the M5-18 runbook describes.
  revision_mode = "Multiple"

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity_id]
  }

  registry {
    server   = var.registry_server
    identity = var.identity_id
  }

  dynamic "secret" {
    for_each = var.secrets
    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = var.identity_id
    }
  }

  ingress {
    external_enabled           = var.external_ingress
    target_port                = var.target_port
    transport                  = "auto"
    allow_insecure_connections = false

    # Terraform pins 100% to the latest revision on create. Traffic shifting
    # during a release is done by the deployment pipeline, and Terraform is
    # told to leave it alone below.
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    http_scale_rule {
      name                = "http-concurrency"
      concurrent_requests = var.http_scale_concurrent_requests
    }

    container {
      name   = var.name
      image  = var.image
      cpu    = var.cpu
      memory = var.memory

      dynamic "env" {
        for_each = var.env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env
        content {
          name        = env.key
          secret_name = env.value
        }
      }

      liveness_probe {
        transport = "HTTP"
        port      = var.target_port
        path      = var.health_path

        initial_delay           = 10
        interval_seconds        = 30
        failure_count_threshold = 3
      }

      readiness_probe {
        transport = "HTTP"
        port      = var.target_port
        path      = coalesce(var.ready_path, var.health_path)

        interval_seconds        = 10
        failure_count_threshold = 3
      }
    }
  }

  lifecycle {
    # Terraform owns the shape of the app; the application pipelines own what
    # is running in it. Without this, every infra apply would roll every
    # service back to whatever tag was last committed here.
    ignore_changes = [
      template[0].container[0].image,
      ingress[0].traffic_weight,
    ]
  }
}

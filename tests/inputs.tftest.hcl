# Input validation tests. Offline: both providers are mocked, so nothing here
# signs in to Azure or reads state. Run from the repository root with
#
#   terraform init -backend=false
#   terraform test
#
# Each failing case sets one bad value on top of a known-good dev baseline and
# expects exactly that variable's validation (or the named precondition) to
# stop the plan. The env_* runs carry the values from envs/*.tfvars - a test
# file cannot load a var file per run - so change them together; they prove the
# rules still accept what each environment actually deploys.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      object_id       = "00000000-0000-0000-0000-000000000002"
      subscription_id = "00000000-0000-0000-0000-000000000003"
      client_id       = "00000000-0000-0000-0000-000000000004"
    }
  }
}

mock_provider "random" {}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000003"
  environment     = "dev"
}

# --------------------------------------------------------------- known good

run "env_dev" {
  command = plan

  variables {
    environment                    = "dev"
    location                       = "uksouth"
    aca_min_replicas               = 0
    aca_max_replicas               = 2
    postgres_sku                   = "B_Standard_B1ms"
    postgres_storage_mb            = 32768
    postgres_ha_enabled            = false
    postgres_backup_retention_days = 7
    redis_sku                      = "Balanced_B0"
    hmrc_base_url                  = "https://test-api.service.hmrc.gov.uk"
    hmrc_allow_live_submission     = false
    expose_dotnet_services         = true
    cors_origins                   = ["http://localhost:4200"]
    deploy_principal_object_id     = "619fb10a-4a93-4795-a7d0-2ccdd76c7362"
  }
}

run "env_staging" {
  command = plan

  variables {
    environment                    = "staging"
    aca_min_replicas               = 0
    aca_max_replicas               = 3
    postgres_sku                   = "GP_Standard_D2ds_v5"
    postgres_storage_mb            = 65536
    postgres_backup_retention_days = 7
    redis_sku                      = "Balanced_B1"
  }
}

run "env_prod" {
  command = plan

  variables {
    environment                    = "prod"
    aca_min_replicas               = 2
    aca_max_replicas               = 10
    aca_zone_redundant             = true
    postgres_sku                   = "GP_Standard_D4ds_v5"
    postgres_storage_mb            = 262144
    postgres_ha_enabled            = true
    postgres_backup_retention_days = 35
    redis_sku                      = "Balanced_B3"
    hmrc_base_url                  = "https://api.service.hmrc.gov.uk"
    hmrc_allow_live_submission     = true
  }
}

# --------------------------------------------------------------- variables

run "rejects_empty_subscription_id" {
  command = plan
  variables {
    subscription_id = ""
  }
  expect_failures = [var.subscription_id]
}

run "rejects_region_outside_uk" {
  command = plan
  variables {
    location = "westeurope"
  }
  expect_failures = [var.location]
}

run "rejects_region_display_name" {
  command = plan
  variables {
    location = "UK South"
  }
  expect_failures = [var.location]
}

run "rejects_single_server_postgres_sku" {
  command = plan
  variables {
    postgres_sku = "GP_Gen5_2"
  }
  expect_failures = [var.postgres_sku]
}

run "rejects_mismatched_postgres_tier" {
  command = plan
  variables {
    postgres_sku = "GP_Standard_E4ds_v5"
  }
  expect_failures = [var.postgres_sku]
}

run "rejects_odd_postgres_storage" {
  command = plan
  variables {
    postgres_storage_mb = 50000
  }
  expect_failures = [var.postgres_storage_mb]
}

run "rejects_backup_retention_over_35" {
  command = plan
  variables {
    postgres_backup_retention_days = 90
  }
  expect_failures = [var.postgres_backup_retention_days]
}

run "rejects_negative_min_replicas" {
  command = plan
  variables {
    aca_min_replicas = -1
  }
  expect_failures = [var.aca_min_replicas]
}

run "rejects_zero_max_replicas" {
  command = plan
  variables {
    aca_min_replicas = 0
    aca_max_replicas = 0
  }
  expect_failures = [var.aca_max_replicas]
}

run "rejects_max_below_min_replicas" {
  command = plan
  variables {
    aca_min_replicas = 4
    aca_max_replicas = 2
  }
  expect_failures = [var.aca_max_replicas]
}

run "rejects_latest_image_tag" {
  command = plan
  variables {
    image_tag = "latest"
  }
  expect_failures = [var.image_tag]
}

run "rejects_malformed_image_tag" {
  command = plan
  variables {
    image_tag = "-bad:tag"
  }
  expect_failures = [var.image_tag]
}

run "rejects_cors_origin_with_trailing_slash" {
  command = plan
  variables {
    cors_origins = ["https://payroll.example.co.uk/"]
  }
  expect_failures = [var.cors_origins]
}

run "rejects_cors_wildcard" {
  command = plan
  variables {
    cors_origins = ["*"]
  }
  expect_failures = [var.cors_origins]
}

run "rejects_plain_http_cors_origin" {
  command = plan
  variables {
    cors_origins = ["http://payroll.example.co.uk"]
  }
  expect_failures = [var.cors_origins]
}

run "rejects_unknown_hmrc_host" {
  command = plan
  variables {
    hmrc_base_url = "https://test-api.service.hmrc.gov.uk/"
  }
  expect_failures = [var.hmrc_base_url]
}

run "rejects_reserved_tag" {
  command = plan
  variables {
    tags = { data_class = "public" }
  }
  expect_failures = [var.tags]
}

run "rejects_invalid_tag_name" {
  command = plan
  variables {
    tags = { "cost/centre" = "payroll" }
  }
  expect_failures = [var.tags]
}

run "rejects_client_id_style_principal" {
  command = plan
  variables {
    deploy_principal_object_id = "ft-app-deploy"
  }
  expect_failures = [var.deploy_principal_object_id]
}

# --------------------------------------------------------------- preconditions

run "rejects_live_hmrc_url_without_live_flag" {
  command = plan
  variables {
    environment                = "prod"
    postgres_ha_enabled        = true
    hmrc_base_url              = "https://api.service.hmrc.gov.uk"
    hmrc_allow_live_submission = false
  }
  expect_failures = [terraform_data.hmrc_live_submission_guard]
}

run "rejects_live_flag_with_sandbox_url" {
  command = plan
  variables {
    environment                = "prod"
    postgres_ha_enabled        = true
    hmrc_base_url              = "https://test-api.service.hmrc.gov.uk"
    hmrc_allow_live_submission = true
  }
  expect_failures = [terraform_data.hmrc_live_submission_guard]
}

run "rejects_burstable_postgres_in_prod" {
  command = plan
  variables {
    environment         = "prod"
    postgres_ha_enabled = true
    postgres_sku        = "B_Standard_B2ms"
  }
  expect_failures = [terraform_data.hmrc_live_submission_guard]
}

locals {
  name   = "${var.prefix}-${var.environment}"
  suffix = substr(sha1("${var.prefix}-${var.environment}-${var.subscription_id}"), 0, 6)

  # Globally unique, lowercase, no hyphens - storage and ACR naming rules.
  compact_name = "${var.prefix}${var.environment}${local.suffix}"

  is_production = var.environment == "prod"

  tags = merge({
    project     = "PayrollFuturistic"
    environment = var.environment
    managed_by  = "terraform"
    repository  = "platform-infra"
    data_class  = "payroll-personal-data"
  }, var.tags)

  # Subnets. Container Apps needs a /23 minimum for a workload-profile
  # environment, and both delegated subnets must be dedicated.
  subnets = {
    apps     = cidrsubnet(var.vnet_cidr, 7, 0) # /23
    postgres = cidrsubnet(var.vnet_cidr, 8, 4) # /24
    private  = cidrsubnet(var.vnet_cidr, 8, 5) # /24 - private endpoints
  }

  # Ports the services actually listen on, from docker-compose.platform.yml.
  ports = {
    backend  = 8000
    dotnet   = 8080
    frontend = 80 # nginx serving the built Angular bundle
  }

  # Postgres admin login. Flexible Server reserves a handful of names
  # (azure_superuser, admin, administrator, root, guest, public).
  pg_admin = "payrolladmin"

  placeholder_image = "mcr.microsoft.com/k8se/quickstart:latest"

  # Terraform creates the app with a placeholder until the application
  # pipelines have pushed a real image; after that it ignores the tag entirely.
  images = {
    backend  = var.use_placeholder_images ? local.placeholder_image : "${azurerm_container_registry.acr.login_server}/payroll-backend:${var.image_tag}"
    rti      = var.use_placeholder_images ? local.placeholder_image : "${azurerm_container_registry.acr.login_server}/hmrc-rti-service:${var.image_tag}"
    hub      = var.use_placeholder_images ? local.placeholder_image : "${azurerm_container_registry.acr.login_server}/integration-hub:${var.image_tag}"
    frontend = var.use_placeholder_images ? local.placeholder_image : "${azurerm_container_registry.acr.login_server}/payroll-frontend:${var.image_tag}"
  }
}

# Live filing outside production is the one thing the SOW forbids outright, so
# it fails at plan time rather than in a review.
resource "terraform_data" "hmrc_live_submission_guard" {
  lifecycle {
    precondition {
      condition     = !var.hmrc_allow_live_submission || local.is_production
      error_message = "hmrc_allow_live_submission may only be true in the prod environment (SOW gating rule 3)."
    }
    # The flag and the URL have to agree. Live URL with the flag off means the
    # RTI service refuses every submission to an endpoint that would have
    # accepted them; flag on with the sandbox URL means production "files"
    # returns HMRC never sees. Both look healthy until the first payroll run.
    precondition {
      condition     = var.hmrc_allow_live_submission == (var.hmrc_base_url == "https://api.service.hmrc.gov.uk")
      error_message = "hmrc_base_url and hmrc_allow_live_submission disagree: the live HMRC URL goes with hmrc_allow_live_submission = true, and the sandbox URL with false."
    }
    precondition {
      condition     = !local.is_production || var.postgres_ha_enabled
      error_message = "production requires postgres_ha_enabled = true to meet the 15 minute RPO."
    }
    # Burstable servers do not support zone-redundant HA, so a B_ SKU in
    # production would fail at apply on the rule above - better said here.
    precondition {
      condition     = !local.is_production || !startswith(var.postgres_sku, "B_")
      error_message = "production may not use a burstable (B_Standard_*) postgres_sku - burstable servers cannot run zone-redundant HA."
    }
    # Convenience in dev, never in production. The RTI service holds the HMRC
    # credentials and is the platform's only route to HMRC; a browsable Swagger
    # page is not worth putting it on the public internet.
    precondition {
      condition     = !var.expose_dotnet_services || !local.is_production
      error_message = "expose_dotnet_services may not be true in the prod environment."
    }
  }
}

output "resource_group" {
  value = azurerm_resource_group.rg.name
}

output "payroll_api_url" {
  description = "Public URL of the payroll API."
  value       = module.backend.url
}

output "rti_service_url" {
  description = "Internal only - resolvable from inside the Container Apps environment."
  value       = module.rti.url
}

output "integration_hub_url" {
  description = "Internal only."
  value       = module.hub.url
}

output "frontend_url" {
  description = "The Angular app. A container in this environment, not Static Web Apps - see apps.tf."
  value       = module.frontend.url
}

output "container_registry" {
  description = "Push application images here; the deployment pipelines take it from there."
  value       = azurerm_container_registry.acr.login_server
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}

output "postgres_fqdn" {
  description = "Private FQDN. Only resolvable from inside the VNet."
  value       = azurerm_postgresql_flexible_server.pg.fqdn
}

output "egress_ip" {
  description = "The single outbound address every service leaves from. This is the value HMRC allowlists."
  value       = azurerm_public_ip.egress.ip_address
}

output "evidence_storage_account" {
  value = azurerm_storage_account.evidence.name
}

output "migration_job" {
  description = "az containerapp job start -n <this> -g <resource_group>"
  value       = azurerm_container_app_job.migrate.name
}

output "application_insights_connection_string" {
  value     = azurerm_application_insights.appi.connection_string
  sensitive = true
}

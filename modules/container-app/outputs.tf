output "id" {
  value = azurerm_container_app.this.id
}

output "name" {
  value = azurerm_container_app.this.name
}

output "fqdn" {
  description = "Ingress hostname. Internal apps resolve only inside the environment."
  value       = try(azurerm_container_app.this.ingress[0].fqdn, null)
}

output "url" {
  value = try("https://${azurerm_container_app.this.ingress[0].fqdn}", null)
}

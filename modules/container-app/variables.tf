variable "name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "container_app_environment_id" {
  type = string
}

variable "identity_id" {
  description = "User-assigned identity used for the registry pull and Key Vault reads."
  type        = string
}

variable "registry_server" {
  type = string
}

variable "image" {
  type = string
}

variable "target_port" {
  type = number
}

variable "external_ingress" {
  description = "True for the app the browser talks to; false keeps the service inside the environment."
  type        = bool
  default     = false
}

variable "health_path" {
  type    = string
  default = "/api/v1/health"
}

variable "ready_path" {
  description = "Readiness path. Defaults to health_path when the service has no separate probe."
  type        = string
  default     = null
}

variable "cpu" {
  type    = number
  default = 0.5
}

variable "memory" {
  type    = string
  default = "1Gi"
}

variable "min_replicas" {
  type    = number
  default = 0
}

variable "max_replicas" {
  type    = number
  default = 3
}

variable "env" {
  description = "Plain environment variables."
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "Environment variables sourced from a secret: env var name -> secret name."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Secrets pulled from Key Vault: secret name -> versionless key vault secret id."
  type        = map(string)
  default     = {}
}

variable "http_scale_concurrent_requests" {
  description = "Concurrent requests per replica before scaling out."
  type        = number
  default     = 50
}

variable "tags" {
  type    = map(string)
  default = {}
}

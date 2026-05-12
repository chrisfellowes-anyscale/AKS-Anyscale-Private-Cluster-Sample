variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "pip_name" {
  type = string
}

variable "firewall_name" {
  type = string
}

variable "firewall_policy_name" {
  type = string
}

variable "rcg_name" {
  type = string
}

variable "firewall_subnet_id" {
  description = "ID of the AzureFirewallSubnet."
  type        = string
}

variable "aks_nodes_cidr" {
  description = "Source CIDR for AKS node egress rules."
  type        = string
}

variable "anyscale_fqdns" {
  description = "Anyscale control plane / API FQDNs (HTTPS:443) — see https://docs.anyscale.com/networking/overview."
  type        = list(string)
}

variable "container_registry_fqdns" {
  description = "Public container registries permitted egress."
  type        = list(string)
}

variable "azure_identity_fqdns" {
  description = "Microsoft identity and ARM endpoints permitted for AKS Workload Identity token exchange and Azure SDK/CLI data-plane auth flows."
  type        = list(string)
}

variable "azure_monitor_fqdns" {
  description = "Azure Monitor, Log Analytics, and Azure Monitor Agent endpoints permitted for diagnostics and Container Insights when public egress fallback is required."
  type        = list(string)
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for firewall diagnostic settings."
  type        = string
}

variable "diagnostic_settings_enabled" {
  description = "Whether this module creates an Azure Monitor diagnostic setting. Disable when Azure Policy manages diagnostics for this resource."
  type        = bool
  default     = false
}

variable "dns_proxy_enabled" {
  description = "Whether Azure Firewall DNS proxy is enabled on the firewall policy."
  type        = bool
}

variable "dns_servers" {
  description = "Upstream DNS servers used by Azure Firewall DNS proxy. Leave empty to use Azure DNS, including private zones linked to the VNet."
  type        = list(string)
}

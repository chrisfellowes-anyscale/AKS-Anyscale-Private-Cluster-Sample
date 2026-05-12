variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "azure_tenant_id" {
  description = "Microsoft Entra tenant ID used for AKS managed Entra integration."
  type        = string
}

variable "tags" {
  type = map(string)
}

variable "cluster_name" {
  type = string
}

variable "dns_prefix" {
  type = string
}

variable "kubernetes_version" {
  description = "Kubernetes version. Pin an exact patch version for reproducible AKS node bootstrap behavior; null uses the regional default."
  type        = string
  nullable    = true
}

###############################################################################
# Networking
###############################################################################
variable "nodes_subnet_id" {
  description = "Subnet ID for AKS node pools (BYO VNet)."
  type        = string
}

variable "apiserver_subnet_id" {
  description = "Subnet ID for the API server VNet integration delegated subnet."
  type        = string
}

variable "service_cidr" {
  description = "Kubernetes service CIDR. Must not overlap node subnet."
  type        = string
}

variable "dns_service_ip" {
  description = "Kubernetes DNS service IP. Must be inside service_cidr."
  type        = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID (privatelink.<region>.azmk8s.io) for the AKS API server."
  type        = string
}

###############################################################################
# Node pools
###############################################################################
variable "system_vm_size" {
  type = string
}

variable "availability_zones" {
  type = list(string)
}

variable "sku_tier" {
  type = string
}

variable "system_node_pool_min_count" {
  type = number
}

variable "system_node_pool_max_count" {
  type = number
}

variable "cpu_vm_size" {
  type = string
}

variable "gpu_pool_configs" {
  type = map(object({
    name               = string
    vm_size            = string
    product_name       = string
    gpu_count          = string
    min_count          = number
    max_count          = number
    availability_zones = optional(list(string), [])
  }))
}

###############################################################################
# Identity / observability
###############################################################################
variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for Container Insights (msi auth)."
  type        = string
}

variable "container_insights_v2_enabled" {
  description = "Whether the Container Insights DCR sends stdout/stderr logs to ContainerLogV2."
  type        = bool
}

variable "container_insights_streams" {
  type = list(string)
}

variable "container_insights_data_collection_interval" {
  type = string
}

variable "container_insights_namespace_filtering_mode" {
  type = string
}

variable "container_insights_namespaces" {
  type = list(string)
}

variable "ampls_enabled" {
  description = "Whether Container Insights should use a private DCE linked to AMPLS."
  type        = bool
}

variable "ampls_scope_name" {
  description = "Azure Monitor Private Link Scope name used to link the Container Insights configuration DCE."
  type        = string
  nullable    = true
}

variable "ampls_resource_group_name" {
  description = "Resource group containing the Azure Monitor Private Link Scope."
  type        = string
  nullable    = true
}

variable "diagnostic_settings_enabled" {
  description = "Whether this module creates an Azure Monitor diagnostic setting. Disable when Azure Policy manages diagnostics for this resource."
  type        = bool
  default     = false
}

variable "anyscale_operator_identity_id" {
  description = "Resource ID of the user-assigned managed identity for the Anyscale operator (federated credential will be created against the cluster's OIDC issuer)."
  type        = string
}

variable "anyscale_operator_namespace" {
  description = "Kubernetes namespace where the Anyscale operator service account lives."
  type        = string
}

variable "anyscale_operator_serviceaccount" {
  description = "Kubernetes service account name for the Anyscale operator."
  type        = string
}

variable "acr_id" {
  description = "ACR resource ID — used to grant kubelet identity AcrPull."
  type        = string
}

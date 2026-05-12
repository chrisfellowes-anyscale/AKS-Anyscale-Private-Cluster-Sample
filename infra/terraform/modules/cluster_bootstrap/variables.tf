variable "enabled" {
  description = "Whether Terraform should manage the Kubernetes bootstrap layer on the AKS cluster."
  type        = bool
}

variable "operator_namespace" {
  description = "Namespace that holds the Anyscale operator service account."
  type        = string
}

variable "operator_service_account_name" {
  description = "Name of the Anyscale operator service account."
  type        = string
}

variable "workload_identity_client_id" {
  description = "Client ID of the user-assigned managed identity used by the Anyscale operator."
  type        = string
}

variable "workload_identity_tenant_id" {
  description = "Microsoft Entra tenant ID used by the workload identity annotations."
  type        = string
}

variable "extension_release_name" {
  description = "Helm release name that the marketplace extension uses for the Anyscale operator."
  type        = string
}

variable "gpu_resources_namespace" {
  description = "Namespace for the NVIDIA device plugin release."
  type        = string
}

variable "nvidia_device_plugin_release_name" {
  description = "Release name for the NVIDIA device plugin Helm chart."
  type        = string
}

variable "nvidia_device_plugin_chart_version" {
  description = "Pinned Helm chart version for the NVIDIA device plugin release."
  type        = string
}

variable "ingress_namespace" {
  description = "Namespace for the ingress-nginx Helm release."
  type        = string
}

variable "ingress_release_name" {
  description = "Release name for the ingress-nginx Helm chart."
  type        = string
}

variable "ingress_chart_version" {
  description = "Pinned Helm chart version for the ingress-nginx release."
  type        = string
}
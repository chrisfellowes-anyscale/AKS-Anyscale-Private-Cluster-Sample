output "contract" {
  description = "Plan-time contract for the Terraform-managed Kubernetes bootstrap layer."
  value = {
    enabled = var.enabled
    service_account = {
      namespace   = var.operator_namespace
      name        = var.operator_service_account_name
      labels      = local.service_account_labels
      annotations = local.service_account_annotations
    }
    helm_releases = {
      nvidia_device_plugin = {
        namespace     = var.gpu_resources_namespace
        release_name  = var.nvidia_device_plugin_release_name
        chart         = "nvidia-device-plugin"
        repository    = "https://nvidia.github.io/k8s-device-plugin"
        chart_version = var.nvidia_device_plugin_chart_version
      }
      ingress_nginx = {
        namespace     = var.ingress_namespace
        release_name  = var.ingress_release_name
        chart         = "ingress-nginx"
        repository    = "https://kubernetes.github.io/ingress-nginx"
        chart_version = var.ingress_chart_version
        service_annotations = {
          "service.beta.kubernetes.io/azure-load-balancer-internal"                  = "true"
          "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path" = "/healthz"
        }
      }
    }
  }
}
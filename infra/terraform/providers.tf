provider "azurerm" {
  features {}
  subscription_id                 = var.azure_subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true
}

provider "azapi" {}

provider "kubernetes" {
  alias       = "bootstrap"
  config_path = local.cluster_bootstrap_kubeconfig_path
}

provider "helm" {
  alias = "bootstrap"

  dynamic "kubernetes" {
    for_each = [1]

    content {
      config_path = local.cluster_bootstrap_kubeconfig_path
    }
  }
}

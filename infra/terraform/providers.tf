provider "azurerm" {
  features {}
  subscription_id                 = var.azure_subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true
}

provider "azapi" {
  subscription_id = var.azure_subscription_id
}

provider "kubernetes" {
  alias       = "bootstrap"
  config_path = local.cluster_bootstrap_kubeconfig_path
}

provider "helm" {
  alias = "bootstrap"
}

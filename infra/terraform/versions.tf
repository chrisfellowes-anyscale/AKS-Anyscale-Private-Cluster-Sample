terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 1.13"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.26"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
  }
}

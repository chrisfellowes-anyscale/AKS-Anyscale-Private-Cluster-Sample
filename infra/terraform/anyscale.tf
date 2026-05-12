locals {
  anyscale_platform_enabled        = var.anyscale_platform.enabled
  anyscale_platform_cloud_name     = coalesce(var.anyscale_platform.cloud_name, local.suffix)
  anyscale_platform_extension_name = var.anyscale_platform.extension_resource_name
  anyscale_platform_extension_configuration_defaults = {
    "workloads.accelerator.tolerations.default[0].key"      = "node.anyscale.com/accelerator-type"
    "workloads.accelerator.tolerations.default[0].value"    = "GPU"
    "workloads.accelerator.tolerations.default[0].effect"   = "NoSchedule"
    "workloads.accelerator.tolerations.default[1].key"      = "nvidia.com/gpu"
    "workloads.accelerator.tolerations.default[1].operator" = "Exists"
    "workloads.accelerator.tolerations.default[1].effect"   = "NoSchedule"
  }
  anyscale_platform_extension_configuration_settings = merge(
    local.anyscale_platform_extension_configuration_defaults,
    var.anyscale_platform.extension_configuration_settings,
  )
  anyscale_platform_deployments = {
    top_level    = "dep-anyscale-${local.suffix}"
    blob         = "dep-anyblob-${local.suffix}"
    fic          = "dep-anyfic-${local.suffix}"
    storage_rbac = "dep-anystoragerbac-${local.suffix}"
    acr_rbac     = "dep-anyacrrbac-${local.suffix}"
    aks_ext      = "dep-anyaksext-${local.suffix}"
  }
}

resource "azurerm_marketplace_agreement" "anyscale_operator" {
  count = local.anyscale_platform_enabled ? 1 : 0

  publisher = var.anyscale_platform.plan_publisher
  offer     = var.anyscale_platform.plan_product
  plan      = var.anyscale_platform.plan_name
}

# The Anyscale portal currently exports an ARM template for the cloud resource
# and AKS marketplace extension. Keep that contract intact and wire it to the
# Terraform-managed AKS, storage, ACR, and operator identity with AzAPI.
resource "azapi_resource" "anyscale_platform" {
  count = local.anyscale_platform_enabled ? 1 : 0

  type                      = "Microsoft.Resources/deployments@2022-09-01"
  name                      = local.anyscale_platform_deployments.top_level
  parent_id                 = azurerm_resource_group.this.id
  schema_validation_enabled = false
  response_export_values    = ["properties.outputs", "properties.provisioningState"]
  body = jsonencode({
    properties = {
      mode     = "Incremental"
      template = jsondecode(file("${path.module}/templates/anyscale-platform-cloud.template.json"))
      parameters = {
        location = {
          value = azurerm_resource_group.this.location
        }
        cloudName = {
          value = local.anyscale_platform_cloud_name
        }
        aksClusterResourceId = {
          value = module.aks.cluster_id
        }
        extensionResourceName = {
          value = local.anyscale_platform_extension_name
        }
        controlPlaneUrl = {
          value = var.anyscale_platform.control_plane_url
        }
        authAudience = {
          value = var.anyscale_platform.auth_audience
        }
        extensionConfigurationSettings = {
          value = local.anyscale_platform_extension_configuration_settings
        }
        storageAccountName = {
          value = module.storage.storage_account_name
        }
        storageMode = {
          value = "existing"
        }
        storageAccountResourceId = {
          value = module.storage.storage_account_id
        }
        storageContainerName = {
          value = module.storage.container_name
        }
        workloadIdentityName = {
          value = module.identity.name
        }
        identityMode = {
          value = "existing"
        }
        identityResourceId = {
          value = module.identity.id
        }
        tagsByResource = {
          value = var.anyscale_platform.tags_by_resource
        }
        acrMode = {
          value = "existing"
        }
        acrName = {
          value = module.acr.acr_name
        }
        acrResourceId = {
          value = module.acr.acr_id
        }
        aksKubeletPrincipalId = {
          value = module.aks.kubelet_identity_object_id
        }
        planName = {
          value = var.anyscale_platform.plan_name
        }
        planPublisher = {
          value = var.anyscale_platform.plan_publisher
        }
        planProduct = {
          value = var.anyscale_platform.plan_product
        }
        releaseTrain = {
          value = var.anyscale_platform.release_train
        }
        manageAksKubeletAcrPullRoleAssignment = {
          value = false
        }
        storageBlobServiceDeploymentName = {
          value = local.anyscale_platform_deployments.blob
        }
        federatedIdentityDeploymentName = {
          value = local.anyscale_platform_deployments.fic
        }
        storageRoleAssignmentDeploymentName = {
          value = local.anyscale_platform_deployments.storage_rbac
        }
        acrRoleAssignmentsDeploymentName = {
          value = local.anyscale_platform_deployments.acr_rbac
        }
        aksExtensionDeploymentName = {
          value = local.anyscale_platform_deployments.aks_ext
        }
      }
    }
  })

  lifecycle {
    precondition {
      condition     = var.cluster_bootstrap.enabled
      error_message = "Anyscale platform deployment requires cluster_bootstrap.enabled=true so Terraform pre-creates the operator service account and baseline Helm bootstrap layer before the marketplace extension runs."
    }
  }

  depends_on = [
    module.aks,
    module.cluster_bootstrap,
    module.storage,
    module.identity,
    module.acr,
    azurerm_marketplace_agreement.anyscale_operator,
  ]
}
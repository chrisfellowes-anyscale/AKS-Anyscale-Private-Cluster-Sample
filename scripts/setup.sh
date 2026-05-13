#!/usr/bin/env bash
###############################################################################
# Idempotent orchestrator for the private AKS / Anyscale sample environment.
#
# Usage:
#   ./scripts/setup.sh preflight   # validate local tools, Azure auth, and .env
#   ./scripts/setup.sh tfvars      # render terraform.auto.tfvars.json from .env
#   ./scripts/setup.sh init        # terraform init
#   ./scripts/setup.sh validate    # fmt + validate + terraform native tests
#   ./scripts/setup.sh plan        # save tfplan
#   ./scripts/setup.sh apply       # apply saved plan and auto-run Anyscale post-config when Bastion kubeconfig + token are ready
#   ./scripts/setup.sh outputs     # print terraform outputs
#   ./scripts/setup.sh bastion     # open az aks bastion preview tunnel/shell
#   ./scripts/setup.sh bastion-tunnel start [--port 64430] # run a reusable Bastion tunnel to the private AKS API
#   ./scripts/setup.sh kubeconfig  # fetch Entra kubeconfig + kubelogin conversion
#   ./scripts/setup.sh kubeconfig-bastion [--admin] [--export] # write kubeconfig pointed at the Bastion tunnel
#   ./scripts/setup.sh anyscale-workspace-ready # patch the operator with the Azure CLI token and AKS instance types
#   ./scripts/setup.sh workspace-intro-smoke [--keep-workspace] # run the Anyscale Intro to Workspaces smoke test
#   ./scripts/setup.sh workspace-compute-ready [--terminate-workspaces] # create/reuse dedicated CPU/GPU workspaces and validate both node pools
#   ./scripts/setup.sh post        # explain the Terraform-managed Kubernetes bootstrap flow
#   ./scripts/setup.sh control-plane-egress-smoke # prove cluster egress to Anyscale control-plane endpoints
#   ./scripts/setup.sh validate-focused [--skip-observability] # run the live validation suite with pass/fail output
#   ./scripts/setup.sh validate-k8s # run DNS/egress/ingress/GPU validation through kubectl
#   ./scripts/setup.sh validate-observability # query Log Analytics for ContainerLogV2 + diagnostics
#   ./scripts/setup.sh functional-test # run validate-k8s after the Terraform-managed bootstrap is applied
#   ./scripts/setup.sh status      # summarize live Azure + Kubernetes status
#   ./scripts/setup.sh destroy     # terraform destroy using generated tfvars
#   ./scripts/setup.sh nuke [--yes] # force-delete the configured RG and purge residual state files
#   ./scripts/setup.sh all         # preflight + init + validate + plan + apply + outputs
###############################################################################
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"
GENERATED_TFVARS="${TERRAFORM_DIR}/terraform.auto.tfvars.json"
CACHE_DIR="${ROOT_DIR}/.cache"

LOG_INFO_PREFIX="setup"
# shellcheck source=./lib/log.sh
source "${ROOT_DIR}/scripts/lib/log.sh"
# shellcheck source=./lib/timeout.sh
source "${ROOT_DIR}/scripts/lib/timeout.sh"

cd "${TERRAFORM_DIR}"

HARNESS_DIR="${CACHE_DIR}/aks-anyscale-sample-harness"
VALIDATION_REPORT_ROOT="${CACHE_DIR}/focused-validation"
DEFAULT_BASTION_TUNNEL_PORT="64430"
DEFAULT_ANYSCALE_HOST="https://console.azure.anyscale.com"

SETUP_TIMEOUT_TERRAFORM_INIT_SECONDS="${SETUP_TIMEOUT_TERRAFORM_INIT_SECONDS:-900}"
SETUP_TIMEOUT_TERRAFORM_VALIDATE_SECONDS="${SETUP_TIMEOUT_TERRAFORM_VALIDATE_SECONDS:-600}"
SETUP_TIMEOUT_TERRAFORM_TEST_SECONDS="${SETUP_TIMEOUT_TERRAFORM_TEST_SECONDS:-1200}"
SETUP_TIMEOUT_TERRAFORM_PLAN_SECONDS="${SETUP_TIMEOUT_TERRAFORM_PLAN_SECONDS:-1800}"
SETUP_TIMEOUT_TERRAFORM_APPLY_SECONDS="${SETUP_TIMEOUT_TERRAFORM_APPLY_SECONDS:-7200}"
SETUP_TIMEOUT_TERRAFORM_DESTROY_SECONDS="${SETUP_TIMEOUT_TERRAFORM_DESTROY_SECONDS:-7200}"
SETUP_TIMEOUT_HELM_SECONDS="${SETUP_TIMEOUT_HELM_SECONDS:-900}"
SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS="${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS:-180}"
SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS="${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS:-1800}"
SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS="${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS:-900}"
SETUP_TIMEOUT_AZURE_EXTENSION_SECONDS="${SETUP_TIMEOUT_AZURE_EXTENSION_SECONDS:-300}"
SETUP_TIMEOUT_AZURE_COMMAND_SECONDS="${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS:-180}"
SETUP_TIMEOUT_KUBECTL_READY_SECONDS="${SETUP_TIMEOUT_KUBECTL_READY_SECONDS:-20}"

FOCUSED_VALIDATION_RUN_ID=""
FOCUSED_VALIDATION_RESULTS=()
FOCUSED_VALIDATION_PASS_COUNT=0
FOCUSED_VALIDATION_FAIL_COUNT=0
FOCUSED_VALIDATION_SKIP_COUNT=0
ANYSCALE_WORKSPACE_WAIT_RESULT=""

escape_env_double_quoted() {
  printf '%s' "$1" | sed 's/[\\"]/\\&/g'
}

set_env_file_var() {
  local name="$1"
  local value="$2"
  local escaped_value tmp_file

  escaped_value="$(escape_env_double_quoted "${value}")"
  mkdir -p "${CACHE_DIR}"
  tmp_file="${CACHE_DIR}/.env.sync.$$"

  awk -v name="${name}" -v line="${name}=\"${escaped_value}\"" '
    index($0, name "=") == 1 { print line; updated = 1; next }
    { print }
    END {
      if (!updated) {
        print line
      }
    }
  ' "${ENV_FILE}" > "${tmp_file}"

  mv "${tmp_file}" "${ENV_FILE}"
}

resource_group_name() {
  printf 'rg-%s-%s-%s\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

default_anyscale_host() {
  printf '%s\n' "${DEFAULT_ANYSCALE_HOST}"
}

# Anyscale uses three related identifiers for the same cloud:
# - cloud resource name: the short leaf name under the resource group
# - cloud name: the canonical path expected by the Anyscale CLI env var
# - cloud ARM id: the Azure resource ID used by az/terraform import flows
default_anyscale_cloud_name() {
  printf '/subscriptions/%s/resourcegroups/%s/providers/anyscale.platform/clouds/%s\n' \
    "${TF_VAR_azure_subscription_id}" \
    "$(resource_group_name)" \
    "$(default_anyscale_cloud_resource_name)"
}

default_anyscale_cloud_resource_name() {
  printf '%s-%s-%s\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

default_anyscale_cloud_arm_id() {
  printf '/subscriptions/%s/resourceGroups/%s/providers/Anyscale.Platform/clouds/%s\n' \
    "${TF_VAR_azure_subscription_id}" \
    "$(resource_group_name)" \
    "$(default_anyscale_cloud_resource_name)"
}

anyscale_cloud_resource_azure_id() {
  local resource_group cloud_name
  resource_group="$(resource_group_name)"
  cloud_name="$(default_anyscale_cloud_resource_name)"

  printf '/subscriptions/%s/resourceGroups/%s/providers/Anyscale.Platform/clouds/%s/cloudResources/default\n' \
    "${TF_VAR_azure_subscription_id}" \
    "${resource_group}" \
    "${cloud_name}"
}

sync_anyscale_cli_env() {
  local derived_cloud_name derived_cloud_resource_name derived_cloud_arm_id
  local cloud_resource_azure_id live_cloud_deployment_id

  [[ -n "${TF_VAR_project:-}" ]] || return 0
  [[ -n "${TF_VAR_environment:-}" ]] || return 0
  [[ -n "${TF_VAR_region_short:-}" ]] || return 0
  [[ -n "${TF_VAR_azure_subscription_id:-}" ]] || return 0

  if [[ -z "${ANYSCALE_HOST:-}" || "${ANYSCALE_HOST}" == "https://console.anyscale.com" ]]; then
    ANYSCALE_HOST="$(default_anyscale_host)"
    export ANYSCALE_HOST
    set_env_file_var "ANYSCALE_HOST" "${ANYSCALE_HOST}"
    log "Auto-populated ANYSCALE_HOST=${ANYSCALE_HOST}"
  fi

  derived_cloud_name="$(default_anyscale_cloud_name)"
  derived_cloud_resource_name="$(default_anyscale_cloud_resource_name)"
  derived_cloud_arm_id="$(default_anyscale_cloud_arm_id)"
  if [[ -z "${ANYSCALE_CLOUD_NAME:-}" || "${ANYSCALE_CLOUD_NAME}" == "my-aks-cloud" || "${ANYSCALE_CLOUD_NAME}" == "${derived_cloud_resource_name}" || "${ANYSCALE_CLOUD_NAME}" == "${derived_cloud_arm_id}" ]]; then
    ANYSCALE_CLOUD_NAME="${derived_cloud_name}"
    export ANYSCALE_CLOUD_NAME
    set_env_file_var "ANYSCALE_CLOUD_NAME" "${ANYSCALE_CLOUD_NAME}"
    log "Auto-populated ANYSCALE_CLOUD_NAME=${ANYSCALE_CLOUD_NAME}"
  fi

  command -v az >/dev/null 2>&1 || return 0

  cloud_resource_azure_id="$(anyscale_cloud_resource_azure_id)"
  live_cloud_deployment_id="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az resource show \
    --ids "${cloud_resource_azure_id}" \
    --query 'properties.cloudResourceId' \
    --output tsv \
    --only-show-errors 2>/dev/null || true)"

  if [[ -n "${live_cloud_deployment_id}" && "${live_cloud_deployment_id}" != "${ANYSCALE_CLOUD_DEPLOYMENT_ID:-}" ]]; then
    ANYSCALE_CLOUD_DEPLOYMENT_ID="${live_cloud_deployment_id}"
    export ANYSCALE_CLOUD_DEPLOYMENT_ID
    set_env_file_var "ANYSCALE_CLOUD_DEPLOYMENT_ID" "${ANYSCALE_CLOUD_DEPLOYMENT_ID}"
    log "Auto-populated ANYSCALE_CLOUD_DEPLOYMENT_ID from Azure resource ${ANYSCALE_CLOUD_NAME}"
  fi
}

clear_anyscale_cloud_deployment_id() {
  [[ -f "${ENV_FILE}" ]] || return 0
  [[ -n "${ANYSCALE_CLOUD_DEPLOYMENT_ID:-}" ]] || return 0

  ANYSCALE_CLOUD_DEPLOYMENT_ID=""
  export ANYSCALE_CLOUD_DEPLOYMENT_ID
  set_env_file_var "ANYSCALE_CLOUD_DEPLOYMENT_ID" ""
  log "Cleared ANYSCALE_CLOUD_DEPLOYMENT_ID after Anyscale cloud removal"
}

canonicalize_gpu_pool_configs_json() {
  local raw_value="$1"
  local candidate_json

  if candidate_json="$(jq -c . <<<"${raw_value}" 2>/dev/null)"; then
    printf '%s\n' "${candidate_json}"
    return 0
  fi

  candidate_json="$(printf '%s' "${raw_value}" \
    | sed -E 's/([{,])([A-Za-z0-9_]+):/\1"\2":/g' \
    | sed -E 's/"(name|vm_size|product_name|gpu_count)":([A-Za-z0-9_.-]+)/"\1":"\2"/g')"

  jq -c . <<<"${candidate_json}" 2>/dev/null || return 1
}

normalize_gpu_pool_configs_min_count() {
  [[ -n "${TF_VAR_gpu_pool_configs:-}" ]] || return 0

  local canonical_gpu_pool_configs normalized_gpu_pool_configs
  canonical_gpu_pool_configs="$(canonicalize_gpu_pool_configs_json "${TF_VAR_gpu_pool_configs}")" \
    || die "TF_VAR_gpu_pool_configs must be valid JSON or Terraform-style object syntax."
  normalized_gpu_pool_configs="$(jq -c 'with_entries(.value.min_count |= (if . < 1 then 1 else . end))' <<<"${canonical_gpu_pool_configs}")"

  if [[ "${normalized_gpu_pool_configs}" != "${TF_VAR_gpu_pool_configs}" ]]; then
    TF_VAR_gpu_pool_configs="${normalized_gpu_pool_configs}"
    export TF_VAR_gpu_pool_configs
    set_env_file_var "TF_VAR_gpu_pool_configs" "${TF_VAR_gpu_pool_configs}"
    log "Normalized TF_VAR_gpu_pool_configs so every GPU pool min_count is at least 1"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found on PATH."
}

load_env() {
  [[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}. Copy .env-template to .env and fill in the required values."
  # shellcheck disable=SC1090
  set -a
  source "${ENV_FILE}"
  set +a

  if [[ -z "${ANYSCALE_HOST:-}" ]]; then
    ANYSCALE_HOST="$(default_anyscale_host)"
    export ANYSCALE_HOST
  fi
}

require_env_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Missing required environment variable ${name} in ${ENV_FILE}."
}

render_tfvars() {
  load_env

  local required_env_vars=(
    TF_VAR_azure_subscription_id
    TF_VAR_azure_tenant_id
    TF_VAR_project
    TF_VAR_environment
    TF_VAR_azure_location
    TF_VAR_region_short
    TF_VAR_aks_sku_tier
    TF_VAR_system_vm_size
    TF_VAR_cpu_vm_size
    TF_VAR_service_cidr
    TF_VAR_dns_service_ip
    TF_VAR_anyscale_operator_namespace
    TF_VAR_anyscale_operator_serviceaccount
    TF_VAR_storage_replication_type
    TF_VAR_ampls_ingestion_access_mode
    TF_VAR_ampls_query_access_mode
    TF_VAR_container_insights_data_collection_interval
    TF_VAR_container_insights_namespace_filtering_mode
    TF_VAR_anyscale_operator_identity
    TF_VAR_vnet_address_space
    TF_VAR_subnet_cidrs
    TF_VAR_dns_forwarding_rules
    TF_VAR_anyscale_fqdns
    TF_VAR_azure_identity_fqdns
    TF_VAR_azure_monitor_fqdns
    TF_VAR_container_registry_fqdns
    TF_VAR_availability_zones
    TF_VAR_system_node_pool_min_count
    TF_VAR_system_node_pool_max_count
    TF_VAR_gpu_pool_configs
    TF_VAR_kubernetes_version
    TF_VAR_storage_cors_rule
    TF_VAR_acr_zone_redundancy_enabled
    TF_VAR_log_analytics_retention_days
    TF_VAR_log_analytics_internet_ingestion_enabled
    TF_VAR_log_analytics_internet_query_enabled
    TF_VAR_ampls_enabled
    TF_VAR_container_insights_v2_enabled
    TF_VAR_container_insights_streams
    TF_VAR_container_insights_namespaces
    TF_VAR_terraform_managed_diagnostic_settings_enabled
    TF_VAR_tags
  )

  local env_name
  for env_name in "${required_env_vars[@]}"; do
    require_env_var "${env_name}"
  done

  normalize_gpu_pool_configs_min_count
  sync_anyscale_cli_env

  jq -n \
    --arg azure_subscription_id "${TF_VAR_azure_subscription_id}" \
    --arg azure_tenant_id "${TF_VAR_azure_tenant_id}" \
    --arg project "${TF_VAR_project}" \
    --arg environment "${TF_VAR_environment}" \
    --arg azure_location "${TF_VAR_azure_location}" \
    --arg region_short "${TF_VAR_region_short}" \
    --arg aks_sku_tier "${TF_VAR_aks_sku_tier}" \
    --arg system_vm_size "${TF_VAR_system_vm_size}" \
    --arg cpu_vm_size "${TF_VAR_cpu_vm_size}" \
    --arg service_cidr "${TF_VAR_service_cidr}" \
    --arg dns_service_ip "${TF_VAR_dns_service_ip}" \
    --arg anyscale_operator_namespace "${TF_VAR_anyscale_operator_namespace}" \
    --arg anyscale_operator_serviceaccount "${TF_VAR_anyscale_operator_serviceaccount}" \
    --arg storage_replication_type "${TF_VAR_storage_replication_type}" \
    --arg ampls_ingestion_access_mode "${TF_VAR_ampls_ingestion_access_mode}" \
    --arg ampls_query_access_mode "${TF_VAR_ampls_query_access_mode}" \
    --arg container_insights_data_collection_interval "${TF_VAR_container_insights_data_collection_interval}" \
    --arg container_insights_namespace_filtering_mode "${TF_VAR_container_insights_namespace_filtering_mode}" \
    --argjson anyscale_operator_identity "${TF_VAR_anyscale_operator_identity}" \
    --argjson vnet_address_space "${TF_VAR_vnet_address_space}" \
    --argjson subnet_cidrs "${TF_VAR_subnet_cidrs}" \
    --argjson dns_forwarding_rules "${TF_VAR_dns_forwarding_rules}" \
    --argjson anyscale_fqdns "${TF_VAR_anyscale_fqdns}" \
    --argjson azure_identity_fqdns "${TF_VAR_azure_identity_fqdns}" \
    --argjson azure_monitor_fqdns "${TF_VAR_azure_monitor_fqdns}" \
    --argjson container_registry_fqdns "${TF_VAR_container_registry_fqdns}" \
    --argjson availability_zones "${TF_VAR_availability_zones}" \
    --argjson system_node_pool_min_count "${TF_VAR_system_node_pool_min_count}" \
    --argjson system_node_pool_max_count "${TF_VAR_system_node_pool_max_count}" \
    --argjson gpu_pool_configs "${TF_VAR_gpu_pool_configs}" \
    --argjson kubernetes_version "${TF_VAR_kubernetes_version}" \
    --argjson storage_cors_rule "${TF_VAR_storage_cors_rule}" \
    --argjson acr_zone_redundancy_enabled "${TF_VAR_acr_zone_redundancy_enabled}" \
    --argjson log_analytics_retention_days "${TF_VAR_log_analytics_retention_days}" \
    --argjson log_analytics_internet_ingestion_enabled "${TF_VAR_log_analytics_internet_ingestion_enabled}" \
    --argjson log_analytics_internet_query_enabled "${TF_VAR_log_analytics_internet_query_enabled}" \
    --argjson ampls_enabled "${TF_VAR_ampls_enabled}" \
    --argjson container_insights_v2_enabled "${TF_VAR_container_insights_v2_enabled}" \
    --argjson container_insights_streams "${TF_VAR_container_insights_streams}" \
    --argjson container_insights_namespaces "${TF_VAR_container_insights_namespaces}" \
    --argjson terraform_managed_diagnostic_settings_enabled "${TF_VAR_terraform_managed_diagnostic_settings_enabled}" \
    --argjson tags "${TF_VAR_tags}" \
    '{
      azure_subscription_id: $azure_subscription_id,
      azure_tenant_id: $azure_tenant_id,
      project: $project,
      environment: $environment,
      azure_location: $azure_location,
      region_short: $region_short,
      aks_sku_tier: $aks_sku_tier,
      system_vm_size: $system_vm_size,
      cpu_vm_size: $cpu_vm_size,
      service_cidr: $service_cidr,
      dns_service_ip: $dns_service_ip,
      anyscale_operator_namespace: $anyscale_operator_namespace,
      anyscale_operator_serviceaccount: $anyscale_operator_serviceaccount,
      storage_replication_type: $storage_replication_type,
      ampls_ingestion_access_mode: $ampls_ingestion_access_mode,
      ampls_query_access_mode: $ampls_query_access_mode,
      container_insights_data_collection_interval: $container_insights_data_collection_interval,
      container_insights_namespace_filtering_mode: $container_insights_namespace_filtering_mode,
      anyscale_operator_identity: $anyscale_operator_identity,
      vnet_address_space: $vnet_address_space,
      subnet_cidrs: $subnet_cidrs,
      dns_forwarding_rules: $dns_forwarding_rules,
      anyscale_fqdns: $anyscale_fqdns,
      azure_identity_fqdns: $azure_identity_fqdns,
      azure_monitor_fqdns: $azure_monitor_fqdns,
      container_registry_fqdns: $container_registry_fqdns,
      availability_zones: $availability_zones,
      system_node_pool_min_count: $system_node_pool_min_count,
      system_node_pool_max_count: $system_node_pool_max_count,
      gpu_pool_configs: $gpu_pool_configs,
      kubernetes_version: $kubernetes_version,
      storage_cors_rule: $storage_cors_rule,
      acr_zone_redundancy_enabled: $acr_zone_redundancy_enabled,
      log_analytics_retention_days: $log_analytics_retention_days,
      log_analytics_internet_ingestion_enabled: $log_analytics_internet_ingestion_enabled,
      log_analytics_internet_query_enabled: $log_analytics_internet_query_enabled,
      ampls_enabled: $ampls_enabled,
      container_insights_v2_enabled: $container_insights_v2_enabled,
      container_insights_streams: $container_insights_streams,
      container_insights_namespaces: $container_insights_namespaces,
      terraform_managed_diagnostic_settings_enabled: $terraform_managed_diagnostic_settings_enabled,
      tags: $tags
    }' > "${GENERATED_TFVARS}"

  log "Rendered ${GENERATED_TFVARS}"
}

terraform_output_raw() {
  terraform output -raw "$1"
}

marketplace_agreement_resource_id() {
  printf '/subscriptions/%s/providers/Microsoft.MarketplaceOrdering/agreements/%s/offers/%s/plans/%s\n' \
    "${TF_VAR_azure_subscription_id}" \
    "anyscale1750870039553" \
    "anyscale-operator-aks" \
    "anyscale-operator"
}

anyscale_platform_deployment_name() {
  printf 'dep-anyscale-%s-%s-%s\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

anyscale_platform_deployment_resource_id() {
  local resource_group deployment_name
  resource_group="$(resource_group_name)"
  deployment_name="$(anyscale_platform_deployment_name)"

  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Resources/deployments/%s\n' \
    "${TF_VAR_azure_subscription_id}" \
    "${resource_group}" \
    "${deployment_name}"
}

anyscale_platform_enabled() {
  if [[ -z "${TF_VAR_anyscale_platform:-}" ]]; then
    return 0
  fi

  jq -e 'if type == "object" and has("enabled") then .enabled else true end' <<<"${TF_VAR_anyscale_platform}" >/dev/null 2>&1
}

ensure_anyscale_marketplace_agreement_state() {
  local resource_address="azurerm_marketplace_agreement.anyscale_operator[0]"
  local agreement_id

  anyscale_platform_enabled || return 0

  agreement_id="$(marketplace_agreement_resource_id)"

  if terraform state show "${resource_address}" >/dev/null 2>&1; then
    return 0
  fi

  if run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az rest \
    --method get \
    --uri "https://management.azure.com${agreement_id}?api-version=2021-01-01" \
    --only-show-errors >/dev/null 2>&1; then
    log "Importing existing Anyscale marketplace agreement into Terraform state"
    terraform import "${resource_address}" "${agreement_id}" >/dev/null
  fi
}

ensure_anyscale_platform_deployment_state() {
  local resource_address="azapi_resource.anyscale_platform[0]"
  local resource_group deployment_name deployment_id

  anyscale_platform_enabled || return 0

  resource_group="$(resource_group_name)"
  deployment_name="$(anyscale_platform_deployment_name)"
  deployment_id="$(anyscale_platform_deployment_resource_id)"

  if terraform state show "${resource_address}" >/dev/null 2>&1; then
    return 0
  fi

  if run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az deployment group show \
    --resource-group "${resource_group}" \
    --name "${deployment_name}" \
    --only-show-errors >/dev/null 2>&1; then
    log "Importing existing Anyscale ARM deployment into Terraform state"
    terraform import "${resource_address}" "${deployment_id}" >/dev/null
  fi
}

ensure_harness_dir() {
  mkdir -p "${HARNESS_DIR}"
}

harness_state_file() {
  ensure_harness_dir
  printf '%s/%s\n' "${HARNESS_DIR}" "$1"
}

bastion_tunnel_pidfile() {
  harness_state_file "bastion-tunnel.pid"
}

bastion_tunnel_portfile() {
  harness_state_file "bastion-tunnel.port"
}

bastion_tunnel_logfile() {
  harness_state_file "bastion-tunnel.log"
}

bastion_kubeconfig_path() {
  harness_state_file "kubeconfig.bastion"
}

bastion_admin_kubeconfig_path() {
  harness_state_file "kubeconfig.bastion.admin"
}

pid_from_file() {
  local pid_file="$1"
  [[ -f "${pid_file}" ]] || return 0
  tr -d '[:space:]' < "${pid_file}"
}

pid_is_running() {
  local pid="${1:-}"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

listener_is_ready() {
  local port="$1"
  lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
}

wait_for_local_listener() {
  local port="$1"
  local attempts="${2:-30}"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if listener_is_ready "${port}"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

listener_pids() {
  local port="$1"
  lsof -t -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
}

first_listener_pid() {
  local port="$1"
  local listener_pid

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    printf '%s\n' "${listener_pid}"
    return 0
  done

  return 1
}

pid_command_line() {
  local pid="$1"
  ps -p "${pid}" -o command= 2>/dev/null || true
}

pid_is_bastion_tunnel() {
  local pid="$1"
  local command_line

  command_line="$(pid_command_line "${pid}")"
  [[ "${command_line}" == *"azure.cli network bastion tunnel"* ]]
}

port_listeners_are_bastion_tunnels() {
  local port="$1"
  local listener_pid found=false

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    found=true
    if ! pid_is_bastion_tunnel "${listener_pid}"; then
      return 1
    fi
  done

  [[ "${found}" == true ]]
}

wait_for_listener_shutdown() {
  local port="$1"
  local attempts="${2:-10}"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if ! listener_is_ready "${port}"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

stop_bastion_listeners_on_port() {
  local port="$1"
  local listener_pid stopped=false

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    if ! pid_is_bastion_tunnel "${listener_pid}"; then
      continue
    fi
    kill "${listener_pid}" 2>/dev/null || true
    stopped=true
  done

  if [[ "${stopped}" == true ]]; then
    wait_for_listener_shutdown "${port}" 10 || true
    return 0
  fi

  return 1
}

kubectl_readyz() {
  local kubeconfig_file="${1:-}"

  if [[ -n "${kubeconfig_file}" ]]; then
    KUBECONFIG="${kubeconfig_file}" kubectl --request-timeout="${SETUP_TIMEOUT_KUBECTL_READY_SECONDS}s" get --raw=/readyz >/dev/null
    return 0
  fi

  kubectl --request-timeout="${SETUP_TIMEOUT_KUBECTL_READY_SECONDS}s" get --raw=/readyz >/dev/null
}

clear_runtime_files() {
  rm -f "$@"
}

focused_validation_report_dir() {
  printf '%s/%s\n' "${VALIDATION_REPORT_ROOT}" "${FOCUSED_VALIDATION_RUN_ID}"
}

focused_validation_display_path() {
  local path="$1"
  if [[ "${path}" == "${ROOT_DIR}"/* ]]; then
    printf '%s\n' "${path#${ROOT_DIR}/}"
    return 0
  fi
  printf '%s\n' "${path}"
}

reset_focused_validation_run() {
  FOCUSED_VALIDATION_RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
  FOCUSED_VALIDATION_RESULTS=()
  FOCUSED_VALIDATION_PASS_COUNT=0
  FOCUSED_VALIDATION_FAIL_COUNT=0
  FOCUSED_VALIDATION_SKIP_COUNT=0
  mkdir -p "$(focused_validation_report_dir)"
}

record_focused_validation_result() {
  local status="$1"
  local check_id="$2"
  local label="$3"
  local logfile="$4"

  FOCUSED_VALIDATION_RESULTS+=("${status}|${check_id}|${label}|${logfile}")
  case "${status}" in
    PASS) ((FOCUSED_VALIDATION_PASS_COUNT+=1)) ;;
    FAIL) ((FOCUSED_VALIDATION_FAIL_COUNT+=1)) ;;
    SKIP) ((FOCUSED_VALIDATION_SKIP_COUNT+=1)) ;;
  esac
}

run_focused_validation_check() {
  local check_id="$1"
  local label="$2"
  shift 2

  local logfile display_logfile
  logfile="$(focused_validation_report_dir)/${check_id}.log"
  display_logfile="$(focused_validation_display_path "${logfile}")"

  printf '\n==> %s\n' "${label}"
  if "$@" > >(tee "${logfile}") 2>&1; then
    record_focused_validation_result "PASS" "${check_id}" "${label}" "${display_logfile}"
    printf '[PASS] %s\n' "${label}"
    return 0
  fi

  record_focused_validation_result "FAIL" "${check_id}" "${label}" "${display_logfile}"
  printf '[FAIL] %s\n' "${label}"
  printf '       log: %s\n' "${display_logfile}"
  return 1
}

skip_focused_validation_check() {
  local check_id="$1"
  local label="$2"
  local reason="$3"
  local logfile display_logfile

  logfile="$(focused_validation_report_dir)/${check_id}.log"
  display_logfile="$(focused_validation_display_path "${logfile}")"
  printf '%s\n' "${reason}" > "${logfile}"
  record_focused_validation_result "SKIP" "${check_id}" "${label}" "${display_logfile}"
  printf '[SKIP] %s\n' "${label}"
  printf '       reason: %s\n' "${reason}"
}

write_focused_validation_summary() {
  local summary_file display_summary_file result status check_id label logfile
  summary_file="$(focused_validation_report_dir)/summary.txt"
  display_summary_file="$(focused_validation_display_path "${summary_file}")"

  {
    printf 'Focused validation run: %s\n' "${FOCUSED_VALIDATION_RUN_ID}"
    printf '%-6s %-36s %s\n' "STATUS" "CHECK" "LOG"
    printf '%-6s %-36s %s\n' "------" "------------------------------------" "---"
    for result in "${FOCUSED_VALIDATION_RESULTS[@]}"; do
      IFS='|' read -r status check_id label logfile <<<"${result}"
      printf '%-6s %-36s %s\n' "${status}" "${label}" "${logfile}"
    done
    printf '\npass=%s fail=%s skip=%s\n' \
      "${FOCUSED_VALIDATION_PASS_COUNT}" \
      "${FOCUSED_VALIDATION_FAIL_COUNT}" \
      "${FOCUSED_VALIDATION_SKIP_COUNT}"
  } | tee "${summary_file}"

  log "Focused validation summary written to ${display_summary_file}"
}

ensure_bastion_extensions() {
  log "Ensuring az aks-preview + bastion extensions"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_EXTENSION_SECONDS}" az extension add --name aks-preview --upgrade --yes --only-show-errors >/dev/null 2>&1 || true
  run_with_timeout "${SETUP_TIMEOUT_AZURE_EXTENSION_SECONDS}" az extension add --name bastion --upgrade --yes --only-show-errors >/dev/null 2>&1 || true
}

resolve_aks_context() {
  local field="$1"
  terraform_output_raw "${field}"
}

resolve_aks_cluster_id() {
  local rg cluster
  rg="$(resolve_aks_context resource_group_name)"
  cluster="$(resolve_aks_context aks_cluster_name)"
  [[ -n "${rg}" && -n "${cluster}" ]] || die "Terraform outputs are missing. Run ./scripts/setup.sh apply first."
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks show --resource-group "${rg}" --name "${cluster}" --query id -o tsv --only-show-errors
}

use_bastion_kubeconfig_if_present() {
  local kubeconfig_file pidfile portfile pid port current_server
  kubeconfig_file="$(bastion_kubeconfig_path)"

  pidfile="$(bastion_tunnel_pidfile)"
  portfile="$(bastion_tunnel_portfile)"
  pid="$(pid_from_file "${pidfile}")"
  port="$(cat "${portfile}" 2>/dev/null || true)"

  if [[ -f "${kubeconfig_file}" && -n "${port}" ]] \
    && pid_is_running "${pid}" \
    && listener_is_ready "${port}"; then
    current_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
    if [[ ! "${current_server}" =~ ^https://(127\.0\.0\.1|localhost):[0-9]+/?$ ]]; then
      export KUBECONFIG="${kubeconfig_file}"
    fi
  elif [[ -z "${KUBECONFIG:-}" && -f "${kubeconfig_file}" ]]; then
    export KUBECONFIG="${kubeconfig_file}"
  fi
}

require_cluster_kubectl_access() {
  require_cmd kubectl
  use_bastion_kubeconfig_if_present
  ensure_kubelogin_kubeconfig
  kubectl_readyz >/dev/null 2>&1 || die "kubectl cannot reach the cluster. Start a Bastion tunnel with ./scripts/setup.sh bastion-tunnel start and set KUBECONFIG via ./scripts/setup.sh kubeconfig-bastion --export."
}

anyscale_cli_bin() {
  printf '%s/.venv/bin/anyscale\n' "${ROOT_DIR}"
}

require_anyscale_cli() {
  local cli_bin
  cli_bin="$(anyscale_cli_bin)"
  [[ -x "${cli_bin}" ]] || die "Anyscale CLI not found at ${cli_bin}. Install it with uv and the repo-local .venv first."
}

anyscale_operator_release_json() {
  local namespace="$1"
  helm list -n "${namespace}" -o json
}

anyscale_operator_release_name() {
  local release_json="$1"
  jq -r 'map(select(.chart | startswith("anyscale-operator-")))[0].name // empty' <<<"${release_json}"
}

anyscale_operator_chart_version() {
  local release_json="$1"
  jq -r 'map(select(.chart | startswith("anyscale-operator-")))[0].chart // empty | sub("^anyscale-operator-"; "")' <<<"${release_json}"
}

anyscale_operator_auth_audience() {
  local release_name="$1"
  local namespace="$2"
  local audience

  audience="$(helm get values "${release_name}" -n "${namespace}" -o json | jq -r '.global.auth.audience // empty')"
  if [[ -n "${audience}" ]]; then
    printf '%s\n' "${audience}"
    return 0
  fi

  printf '%s\n' 'api://086bc555-6989-4362-ba30-fded273e432b/.default'
}

###############################################################################
preflight() {
  log "Checking required CLI tools..."
  for tool_name in az terraform kubectl kubelogin helm jq; do require_cmd "${tool_name}"; done
  render_tfvars

  log "Checking az login..."
  az account show --only-show-errors >/dev/null 2>&1 || die "Not logged in. Run: az login --tenant <tenant-id>"

  local sub_id
  sub_id="${TF_VAR_azure_subscription_id}"
  log "Setting active subscription to ${sub_id}"
  az account set --subscription "${sub_id}" --only-show-errors
}

###############################################################################
tf_init() {
  render_tfvars
  log "terraform init"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_INIT_SECONDS}" terraform init -input=false
}

###############################################################################
validate() {
  render_tfvars
  log "terraform fmt"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_VALIDATE_SECONDS}" terraform fmt -recursive -check
  log "terraform validate"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_VALIDATE_SECONDS}" terraform validate
  log "terraform test (plan-only)"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_TEST_SECONDS}" terraform test -filter=tests/plan.tftest.hcl
  log "terraform test (identity contract)"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_TEST_SECONDS}" terraform test -filter=tests/identity_contract.tftest.hcl
  log "terraform test (private-mode contract)"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_TEST_SECONDS}" terraform test -filter=tests/private_mode.tftest.hcl
}

###############################################################################
plan() {
  render_tfvars
  ensure_anyscale_marketplace_agreement_state
  ensure_anyscale_platform_deployment_state
  log "terraform plan -> tfplan"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_PLAN_SECONDS}" terraform plan -input=false -out=tfplan
}

###############################################################################
apply() {
  render_tfvars
  ensure_anyscale_marketplace_agreement_state
  ensure_anyscale_platform_deployment_state
  if [[ ! -f tfplan ]]; then plan; fi
  log "terraform apply tfplan (this will take ~20 min - Azure Firewall + AKS)"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_APPLY_SECONDS}" terraform apply -auto-approve tfplan
  sync_anyscale_cli_env
  rm -f tfplan
  maybe_auto_anyscale_workspace_ready
}

maybe_auto_anyscale_workspace_ready() {
  if [[ -z "${ANYSCALE_CLI_TOKEN:-}" ]]; then
    warn "Skipping automatic anyscale-workspace-ready because ANYSCALE_CLI_TOKEN is unset."
    return 0
  fi

  if ! command -v kubectl >/dev/null 2>&1 || ! command -v kubelogin >/dev/null 2>&1 || ! command -v helm >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    warn "Skipping automatic anyscale-workspace-ready because kubectl, kubelogin, helm, or jq is unavailable."
    return 0
  fi

  if [[ ! -x "$(anyscale_cli_bin)" ]]; then
    warn "Skipping automatic anyscale-workspace-ready because the repo-local Anyscale CLI is not installed."
    return 0
  fi

  use_bastion_kubeconfig_if_present
  ensure_kubelogin_kubeconfig

  if ! kubectl_readyz >/dev/null 2>&1; then
    warn "Skipping automatic anyscale-workspace-ready because kubectl cannot reach the private AKS API. Start the Bastion tunnel, export the Bastion kubeconfig, then rerun ./scripts/setup.sh anyscale-workspace-ready."
    return 0
  fi

  log "Auto-running anyscale-workspace-ready because Bastion-backed Kubernetes access and ANYSCALE_CLI_TOKEN are already available"
  anyscale_workspace_ready
}

###############################################################################
outputs() {
  load_env
  sync_anyscale_cli_env
  terraform output
}

###############################################################################
# Read-only environment status. Kubernetes checks require an active Bastion
# tunnel because the AKS API server is private.
###############################################################################
status() {
  load_env
  sync_anyscale_cli_env

  local resource_group cluster private_fqdn
  resource_group="$(terraform_output_raw resource_group_name)"
  cluster="$(terraform_output_raw aks_cluster_name)"
  private_fqdn="$(terraform_output_raw aks_private_fqdn)"

  [[ -n "${resource_group}" && -n "${cluster}" ]] || die "Terraform outputs are missing. Run ./scripts/setup.sh apply first."

  log "Terraform deployment"
  printf '  Resource group: %s\n' "${resource_group}"
  printf '  AKS cluster:    %s\n' "${cluster}"
  printf '  Private FQDN:   %s\n' "${private_fqdn}"

  log "Anyscale CLI metadata"
  printf '  Host:               %s\n' "${ANYSCALE_HOST:-$(default_anyscale_host)}"
  printf '  Cloud name:         %s\n' "${ANYSCALE_CLOUD_NAME:-<unset>}"
  printf '  Cloud deployment:   %s\n' "${ANYSCALE_CLOUD_DEPLOYMENT_ID:-<unset>}"

  log "Azure AKS state"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks show \
    --resource-group "${resource_group}" \
    --name "${cluster}" \
    --query '{provisioningState:provisioningState,power:powerState.code,private:apiServerAccessProfile.enablePrivateCluster,vnetIntegration:apiServerAccessProfile.enableVnetIntegration,kubernetesVersion:kubernetesVersion}' \
    --output table \
    --only-show-errors

  log "Node pools"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks nodepool list \
    --resource-group "${resource_group}" \
    --cluster-name "${cluster}" \
    --query '[].{name:name,mode:mode,vmSize:vmSize,count:count,min:minCount,max:maxCount,state:provisioningState}' \
    --output table \
    --only-show-errors

  log "Enterprise DNS path"
  printf '  VNet DNS servers:             %s\n' "$(terraform output -json vnet_dns_servers | jq -r 'join(", ")')"
  printf '  DNS resolver inbound IP:      %s\n' "$(terraform output -raw dns_resolver_inbound_endpoint_ip)"
  printf '  Azure Firewall private IP:    %s\n' "$(terraform output -raw firewall_private_ip)"

  if kubectl get nodes --request-timeout=15s >/dev/null 2>&1; then
    log "Kubernetes nodes"
    kubectl get nodes -o wide

    log "Helm add-ons"
    helm list -n gpu-resources || true
    helm list -n ingress-nginx || true

    log "Ingress service"
    kubectl get service -n ingress-nginx ingress-nginx-controller -o wide || true
  else
    log "kubectl cannot reach the private API server from this shell. Start the Bastion shell with ./scripts/setup.sh bastion, run ./scripts/setup.sh kubeconfig inside it, then rerun status."
  fi
}

###############################################################################
# Open a private AKS API shell through Azure Bastion (az aks bastion preview).
# Docs: https://learn.microsoft.com/azure/bastion/bastion-connect-to-aks-private-cluster
###############################################################################
bastion() {
  local use_admin=false
  if [[ "${1:-}" == "--admin" ]]; then
    use_admin=true
  fi

  local rg cluster bastion_id
  rg="$(terraform output -raw resource_group_name)"
  cluster="$(terraform output -raw aks_cluster_name)"
  bastion_id="$(terraform output -json | jq -r '.aks_bastion_connect_command.value' | grep -oE '/subscriptions/[^ ]+/bastionHosts/[^ ]+')"

  ensure_bastion_extensions

  if [[ "${use_admin}" == true ]]; then
    warn "Opening break-glass admin Bastion shell. Prefer non-admin kubelogin access for normal validation."
    az aks bastion --name "${cluster}" --resource-group "${rg}" --admin --bastion "${bastion_id}" --yes
  else
    log "Opening Entra-backed Bastion shell. Run setup.sh kubeconfig inside the shell if kubectl needs conversion."
    az aks bastion --name "${cluster}" --resource-group "${rg}" --bastion "${bastion_id}" --yes
  fi
}

###############################################################################
# Run a noninteractive Bastion tunnel that agents and scripts can reuse without
# entering the interactive `az aks bastion` subshell wrapper.
###############################################################################
bastion_tunnel() {
  require_cmd az
  require_cmd lsof

  local action="${1:-start}"
  shift || true

  local pidfile portfile logfile pid port rg cluster bastion_name cluster_id launcher_pid listener_pid
  pidfile="$(bastion_tunnel_pidfile)"
  portfile="$(bastion_tunnel_portfile)"
  logfile="$(bastion_tunnel_logfile)"
  port="${DEFAULT_BASTION_TUNNEL_PORT}"

  case "${action}" in
    start)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --port)
            [[ $# -ge 2 ]] || die "--port requires a value."
            port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh bastion-tunnel start [--port 64430]
  ./scripts/setup.sh bastion-tunnel status
  ./scripts/setup.sh bastion-tunnel stop

Starts a reusable Azure Bastion tunnel to the private AKS API server using
`az network bastion tunnel`.
USAGE
            return 0
            ;;
          *)
            die "Unknown bastion-tunnel option: $1"
            ;;
        esac
      done

      pid="$(pid_from_file "${pidfile}")"
      if pid_is_running "${pid}"; then
        port="$(cat "${portfile}" 2>/dev/null || echo "${port}")"
        if ! listener_is_ready "${port}"; then
          warn "Recorded Bastion tunnel pid ${pid} is running but 127.0.0.1:${port} is not listening. Restarting it."
          kill "${pid}" 2>/dev/null || true
          clear_runtime_files "${pidfile}" "${portfile}"
        elif ! port_listeners_are_bastion_tunnels "${port}"; then
          die "Tracked Bastion tunnel port ${port} is in use by another process. Stop it or choose another port with --port."
        else
          listener_pid="$(first_listener_pid "${port}" 2>/dev/null || true)"
          if [[ -n "${listener_pid}" ]]; then
            printf '%s\n' "${listener_pid}" > "${pidfile}"
            pid="${listener_pid}"
          fi
          log "Bastion tunnel already running on 127.0.0.1:${port} (pid ${pid})"
          printf 'log file: %s\n' "${logfile}"
          return 0
        fi
      fi

      if listener_is_ready "${port}"; then
        if ! port_listeners_are_bastion_tunnels "${port}"; then
          die "Local port ${port} is already in use. Pick another port with --port."
        fi

        warn "Removing stale Bastion tunnel listener on 127.0.0.1:${port} before starting a fresh tunnel."
        stop_bastion_listeners_on_port "${port}" || true
        if listener_is_ready "${port}"; then
          die "Local port ${port} is already in use after removing stale Bastion listeners. Pick another port with --port."
        fi
      fi

      rg="$(resolve_aks_context resource_group_name)"
      cluster="$(resolve_aks_context aks_cluster_name)"
      bastion_name="$(resolve_aks_context bastion_name)"
      cluster_id="$(resolve_aks_cluster_id)"
      [[ -n "${rg}" && -n "${cluster}" && -n "${bastion_name}" && -n "${cluster_id}" ]] || die "Missing Terraform outputs required for the Bastion tunnel."

      ensure_bastion_extensions
      : > "${logfile}"

      log "Starting Bastion tunnel to ${cluster} on 127.0.0.1:${port}"
      nohup az network bastion tunnel \
        --resource-group "${rg}" \
        --name "${bastion_name}" \
        --target-resource-id "${cluster_id}" \
        --resource-port 443 \
        --port "${port}" > "${logfile}" 2>&1 &
      launcher_pid="$!"

      printf '%s\n' "${port}" > "${portfile}"

      if ! wait_for_local_listener "${port}" 30; then
        kill "${launcher_pid}" 2>/dev/null || true
        stop_bastion_listeners_on_port "${port}" || true
        clear_runtime_files "${pidfile}" "${portfile}"
        tail -20 "${logfile}" >&2 || true
        die "Bastion tunnel did not open on port ${port}."
      fi

      listener_pid="$(first_listener_pid "${port}" 2>/dev/null || true)"
      [[ -n "${listener_pid}" ]] || die "Bastion tunnel opened on port ${port} but no listener PID was found."
      printf '%s\n' "${listener_pid}" > "${pidfile}"

      log "Bastion tunnel ready on 127.0.0.1:${port} (pid ${listener_pid})"
      printf 'export ANYSCALE_BASTION_PORT=%s\n' "${port}"
      printf 'log file: %s\n' "${logfile}"
      ;;
    status)
      pid="$(pid_from_file "${pidfile}")"
      port="$(cat "${portfile}" 2>/dev/null || true)"
      if [[ -n "${port}" ]] && listener_is_ready "${port}" && port_listeners_are_bastion_tunnels "${port}"; then
        pid="$(first_listener_pid "${port}" 2>/dev/null || true)"
        [[ -n "${pid}" ]] && printf '%s\n' "${pid}" > "${pidfile}"
        printf 'status=running\n'
        printf 'pid=%s\n' "${pid}"
        printf 'port=%s\n' "${port}"
        printf 'log=%s\n' "${logfile}"
        return 0
      fi

      clear_runtime_files "${pidfile}" "${portfile}"
      printf 'status=stopped\n'
      printf 'log=%s\n' "${logfile}"
      return 1
      ;;
    stop)
      local stopped=false
      pid="$(pid_from_file "${pidfile}")"
      port="$(cat "${portfile}" 2>/dev/null || true)"
      if pid_is_running "${pid}"; then
        kill "${pid}" 2>/dev/null || true
        stopped=true
      fi
      if [[ -n "${port}" ]] && stop_bastion_listeners_on_port "${port}"; then
        stopped=true
      fi
      if [[ "${stopped}" == true ]]; then
        log "Stopped Bastion tunnel${port:+ on 127.0.0.1:${port}}"
      else
        warn "No running Bastion tunnel found."
      fi
      clear_runtime_files \
        "${pidfile}" \
        "${portfile}" \
        "$(bastion_kubeconfig_path)" \
        "$(bastion_admin_kubeconfig_path)"
      ;;
    *)
      die "Usage: ./scripts/setup.sh bastion-tunnel {start|status|stop}"
      ;;
  esac
}

###############################################################################
# Fetch a dedicated kubeconfig that targets the local Bastion tunnel rather than
# the cluster private FQDN directly.
###############################################################################
kubeconfig_bastion() {
  require_cmd az
  require_cmd kubectl
  require_cmd kubelogin

  local admin=false print_path=false export_line=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --admin)
        admin=true
        shift
        ;;
      --print-path)
        print_path=true
        shift
        ;;
      --export)
        export_line=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh kubeconfig-bastion [--admin] [--print-path|--export]

Writes a kubeconfig file pointed at the local Bastion tunnel listener.
Run ./scripts/setup.sh bastion-tunnel start first.
USAGE
        return 0
        ;;
      *)
        die "Unknown kubeconfig-bastion option: $1"
        ;;
    esac
  done

  local pidfile portfile pid port rg cluster kubeconfig_file tmp_file original_server tls_server_name
  pidfile="$(bastion_tunnel_pidfile)"
  portfile="$(bastion_tunnel_portfile)"
  pid="$(pid_from_file "${pidfile}")"

  port="$(cat "${portfile}" 2>/dev/null || true)"
  pid_is_running "${pid}" || die "Bastion tunnel is not running. Start it with ./scripts/setup.sh bastion-tunnel start."
  [[ -n "${port}" ]] || die "Could not determine the Bastion tunnel port."
  listener_is_ready "${port}" || die "Bastion tunnel is not listening on 127.0.0.1:${port}. Restart it with ./scripts/setup.sh bastion-tunnel start."

  rg="$(resolve_aks_context resource_group_name)"
  cluster="$(resolve_aks_context aks_cluster_name)"
  [[ -n "${rg}" && -n "${cluster}" ]] || die "Terraform outputs are missing. Run ./scripts/setup.sh apply first."

  if [[ "${admin}" == true ]]; then
    kubeconfig_file="$(bastion_admin_kubeconfig_path)"
  else
    kubeconfig_file="$(bastion_kubeconfig_path)"
  fi

  if [[ "${admin}" == true ]]; then
    az aks get-credentials \
      --resource-group "${rg}" \
      --name "${cluster}" \
      --file "${kubeconfig_file}" \
      --overwrite-existing \
      --admin \
      --only-show-errors >/dev/null
  else
    az aks get-credentials \
      --resource-group "${rg}" \
      --name "${cluster}" \
      --file "${kubeconfig_file}" \
      --overwrite-existing \
      --only-show-errors >/dev/null
  fi

  original_server="$(kubectl config view --kubeconfig "${kubeconfig_file}" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  tls_server_name="${original_server#https://}"
  tls_server_name="${tls_server_name%%/*}"
  tls_server_name="${tls_server_name%%:*}"

  tmp_file="${kubeconfig_file}.tmp"
  awk -v port="${port}" -v tls_server_name="${tls_server_name}" '
    /^    server: https:\/\// {
      print "    server: https://127.0.0.1:" port
      if (tls_server_name != "") {
        print "    tls-server-name: " tls_server_name
      }
      next
    }
    { print }
  ' "${kubeconfig_file}" > "${tmp_file}"
  mv "${tmp_file}" "${kubeconfig_file}"

  if [[ "${admin}" != true ]]; then
    KUBECONFIG="${kubeconfig_file}" kubelogin convert-kubeconfig -l azurecli >/dev/null
  fi

  kubectl_readyz "${kubeconfig_file}"

  if [[ "${print_path}" == true ]]; then
    printf '%s\n' "${kubeconfig_file}"
    return 0
  fi

  if [[ "${export_line}" == true ]]; then
    printf 'export KUBECONFIG=%q\n' "${kubeconfig_file}"
    return 0
  fi

  log "Bastion kubeconfig ready at ${kubeconfig_file}"
  printf 'export KUBECONFIG=%q\n' "${kubeconfig_file}"
  KUBECONFIG="${kubeconfig_file}" kubectl get nodes -o wide
}

###############################################################################
# Fetch Entra-backed kubeconfig and convert it for kubectl with kubelogin.
# For private clusters, run this from a shell with network path to the API server,
# or inside the shell opened by ./scripts/setup.sh bastion.
###############################################################################
kubeconfig() {
  require_cmd az
  require_cmd kubelogin
  require_cmd kubectl

  local rg cluster current_server
  rg="$(terraform output -raw resource_group_name)"
  cluster="$(terraform output -raw aks_cluster_name)"

  current_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  if [[ -n "${KUBECONFIG:-}" && "${current_server}" =~ ^https://(localhost|127\.0\.0\.1):[0-9]+/?$ ]]; then
    log "Using Bastion-provided kubeconfig at ${KUBECONFIG}"
  else
    log "Fetching Entra-backed kubeconfig for ${cluster}"
    az aks get-credentials --resource-group "${rg}" --name "${cluster}" --overwrite-existing --only-show-errors
  fi

  log "Converting kubeconfig for azurecli login with kubelogin"
  kubelogin convert-kubeconfig -l azurecli

  log "Checking kubectl access"
  kubectl get --raw=/readyz >/dev/null
  kubectl auth can-i get nodes >/dev/null
  kubectl get nodes -o wide
}

ensure_kubelogin_kubeconfig() {
  require_cmd kubectl
  require_cmd kubelogin
  use_bastion_kubeconfig_if_present
  kubelogin convert-kubeconfig -l azurecli >/dev/null 2>&1 || true
}

validation_namespace() {
  printf 'anyscale-validation\n'
}

job_progress_state_file() {
  local namespace="$1"
  local job_name="$2"

  harness_state_file "job-progress-${namespace}-${job_name}.state"
}

job_pod_name() {
  local namespace="$1"
  local job_name="$2"

  kubectl get pod --namespace "${namespace}" -l "job-name=${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

job_event_snapshot() {
  local namespace="$1"
  local pod_name="$2"

  [[ -n "${pod_name}" ]] || return 0

  kubectl get events \
    --namespace "${namespace}" \
    --field-selector "involvedObject.kind=Pod,involvedObject.name=${pod_name}" \
    --sort-by=.lastTimestamp \
    -o custom-columns='REASON:.reason,MESSAGE:.message' \
    --no-headers 2>/dev/null | tail -3 | sed '/^$/d' || true
}

print_job_progress() {
  local namespace="$1"
  local job_name="$2"
  local active succeeded failed pod_name pod_phase node_name state_file event_snapshot status_snapshot
  local scheduler_pending=false autoscaler_triggered=false

  active="$(kubectl get job --namespace "${namespace}" "${job_name}" -o jsonpath='{.status.active}' 2>/dev/null || true)"
  succeeded="$(kubectl get job --namespace "${namespace}" "${job_name}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  failed="$(kubectl get job --namespace "${namespace}" "${job_name}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"

  pod_name="$(job_pod_name "${namespace}" "${job_name}")"
  pod_phase="-"
  node_name="-"

  if [[ -n "${pod_name}" ]]; then
    pod_phase="$(kubectl get pod --namespace "${namespace}" "${pod_name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    node_name="$(kubectl get pod --namespace "${namespace}" "${pod_name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  fi

  event_snapshot="$(job_event_snapshot "${namespace}" "${pod_name}")"
  [[ "${event_snapshot}" == *"FailedScheduling"* && "${event_snapshot}" == *"Insufficient nvidia.com/gpu"* ]] && scheduler_pending=true
  [[ "${event_snapshot}" == *"TriggeredScaleUp"* ]] && autoscaler_triggered=true

  status_snapshot="${active:-0}|${succeeded:-0}|${failed:-0}|${pod_name:-none}|${pod_phase:-Unknown}|${node_name:-pending}|${event_snapshot}"
  state_file="$(job_progress_state_file "${namespace}" "${job_name}")"
  if [[ -f "${state_file}" ]] && [[ "$(cat "${state_file}")" == "${status_snapshot}" ]]; then
    return 0
  fi
  printf '%s\n' "${status_snapshot}" > "${state_file}"

  log "Waiting on job/${job_name}: active=${active:-0} succeeded=${succeeded:-0} failed=${failed:-0} pod=${pod_name:-none} phase=${pod_phase:-Unknown} node=${node_name:-pending}"

  if [[ -n "${pod_name}" && "${pod_phase}" != "Succeeded" ]]; then
    if [[ "${job_name}" == "anyscale-gpu-smoke" && "${scheduler_pending}" == true ]]; then
      warn "GPU pod is still pending because no node currently advertises free nvidia.com/gpu capacity. This is expected while the GPU pool scales from zero and the NVIDIA device plugin converges."
      if [[ "${autoscaler_triggered}" == true ]]; then
        warn "Cluster autoscaler has already requested the GPU pool scale-up. Waiting for the new GPU node to become Ready and report GPU allocatable capacity."
      fi
    elif [[ -n "${event_snapshot}" ]]; then
      printf '%s\n' "${event_snapshot}"
    fi
  fi
}

print_job_logs_or_status() {
  local namespace="$1"
  local job_name="$2"
  local pod_name exit_code reason

  if kubectl logs --namespace "${namespace}" "job/${job_name}"; then
    return 0
  fi

  pod_name="$(job_pod_name "${namespace}" "${job_name}")"
  if [[ -n "${pod_name}" ]]; then
    exit_code="$(kubectl get pod --namespace "${namespace}" "${pod_name}" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"
    reason="$(kubectl get pod --namespace "${namespace}" "${pod_name}" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)"

    if [[ "${exit_code}" == "0" ]]; then
      warn "Could not stream logs for completed job/${job_name}; pod ${pod_name} exited 0 (${reason:-Completed})."
      kubectl get pod --namespace "${namespace}" "${pod_name}" -o wide || true
      return 0
    fi

    kubectl describe pod --namespace "${namespace}" "${pod_name}" || true
  fi

  return 1
}

wait_for_job() {
  local namespace="$1"
  local job_name="$2"
  local timeout="${3:-20m}"
  local wait_log wait_pid wait_status progress_state_file

  wait_log="$(mktemp "${TMPDIR:-${ROOT_DIR}}/wait-for-job.${job_name}.XXXXXX")"
  progress_state_file="$(job_progress_state_file "${namespace}" "${job_name}")"
  rm -f "${progress_state_file}"
  kubectl wait --namespace "${namespace}" --for=condition=complete "job/${job_name}" --timeout="${timeout}" >"${wait_log}" 2>&1 &
  wait_pid="$!"

  while kill -0 "${wait_pid}" 2>/dev/null; do
    print_job_progress "${namespace}" "${job_name}" || true
    sleep 15
  done

  if wait "${wait_pid}"; then
    wait_status=0
  else
    wait_status=$?
  fi

  cat "${wait_log}"
  rm -f "${wait_log}"
  rm -f "${progress_state_file}"

  if [[ "${wait_status}" -ne 0 ]]; then
    local pod_name
    pod_name="$(job_pod_name "${namespace}" "${job_name}")"
    kubectl describe job --namespace "${namespace}" "${job_name}" || true
    if [[ -n "${pod_name}" ]]; then
      kubectl describe pod --namespace "${namespace}" "${pod_name}" || true
    fi
    return "${wait_status}"
  fi

  print_job_logs_or_status "${namespace}" "${job_name}"
}

cleanup_validation() {
  local namespace
  namespace="$(validation_namespace)"
  kubectl delete namespace "${namespace}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

prepare_validation_namespace() {
  local namespace
  namespace="$(validation_namespace)"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply --validate=false -f -
}

control_plane_egress_smoke() {
  require_cmd jq
  require_cluster_kubectl_access
  load_env

  local namespace hosts_json hosts_env
  local hosts=()
  namespace="$(validation_namespace)"
  prepare_validation_namespace

  hosts_json="${TF_VAR_anyscale_fqdns:-[]}"
  while IFS= read -r host; do
    [[ -n "${host}" ]] && hosts+=("${host}")
  done < <(jq -r '(. + ["console.anyscale.com", "console.azure.anyscale.com", "api.anyscale.com"]) | unique[]' <<<"${hosts_json}")

  hosts_env=""
  for host in "${hosts[@]}"; do
    hosts_env+="${host} "
  done
  hosts_env="${hosts_env% }"

  log "Validating cluster egress to Anyscale control-plane endpoints"
  kubectl delete job --namespace "${namespace}" anyscale-control-plane-egress --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-control-plane-egress
  namespace: ${namespace}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: control-plane-egress
        image: curlimages/curl:8.11.1
        env:
        - name: HOSTS
          value: "${hosts_env}"
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -eu
          for host in \${HOSTS}; do
            echo "== resolving \${host} =="
            nslookup "\${host}"
            echo "== probing https://\${host}/ =="
            code="\$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 20 --max-time 60 "https://\${host}/")"
            case "\${code}" in
              2*|3*|4*) echo "https://\${host}/ -> HTTP \${code}" ;;
              *) echo "Unexpected HTTP status \${code} for https://\${host}/" >&2; exit 1 ;;
            esac
          done
          echo CONTROL_PLANE_EGRESS_OK
EOF
  wait_for_job "${namespace}" anyscale-control-plane-egress 15m
}

validate_access() {
  log "Validating kubelogin-backed kubectl access"
  ensure_kubelogin_kubeconfig
  kubectl get --raw=/readyz >/dev/null
  kubectl auth can-i get nodes
  kubectl get nodes -o wide
}

validate_private_dns_and_egress() {
  local namespace storage_account acr_login_server aks_private_fqdn workspace_customer_id region
  namespace="$(validation_namespace)"
  storage_account="$(terraform output -raw storage_account_name)"
  acr_login_server="$(terraform output -raw acr_login_server)"
  aks_private_fqdn="$(terraform output -raw aks_private_fqdn)"
  workspace_customer_id="$(terraform output -raw log_analytics_workspace_customer_id)"
  region="$(terraform output -raw location)"

  log "Validating DNS resolution for Private Link and Anyscale endpoints"
  kubectl delete job --namespace "${namespace}" anyscale-dns-egress --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-dns-egress
  namespace: ${namespace}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: dns-egress
        image: curlimages/curl:8.11.1
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -eu
          for host in \
            ${storage_account}.blob.core.windows.net \
            ${storage_account}.dfs.core.windows.net \
            ${acr_login_server} \
            arcmktplaceprod.azurecr.io \
            ${aks_private_fqdn} \
            global.handler.control.monitor.azure.com \
            ${region}.handler.control.monitor.azure.com \
            ${workspace_customer_id}.ods.opinsights.azure.com \
            ${workspace_customer_id}.oms.opinsights.azure.com \
            api.anyscale.com \
            console.azure.anyscale.com \
            console.anyscale.com; do
            echo "== resolving \${host} =="
            nslookup "\${host}"
          done
          for url in \
            https://${storage_account}.blob.core.windows.net/ \
            https://arcmktplaceprod.azurecr.io/v2/ \
            https://global.handler.control.monitor.azure.com/ \
            https://${workspace_customer_id}.ods.opinsights.azure.com/ \
            https://api.anyscale.com/ \
            https://console.azure.anyscale.com/ \
            https://console.anyscale.com/; do
            echo "== probing \${url} =="
            code="\$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 20 --max-time 60 "\${url}")"
            case "\${code}" in
              2*|3*|4*) echo "\${url} -> HTTP \${code}" ;;
              *) echo "Unexpected HTTP status \${code} for \${url}" >&2; exit 1 ;;
            esac
          done
EOF
  wait_for_job "${namespace}" anyscale-dns-egress 15m
}

validate_workload_identity_storage() {
  require_cmd jq

  local wi namespace service_account storage_account container tenant_id client_id
  wi="$(terraform output -json anyscale_operator_workload_identity)"
  namespace="$(jq -r '.namespace' <<<"${wi}")"
  service_account="$(jq -r '.service_account' <<<"${wi}")"
  storage_account="$(jq -r '.storage.account_name' <<<"${wi}")"
  container="$(jq -r '.storage.container' <<<"${wi}")"
  tenant_id="$(jq -r '.tenant_id' <<<"${wi}")"
  client_id="$(jq -r '.client_id' <<<"${wi}")"

  kubectl get namespace "${namespace}" >/dev/null
  kubectl get serviceaccount --namespace "${namespace}" "${service_account}" >/dev/null

  log "Validating Anyscale operator Workload Identity read/write access to Azure Storage"
  kubectl delete job --namespace "${namespace}" anyscale-wi-storage --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-wi-storage
  namespace: ${namespace}
  labels:
    azure.workload.identity/use: "true"
spec:
  backoffLimit: 1
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: ${service_account}
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: storage-rw
        image: mcr.microsoft.com/azure-cli:2.74.0
        env:
        - name: AZURE_CLIENT_ID
          value: "${client_id}"
        - name: AZURE_TENANT_ID
          value: "${tenant_id}"
        - name: STORAGE_ACCOUNT
          value: "${storage_account}"
        - name: STORAGE_CONTAINER
          value: "${container}"
        command: ["/bin/bash", "-lc"]
        args:
        - |
          set -euo pipefail
          test -f "\${AZURE_FEDERATED_TOKEN_FILE}"
          az login --service-principal \
            --username "\${AZURE_CLIENT_ID}" \
            --tenant "\${AZURE_TENANT_ID}" \
            --federated-token "\$(cat "\${AZURE_FEDERATED_TOKEN_FILE}")" \
            --allow-no-subscriptions \
            --only-show-errors >/dev/null
          blob_name="workload-identity-smoke-\${HOSTNAME}.txt"
          echo "WORKLOAD_IDENTITY_STORAGE_OK" > /tmp/wi.txt
          az storage blob upload \
            --account-name "\${STORAGE_ACCOUNT}" \
            --container-name "\${STORAGE_CONTAINER}" \
            --name "\${blob_name}" \
            --file /tmp/wi.txt \
            --auth-mode login \
            --overwrite true \
            --only-show-errors >/dev/null
          az storage blob download \
            --account-name "\${STORAGE_ACCOUNT}" \
            --container-name "\${STORAGE_CONTAINER}" \
            --name "\${blob_name}" \
            --file /tmp/wi.out \
            --auth-mode login \
            --only-show-errors >/dev/null
          grep -q WORKLOAD_IDENTITY_STORAGE_OK /tmp/wi.out
          az storage blob delete \
            --account-name "\${STORAGE_ACCOUNT}" \
            --container-name "\${STORAGE_CONTAINER}" \
            --name "\${blob_name}" \
            --auth-mode login \
            --only-show-errors >/dev/null
          echo WORKLOAD_IDENTITY_STORAGE_OK
EOF
  wait_for_job "${namespace}" anyscale-wi-storage 20m
}

validate_internal_ingress() {
  local namespace ingress_ip
  namespace="$(validation_namespace)"

  log "Validating internal ingress-nginx reachability"
  kubectl apply --validate=false -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: anyscale-echo
  namespace: ${namespace}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: anyscale-echo
  template:
    metadata:
      labels:
        app: anyscale-echo
    spec:
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: echo
        image: registry.k8s.io/e2e-test-images/agnhost:2.45
        args: ["netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: anyscale-echo
  namespace: ${namespace}
spec:
  selector:
    app: anyscale-echo
  ports:
  - name: http
    port: 80
    targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: anyscale-echo
  namespace: ${namespace}
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /echo
        pathType: Prefix
        backend:
          service:
            name: anyscale-echo
            port:
              number: 80
EOF

  kubectl rollout status --namespace "${namespace}" deployment/anyscale-echo --timeout=10m
  ingress_ip="$(kubectl get service --namespace ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  [[ -n "${ingress_ip}" ]] || die "ingress-nginx internal load balancer IP is not assigned."

  kubectl delete job --namespace "${namespace}" anyscale-ingress-probe --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-ingress-probe
  namespace: ${namespace}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: curl
        image: curlimages/curl:8.11.1
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -eu
          curl -fsS --connect-timeout 20 --max-time 60 "http://${ingress_ip}/echo"
          echo INGRESS_OK
EOF
  wait_for_job "${namespace}" anyscale-ingress-probe 10m
}

validate_gpu() {
  local namespace
  namespace="$(validation_namespace)"

  log "Validating GPU node pool, autoscale, NVIDIA plugin, and nvidia-smi"
  log "GPU validation can take several minutes when the T4 pool scales from zero. Progress snapshots will print while the job waits."
  kubectl get daemonset --namespace gpu-resources nvidia-device-plugin >/dev/null
  kubectl delete job --namespace "${namespace}" anyscale-gpu-smoke --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-gpu-smoke
  namespace: ${namespace}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.azure.com/accelerator
                operator: Exists
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      - key: node.anyscale.com/accelerator-type
        operator: Exists
        effect: NoSchedule
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: nvidia-smi
        image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
        command: ["/bin/bash", "-lc"]
        args: ["nvidia-smi && echo GPU_OK"]
        resources:
          limits:
            nvidia.com/gpu: 1
EOF
  wait_for_job "${namespace}" anyscale-gpu-smoke 45m
}

validate_anyscale_operator_patches() {
  local namespace patches_yaml

  load_env
  namespace="${TF_VAR_anyscale_operator_namespace}"

  require_cluster_kubectl_access

  log "Validating Anyscale operator GPU toleration patches"
  patches_yaml="$(kubectl get configmap patches -n "${namespace}" -o jsonpath='{.data.patches\.yaml}')"
  [[ -n "${patches_yaml}" ]] || die "Anyscale operator patches ConfigMap is empty in namespace ${namespace}."

  grep -q 'key: node.anyscale.com/accelerator-type' <<<"${patches_yaml}" || die "Anyscale operator patches ConfigMap is missing the accelerator-type GPU toleration."
  grep -q 'key: nvidia.com/gpu' <<<"${patches_yaml}" || die "Anyscale operator patches ConfigMap is missing the AKS nvidia.com/gpu toleration."

  log "Anyscale operator patches ConfigMap includes both GPU tolerations."
}

validate_k8s() {
  validate_access
  validate_anyscale_operator_patches
  prepare_validation_namespace
  validate_private_dns_and_egress
  validate_workload_identity_storage
  validate_internal_ingress
  validate_gpu
  log "Functional Kubernetes validation completed."
}

validate_observability() {
  require_cmd az
  require_cmd jq

  local workspace_customer_id container_query diagnostics_query container_json diagnostics_json container_rows diagnostics_rows
  workspace_customer_id="$(terraform output -raw log_analytics_workspace_customer_id)"
  [[ -n "${workspace_customer_id}" ]] || die "Missing log_analytics_workspace_customer_id output. Run ./scripts/setup.sh apply first."

  container_query='ContainerLogV2 | where TimeGenerated > ago(2h) | summarize Records=count(), Namespaces=make_set(PodNamespace, 10), Sample=any(LogMessage)'
  diagnostics_query='union isfuzzy=true withsource=TableName AzureDiagnostics, AzureMetrics, StorageBlobLogs, ContainerRegistryLoginEvents, ContainerRegistryRepositoryEvents, MicrosoftAzureBastionAuditLogs | where TimeGenerated > ago(2h) | summarize Records=count() by TableName | order by Records desc'

  log "Querying ContainerLogV2 in Log Analytics"
  container_json="$(az monitor log-analytics query --workspace "${workspace_customer_id}" --analytics-query "${container_query}" --output json --only-show-errors)"
  jq . <<<"${container_json}"
  container_rows="$(jq -r 'def n: tonumber? // 0; if type == "array" then (.[0].Records? | n) else (.tables[0].rows[0][0] | n) end' <<<"${container_json}")"
  [[ "${container_rows}" =~ ^[0-9]+$ && "${container_rows}" -gt 0 ]] || die "ContainerLogV2 has no records yet. Run this again after Azure Monitor ingestion catches up."

  log "Querying diagnostic tables in Log Analytics"
  diagnostics_json="$(az monitor log-analytics query --workspace "${workspace_customer_id}" --analytics-query "${diagnostics_query}" --output json --only-show-errors)"
  jq . <<<"${diagnostics_json}"
  diagnostics_rows="$(jq -r 'def n: tonumber? // 0; if type == "array" then ([.[].Records? | n] | add // 0) else ([.tables[0].rows[]?[1] | n] | add // 0) end' <<<"${diagnostics_json}")"
  [[ "${diagnostics_rows}" =~ ^[0-9]+$ && "${diagnostics_rows}" -gt 0 ]] || die "Diagnostic tables have no records yet. Generate traffic and run this again after ingestion catches up."

  log "Observability validation completed."
}

validate_focused() {
  local include_observability=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-observability)
        include_observability=false
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh validate-focused
  ./scripts/setup.sh validate-focused --skip-observability

Runs the post-deploy live validation suite with PASS/FAIL output and per-check
logs under .cache/focused-validation/<timestamp>/.
USAGE
        return 0
        ;;
      *)
        die "Unknown validate-focused option: $1"
        ;;
    esac
  done

  reset_focused_validation_run
  log "Running focused live validation suite"

  local cluster_access_ready=false
  local validation_namespace_ready=false

  if run_focused_validation_check "kubectl-access" "kubelogin kubectl access" validate_access; then
    cluster_access_ready=true
  fi

  if [[ "${cluster_access_ready}" == true ]]; then
    run_focused_validation_check "anyscale-operator-patches" "Anyscale operator GPU toleration patches" validate_anyscale_operator_patches || true
    if run_focused_validation_check "validation-namespace" "validation namespace preparation" prepare_validation_namespace; then
      validation_namespace_ready=true
    fi
  else
    skip_focused_validation_check "anyscale-operator-patches" "Anyscale operator GPU toleration patches" "skipped because kubectl access failed"
    skip_focused_validation_check "validation-namespace" "validation namespace preparation" "skipped because kubectl access failed"
  fi

  if [[ "${validation_namespace_ready}" == true ]]; then
    run_focused_validation_check "private-dns-egress" "private DNS and control-plane egress" validate_private_dns_and_egress || true
    run_focused_validation_check "workload-identity-storage" "workload identity storage access" validate_workload_identity_storage || true
    run_focused_validation_check "internal-ingress" "internal ingress reachability" validate_internal_ingress || true
    run_focused_validation_check "gpu-smoke" "GPU scheduling and nvidia-smi" validate_gpu || true
  else
    skip_focused_validation_check "private-dns-egress" "private DNS and control-plane egress" "skipped because validation namespace setup failed"
    skip_focused_validation_check "workload-identity-storage" "workload identity storage access" "skipped because validation namespace setup failed"
    skip_focused_validation_check "internal-ingress" "internal ingress reachability" "skipped because validation namespace setup failed"
    skip_focused_validation_check "gpu-smoke" "GPU scheduling and nvidia-smi" "skipped because validation namespace setup failed"
  fi

  if [[ "${include_observability}" == true ]]; then
    run_focused_validation_check "observability" "Log Analytics and diagnostics ingestion" validate_observability || true
  else
    skip_focused_validation_check "observability" "Log Analytics and diagnostics ingestion" "skipped by --skip-observability"
  fi

  write_focused_validation_summary
  [[ "${FOCUSED_VALIDATION_FAIL_COUNT}" -eq 0 ]]
}

###############################################################################
anyscale_workspace_ready() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh anyscale-workspace-ready

Validates Azure-hosted Anyscale CLI access, then patches the live operator
release with the Azure CLI token and AKS-aligned CPU/GPU instance types.
Requires a Bastion-backed kubeconfig and ANYSCALE_CLI_TOKEN in .env.
USAGE
        return 0
        ;;
      *)
        die "Unknown anyscale-workspace-ready option: $1"
        ;;
    esac
  done

  load_env
  sync_anyscale_cli_env
  require_anyscale_cli
  require_cmd helm
  require_cmd jq
  require_cluster_kubectl_access
  require_env_var ANYSCALE_CLI_TOKEN
  require_env_var ANYSCALE_CLOUD_NAME
  require_env_var ANYSCALE_CLOUD_DEPLOYMENT_ID

  local cli_bin namespace release_json release_name chart_version audience
  local operator_client_id values_file

  cli_bin="$(anyscale_cli_bin)"
  namespace="${TF_VAR_anyscale_operator_namespace}"

  log "Validating Anyscale CLI access against ${ANYSCALE_HOST}"
  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" "${cli_bin}" cloud config get --name "${ANYSCALE_CLOUD_NAME}" >/dev/null

  release_json="$(anyscale_operator_release_json "${namespace}")"
  release_name="$(anyscale_operator_release_name "${release_json}")"
  chart_version="$(anyscale_operator_chart_version "${release_json}")"
  [[ -n "${release_name}" ]] || die "Could not find the installed anyscale-operator Helm release in namespace ${namespace}."
  [[ -n "${chart_version}" ]] || die "Could not determine the installed anyscale-operator chart version."

  audience="$(anyscale_operator_auth_audience "${release_name}" "${namespace}")"
  operator_client_id="$(terraform_output_raw anyscale_operator_identity_client_id)"
  [[ -n "${operator_client_id}" ]] || die "Terraform output anyscale_operator_identity_client_id is empty. Run ./scripts/setup.sh apply first."

  mkdir -p "${CACHE_DIR}"
  values_file="${CACHE_DIR}/anyscale-operator.workspace-ready.values.yaml"

  cat > "${values_file}" <<EOF
global:
  cloudDeploymentId: "${ANYSCALE_CLOUD_DEPLOYMENT_ID}"
  cloudProvider: "azure"
  auth:
    anyscaleCliToken: "${ANYSCALE_CLI_TOKEN}"
    iamIdentity: "${operator_client_id}"
    audience: "${audience}"
workloads:
  serviceAccount:
    name: ${TF_VAR_anyscale_operator_serviceaccount}
  accelerator:
    tolerations:
      default:
      - key: "node.anyscale.com/accelerator-type"
        value: "GPU"
        effect: "NoSchedule"
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
  instanceTypes:
    enableDefaults: true
    additional:
      14CPU-56GB-CPU:
        resources:
          CPU: 14
          memory: 56Gi
        nodeSelector:
          agentpool: cpu
      8CPU-32GB-1xT4-AKS:
        resources:
          CPU: 8
          GPU: 1
          'accelerator_type:T4': 1
          memory: 32Gi
        accelerators:
        - T4
        nodeSelector:
          agentpool: gput4
        tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
        - key: "node.anyscale.com/accelerator-type"
          operator: "Exists"
          effect: "NoSchedule"
        - key: "node.anyscale.com/capacity-type"
          operator: "Exists"
          effect: "NoSchedule"
EOF

  log "Updating the Anyscale Helm repository"
  helm repo add anyscale https://anyscale.github.io/helm-charts >/dev/null 2>&1 || true
  run_with_timeout "${SETUP_TIMEOUT_HELM_SECONDS}" helm repo update anyscale >/dev/null

  log "Patching ${release_name} with the Azure CLI token and AKS instance types"
  run_with_timeout "${SETUP_TIMEOUT_HELM_SECONDS}" helm upgrade "${release_name}" anyscale/anyscale-operator \
    --namespace "${namespace}" \
    --version "${chart_version}" \
    --reuse-values \
    --wait \
    -f "${values_file}"

  kubectl get configmap instance-types -n "${namespace}" -o jsonpath='{.data.instance_types\.yaml}' | grep -q '14CPU-56GB-CPU'
  kubectl get configmap instance-types -n "${namespace}" -o jsonpath='{.data.instance_types\.yaml}' | grep -q '8CPU-32GB-1xT4-AKS'
  validate_anyscale_operator_patches

  if kubectl logs -n "${namespace}" deployment/anyscale-operator -c operator --tail=120 2>/dev/null | grep -q 'authentication handshake failed'; then
    warn "The operator log tail still shows authentication handshake failures. Re-check ANYSCALE_CLI_TOKEN and control-plane reachability to ${ANYSCALE_HOST}."
  else
    log "Recent operator logs no longer show authentication handshake failures."
  fi

  log "Workspace-ready operator patch applied. Values file: ${values_file}"
}

write_anyscale_compute_config_file() {
  local file_path="$1"
  local profile="${2:-mixed}"

  case "${profile}" in
    mixed)
      cat > "${file_path}" <<EOF
cloud: ${ANYSCALE_CLOUD_NAME}
head_node:
  instance_type: 8CPU-32GB
worker_nodes:
  - name: cpu-workers
    instance_type: 14CPU-56GB-CPU
    min_nodes: 0
    max_nodes: 4
  - name: gpu-workers
    instance_type: 8CPU-32GB-1xT4-AKS
    min_nodes: 0
    max_nodes: 2
EOF
      ;;
    cpu)
      cat > "${file_path}" <<EOF
cloud: ${ANYSCALE_CLOUD_NAME}
head_node:
  instance_type: 14CPU-56GB-CPU
worker_nodes:
  - name: cpu-workers
    instance_type: 14CPU-56GB-CPU
    min_nodes: 0
    max_nodes: 1
EOF
      ;;
    gpu)
      cat > "${file_path}" <<EOF
cloud: ${ANYSCALE_CLOUD_NAME}
head_node:
  instance_type: 8CPU-32GB-1xT4-AKS
worker_nodes:
  - name: gpu-workers
    instance_type: 8CPU-32GB-1xT4-AKS
    min_nodes: 0
    max_nodes: 1
EOF
      ;;
    *)
      die "Unknown Anyscale compute config profile ${profile}"
      ;;
  esac
}

ensure_anyscale_compute_config() {
  local compute_config_name="$1"
  local cli_bin="$2"
  local config_file="$3"
  local profile="${4:-mixed}"

  if run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" compute-config get \
      --name "${compute_config_name}" \
      --cloud-name "${ANYSCALE_CLOUD_NAME}" >/dev/null 2>&1; then
    log "Using existing Anyscale compute config ${compute_config_name}"
    return 0
  fi

  write_anyscale_compute_config_file "${config_file}" "${profile}"

  log "Creating Anyscale compute config ${compute_config_name}"
  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" compute-config create \
      --name "${compute_config_name}" \
      --config-file "${config_file}" >/dev/null
}

normalize_anyscale_workspace_status() {
  local raw_status="$1"

  printf '%s\n' "${raw_status}" \
    | tail -n 1 \
    | sed -E 's/^.*\)\s*//' \
    | tr -d '\r' \
    | awk '{$1=$1; print}'
}

wait_for_anyscale_workspace_running() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local deadline current_epoch raw_status current_status previous_status=""

  ANYSCALE_WORKSPACE_WAIT_RESULT=""
  : > "${wait_log}"
  deadline=$(( $(date +%s) + SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS ))

  while true; do
    if ! raw_status="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 status \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      printf '%s\n' "${raw_status}" | tee -a "${wait_log}"
      return 1
    fi

    current_status="$(normalize_anyscale_workspace_status "${raw_status}")"
    printf '%s\n' "${raw_status}" >> "${wait_log}"

    if [[ -z "${current_status}" ]]; then
      current_status="UNKNOWN"
    fi

    if [[ "${current_status}" != "${previous_status}" ]]; then
      log "Workspace ${workspace_name} status: ${current_status}"
      previous_status="${current_status}"
    fi

    case "${current_status}" in
      RUNNING)
        ANYSCALE_WORKSPACE_WAIT_RESULT="${current_status}"
        return 0
        ;;
      TERMINATED|TERMINATING|CREATE_FAILED|FAILED|ERROR)
        ANYSCALE_WORKSPACE_WAIT_RESULT="${current_status}"
        return 1
        ;;
    esac

    current_epoch=$(date +%s)
    if (( current_epoch >= deadline )); then
      ANYSCALE_WORKSPACE_WAIT_RESULT="Timed out waiting for RUNNING; last observed state=${current_status}"
      return 1
    fi

    sleep 15
  done
}

workspace_head_pod_name() {
  local workspace_name="$1"
  local namespace head_pod_name

  namespace="${TF_VAR_anyscale_operator_namespace}"
  head_pod_name="$(kubectl get pods -n "${namespace}" \
    -l "app.kubernetes.io/name=${workspace_name},ray-node-type=head" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  [[ -n "${head_pod_name}" ]] || die "Could not find a Ray head pod for workspace ${workspace_name} in namespace ${namespace}."
  printf '%s\n' "${head_pod_name}"
}

workspace_exec_head_bash() {
  local workspace_name="$1"
  local script="$2"
  local namespace head_pod_name

  namespace="${TF_VAR_anyscale_operator_namespace}"
  head_pod_name="$(workspace_head_pod_name "${workspace_name}")"

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod_name}" -- bash -lc "${script}"
}

###############################################################################
workspace_intro_smoke() {
  local workspace_name=""
  local compute_config_name="aks-cpu-gpu"
  local keep_workspace=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ $# -ge 2 ]] || die "Missing value for --name"
        workspace_name="$2"
        shift 2
        ;;
      --compute-config)
        [[ $# -ge 2 ]] || die "Missing value for --compute-config"
        compute_config_name="$2"
        shift 2
        ;;
      --keep-workspace)
        keep_workspace=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-intro-smoke
  ./scripts/setup.sh workspace-intro-smoke --keep-workspace
  ./scripts/setup.sh workspace-intro-smoke --name my-workspace --compute-config aks-cpu-gpu

Re-runs the Azure-hosted Anyscale operator post-config, validates the operator
GPU toleration patches, ensures the AKS CPU/GPU compute config exists, then
executes the Anyscale "Intro to workspaces" dependency-management smoke test
through the Bastion-backed head pod. Requires a Bastion-backed kubeconfig and
ANYSCALE_CLI_TOKEN in .env.
USAGE
        return 0
        ;;
      *)
        die "Unknown workspace-intro-smoke option: $1"
        ;;
    esac
  done

  load_env
  sync_anyscale_cli_env
  require_anyscale_cli
  require_cluster_kubectl_access
  require_env_var ANYSCALE_CLI_TOKEN
  require_env_var ANYSCALE_CLOUD_NAME
  require_env_var ANYSCALE_CLOUD_DEPLOYMENT_ID

  local cli_bin compute_config_file create_log start_log wait_log install_log tutorial_log tutorial_command
  local workspace_created=false workspace_intro_succeeded=false create_output start_output wait_output install_output tutorial_output

  cli_bin="$(anyscale_cli_bin)"
  mkdir -p "${CACHE_DIR}"

  if [[ -z "${workspace_name}" ]]; then
    workspace_name="workspace-intro-smoke-$(date +%Y%m%d%H%M%S)"
  fi

  compute_config_file="${CACHE_DIR}/anyscale-compute.${compute_config_name}.yaml"
  create_log="${CACHE_DIR}/${workspace_name}.create.log"
  start_log="${CACHE_DIR}/${workspace_name}.start.log"
  wait_log="${CACHE_DIR}/${workspace_name}.wait.log"
  install_log="${CACHE_DIR}/${workspace_name}.install.log"
  tutorial_log="${CACHE_DIR}/${workspace_name}.tutorial.log"

  workspace_intro_cleanup() {
    if [[ "${workspace_created}" != true ]]; then
      return 0
    fi

    if [[ "${keep_workspace}" == true ]]; then
      return 0
    fi

    if [[ "${workspace_intro_succeeded}" != true ]]; then
      warn "Keeping workspace ${workspace_name} for debugging because the smoke test did not complete successfully. Rerun with --keep-workspace if you want to make that intent explicit."
      return 0
    fi

    warn "Terminating workspace ${workspace_name}"
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 terminate \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" >/dev/null 2>&1 || \
      warn "Failed to terminate workspace ${workspace_name}. Terminate it manually from the Anyscale console if it remains active."
  }

  trap workspace_intro_cleanup EXIT

  anyscale_workspace_ready
  validate_anyscale_operator_patches
  ensure_anyscale_compute_config "${compute_config_name}" "${cli_bin}" "${compute_config_file}" "mixed"

  log "Creating workspace ${workspace_name} for the Intro to Workspaces smoke test"
  local create_status=0
  if ! create_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 create \
      --name "${workspace_name}" \
      --compute-config "${compute_config_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" \
      --env "MY_EMOJI=:thumbs_up:" 2>&1)"; then
    create_status=$?
  fi
  printf '%s\n' "${create_output}" | tee "${create_log}"
  if [[ "${create_status}" -ne 0 ]] && ! grep -q 'Workspace created successfully id:' <<<"${create_output}"; then
    printf '%s\n' "${create_output}" | tee "${create_log}"
    die "The workspace create step failed. See ${create_log}."
  fi
  if [[ "${create_status}" -ne 0 ]]; then
    warn "The Anyscale CLI did not exit cleanly after reporting workspace creation; continuing with explicit workspace_v2 wait."
  fi
  workspace_created=true

  log "Starting workspace ${workspace_name}"
  if ! start_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 start \
      --name "${workspace_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
    printf '%s\n' "${start_output}" | tee "${start_log}"
    die "The workspace start step failed. See ${start_log}."
  fi
  printf '%s\n' "${start_output}" | tee "${start_log}"

  log "Waiting for workspace ${workspace_name} to reach RUNNING"
  if ! wait_for_anyscale_workspace_running "${workspace_name}" "${cli_bin}" "${wait_log}"; then
    wait_output="${ANYSCALE_WORKSPACE_WAIT_RESULT}"
    printf '%s\n' "${wait_output}" | tee -a "${wait_log}"
    die "The workspace did not reach RUNNING. See ${wait_log}."
  fi
  wait_output="${ANYSCALE_WORKSPACE_WAIT_RESULT}"
  printf '%s\n' "${wait_output}" | tee -a "${wait_log}"

  log "Installing emoji in workspace ${workspace_name} through the Bastion-backed head pod"
  if ! install_output="$(workspace_exec_head_bash "${workspace_name}" 'python -m pip install emoji' 2>&1)"; then
    printf '%s\n' "${install_output}" | tee "${install_log}"
    die "The tutorial dependency-install step failed. See ${install_log}."
  fi
  printf '%s\n' "${install_output}" | tee "${install_log}"

  tutorial_command="$(cat <<'EOF'
python - <<'PY'
import os
import ray

if ray.is_initialized():
    ray.shutdown()

ray.init(address="auto")

@ray.remote
def render_intro_message():
    import emoji

    my_emoji = os.environ.get("MY_EMOJI", ":thumbs_up:")
    return emoji.emojize(f"Dependencies are {my_emoji}")

print(ray.get(render_intro_message.remote()))
print("WORKSPACE_INTRO_SMOKE_OK")
PY
EOF
)"

  log "Running the Intro to Workspaces Ray smoke command in ${workspace_name} through the Bastion-backed head pod"
  if ! tutorial_output="$(workspace_exec_head_bash "${workspace_name}" "${tutorial_command}" 2>&1)"; then
    printf '%s\n' "${tutorial_output}" | tee "${tutorial_log}"
    die "The workspace tutorial smoke command failed. See ${tutorial_log}."
  fi
  printf '%s\n' "${tutorial_output}" | tee "${tutorial_log}"

  grep -q 'WORKSPACE_INTRO_SMOKE_OK' <<<"${tutorial_output}" || die "The workspace tutorial smoke command completed without the expected success marker. See ${tutorial_log}."

  workspace_intro_succeeded=true
  log "Workspace intro smoke completed successfully. Logs: ${install_log}, ${tutorial_log}"

  if [[ "${keep_workspace}" == true ]]; then
    trap - EXIT
    log "Keeping workspace ${workspace_name} running for follow-up debugging."
  fi
}

workspace_compute_ready() {
  local cpu_workspace_name="workspace-cpu-ready"
  local gpu_workspace_name="workspace-gpu-ready"
  local cpu_compute_config_name="aks-cpu-only"
  local gpu_compute_config_name="aks-gpu-only"
  local terminate_workspaces=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpu-workspace-name)
        [[ $# -ge 2 ]] || die "Missing value for --cpu-workspace-name"
        cpu_workspace_name="$2"
        shift 2
        ;;
      --gpu-workspace-name)
        [[ $# -ge 2 ]] || die "Missing value for --gpu-workspace-name"
        gpu_workspace_name="$2"
        shift 2
        ;;
      --cpu-compute-config)
        [[ $# -ge 2 ]] || die "Missing value for --cpu-compute-config"
        cpu_compute_config_name="$2"
        shift 2
        ;;
      --gpu-compute-config)
        [[ $# -ge 2 ]] || die "Missing value for --gpu-compute-config"
        gpu_compute_config_name="$2"
        shift 2
        ;;
      --terminate-workspaces)
        terminate_workspaces=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-compute-ready
  ./scripts/setup.sh workspace-compute-ready --terminate-workspaces
  ./scripts/setup.sh workspace-compute-ready --cpu-workspace-name my-cpu --gpu-workspace-name my-gpu

Creates or reuses dedicated CPU and GPU compute configs, creates or starts
dedicated workspaces for each node pool, validates each workspace from the
private Bastion-backed kubeconfig path, and leaves the workspaces running by
default so they are ready to use through the Anyscale CLI.
USAGE
        return 0
        ;;
      *)
        die "Unknown workspace-compute-ready option: $1"
        ;;
    esac
  done

  load_env
  sync_anyscale_cli_env
  require_anyscale_cli
  require_cluster_kubectl_access
  require_env_var ANYSCALE_CLI_TOKEN
  require_env_var ANYSCALE_CLOUD_NAME
  require_env_var ANYSCALE_CLOUD_DEPLOYMENT_ID

  local cli_bin namespace
  local cpu_compute_config_file gpu_compute_config_file
  local cpu_create_log cpu_start_log cpu_wait_log cpu_validate_log
  local gpu_create_log gpu_start_log gpu_wait_log gpu_validate_log
  local cpu_head_pod gpu_head_pod cpu_node_name gpu_node_name
  local cpu_validation_command gpu_validation_command

  cli_bin="$(anyscale_cli_bin)"
  namespace="${TF_VAR_anyscale_operator_namespace}"
  mkdir -p "${CACHE_DIR}"

  cpu_compute_config_file="${CACHE_DIR}/anyscale-compute.${cpu_compute_config_name}.yaml"
  gpu_compute_config_file="${CACHE_DIR}/anyscale-compute.${gpu_compute_config_name}.yaml"
  cpu_create_log="${CACHE_DIR}/${cpu_workspace_name}.create.log"
  cpu_start_log="${CACHE_DIR}/${cpu_workspace_name}.start.log"
  cpu_wait_log="${CACHE_DIR}/${cpu_workspace_name}.wait.log"
  cpu_validate_log="${CACHE_DIR}/${cpu_workspace_name}.validate.log"
  gpu_create_log="${CACHE_DIR}/${gpu_workspace_name}.create.log"
  gpu_start_log="${CACHE_DIR}/${gpu_workspace_name}.start.log"
  gpu_wait_log="${CACHE_DIR}/${gpu_workspace_name}.wait.log"
  gpu_validate_log="${CACHE_DIR}/${gpu_workspace_name}.validate.log"

  ensure_named_workspace_running() {
    local workspace_name="$1"
    local compute_config_name="$2"
    local create_log="$3"
    local start_log="$4"
    local wait_log="$5"
    local status_output current_status create_output start_output
    local create_status=0

    if status_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 status \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      current_status="$(normalize_anyscale_workspace_status "${status_output}")"
      printf '%s\n' "${status_output}" > "${wait_log}"

      case "${current_status}" in
        RUNNING)
          log "Workspace ${workspace_name} is already RUNNING"
          return 0
          ;;
        STARTING)
          log "Waiting for existing workspace ${workspace_name} to reach RUNNING"
          if ! wait_for_anyscale_workspace_running "${workspace_name}" "${cli_bin}" "${wait_log}"; then
            printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}"
            die "The workspace ${workspace_name} did not reach RUNNING. See ${wait_log}."
          fi
          printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}"
          return 0
          ;;
      esac
    else
      log "Creating workspace ${workspace_name} with compute config ${compute_config_name}"
      if ! create_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
        "${cli_bin}" workspace_v2 create \
          --name "${workspace_name}" \
          --compute-config "${compute_config_name}" \
          --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
        create_status=$?
      fi
      printf '%s\n' "${create_output}" | tee "${create_log}"
      if [[ "${create_status}" -ne 0 ]] && ! grep -q 'Workspace created successfully id:' <<<"${create_output}"; then
        die "The workspace create step failed for ${workspace_name}. See ${create_log}."
      fi
      if [[ "${create_status}" -ne 0 ]]; then
        warn "The Anyscale CLI did not exit cleanly after reporting workspace creation for ${workspace_name}; continuing with explicit start and wait."
      fi
    fi

    log "Starting workspace ${workspace_name}"
    if ! start_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 start \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      printf '%s\n' "${start_output}" | tee "${start_log}"
      if ! grep -Eiq 'already.*running|currently in state: STARTING' <<<"${start_output}"; then
        die "The workspace start step failed for ${workspace_name}. See ${start_log}."
      fi
    else
      printf '%s\n' "${start_output}" | tee "${start_log}"
    fi

    log "Waiting for workspace ${workspace_name} to reach RUNNING"
    if ! wait_for_anyscale_workspace_running "${workspace_name}" "${cli_bin}" "${wait_log}"; then
      printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}"
      die "The workspace ${workspace_name} did not reach RUNNING. See ${wait_log}."
    fi
    printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}"
  }

  anyscale_workspace_ready
  validate_anyscale_operator_patches
  ensure_anyscale_compute_config "${cpu_compute_config_name}" "${cli_bin}" "${cpu_compute_config_file}" "cpu"
  ensure_anyscale_compute_config "${gpu_compute_config_name}" "${cli_bin}" "${gpu_compute_config_file}" "gpu"

  ensure_named_workspace_running "${cpu_workspace_name}" "${cpu_compute_config_name}" "${cpu_create_log}" "${cpu_start_log}" "${cpu_wait_log}"
  ensure_named_workspace_running "${gpu_workspace_name}" "${gpu_compute_config_name}" "${gpu_create_log}" "${gpu_start_log}" "${gpu_wait_log}"

  cpu_head_pod="$(workspace_head_pod_name "${cpu_workspace_name}")"
  cpu_node_name="$(kubectl get pod -n "${namespace}" "${cpu_head_pod}" -o jsonpath='{.spec.nodeName}')"
  cpu_validation_command="$(cat <<'EOF'
python - <<'PY'
import ray

ray.init(address="auto")

@ray.remote(num_cpus=1)
def cpu_probe():
    return "CPU_WORKSPACE_OK"

print(ray.get(cpu_probe.remote()))
PY
EOF
)"

  {
    printf 'workspace=%s\n' "${cpu_workspace_name}"
    printf 'compute_config=%s\n' "${cpu_compute_config_name}"
    printf 'head_pod=%s\n' "${cpu_head_pod}"
    printf 'node=%s\n' "${cpu_node_name}"
    kubectl get pod -n "${namespace}" "${cpu_head_pod}" -o wide
    workspace_exec_head_bash "${cpu_workspace_name}" "${cpu_validation_command}"
  } 2>&1 | tee "${cpu_validate_log}"

  [[ "${cpu_node_name}" == aks-cpu-* ]] || die "CPU workspace ${cpu_workspace_name} is running on unexpected node ${cpu_node_name}. See ${cpu_validate_log}."
  grep -q 'CPU_WORKSPACE_OK' "${cpu_validate_log}" || die "CPU workspace validation did not emit the expected success marker. See ${cpu_validate_log}."

  gpu_head_pod="$(workspace_head_pod_name "${gpu_workspace_name}")"
  gpu_node_name="$(kubectl get pod -n "${namespace}" "${gpu_head_pod}" -o jsonpath='{.spec.nodeName}')"
  gpu_validation_command="$(cat <<'EOF'
nvidia-smi -L
python - <<'PY'
import ray

ray.init(address="auto")

@ray.remote(num_gpus=1)
def gpu_probe():
    import os

    return f"GPU_WORKSPACE_OK:{os.environ.get('CUDA_VISIBLE_DEVICES', 'none')}"

print(ray.get(gpu_probe.remote()))
PY
EOF
)"

  {
    printf 'workspace=%s\n' "${gpu_workspace_name}"
    printf 'compute_config=%s\n' "${gpu_compute_config_name}"
    printf 'head_pod=%s\n' "${gpu_head_pod}"
    printf 'node=%s\n' "${gpu_node_name}"
    kubectl get pod -n "${namespace}" "${gpu_head_pod}" -o wide
    workspace_exec_head_bash "${gpu_workspace_name}" "${gpu_validation_command}"
  } 2>&1 | tee "${gpu_validate_log}"

  [[ "${gpu_node_name}" == aks-gput4-* ]] || die "GPU workspace ${gpu_workspace_name} is running on unexpected node ${gpu_node_name}. See ${gpu_validate_log}."
  grep -q 'GPU 0:' "${gpu_validate_log}" || die "GPU workspace validation did not observe a GPU device. See ${gpu_validate_log}."
  grep -Eq 'GPU_WORKSPACE_OK:[0-9]+' "${gpu_validate_log}" || die "GPU workspace validation did not emit the expected success marker. See ${gpu_validate_log}."

  log "Dedicated CPU and GPU workspaces are ready to use through the Anyscale CLI."
  log "CPU workspace: ${cpu_workspace_name} (${cpu_compute_config_name})"
  log "GPU workspace: ${gpu_workspace_name} (${gpu_compute_config_name})"
  log "Validation logs: ${cpu_validate_log}, ${gpu_validate_log}"

  if [[ "${terminate_workspaces}" == true ]]; then
    warn "Terminating workspace ${cpu_workspace_name}"
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 terminate \
        --name "${cpu_workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" >/dev/null 2>&1 || \
      warn "Failed to terminate workspace ${cpu_workspace_name}."

    warn "Terminating workspace ${gpu_workspace_name}"
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 terminate \
        --name "${gpu_workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" >/dev/null 2>&1 || \
      warn "Failed to terminate workspace ${gpu_workspace_name}."
  fi
}

###############################################################################
post() {
  log "Kubernetes bootstrap is Terraform-managed. Re-run terraform apply to reconcile the operator service account, NVIDIA device plugin, and ingress-nginx releases."
  log "If the current shell already has a Bastion-backed kubeconfig and ANYSCALE_CLI_TOKEN, ./scripts/setup.sh apply now auto-runs ./scripts/setup.sh anyscale-workspace-ready after Terraform finishes."
  log "Otherwise, rerun ./scripts/setup.sh anyscale-workspace-ready to inject the Azure CLI token and AKS-aligned CPU/GPU instance types into the operator release."
  log "Use ./scripts/setup.sh workspace-intro-smoke to run the Azure-hosted Anyscale tutorial smoke after the operator patch is in place."
  log "Use ./scripts/setup.sh workspace-compute-ready to create or reuse dedicated CPU and GPU workspaces and leave them running for CLI use."
  warn "For a Bastion-backed local workflow, export TF_VAR_cluster_bootstrap with the Bastion kubeconfig path before re-running terraform apply."
}

functional_test() {
  validate_k8s
}

###############################################################################
destroy() {
  render_tfvars
  warn "Destroying ALL resources in the workspace."
  read -r -p "Type the project name to confirm destroy: " confirm
  [[ "${confirm}" == "${TF_VAR_project}" ]] || die "Cancelled."
  bastion_tunnel stop >/dev/null 2>&1 || true
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_DESTROY_SECONDS}" terraform destroy -auto-approve
  clear_anyscale_cloud_deployment_id
}

###############################################################################
# Delete the Azure resource group directly and remove local Terraform state.
# This is intentionally stronger than terraform destroy and is useful for
# rebuilding after failed private AKS/bootstrap experiments.
###############################################################################
nuke() {
  local force=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)
        force=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh nuke
  ./scripts/setup.sh nuke --yes

Deletes the configured resource group with Azure CLI, waits until it is gone,
then removes local Terraform state and saved plan files. It keeps .env and the
committed .terraform.lock.hcl intact.
USAGE
        return 0
        ;;
      *) die "Unknown nuke option: $1" ;;
    esac
  done

  load_env
  require_cmd az

  local resource_group
  resource_group="$(resource_group_name)"

  if [[ "${force}" != true ]]; then
    warn "This will delete Azure resource group ${resource_group} and remove local Terraform state."
    read -r -p "Type the project name to confirm nuke: " confirm
    [[ "${confirm}" == "${TF_VAR_project}" ]] || die "Cancelled."
  fi

  bastion_tunnel stop >/dev/null 2>&1 || true

  az account set --subscription "${TF_VAR_azure_subscription_id}" --only-show-errors
  if az group show --name "${resource_group}" --only-show-errors >/dev/null 2>&1; then
    warn "Deleting resource group ${resource_group}"
    az group delete --name "${resource_group}" --yes --no-wait --only-show-errors
    log "Waiting for ${resource_group} deletion to complete"
    local max_attempts=180
    local attempt=1
    while (( attempt <= max_attempts )); do
      if [[ "$(az group exists --name "${resource_group}" --output tsv --only-show-errors 2>/dev/null || printf 'true')" == "false" ]]; then
        break
      fi
      sleep 10
      ((attempt++))
    done

    if (( attempt > max_attempts )); then
      die "Timed out waiting for resource group ${resource_group} to delete. Check Azure activity logs and retry."
    fi
  else
    log "Resource group ${resource_group} is already absent."
  fi

  log "Removing local Terraform state and saved plans"
  rm -f terraform.tfstate terraform.tfstate.backup .terraform.tfstate.lock.info tfplan *.tfplan
  rm -f terraform.tfstate.*.backup
  clear_anyscale_cloud_deployment_id
  log "Nuke completed. Run ./scripts/setup.sh init before the next plan/apply if providers are not initialized."
}

###############################################################################
cmd="${1:-}"
case "${cmd}" in
  preflight)  preflight ;;
  tfvars)     render_tfvars ;;
  init)       tf_init ;;
  validate)   validate ;;
  plan)       plan ;;
  apply)      apply ;;
  outputs)    outputs ;;
  bastion)    shift; bastion "$@" ;;
  bastion-tunnel) shift; bastion_tunnel "$@" ;;
  kubeconfig) kubeconfig ;;
  kubeconfig-bastion) shift; kubeconfig_bastion "$@" ;;
  anyscale-workspace-ready) shift; anyscale_workspace_ready "$@" ;;
  workspace-intro-smoke) shift; workspace_intro_smoke "$@" ;;
  workspace-compute-ready) shift; workspace_compute_ready "$@" ;;
  post)       post ;;
  control-plane-egress-smoke) control_plane_egress_smoke ;;
  validate-focused) shift; validate_focused "$@" ;;
  validate-k8s) validate_k8s ;;
  validate-observability) validate_observability ;;
  functional-test) functional_test ;;
  status)     status ;;
  destroy)    destroy ;;
  nuke)       shift; nuke "$@" ;;
  all)        preflight; tf_init; validate; plan; apply; outputs ;;
  *) die "Usage: $0 {preflight|tfvars|init|validate|plan|apply|outputs|bastion|bastion-tunnel|kubeconfig|kubeconfig-bastion|anyscale-workspace-ready|workspace-intro-smoke|post|control-plane-egress-smoke|validate-focused|validate-k8s|validate-observability|functional-test|status|destroy|nuke|all}" ;;
esac

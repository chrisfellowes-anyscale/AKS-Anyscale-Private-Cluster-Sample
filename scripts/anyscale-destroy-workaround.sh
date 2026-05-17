#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
CACHE_DIR="${ROOT_DIR}/.cache"

LOG_INFO_PREFIX="anyscale-destroy-workaround"
LOG_WARN_PREFIX="anyscale-destroy-workaround"
LOG_ERROR_PREFIX="anyscale-destroy-workaround"

# shellcheck source=./lib/log.sh
source "${ROOT_DIR}/scripts/lib/log.sh"
# shellcheck source=./lib/timeout.sh
source "${ROOT_DIR}/scripts/lib/timeout.sh"

DEFAULT_ANYSCALE_HOST="https://console.azure.anyscale.com"
DEFAULT_TIMEOUT_SECONDS=900
DEFAULT_POLL_INTERVAL_SECONDS=20
SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS="${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS:-180}"
SETUP_TIMEOUT_AZURE_COMMAND_SECONDS="${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS:-180}"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/anyscale-destroy-workaround.sh [--timeout-seconds 900] [--poll-interval-seconds 20]

Temporary workaround for Azure-backed Anyscale cloud deletion. The script
drains the current cloud's workspaces and cluster sessions before issuing the
ARM delete for the Anyscale.Platform/clouds resource.
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_env_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Required environment variable is missing: ${name}"
}

anyscale_cli_bin() {
  printf '%s\n' "${ROOT_DIR}/.venv/bin/anyscale"
}

anyscale_python_bin() {
  printf '%s\n' "${ROOT_DIR}/.venv/bin/python"
}

load_env_defaults() {
  local existing_anyscale_host="${ANYSCALE_HOST:-}"
  local existing_anyscale_cloud_name="${ANYSCALE_CLOUD_NAME:-}"
  local existing_anyscale_cloud_arm_id="${ANYSCALE_CLOUD_ARM_ID:-}"
  local existing_subscription_id="${AZURE_SUBSCRIPTION_ID:-}"

  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
  fi

  [[ -n "${existing_anyscale_host}" ]] && export ANYSCALE_HOST="${existing_anyscale_host}"
  [[ -n "${existing_anyscale_cloud_name}" ]] && export ANYSCALE_CLOUD_NAME="${existing_anyscale_cloud_name}"
  [[ -n "${existing_anyscale_cloud_arm_id}" ]] && export ANYSCALE_CLOUD_ARM_ID="${existing_anyscale_cloud_arm_id}"
  [[ -n "${existing_subscription_id}" ]] && export AZURE_SUBSCRIPTION_ID="${existing_subscription_id}"
}

list_clouds_json() {
  local cli_bin="$1"

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" cloud list -j --no-interactive --max-items 200
}

list_workspaces_json() {
  local cli_bin="$1"

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 list -j --no-interactive --include-archived --max-items 500
}

cloud_exists_in_arm() {
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az resource show --ids "${ANYSCALE_CLOUD_ARM_ID}" --only-show-errors >/dev/null 2>&1
}

terminate_workspace() {
  local cli_bin="$1"
  local workspace_id="$2"
  local workspace_name="$3"
  local workspace_state="$4"
  local terminate_log="$5"
  local output

  if [[ "${workspace_state}" == "TERMINATED" ]]; then
    return 0
  fi

  if output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 terminate --id "${workspace_id}" 2>&1)"; then
    printf '%s\n' "${output}" >> "${terminate_log}"
    log "Terminate requested for workspace ${workspace_name} (${workspace_id})"
    return 0
  fi

  printf '%s\n' "${output}" >> "${terminate_log}"
  if grep -Eiq 'already.*terminated|currently in state: TERMINATED|currently in state: TERMINATING' <<<"${output}"; then
    warn "Workspace ${workspace_name} (${workspace_id}) was already terminating or terminated."
    return 0
  fi

  warn "Workspace terminate request failed for ${workspace_name} (${workspace_id}); continuing to direct cluster termination and final state checks."
  return 0
}

terminate_cluster_directly() {
  local python_bin="$1"
  local cluster_id="$2"
  local project_id="$3"
  local cluster_log="$4"
  local output

  [[ -n "${cluster_id}" && "${cluster_id}" != "null" ]] || return 0
  [[ -n "${project_id}" && "${project_id}" != "null" ]] || return 0

  if output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${python_bin}" - "${cluster_id}" "${project_id}" 2>&1 <<'PY'
import sys

from anyscale.controllers.cluster_controller import ClusterController

cluster_id = sys.argv[1]
project_id = sys.argv[2]

ClusterController().terminate(
    cluster_name=None,
    cluster_id=cluster_id,
    project_id=project_id,
    project_name=None,
    cloud_id=None,
    cloud_name=None,
)

print(f"terminate requested for {cluster_id}")
PY
  )"; then
    printf '%s\n' "${output}" >> "${cluster_log}"
    log "Direct cluster terminate requested for ${cluster_id}"
    return 0
  fi

  printf '%s\n' "${output}" >> "${cluster_log}"
  warn "Direct cluster terminate request failed for ${cluster_id}; the final ARM delete will decide whether teardown can continue."
}

wait_for_cloud_workspaces_terminated() {
  local cli_bin="$1"
  local cloud_id="$2"
  local timeout_seconds="$3"
  local poll_interval_seconds="$4"
  local run_dir="$5"
  local deadline current_epoch workspaces_json remaining remaining_count summary

  deadline=$(( $(date +%s) + timeout_seconds ))

  while true; do
    workspaces_json="$(list_workspaces_json "${cli_bin}")"
    printf '%s\n' "${workspaces_json}" > "${run_dir}/workspaces.latest.json"
    remaining="$(jq -c --arg cloud_id "${cloud_id}" '[.[] | select(.cloud_id == $cloud_id and .state != "TERMINATED")]' <<<"${workspaces_json}")"
    remaining_count="$(jq 'length' <<<"${remaining}")"

    if [[ "${remaining_count}" == "0" ]]; then
      log "All current-cloud workspaces reached TERMINATED before ARM delete."
      return 0
    fi

    summary="$(jq -r '.[] | "- \(.name) (\(.id)) state=\(.state) cluster=\(.cluster_id // "n/a")"' <<<"${remaining}")"
    warn "Waiting for current cloud workspaces to reach TERMINATED:"
    printf '%s\n' "${summary}"
    printf '%s\n' "${summary}" > "${run_dir}/workspaces.remaining.txt"

    current_epoch="$(date +%s)"
    if (( current_epoch >= deadline )); then
      die "Timed out waiting for current cloud workspaces to terminate. Inspect ${run_dir}/workspaces.latest.json and ${run_dir}/workspaces.remaining.txt before retrying destroy."
    fi

    sleep "${poll_interval_seconds}"
  done
}

delete_cloud_in_arm() {
  local run_dir="$1"
  local delete_log="${run_dir}/arm-delete.log"
  local output attempt max_attempts

  if ! cloud_exists_in_arm; then
    log "Azure resource ${ANYSCALE_CLOUD_ARM_ID} is already absent."
    return 0
  fi

  if output="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az resource delete --ids "${ANYSCALE_CLOUD_ARM_ID}" --only-show-errors 2>&1)"; then
    printf '%s\n' "${output}" > "${delete_log}"
  else
    printf '%s\n' "${output}" > "${delete_log}"
    die "Azure still refused to delete ${ANYSCALE_CLOUD_ARM_ID}. This temporary workaround runs before AKS teardown, so a failure here means the Anyscale control plane is still blocking cloud removal. See ${delete_log}."
  fi

  max_attempts=30
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! cloud_exists_in_arm; then
      log "Azure resource ${ANYSCALE_CLOUD_ARM_ID} was deleted before Terraform continued."
      return 0
    fi
    sleep 10
  done

  die "Azure accepted the delete for ${ANYSCALE_CLOUD_ARM_ID}, but the resource still exists after waiting. See ${delete_log}."
}

main() {
  local timeout_seconds="${DEFAULT_TIMEOUT_SECONDS}"
  local poll_interval_seconds="${DEFAULT_POLL_INTERVAL_SECONDS}"
  local cli_bin python_bin run_id run_dir
  local clouds_json cloud_id workspaces_json current_cloud_workspaces workspace_count
  local workspace_json workspace_id workspace_name workspace_state cluster_id project_id

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout-seconds)
        timeout_seconds="$2"
        shift 2
        ;;
      --poll-interval-seconds)
        poll_interval_seconds="$2"
        shift 2
        ;;
      --help|-h)
        usage
        return 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  [[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || die "--timeout-seconds must be a positive integer."
  [[ "${poll_interval_seconds}" =~ ^[1-9][0-9]*$ ]] || die "--poll-interval-seconds must be a positive integer."

  load_env_defaults

  export ANYSCALE_HOST="${ANYSCALE_HOST:-${DEFAULT_ANYSCALE_HOST}}"

  require_cmd az
  require_cmd jq
  cli_bin="$(anyscale_cli_bin)"
  python_bin="$(anyscale_python_bin)"
  [[ -x "${cli_bin}" ]] || die "Missing repo-local Anyscale CLI: ${cli_bin}"
  [[ -x "${python_bin}" ]] || die "Missing repo-local Python: ${python_bin}"

  require_env_var ANYSCALE_CLI_TOKEN
  require_env_var ANYSCALE_CLOUD_NAME
  require_env_var ANYSCALE_CLOUD_ARM_ID
  require_env_var AZURE_SUBSCRIPTION_ID

  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  run_dir="${CACHE_DIR}/anyscale-destroy-workaround-${run_id}"
  mkdir -p "${run_dir}"

  log "Running temporary Anyscale destroy workaround for ${ANYSCALE_CLOUD_NAME}"
  log "Artifacts will be written to ${run_dir}"

  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az account set --subscription "${AZURE_SUBSCRIPTION_ID}" --only-show-errors

  clouds_json="$(list_clouds_json "${cli_bin}")"
  printf '%s\n' "${clouds_json}" > "${run_dir}/clouds.json"
  cloud_id="$(jq -r --arg cloud_name "${ANYSCALE_CLOUD_NAME}" 'map(select(.name == $cloud_name)) | .[0].id // empty' <<<"${clouds_json}")"

  if [[ -z "${cloud_id}" ]]; then
    warn "Current cloud ${ANYSCALE_CLOUD_NAME} is not visible in the Anyscale cloud list. Falling back to direct ARM delete."
    delete_cloud_in_arm "${run_dir}"
    return 0
  fi

  log "Mapped ${ANYSCALE_CLOUD_NAME} to Anyscale cloud id ${cloud_id}"

  workspaces_json="$(list_workspaces_json "${cli_bin}")"
  printf '%s\n' "${workspaces_json}" > "${run_dir}/workspaces.before.json"
  current_cloud_workspaces="$(jq -c --arg cloud_id "${cloud_id}" '[.[] | select(.cloud_id == $cloud_id)]' <<<"${workspaces_json}")"
  workspace_count="$(jq 'length' <<<"${current_cloud_workspaces}")"

  if [[ "${workspace_count}" == "0" ]]; then
    log "No current-cloud workspaces were found for ${cloud_id}."
  else
    while IFS= read -r workspace_json; do
      [[ -n "${workspace_json}" ]] || continue
      workspace_id="$(jq -r '.id' <<<"${workspace_json}")"
      workspace_name="$(jq -r '.name' <<<"${workspace_json}")"
      workspace_state="$(jq -r '.state' <<<"${workspace_json}")"
      cluster_id="$(jq -r '.cluster_id // empty' <<<"${workspace_json}")"
      project_id="$(jq -r '.project_id // empty' <<<"${workspace_json}")"

      terminate_workspace "${cli_bin}" "${workspace_id}" "${workspace_name}" "${workspace_state}" "${run_dir}/workspace-terminate.log"
      terminate_cluster_directly "${python_bin}" "${cluster_id}" "${project_id}" "${run_dir}/cluster-terminate.log"
    done < <(jq -c '.[]' <<<"${current_cloud_workspaces}")
  fi

  wait_for_cloud_workspaces_terminated "${cli_bin}" "${cloud_id}" "${timeout_seconds}" "${poll_interval_seconds}" "${run_dir}"
  delete_cloud_in_arm "${run_dir}"

  workspaces_json="$(list_workspaces_json "${cli_bin}")"
  printf '%s\n' "${workspaces_json}" > "${run_dir}/workspaces.after.json"
  log "Temporary Anyscale destroy workaround completed successfully."
}

main "$@"
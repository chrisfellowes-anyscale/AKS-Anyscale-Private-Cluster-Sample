#!/usr/bin/env bash
###############################################################################
# End-to-end idempotency harness for the private AKS / Anyscale sample.
###############################################################################
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"
SETUP_SCRIPT="${ROOT_DIR}/scripts/setup.sh"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${ROOT_DIR}/.cache/idempotency-validation/${RUN_ID}"
LOG_DIR="${RUN_DIR}/logs"
SUMMARY_TSV="${RUN_DIR}/summary.tsv"
SUMMARY_MD="${RUN_DIR}/summary.md"
SUMMARY_JSON="${RUN_DIR}/summary.json"

include_teardown=false
include_force_teardown=false
destructive_ack=false
skip_workload=false

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/validate-idempotency.sh
  ./scripts/validate-idempotency.sh --skip-workload
  ./scripts/validate-idempotency.sh --include-teardown
  ./scripts/validate-idempotency.sh --include-force-teardown --i-understand-this-deletes-azure-resources

Default mode is non-destructive: deploy twice, verify twice, workload proof all
twice, then assert that Terraform has a no-op plan.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-teardown)
      include_teardown=true
      shift
      ;;
    --include-force-teardown)
      include_force_teardown=true
      shift
      ;;
    --i-understand-this-deletes-azure-resources)
      destructive_ack=true
      shift
      ;;
    --skip-workload)
      skip_workload=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${include_teardown}" == true && "${include_force_teardown}" == true ]]; then
  printf 'Use either --include-teardown or --include-force-teardown, not both.\n' >&2
  exit 1
fi

if [[ "${include_force_teardown}" == true && "${destructive_ack}" != true ]]; then
  printf 'Force teardown requires --i-understand-this-deletes-azure-resources.\n' >&2
  exit 1
fi

mkdir -p "${LOG_DIR}"
command -v jq >/dev/null 2>&1 || {
  printf 'Required command jq not found on PATH.\n' >&2
  exit 1
}
command -v kubectl >/dev/null 2>&1 || {
  printf 'Required command kubectl not found on PATH.\n' >&2
  exit 1
}
printf 'stage\tresult\tduration_seconds\tlog\n' > "${SUMMARY_TSV}"

run_harness_stage() {
  local stage_name="$1"
  shift

  local log_file start_epoch end_epoch duration_seconds exit_code
  log_file="${LOG_DIR}/${stage_name}.log"
  start_epoch="$(date +%s)"
  printf '[idempotency] %s started\n' "${stage_name}"

  set +e
  ( "$@" ) 2>&1 | tee "${log_file}"
  exit_code=${PIPESTATUS[0]}
  set -e

  end_epoch="$(date +%s)"
  duration_seconds=$((end_epoch - start_epoch))

  if [[ "${exit_code}" -eq 0 ]]; then
    printf '[idempotency] %s ok (%ss)\n' "${stage_name}" "${duration_seconds}"
    printf '%s\tPASS\t%s\t%s\n' "${stage_name}" "${duration_seconds}" "${log_file}" >> "${SUMMARY_TSV}"
    return 0
  fi

  printf '[idempotency] %s failed (%ss). See %s\n' "${stage_name}" "${duration_seconds}" "${log_file}" >&2
  printf '%s\tFAIL\t%s\t%s\n' "${stage_name}" "${duration_seconds}" "${log_file}" >> "${SUMMARY_TSV}"
  write_summaries
  exit "${exit_code}"
}

terraform_noop_plan() {
  local cluster_bootstrap_json kubeconfig_path plan_exit

  kubeconfig_path="${ROOT_DIR}/.cache/aks-anyscale-sample-harness/kubeconfig.bastion"
  if [[ ! -f "${kubeconfig_path}" ]]; then
    printf 'Missing Bastion-backed kubeconfig at %s. Run deploy before the no-op plan.\n' "${kubeconfig_path}" >&2
    return 1
  fi
  if ! KUBECONFIG="${kubeconfig_path}" kubectl --request-timeout=15s get --raw=/readyz >/dev/null 2>&1; then
    printf 'Bastion-backed kubeconfig at %s is not currently usable. Run deploy or verify --live to refresh it.\n' "${kubeconfig_path}" >&2
    return 1
  fi
  export KUBECONFIG="${kubeconfig_path}"
  export KUBE_CONFIG_PATH="${kubeconfig_path}"

  cluster_bootstrap_json="${TF_VAR_cluster_bootstrap:-{}}"
  if ! jq -e . >/dev/null 2>&1 <<<"${cluster_bootstrap_json}"; then
    cluster_bootstrap_json="{}"
  fi
  export TF_VAR_cluster_bootstrap
  TF_VAR_cluster_bootstrap="$(jq -cn \
    --argjson cluster_bootstrap "${cluster_bootstrap_json}" \
    --arg kubeconfig_path "${kubeconfig_path}" \
    '$cluster_bootstrap + {kubeconfig_path: $kubeconfig_path}')"

  pushd "${TERRAFORM_DIR}" >/dev/null
  set +e
  terraform plan \
    -input=false \
    -detailed-exitcode \
    -var="cluster_bootstrap=${TF_VAR_cluster_bootstrap}" \
    -out="${RUN_DIR}/idempotency.tfplan"
  plan_exit=$?
  set -e
  popd >/dev/null

  case "${plan_exit}" in
    0)
      return 0
      ;;
    2)
      printf 'Terraform reported a non-idempotent plan (detailed-exitcode=2).\n' >&2
      return 2
      ;;
    *)
      return "${plan_exit}"
      ;;
  esac
}

write_summaries() {
  {
    printf '# Idempotency Validation Summary\n\n'
    printf 'Run directory: `%s`\n\n' "${RUN_DIR}"
    printf '| Stage | Result | Duration | Log |\n'
    printf '|---|---:|---:|---|\n'
    tail -n +2 "${SUMMARY_TSV}" | while IFS=$'\t' read -r stage_name stage_result duration_seconds log_file; do
      printf '| `%s` | %s | %ss | `%s` |\n' "${stage_name}" "${stage_result}" "${duration_seconds}" "${log_file}"
    done
  } > "${SUMMARY_MD}"

  {
    printf '{\n'
    printf '  "run_dir": %s,\n' "$(printf '%s' "${RUN_DIR}" | jq -R .)"
    printf '  "stages": [\n'
    local first_stage=true
    while IFS=$'\t' read -r stage_name stage_result duration_seconds log_file; do
      if [[ "${stage_name}" == "stage" ]]; then
        continue
      fi
      if [[ "${first_stage}" == true ]]; then
        first_stage=false
      else
        printf ',\n'
      fi
      printf '    {"stage": %s, "result": %s, "duration_seconds": %s, "log": %s}' \
        "$(printf '%s' "${stage_name}" | jq -R .)" \
        "$(printf '%s' "${stage_result}" | jq -R .)" \
        "${duration_seconds}" \
        "$(printf '%s' "${log_file}" | jq -R .)"
    done < "${SUMMARY_TSV}"
    printf '\n  ]\n'
    printf '}\n'
  } > "${SUMMARY_JSON}"
}

run_harness_stage deploy-first "${SETUP_SCRIPT}" deploy
run_harness_stage verify-first "${SETUP_SCRIPT}" verify --full
if [[ "${skip_workload}" != true ]]; then
  run_harness_stage workload-first "${SETUP_SCRIPT}" workload proof all
fi

run_harness_stage deploy-second "${SETUP_SCRIPT}" deploy
run_harness_stage verify-second "${SETUP_SCRIPT}" verify --full
if [[ "${skip_workload}" != true ]]; then
  run_harness_stage workload-second "${SETUP_SCRIPT}" workload proof all
fi

run_harness_stage terraform-noop-plan terraform_noop_plan

if [[ "${include_teardown}" == true ]]; then
  run_harness_stage teardown "${SETUP_SCRIPT}" teardown
elif [[ "${include_force_teardown}" == true ]]; then
  run_harness_stage teardown-force "${SETUP_SCRIPT}" teardown --force --yes
fi

write_summaries
printf '[idempotency] summary: %s\n' "${SUMMARY_MD}"

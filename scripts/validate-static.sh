#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"
CACHE_DIR="${ROOT_DIR}/.cache"
REPORT_ROOT="${CACHE_DIR}/static-validation"
RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_DIR="${REPORT_ROOT}/${RUN_ID}"

# shellcheck source=./lib/timeout.sh
source "${ROOT_DIR}/scripts/lib/timeout.sh"

STATIC_VALIDATE_USE_LOGIN_SHELL="${STATIC_VALIDATE_USE_LOGIN_SHELL:-0}"
STATIC_TIMEOUT_AZURE_ACCOUNT_SECONDS="${STATIC_TIMEOUT_AZURE_ACCOUNT_SECONDS:-60}"
STATIC_TIMEOUT_TERRAFORM_FMT_SECONDS="${STATIC_TIMEOUT_TERRAFORM_FMT_SECONDS:-300}"
STATIC_TIMEOUT_TERRAFORM_INIT_SECONDS="${STATIC_TIMEOUT_TERRAFORM_INIT_SECONDS:-900}"
STATIC_TIMEOUT_TERRAFORM_VALIDATE_SECONDS="${STATIC_TIMEOUT_TERRAFORM_VALIDATE_SECONDS:-600}"
STATIC_TIMEOUT_TERRAFORM_TEST_SECONDS="${STATIC_TIMEOUT_TERRAFORM_TEST_SECONDS:-1200}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { printf "${GREEN}[static-validate]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
die()  { printf "${RED}[error]${NC} %s\n" "$*" >&2; exit 1; }

RESULTS=()
PASS_COUNT=0
FAIL_COUNT=0

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found on PATH."
}

azure_account_field() {
  local query="$1"
  local value="" login_command=""

  value="$(run_with_timeout "${STATIC_TIMEOUT_AZURE_ACCOUNT_SECONDS}" az account show --query "${query}" --output tsv --only-show-errors 2>/dev/null || true)"
  if [[ -z "${value}" && "${STATIC_VALIDATE_USE_LOGIN_SHELL}" == "1" ]]; then
    printf -v login_command '%q ' az account show --query "${query}" --output tsv --only-show-errors
    value="$(run_with_timeout "${STATIC_TIMEOUT_AZURE_ACCOUNT_SECONDS}" bash -lc "${login_command% }" 2>/dev/null || true)"
  fi

  printf '%s\n' "${value}"
}

display_path() {
  local path="$1"
  if [[ "${path}" == "${ROOT_DIR}"/* ]]; then
    printf '%s\n' "${path#${ROOT_DIR}/}"
    return 0
  fi
  printf '%s\n' "${path}"
}

record_result() {
  local status="$1"
  local label="$2"
  local logfile="$3"

  RESULTS+=("${status}|${label}|${logfile}")
  case "${status}" in
    PASS) ((PASS_COUNT+=1)) ;;
    FAIL) ((FAIL_COUNT+=1)) ;;
  esac
}

run_check() {
  local check_id="$1"
  local label="$2"
  shift 2

  local logfile display_logfile
  logfile="${REPORT_DIR}/${check_id}.log"
  display_logfile="$(display_path "${logfile}")"

  printf '\n==> %s\n' "${label}"
  if "$@" 2>&1 | tee "${logfile}"; then
    record_result "PASS" "${label}" "${display_logfile}"
    printf '[PASS] %s\n' "${label}"
    return 0
  fi

  record_result "FAIL" "${label}" "${display_logfile}"
  printf '[FAIL] %s\n' "${label}"
  printf '       log: %s\n' "${display_logfile}"
  return 1
}

write_summary() {
  local summary_file display_summary result status label logfile
  summary_file="${REPORT_DIR}/summary.txt"
  display_summary="$(display_path "${summary_file}")"

  {
    printf 'Static validation run: %s\n' "${RUN_ID}"
    printf '%-6s %-44s %s\n' "STATUS" "CHECK" "LOG"
    printf '%-6s %-44s %s\n' "------" "--------------------------------------------" "---"
    for result in "${RESULTS[@]}"; do
      IFS='|' read -r status label logfile <<<"${result}"
      printf '%-6s %-44s %s\n' "${status}" "${label}" "${logfile}"
    done
    printf '\npass=%s fail=%s\n' "${PASS_COUNT}" "${FAIL_COUNT}"
  } | tee "${summary_file}"

  log "Static validation summary written to ${display_summary}"
}

ensure_azure_cli_context() {
  require_cmd az
  local subscription_id tenant_id

  subscription_id="$(azure_account_field id)"
  tenant_id="$(azure_account_field tenantId)"

  if [[ -z "${subscription_id}" || -z "${tenant_id}" ]]; then
    die "Azure CLI is not authenticated. Run 'az login' locally or configure azure/login in CI."
  fi

  if [[ -z "${ARM_SUBSCRIPTION_ID:-}" ]]; then
    export ARM_SUBSCRIPTION_ID
    ARM_SUBSCRIPTION_ID="${subscription_id}"
  fi

  if [[ -z "${ARM_TENANT_ID:-}" ]]; then
    export ARM_TENANT_ID
    ARM_TENANT_ID="${tenant_id}"
  fi

  export ARM_USE_CLI="${ARM_USE_CLI:-true}"
}

terraform_fmt_check() {
  run_with_timeout "${STATIC_TIMEOUT_TERRAFORM_FMT_SECONDS}" terraform -chdir="${TERRAFORM_DIR}" fmt -recursive -check
}

terraform_init_static() {
  run_with_timeout "${STATIC_TIMEOUT_TERRAFORM_INIT_SECONDS}" terraform -chdir="${TERRAFORM_DIR}" init -backend=false -input=false
}

terraform_validate_config() {
  run_with_timeout "${STATIC_TIMEOUT_TERRAFORM_VALIDATE_SECONDS}" terraform -chdir="${TERRAFORM_DIR}" validate
}

terraform_test_plan() {
  run_with_timeout "${STATIC_TIMEOUT_TERRAFORM_TEST_SECONDS}" terraform -chdir="${TERRAFORM_DIR}" test -filter=tests/plan.tftest.hcl
}

terraform_test_identity() {
  run_with_timeout "${STATIC_TIMEOUT_TERRAFORM_TEST_SECONDS}" terraform -chdir="${TERRAFORM_DIR}" test -filter=tests/identity_contract.tftest.hcl
}

terraform_test_private_mode() {
  run_with_timeout "${STATIC_TIMEOUT_TERRAFORM_TEST_SECONDS}" terraform -chdir="${TERRAFORM_DIR}" test -filter=tests/private_mode.tftest.hcl
}

main() {
  require_cmd terraform
  require_cmd tee
  mkdir -p "${REPORT_DIR}"

  ensure_azure_cli_context

  log "Running static Terraform validation suite"
  run_check "terraform-fmt" "terraform fmt -check" terraform_fmt_check || true
  run_check "terraform-init" "terraform init -backend=false" terraform_init_static || true
  run_check "terraform-validate" "terraform validate" terraform_validate_config || true
  run_check "terraform-test-plan" "terraform test plan contract" terraform_test_plan || true
  run_check "terraform-test-identity" "terraform test identity contract" terraform_test_identity || true
  run_check "terraform-test-private-mode" "terraform test private-mode contract" terraform_test_private_mode || true

  write_summary
  [[ "${FAIL_COUNT}" -eq 0 ]]
}

main "$@"

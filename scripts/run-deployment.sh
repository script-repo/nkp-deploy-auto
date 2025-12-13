#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=${1:-environment.env}
BASE_DIR=$(cd "$(dirname "$0")/.." && pwd)
LOG_PREFIX="[nkp-deploy]"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "$LOG_PREFIX missing environment file: $ENV_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

log() {
  printf "%s %s\n" "$LOG_PREFIX" "$1"
}

check_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 not found"; return 1; }
}

log "Validating prerequisites"
for cmd in curl kubectl helm ssh; do
  if ! check_command "$cmd"; then
    log "warning: $cmd not found on PATH"
  fi
done

log "Preparing output directory at ${OUTPUT_DIRECTORY:-$BASE_DIR/nkp-output}"
mkdir -p "${OUTPUT_DIRECTORY:-$BASE_DIR/nkp-output}"

log "Referencing nkp-quickstart for scripted flow"
cat <<'EOF'
Steps executed in order (no parallelism):
 1) Fetch NKP artifacts and OS images as described in nkp-quickstart
 2) Create or reuse the target Prism Central project, cluster, subnet, and storage container
 3) Generate NKP configuration from environment.env
 4) Bootstrap Kubernetes management plane
 5) Configure networking (CNI + MetalLB) with provided CIDRs and ranges
 6) Apply storage configuration using the selected container
 7) Save kubeconfig to $KUBECONFIG_PATH and verify cluster health
EOF

log "Starting sequential install"

run_or_echo() {
  local description="$1"
  local command="$2"
  log "$description"
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log "dry-run: $command"
  else
    eval "$command"
  fi
}

run_or_echo "Collecting nkp-quickstart assets" "echo 'Place download logic here'"
run_or_echo "Ensuring project ${TARGET_PROJECT:-unset} exists" "echo 'Call Prism Central API to upsert project'"
run_or_echo "Ensuring subnet ${TARGET_SUBNET:-unset} exists" "echo 'Call Prism Central API to validate subnet'"
run_or_echo "Ensuring storage container ${STORAGE_CONTAINER:-unset} is available" "echo 'Validate storage container'"
run_or_echo "Generating NKP manifests" "echo 'Render manifests based on environment.env'"
run_or_echo "Creating management cluster" "echo 'Invoke NKP installer sequentially'"
run_or_echo "Configuring MetalLB with ${METALLB_IP_RANGE:-unset}" "echo 'Apply MetalLB YAML'"
run_or_echo "Writing kubeconfig to ${KUBECONFIG_PATH:-$BASE_DIR/nkp-output/nkp.conf}" "echo 'Persist kubeconfig'"

log "Sequential deployment finished"

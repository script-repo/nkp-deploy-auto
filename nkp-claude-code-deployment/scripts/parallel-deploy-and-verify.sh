#!/bin/bash
# =============================================================================
# Parallel End-to-End NKP Deployment Runner
# - Runs prerequisite validation and node preparation in parallel
# - Executes deployment and verification with logging
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${ROOT_DIR}/environment.env"

if [ ! -f "${ENV_FILE}" ]; then
    echo "environment.env not found at ${ENV_FILE}." >&2
    exit 1
fi

# Load environment variables for downstream scripts
source "${ENV_FILE}"

LOG_DIR="${ROOT_DIR}/logs"
RUN_ID=$(date +%Y%m%d%H%M%S)
mkdir -p "${LOG_DIR}"

SUMMARY_FILE="${LOG_DIR}/parallel-deploy-${RUN_ID}.summary"
PARALLEL_TASK_LOG_DIR="${LOG_DIR}/parallel-tasks-${RUN_ID}"
mkdir -p "${PARALLEL_TASK_LOG_DIR}"

declare -A TASK_PIDS=()
declare -A TASK_LOGS=()

SKIP_PREP=false
SKIP_VERIFY=false

usage() {
    cat <<USAGE
Parallel NKP deployment runner

Usage: $(basename "$0") [--skip-prepare] [--skip-verify]

Options:
  --skip-prepare    Skip parallel node preparation (swap, services, kernel tuning)
  --skip-verify     Skip post-deployment verification
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-prepare)
            SKIP_PREP=true
            shift
            ;;
        --skip-verify)
            SKIP_VERIFY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

echo "==========================================================" | tee -a "${SUMMARY_FILE}"
echo " Parallel NKP Deployment (validation + prep in parallel)" | tee -a "${SUMMARY_FILE}"
echo " Cluster: ${CLUSTER_NAME}" | tee -a "${SUMMARY_FILE}"
echo " Run ID: ${RUN_ID}" | tee -a "${SUMMARY_FILE}"
echo " Logs: ${LOG_DIR}" | tee -a "${SUMMARY_FILE}"
echo "==========================================================" | tee -a "${SUMMARY_FILE}"
echo "" | tee -a "${SUMMARY_FILE}"

start_parallel_task() {
    local name=$1
    shift
    local log_file="${PARALLEL_TASK_LOG_DIR}/${name}.log"

    echo "[START] ${name} -> ${log_file}" | tee -a "${SUMMARY_FILE}"
    ("$@") &> "${log_file}" &
    local pid=$!

    TASK_PIDS[$pid]="${name}"
    TASK_LOGS[$pid]="${log_file}"
}

wait_for_parallel_tasks() {
    local failures=0

    for pid in "${!TASK_PIDS[@]}"; do
        local task_name="${TASK_PIDS[$pid]}"
        local log_file="${TASK_LOGS[$pid]}"

        if wait "$pid"; then
            echo "[DONE] ${task_name}" | tee -a "${SUMMARY_FILE}"
        else
            echo "[FAIL] ${task_name} (see ${log_file})" | tee -a "${SUMMARY_FILE}"
            ((failures++))
        fi
    done

    return ${failures}
}

run_serial_step() {
    local name=$1
    shift
    local log_file="${LOG_DIR}/${RUN_ID}-${name}.log"

    echo "[START] ${name} -> ${log_file}" | tee -a "${SUMMARY_FILE}"
    if "$@" &> "${log_file}"; then
        echo "[DONE] ${name}" | tee -a "${SUMMARY_FILE}"
    else
        echo "[FAIL] ${name} (see ${log_file})" | tee -a "${SUMMARY_FILE}"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Phase 1: Parallel validation + optional preparation
# -----------------------------------------------------------------------------
start_parallel_task "validate-prereqs" "${SCRIPT_DIR}/parallel-validate.sh"

if [ "${SKIP_PREP}" = false ]; then
    start_parallel_task "prepare-nodes" "${SCRIPT_DIR}/parallel-prepare-nodes.sh"
else
    echo "[SKIP] Node preparation" | tee -a "${SUMMARY_FILE}"
fi

if ! wait_for_parallel_tasks; then
    echo "One or more parallel tasks failed. Check logs under ${PARALLEL_TASK_LOG_DIR}." | tee -a "${SUMMARY_FILE}"
    exit 1
fi

echo "" | tee -a "${SUMMARY_FILE}"
echo "Parallel tasks completed successfully. Proceeding to deployment." | tee -a "${SUMMARY_FILE}"
echo "" | tee -a "${SUMMARY_FILE}"

# -----------------------------------------------------------------------------
# Phase 2: Deployment
# -----------------------------------------------------------------------------
run_serial_step "deploy-nkp" "${SCRIPT_DIR}/deploy-nkp.sh"

# -----------------------------------------------------------------------------
# Phase 3: Verification (optional)
# -----------------------------------------------------------------------------
if [ "${SKIP_VERIFY}" = false ]; then
    run_serial_step "verify-deployment" "${SCRIPT_DIR}/verify-deployment.sh"
else
    echo "[SKIP] Verification" | tee -a "${SUMMARY_FILE}"
fi

echo "" | tee -a "${SUMMARY_FILE}"
echo "==========================================================" | tee -a "${SUMMARY_FILE}"
echo " Parallel deployment run complete" | tee -a "${SUMMARY_FILE}"
echo " Summary log: ${SUMMARY_FILE}" | tee -a "${SUMMARY_FILE}"
echo " Individual task logs: ${PARALLEL_TASK_LOG_DIR}" | tee -a "${SUMMARY_FILE}"
echo "==========================================================" | tee -a "${SUMMARY_FILE}"

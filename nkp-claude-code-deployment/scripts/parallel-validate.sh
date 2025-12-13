#!/bin/bash
# =============================================================================
# Parallel Validation Orchestrator
# Runs validation checks concurrently across all nodes and bastion
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Load environment
if [ -f "${ROOT_DIR}/environment.env" ]; then
    source "${ROOT_DIR}/environment.env"
else
    echo -e "${RED}ERROR: environment.env not found${NC}"
    exit 1
fi

expand_path() {
    local path="$1"
    [[ -z "${path}" ]] && return
    if [[ "${path}" == "~"* ]]; then
        path="${path/#\~/${HOME}}"
    fi
    realpath -m "${path}"
}

SSH_PRIVATE_KEY_FILE="$(expand_path "${SSH_PRIVATE_KEY_FILE}")"

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN} NKP Parallel Pre-flight Validation${NC}"
echo -e "${CYAN} Cluster: ${CLUSTER_NAME}${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo ""

# Create temp directory for results
RESULTS_DIR="/tmp/nkp-validation-$$"
mkdir -p "${RESULTS_DIR}"

# Track PIDs for parallel processes
declare -a PIDS
declare -A PID_NAMES

# =============================================================================
# FUNCTION: Launch parallel task
# =============================================================================
launch_task() {
    local name=$1
    local cmd=$2
    local log_file="${RESULTS_DIR}/${name}.log"
    
    echo -e "${BLUE}[LAUNCH]${NC} Starting: ${name}"
    
    # Run in background, capture output
    eval "${cmd}" > "${log_file}" 2>&1 &
    local pid=$!
    
    PIDS+=($pid)
    PID_NAMES[$pid]="${name}"
}

# =============================================================================
# TASK 1: Bastion Host Validation
# =============================================================================
bastion_check() {
    echo "=== Bastion Host Validation ==="
    local passed=0
    local failed=0
    
    # Docker check
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        echo "[PASS] Docker is installed and running"
        ((passed++))
    elif command -v podman &> /dev/null; then
        echo "[PASS] Podman is installed"
        ((passed++))
    else
        echo "[FAIL] Neither Docker nor Podman available"
        ((failed++))
    fi
    
    # kubectl check
    if command -v kubectl &> /dev/null; then
        echo "[PASS] kubectl is installed"
        ((passed++))
    else
        echo "[FAIL] kubectl not found"
        ((failed++))
    fi
    
    # helm check
    if command -v helm &> /dev/null; then
        echo "[PASS] helm is installed"
        ((passed++))
    else
        echo "[FAIL] helm not found"
        ((failed++))
    fi
    
    # Disk space
    local disk_free=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "${disk_free}" -ge 50 ]; then
        echo "[PASS] Disk space: ${disk_free}GB free"
        ((passed++))
    else
        echo "[FAIL] Insufficient disk: ${disk_free}GB (need 50GB+)"
        ((failed++))
    fi
    
    # nkp binary
    if [ -f "./nkp" ] || command -v nkp &> /dev/null; then
        echo "[PASS] nkp binary found"
        ((passed++))
    else
        echo "[WARN] nkp binary not found (will need to download)"
    fi
    
    # SSH key
    if [ -f "${SSH_PRIVATE_KEY_FILE}" ]; then
        echo "[PASS] SSH key exists: ${SSH_PRIVATE_KEY_FILE}"
        ((passed++))
    else
        echo "[FAIL] SSH key not found: ${SSH_PRIVATE_KEY_FILE}"
        ((failed++))
    fi
    
    echo ""
    echo "Bastion: ${passed} passed, ${failed} failed"
    
    if [ ${failed} -gt 0 ]; then
        return 1
    fi
    return 0
}

# =============================================================================
# TASK 2: Network Validation
# =============================================================================
network_check() {
    echo "=== Network Validation ==="
    local passed=0
    local failed=0
    
    # VIP check
    if ! ping -c 1 -W 2 "${CONTROL_PLANE_ENDPOINT_HOST}" &> /dev/null; then
        echo "[PASS] Control plane VIP ${CONTROL_PLANE_ENDPOINT_HOST} is available"
        ((passed++))
    else
        echo "[FAIL] VIP ${CONTROL_PLANE_ENDPOINT_HOST} is already in use"
        ((failed++))
    fi
    
    # MetalLB first IP
    if [ -n "${METALLB_IP_RANGE}" ]; then
        local start_ip=$(echo ${METALLB_IP_RANGE} | cut -d'-' -f1)
        if ! ping -c 1 -W 2 "${start_ip}" &> /dev/null; then
            echo "[PASS] First MetalLB IP ${start_ip} is available"
            ((passed++))
        else
            echo "[WARN] MetalLB IP ${start_ip} responds to ping"
        fi
    fi
    
    # DNS resolution for nodes
    for node in ${ALL_NODES}; do
        if host ${node} &> /dev/null || ping -c 1 -W 2 ${node} &> /dev/null; then
            echo "[PASS] Can reach ${node}"
            ((passed++))
        else
            echo "[WARN] Cannot resolve/reach ${node}"
        fi
    done
    
    echo ""
    echo "Network: ${passed} passed, ${failed} failed"
    
    if [ ${failed} -gt 0 ]; then
        return 1
    fi
    return 0
}

# =============================================================================
# LAUNCH ALL PARALLEL TASKS
# =============================================================================

echo -e "${CYAN}Launching parallel validation tasks...${NC}"
echo ""

# Task 1: Bastion validation (local)
launch_task "bastion" "bastion_check"

# Task 2: Network validation (local)
launch_task "network" "network_check"

# Task 3+: Node validations (parallel per node)
for node in ${ALL_NODES}; do
    node_name=$(echo ${node} | tr '.' '-')
    launch_task "node-${node_name}" "bash ${SCRIPT_DIR}/validate-node.sh ${node} ${SSH_USER} ${SSH_PRIVATE_KEY_FILE}"
done

echo ""
echo -e "${CYAN}Waiting for all validations to complete...${NC}"
echo ""

# =============================================================================
# WAIT FOR ALL TASKS AND COLLECT RESULTS
# =============================================================================

TOTAL_TASKS=${#PIDS[@]}
COMPLETED=0
FAILED_TASKS=0

for pid in "${PIDS[@]}"; do
    task_name="${PID_NAMES[$pid]}"
    
    if wait $pid; then
        echo -e "${GREEN}[DONE]${NC} ${task_name} completed successfully"
    else
        echo -e "${RED}[FAIL]${NC} ${task_name} failed"
        ((FAILED_TASKS++))
    fi
    ((COMPLETED++))
    
    # Show progress
    echo -e "Progress: ${COMPLETED}/${TOTAL_TASKS} tasks complete"
done

# =============================================================================
# AGGREGATE AND REPORT RESULTS
# =============================================================================

echo ""
echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN} Validation Summary${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo ""

# Show all log files
echo "Detailed logs:"
for log in ${RESULTS_DIR}/*.log; do
    if [ -f "$log" ]; then
        task=$(basename "$log" .log)
        echo ""
        echo -e "${BLUE}--- ${task} ---${NC}"
        cat "$log"
    fi
done

echo ""
echo -e "${CYAN}=====================================================${NC}"
echo -e "Total Tasks: ${TOTAL_TASKS}"
echo -e "${GREEN}Successful: $((TOTAL_TASKS - FAILED_TASKS))${NC}"
echo -e "${RED}Failed: ${FAILED_TASKS}${NC}"
echo -e "${CYAN}=====================================================${NC}"

# Cleanup
rm -rf "${RESULTS_DIR}"

if [ ${FAILED_TASKS} -gt 0 ]; then
    echo ""
    echo -e "${RED}Pre-flight validation FAILED. Please fix issues before proceeding.${NC}"
    exit 1
else
    echo ""
    echo -e "${GREEN}All pre-flight checks passed!${NC}"
    exit 0
fi

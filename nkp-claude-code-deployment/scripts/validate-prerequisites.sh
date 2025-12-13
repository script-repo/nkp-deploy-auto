#!/bin/bash
# =============================================================================
# NKP Pre-flight Validation Script
# Validates all prerequisites before NKP deployment
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED++))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((WARNINGS++))
}

check_command() {
    if command -v "$1" &> /dev/null; then
        log_pass "$1 is installed: $(command -v $1)"
        return 0
    else
        log_fail "$1 is not installed"
        return 1
    fi
}

ssh_exec() {
    local host=$1
    local cmd=$2
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i "${SSH_PRIVATE_KEY_FILE}" "${SSH_USER}@${host}" "${cmd}" 2>/dev/null
}

# =============================================================================
# LOAD ENVIRONMENT
# =============================================================================

if [ -f "./environment.env" ]; then
    source ./environment.env
    log_info "Loaded environment from ./environment.env"
elif [ -f "./environment.env.template" ]; then
    log_fail "environment.env not found. Copy environment.env.template to environment.env and fill in values."
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

# Validate required variables
REQUIRED_VARS=(
    "CLUSTER_NAME"
    "CONTROL_PLANE_ENDPOINT_HOST"
    "SSH_USER"
    "SSH_PRIVATE_KEY_FILE"
    "METALLB_IP_RANGE"
)

log_info "=============================================="
log_info "NKP Pre-flight Validation"
log_info "Cluster: ${CLUSTER_NAME}"
log_info "=============================================="

echo ""
log_info "Checking required environment variables..."
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        log_fail "Required variable ${var} is not set"
    else
        log_pass "${var} is set"
    fi
done

# =============================================================================
# BASTION HOST CHECKS
# =============================================================================

echo ""
log_info "=============================================="
log_info "Bastion Host Prerequisites"
log_info "=============================================="

# Check Docker or Podman
if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
    log_pass "Docker is installed: v${DOCKER_VERSION}"
    
    if docker info &> /dev/null; then
        log_pass "Docker daemon is running"
    else
        log_fail "Docker daemon is not running or not accessible"
    fi
elif command -v podman &> /dev/null; then
    PODMAN_VERSION=$(podman --version | grep -oP '\d+\.\d+' | head -1)
    log_pass "Podman is installed: v${PODMAN_VERSION}"
else
    log_fail "Neither Docker nor Podman is installed"
fi

# Check kubectl
check_command kubectl
if command -v kubectl &> /dev/null; then
    KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo "unknown")
    log_info "kubectl version: ${KUBECTL_VERSION}"
fi

# Check helm
check_command helm

# Check nkp binary
if [ -f "./nkp" ]; then
    log_pass "nkp binary found in current directory"
    NKP_VERSION=$(./nkp version 2>/dev/null || echo "unknown")
    log_info "nkp version: ${NKP_VERSION}"
elif command -v nkp &> /dev/null; then
    log_pass "nkp binary found in PATH"
else
    log_warn "nkp binary not found - will need to be downloaded"
fi

# Check disk space
DISK_FREE=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "${DISK_FREE}" -ge 50 ]; then
    log_pass "Sufficient disk space: ${DISK_FREE}GB free"
else
    log_fail "Insufficient disk space: ${DISK_FREE}GB free (need 50GB+)"
fi

# Check SSH key exists
if [ -f "${SSH_PRIVATE_KEY_FILE}" ]; then
    log_pass "SSH private key exists: ${SSH_PRIVATE_KEY_FILE}"
else
    log_fail "SSH private key not found: ${SSH_PRIVATE_KEY_FILE}"
fi

# =============================================================================
# SSH CONNECTIVITY CHECKS
# =============================================================================

echo ""
log_info "=============================================="
log_info "SSH Connectivity Tests"
log_info "=============================================="

for node in ${ALL_NODES}; do
    if ssh_exec "${node}" "echo OK" | grep -q "OK"; then
        log_pass "SSH connection to ${node} successful"
    else
        log_fail "SSH connection to ${node} failed"
    fi
done

# =============================================================================
# NODE PREREQUISITES
# =============================================================================

echo ""
log_info "=============================================="
log_info "Node Prerequisites"
log_info "=============================================="

for node in ${ALL_NODES}; do
    log_info "--- Checking node: ${node} ---"
    
    # Check swap
    SWAP=$(ssh_exec "${node}" "swapon --show 2>/dev/null | wc -l")
    if [ "${SWAP}" == "0" ]; then
        log_pass "${node}: Swap is disabled"
    else
        log_fail "${node}: Swap is enabled"
    fi
    
    # Check iscsid
    ISCSID=$(ssh_exec "${node}" "systemctl is-active iscsid 2>/dev/null || echo inactive")
    if [ "${ISCSID}" == "active" ]; then
        log_pass "${node}: iscsid is running"
    else
        log_warn "${node}: iscsid is not running (required for some storage)"
    fi
    
    # Check firewalld
    FIREWALLD=$(ssh_exec "${node}" "systemctl is-active firewalld 2>/dev/null || echo inactive")
    if [ "${FIREWALLD}" == "inactive" ]; then
        log_pass "${node}: firewalld is disabled"
    else
        log_warn "${node}: firewalld is active (may need configuration)"
    fi
    
    # Check disk space
    ROOT_FREE=$(ssh_exec "${node}" "df -BG / | awk 'NR==2 {print \$4}' | sed 's/G//'")
    if [ "${ROOT_FREE:-0}" -ge 20 ]; then
        log_pass "${node}: Sufficient root disk space: ${ROOT_FREE}GB"
    else
        log_fail "${node}: Insufficient root disk space: ${ROOT_FREE}GB"
    fi
    
    # Check required ports
    for port in 6443 2379 2380 10250 10251 10252; do
        PORT_CHECK=$(ssh_exec "${node}" "ss -tlnp | grep -c :${port} || echo 0")
        if [ "${PORT_CHECK:-0}" == "0" ]; then
            log_pass "${node}: Port ${port} is available"
        else
            log_warn "${node}: Port ${port} appears to be in use"
        fi
    done
done

# =============================================================================
# NETWORK CHECKS
# =============================================================================

echo ""
log_info "=============================================="
log_info "Network Validation"
log_info "=============================================="

# Check control plane VIP is not in use
ping -c 1 -W 2 "${CONTROL_PLANE_ENDPOINT_HOST}" &> /dev/null
if [ $? -eq 0 ]; then
    log_fail "Control plane VIP ${CONTROL_PLANE_ENDPOINT_HOST} is already in use"
else
    log_pass "Control plane VIP ${CONTROL_PLANE_ENDPOINT_HOST} is available"
fi

# Check MetalLB IPs are not in use
if [ -n "${METALLB_IP_RANGE}" ]; then
    START_IP=$(echo ${METALLB_IP_RANGE} | cut -d'-' -f1)
    log_info "Testing first MetalLB IP: ${START_IP}"
    ping -c 1 -W 2 "${START_IP}" &> /dev/null
    if [ $? -eq 0 ]; then
        log_warn "First MetalLB IP ${START_IP} responds to ping (may be in use)"
    else
        log_pass "First MetalLB IP ${START_IP} appears available"
    fi
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
log_info "=============================================="
log_info "Validation Summary"
log_info "=============================================="
echo -e "${GREEN}Passed:${NC}   ${PASSED}"
echo -e "${YELLOW}Warnings:${NC} ${WARNINGS}"
echo -e "${RED}Failed:${NC}   ${FAILED}"
echo ""

if [ ${FAILED} -gt 0 ]; then
    log_fail "Pre-flight validation FAILED. Please fix the issues above before proceeding."
    exit 1
else
    if [ ${WARNINGS} -gt 0 ]; then
        log_warn "Pre-flight validation passed with warnings. Review warnings before proceeding."
    else
        log_pass "All pre-flight checks passed!"
    fi
    exit 0
fi

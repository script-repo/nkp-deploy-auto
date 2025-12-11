#!/bin/bash
# =============================================================================
# Parallel Node Preparation Script
# Prepares all nodes concurrently for NKP deployment
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

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN} NKP Parallel Node Preparation${NC}"
echo -e "${CYAN}=====================================================${NC}"
echo ""

# Track background jobs
declare -a PIDS
declare -A PID_NODES

# =============================================================================
# Prepare a single node
# =============================================================================
prepare_node() {
    local node=$1
    local ssh_user=$2
    local ssh_key=$3
    
    echo "[${node}] Starting preparation..."
    
    ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -i "${ssh_key}" "${ssh_user}@${node}" bash << 'REMOTE_SCRIPT'
        set -e
        
        echo "[$(hostname)] Disabling swap..."
        sudo swapoff -a 2>/dev/null || true
        sudo sed -i '/swap/d' /etc/fstab 2>/dev/null || true
        
        echo "[$(hostname)] Enabling iscsid..."
        sudo systemctl enable iscsid 2>/dev/null || true
        sudo systemctl start iscsid 2>/dev/null || true
        
        echo "[$(hostname)] Configuring firewall..."
        sudo systemctl disable firewalld 2>/dev/null || true
        sudo systemctl stop firewalld 2>/dev/null || true
        
        echo "[$(hostname)] Setting up kernel modules..."
        sudo modprobe br_netfilter 2>/dev/null || true
        sudo modprobe overlay 2>/dev/null || true
        
        echo "[$(hostname)] Configuring sysctl..."
        cat << 'SYSCTL' | sudo tee /etc/sysctl.d/99-kubernetes.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL
        sudo sysctl --system > /dev/null 2>&1 || true
        
        echo "[$(hostname)] Verifying configuration..."
        echo "  Swap: $(swapon --show 2>/dev/null | wc -l) entries"
        echo "  iscsid: $(systemctl is-active iscsid 2>/dev/null || echo 'not installed')"
        echo "  firewalld: $(systemctl is-active firewalld 2>/dev/null || echo 'inactive')"
        echo "  IP forward: $(cat /proc/sys/net/ipv4/ip_forward)"
        
        echo "[$(hostname)] Preparation complete!"
REMOTE_SCRIPT
    
    return $?
}

# =============================================================================
# Launch preparation for all nodes in parallel
# =============================================================================

echo -e "${BLUE}Launching parallel node preparation...${NC}"
echo ""

for node in ${ALL_NODES}; do
    echo -e "${BLUE}[LAUNCH]${NC} Preparing node: ${node}"
    
    # Run in background
    prepare_node "${node}" "${SSH_USER}" "${SSH_PRIVATE_KEY_FILE}" &
    pid=$!
    
    PIDS+=($pid)
    PID_NODES[$pid]="${node}"
done

echo ""
echo -e "${CYAN}All preparation jobs launched. Waiting for completion...${NC}"
echo ""

# =============================================================================
# Wait for all jobs
# =============================================================================

FAILED=0
for pid in "${PIDS[@]}"; do
    node="${PID_NODES[$pid]}"
    
    if wait $pid; then
        echo -e "${GREEN}[SUCCESS]${NC} ${node} prepared successfully"
    else
        echo -e "${RED}[FAILED]${NC} ${node} preparation failed"
        ((FAILED++))
    fi
done

# =============================================================================
# Summary
# =============================================================================

echo ""
echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN} Preparation Summary${NC}"
echo -e "${CYAN}=====================================================${NC}"

TOTAL=$(echo ${ALL_NODES} | wc -w)
SUCCESS=$((TOTAL - FAILED))

echo -e "Total Nodes: ${TOTAL}"
echo -e "${GREEN}Successful: ${SUCCESS}${NC}"
echo -e "${RED}Failed: ${FAILED}${NC}"

if [ ${FAILED} -gt 0 ]; then
    echo ""
    echo -e "${RED}Some nodes failed preparation. Check SSH connectivity and permissions.${NC}"
    exit 1
else
    echo ""
    echo -e "${GREEN}All nodes prepared successfully!${NC}"
    exit 0
fi

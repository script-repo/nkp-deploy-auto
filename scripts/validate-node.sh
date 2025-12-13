#!/bin/bash
# =============================================================================
# Parallel Node Validation Script
# Validates a single node - designed to run multiple instances concurrently
# Usage: ./validate-node.sh <node_ip> <ssh_user> <ssh_key>
# =============================================================================

NODE_IP="${1:?Node IP required}"
SSH_USER="${2:-konvoy}"
SSH_KEY="${3:-$HOME/.ssh/id_rsa}"

expand_path() {
    local path="$1"
    [[ -z "${path}" ]] && return
    if [[ "${path}" == "~"* ]]; then
        path="${path/#\~/${HOME}}"
    fi
    realpath -m "${path}"
}

SSH_KEY="$(expand_path "${SSH_KEY}")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Results file for aggregation
RESULT_FILE="/tmp/node-validation-${NODE_IP}.json"

# Initialize result
cat > "${RESULT_FILE}" << EOF
{
  "node": "${NODE_IP}",
  "timestamp": "$(date -Iseconds)",
  "checks": {}
}
EOF

log_result() {
    local check=$1
    local status=$2
    local message=$3
    
    # Update JSON result
    jq --arg check "$check" --arg status "$status" --arg msg "$message" \
       '.checks[$check] = {"status": $status, "message": $msg}' \
       "${RESULT_FILE}" > "${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "${RESULT_FILE}"
    
    # Console output
    case $status in
        "PASS") echo -e "${GREEN}[PASS]${NC} ${NODE_IP}: ${check} - ${message}" ;;
        "FAIL") echo -e "${RED}[FAIL]${NC} ${NODE_IP}: ${check} - ${message}" ;;
        "WARN") echo -e "${YELLOW}[WARN]${NC} ${NODE_IP}: ${check} - ${message}" ;;
    esac
}

# SSH wrapper
ssh_cmd() {
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes \
        -i "${SSH_KEY}" "${SSH_USER}@${NODE_IP}" "$@" 2>/dev/null
}

echo "=============================================="
echo "Validating node: ${NODE_IP}"
echo "=============================================="

# Check 1: SSH Connectivity
if ssh_cmd "echo OK" | grep -q "OK"; then
    log_result "ssh_connectivity" "PASS" "SSH connection successful"
else
    log_result "ssh_connectivity" "FAIL" "Cannot establish SSH connection"
    echo "ERROR: Cannot connect to ${NODE_IP}. Skipping remaining checks."
    exit 1
fi

# Check 2: Swap Status
SWAP_LINES=$(ssh_cmd "swapon --show 2>/dev/null | wc -l")
if [ "${SWAP_LINES:-1}" -eq 0 ]; then
    log_result "swap_disabled" "PASS" "Swap is disabled"
else
    log_result "swap_disabled" "FAIL" "Swap is enabled (${SWAP_LINES} swap entries)"
fi

# Check 3: iscsid Service
ISCSID_STATUS=$(ssh_cmd "systemctl is-active iscsid 2>/dev/null || echo inactive")
if [ "${ISCSID_STATUS}" == "active" ]; then
    log_result "iscsid_service" "PASS" "iscsid is running"
else
    log_result "iscsid_service" "WARN" "iscsid is ${ISCSID_STATUS} (needed for some storage)"
fi

# Check 4: Firewalld Status
FIREWALLD_STATUS=$(ssh_cmd "systemctl is-active firewalld 2>/dev/null || echo inactive")
if [ "${FIREWALLD_STATUS}" == "inactive" ]; then
    log_result "firewalld" "PASS" "firewalld is disabled"
else
    log_result "firewalld" "WARN" "firewalld is ${FIREWALLD_STATUS}"
fi

# Check 5: Root Disk Space
ROOT_FREE=$(ssh_cmd "df -BG / | awk 'NR==2 {print \$4}' | sed 's/G//'")
if [ "${ROOT_FREE:-0}" -ge 20 ]; then
    log_result "disk_space" "PASS" "${ROOT_FREE}GB free on root"
else
    log_result "disk_space" "FAIL" "Only ${ROOT_FREE}GB free (need 20GB+)"
fi

# Check 6: Memory
TOTAL_MEM=$(ssh_cmd "free -g | awk '/^Mem:/ {print \$2}'")
if [ "${TOTAL_MEM:-0}" -ge 14 ]; then
    log_result "memory" "PASS" "${TOTAL_MEM}GB total RAM"
else
    log_result "memory" "WARN" "Only ${TOTAL_MEM}GB RAM (16GB recommended)"
fi

# Check 7: CPU Cores
CPU_CORES=$(ssh_cmd "nproc")
if [ "${CPU_CORES:-0}" -ge 4 ]; then
    log_result "cpu_cores" "PASS" "${CPU_CORES} CPU cores"
else
    log_result "cpu_cores" "WARN" "Only ${CPU_CORES} CPU cores (4+ recommended)"
fi

# Check 8: Required Ports
PORTS_IN_USE=""
for port in 6443 2379 2380 10250 10251 10252; do
    PORT_CHECK=$(ssh_cmd "ss -tlnp 2>/dev/null | grep -c ':${port} ' || echo 0")
    if [ "${PORT_CHECK:-0}" -ne 0 ]; then
        PORTS_IN_USE="${PORTS_IN_USE} ${port}"
    fi
done

if [ -z "${PORTS_IN_USE}" ]; then
    log_result "required_ports" "PASS" "All required ports available"
else
    log_result "required_ports" "WARN" "Ports in use:${PORTS_IN_USE}"
fi

# Check 9: Time Sync
CHRONY_ACTIVE=$(ssh_cmd "systemctl is-active chronyd 2>/dev/null || echo inactive")
NTP_ACTIVE=$(ssh_cmd "systemctl is-active ntpd 2>/dev/null || echo inactive")
TIMESYNCD_ACTIVE=$(ssh_cmd "systemctl is-active systemd-timesyncd 2>/dev/null || echo inactive")

if [ "${CHRONY_ACTIVE}" == "active" ] || [ "${NTP_ACTIVE}" == "active" ] || [ "${TIMESYNCD_ACTIVE}" == "active" ]; then
    log_result "time_sync" "PASS" "Time synchronization active"
else
    log_result "time_sync" "WARN" "No time sync service detected"
fi

# Check 10: OS Version
OS_INFO=$(ssh_cmd "cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'\"' -f2")
case "${OS_INFO}" in
    *"Rocky"*9*|*"Red Hat"*8*|*"Ubuntu"*22*)
        log_result "os_version" "PASS" "${OS_INFO}"
        ;;
    *)
        log_result "os_version" "WARN" "${OS_INFO} (verify compatibility)"
        ;;
esac

# Generate summary
echo ""
echo "=============================================="
echo "Node ${NODE_IP} Validation Complete"
echo "=============================================="

# Count results
PASS_COUNT=$(jq '[.checks[].status] | map(select(. == "PASS")) | length' "${RESULT_FILE}")
FAIL_COUNT=$(jq '[.checks[].status] | map(select(. == "FAIL")) | length' "${RESULT_FILE}")
WARN_COUNT=$(jq '[.checks[].status] | map(select(. == "WARN")) | length' "${RESULT_FILE}")

echo -e "Results: ${GREEN}${PASS_COUNT} PASS${NC} | ${RED}${FAIL_COUNT} FAIL${NC} | ${YELLOW}${WARN_COUNT} WARN${NC}"
echo "Details saved to: ${RESULT_FILE}"

# Exit code based on failures
if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
else
    exit 0
fi

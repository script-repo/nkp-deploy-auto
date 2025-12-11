#!/bin/bash
# =============================================================================
# NKP Post-Deployment Verification Script
# Validates all components after NKP deployment
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Get kubeconfig from argument or environment
KUBECONFIG_PATH="${1:-${KUBECONFIG_PATH:-./nkp-output/${CLUSTER_NAME}.conf}}"

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

log_header() {
    echo ""
    echo -e "${BLUE}=============================================="
    echo -e " $1"
    echo -e "==============================================${NC}"
}

kc() {
    kubectl --kubeconfig="${KUBECONFIG_PATH}" "$@"
}

# =============================================================================
# VALIDATE KUBECONFIG
# =============================================================================

log_header "Validating Kubeconfig"

if [ ! -f "${KUBECONFIG_PATH}" ]; then
    log_fail "Kubeconfig not found: ${KUBECONFIG_PATH}"
    exit 1
fi

if kc cluster-info &> /dev/null; then
    log_pass "Kubeconfig is valid and cluster is accessible"
else
    log_fail "Cannot connect to cluster using kubeconfig"
    exit 1
fi

# =============================================================================
# NODE HEALTH
# =============================================================================

log_header "Node Health Check"

# Check all nodes are Ready
NOT_READY=$(kc get nodes --no-headers | grep -v "Ready" | wc -l)
if [ "${NOT_READY}" -eq 0 ]; then
    log_pass "All nodes are in Ready state"
else
    log_fail "${NOT_READY} node(s) are not Ready"
    kc get nodes | grep -v "Ready"
fi

# Check node count
NODE_COUNT=$(kc get nodes --no-headers | wc -l)
log_info "Total nodes: ${NODE_COUNT}"

# Control plane nodes
CP_NODES=$(kc get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l)
if [ "${CP_NODES}" -ge 3 ]; then
    log_pass "Control plane has ${CP_NODES} nodes (HA enabled)"
elif [ "${CP_NODES}" -ge 1 ]; then
    log_warn "Control plane has ${CP_NODES} node(s) (not HA)"
else
    log_fail "No control plane nodes found"
fi

# Worker nodes
WORKER_NODES=$(kc get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers | wc -l)
if [ "${WORKER_NODES}" -ge 4 ]; then
    log_pass "Worker pool has ${WORKER_NODES} nodes"
else
    log_warn "Worker pool has ${WORKER_NODES} nodes (4+ recommended)"
fi

# =============================================================================
# SYSTEM PODS
# =============================================================================

log_header "System Pod Health"

# Check for non-running pods
PROBLEM_PODS=$(kc get pods -A --no-headers | grep -v "Running\|Completed" | wc -l)
if [ "${PROBLEM_PODS}" -eq 0 ]; then
    log_pass "All pods are Running or Completed"
else
    log_warn "${PROBLEM_PODS} pod(s) are not in Running/Completed state"
    kc get pods -A | grep -v "Running\|Completed" | head -20
fi

# Check critical namespaces
CRITICAL_NS=("kube-system" "metallb-system" "kommander" "kommander-flux")
for ns in "${CRITICAL_NS[@]}"; do
    if kc get namespace ${ns} &> /dev/null; then
        NS_PODS=$(kc get pods -n ${ns} --no-headers 2>/dev/null | wc -l)
        NS_RUNNING=$(kc get pods -n ${ns} --no-headers 2>/dev/null | grep -c "Running" || echo 0)
        if [ "${NS_RUNNING}" -eq "${NS_PODS}" ] && [ "${NS_PODS}" -gt 0 ]; then
            log_pass "Namespace ${ns}: ${NS_RUNNING}/${NS_PODS} pods running"
        else
            log_warn "Namespace ${ns}: ${NS_RUNNING}/${NS_PODS} pods running"
        fi
    else
        if [ "${ns}" == "kommander" ] || [ "${ns}" == "kommander-flux" ]; then
            log_warn "Namespace ${ns} not found (Kommander may not be installed)"
        else
            log_fail "Critical namespace ${ns} not found"
        fi
    fi
done

# =============================================================================
# NETWORKING
# =============================================================================

log_header "Networking Health"

# Check CNI pods (Cilium or Calico)
CILIUM_PODS=$(kc get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | wc -l)
CALICO_PODS=$(kc get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | wc -l)

if [ "${CILIUM_PODS}" -gt 0 ]; then
    CILIUM_RUNNING=$(kc get pods -n kube-system -l k8s-app=cilium --no-headers | grep -c "Running" || echo 0)
    if [ "${CILIUM_RUNNING}" -eq "${CILIUM_PODS}" ]; then
        log_pass "Cilium CNI: ${CILIUM_RUNNING}/${CILIUM_PODS} pods running"
    else
        log_warn "Cilium CNI: ${CILIUM_RUNNING}/${CILIUM_PODS} pods running"
    fi
elif [ "${CALICO_PODS}" -gt 0 ]; then
    CALICO_RUNNING=$(kc get pods -n kube-system -l k8s-app=calico-node --no-headers | grep -c "Running" || echo 0)
    if [ "${CALICO_RUNNING}" -eq "${CALICO_PODS}" ]; then
        log_pass "Calico CNI: ${CALICO_RUNNING}/${CALICO_PODS} pods running"
    else
        log_warn "Calico CNI: ${CALICO_RUNNING}/${CALICO_PODS} pods running"
    fi
else
    log_fail "No CNI pods found"
fi

# Check MetalLB
METALLB_PODS=$(kc get pods -n metallb-system --no-headers 2>/dev/null | wc -l)
if [ "${METALLB_PODS}" -gt 0 ]; then
    METALLB_RUNNING=$(kc get pods -n metallb-system --no-headers | grep -c "Running" || echo 0)
    log_pass "MetalLB: ${METALLB_RUNNING}/${METALLB_PODS} pods running"
    
    # Check IPAddressPool
    POOLS=$(kc get ipaddresspool -n metallb-system --no-headers 2>/dev/null | wc -l)
    if [ "${POOLS}" -gt 0 ]; then
        log_pass "MetalLB IPAddressPool configured"
    else
        log_fail "No MetalLB IPAddressPool found"
    fi
else
    log_warn "MetalLB pods not found"
fi

# Test LoadBalancer (create and delete test service)
log_info "Testing LoadBalancer service..."
kc create deployment nginx-test --image=nginx --dry-run=client -o yaml | kc apply -f - 2>/dev/null || true
kc expose deployment nginx-test --type=LoadBalancer --port=80 --dry-run=client -o yaml | kc apply -f - 2>/dev/null || true
sleep 10
LB_IP=$(kc get svc nginx-test -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ -n "${LB_IP}" ]; then
    log_pass "LoadBalancer test passed - assigned IP: ${LB_IP}"
else
    log_warn "LoadBalancer did not assign IP within timeout"
fi
kc delete deployment nginx-test --ignore-not-found 2>/dev/null || true
kc delete svc nginx-test --ignore-not-found 2>/dev/null || true

# =============================================================================
# STORAGE
# =============================================================================

log_header "Storage Health"

# Check StorageClasses
SC_COUNT=$(kc get storageclass --no-headers | wc -l)
if [ "${SC_COUNT}" -gt 0 ]; then
    log_pass "${SC_COUNT} StorageClass(es) found"
    DEFAULT_SC=$(kc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${DEFAULT_SC}" ]; then
        log_pass "Default StorageClass: ${DEFAULT_SC}"
    else
        log_warn "No default StorageClass set"
    fi
else
    log_fail "No StorageClasses found"
fi

# Check CSI drivers
CSI_DRIVERS=$(kc get csidrivers --no-headers 2>/dev/null | wc -l)
if [ "${CSI_DRIVERS}" -gt 0 ]; then
    log_pass "${CSI_DRIVERS} CSI driver(s) installed"
else
    log_warn "No CSI drivers found"
fi

# Test PVC creation
log_info "Testing PVC creation..."
cat <<EOF | kc apply -f - 2>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc-verification
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
sleep 10
PVC_STATUS=$(kc get pvc test-pvc-verification -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "${PVC_STATUS}" == "Bound" ]; then
    log_pass "PVC test passed - PVC is Bound"
elif [ "${PVC_STATUS}" == "Pending" ]; then
    log_warn "PVC is Pending (may need dynamic provisioner or manual PV)"
else
    log_warn "PVC status: ${PVC_STATUS:-unknown}"
fi
kc delete pvc test-pvc-verification --ignore-not-found 2>/dev/null || true

# =============================================================================
# KOMMANDER
# =============================================================================

log_header "Kommander Health"

if kc get namespace kommander &> /dev/null; then
    # Check Kommander pods
    KOMMANDER_PODS=$(kc get pods -n kommander --no-headers | wc -l)
    KOMMANDER_RUNNING=$(kc get pods -n kommander --no-headers | grep -c "Running" || echo 0)
    
    if [ "${KOMMANDER_RUNNING}" -ge 10 ]; then
        log_pass "Kommander pods: ${KOMMANDER_RUNNING}/${KOMMANDER_PODS} running"
    else
        log_warn "Kommander pods: ${KOMMANDER_RUNNING}/${KOMMANDER_PODS} running"
    fi
    
    # Check Traefik (ingress)
    TRAEFIK_PODS=$(kc get pods -n kommander -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | wc -l)
    if [ "${TRAEFIK_PODS}" -gt 0 ]; then
        log_pass "Traefik ingress is deployed"
        
        # Get Traefik LoadBalancer IP
        TRAEFIK_IP=$(kc get svc -n kommander kommander-traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "${TRAEFIK_IP}" ]; then
            log_pass "Dashboard accessible at: https://${TRAEFIK_IP}"
        fi
    else
        log_warn "Traefik ingress not found"
    fi
    
    # Check License
    LICENSE=$(kc get license -n kommander --no-headers 2>/dev/null | wc -l)
    if [ "${LICENSE}" -gt 0 ]; then
        LICENSE_VALID=$(kc get license -n kommander -o jsonpath='{.items[0].status.valid}' 2>/dev/null || echo "false")
        if [ "${LICENSE_VALID}" == "true" ]; then
            log_pass "NKP license is valid"
        else
            log_warn "NKP license found but may not be valid"
        fi
    else
        log_warn "No NKP license found - using default license"
    fi
else
    log_warn "Kommander namespace not found - Kommander may not be installed"
fi

# =============================================================================
# CERTIFICATES
# =============================================================================

log_header "Certificate Health"

CERTS=$(kc get certificates -A --no-headers 2>/dev/null | wc -l)
if [ "${CERTS}" -gt 0 ]; then
    READY_CERTS=$(kc get certificates -A -o jsonpath='{range .items[?(@.status.conditions[0].status=="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l)
    if [ "${READY_CERTS}" -eq "${CERTS}" ]; then
        log_pass "All ${CERTS} certificates are ready"
    else
        log_warn "${READY_CERTS}/${CERTS} certificates are ready"
        kc get certificates -A | grep -v "True"
    fi
else
    log_info "No Certificate resources found (may be using self-signed)"
fi

# =============================================================================
# SUMMARY
# =============================================================================

log_header "Verification Summary"

echo ""
echo -e "Total Checks:"
echo -e "  ${GREEN}Passed:${NC}   ${PASSED}"
echo -e "  ${YELLOW}Warnings:${NC} ${WARNINGS}"
echo -e "  ${RED}Failed:${NC}   ${FAILED}"
echo ""

# Generate summary file
SUMMARY_FILE="${OUTPUT_DIR:-./nkp-output}/verification-summary.txt"
cat > "${SUMMARY_FILE}" << EOF
NKP Deployment Verification Summary
====================================
Date: $(date)
Kubeconfig: ${KUBECONFIG_PATH}

Results:
- Passed:   ${PASSED}
- Warnings: ${WARNINGS}
- Failed:   ${FAILED}

Cluster Info:
$(kc cluster-info 2>/dev/null || echo "Unable to get cluster info")

Node Status:
$(kc get nodes -o wide 2>/dev/null || echo "Unable to get nodes")

EOF

log_info "Summary saved to: ${SUMMARY_FILE}"

if [ ${FAILED} -gt 0 ]; then
    log_fail "Verification completed with ${FAILED} failure(s)"
    exit 1
elif [ ${WARNINGS} -gt 0 ]; then
    log_warn "Verification completed with ${WARNINGS} warning(s)"
    exit 0
else
    log_pass "All verification checks passed!"
    exit 0
fi

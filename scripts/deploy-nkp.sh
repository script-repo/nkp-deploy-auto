#!/bin/bash
# =============================================================================
# NKP Automated Deployment Script
# Deploys Nutanix Kubernetes Platform 2.16 on Pre-provisioned Infrastructure
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_header() {
    echo ""
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${CYAN} $1${NC}"
    echo -e "${CYAN}=====================================================${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_step() {
    echo -e "${GREEN}[STEP $1]${NC} $2"
}

check_error() {
    if [ $? -ne 0 ]; then
        log_error "$1"
        exit 1
    fi
}

wait_for_condition() {
    local resource=$1
    local condition=$2
    local timeout=$3
    local kubeconfig=$4
    
    log_info "Waiting for ${resource} to be ${condition} (timeout: ${timeout})..."
    kubectl wait --for=condition=${condition} ${resource} --timeout=${timeout} --kubeconfig=${kubeconfig}
}

# =============================================================================
# LOAD ENVIRONMENT
# =============================================================================

log_header "Loading Environment Configuration"

if [ -f "${ROOT_DIR}/environment.env" ]; then
    source "${ROOT_DIR}/environment.env"
    log_success "Environment loaded from environment.env"
else
    log_error "environment.env not found. Please create it from environment.env.template"
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

# Create output directory
mkdir -p "${OUTPUT_DIR}"
log_info "Output directory: ${OUTPUT_DIR}"

# =============================================================================
# PHASE 1: PRE-FLIGHT VALIDATION
# =============================================================================

log_header "Phase 1: Pre-flight Validation"
log_step "1" "Running prerequisite validation..."

if [ -f "${SCRIPT_DIR}/validate-prerequisites.sh" ]; then
    bash "${SCRIPT_DIR}/validate-prerequisites.sh"
    check_error "Pre-flight validation failed"
else
    log_warn "Validation script not found, skipping..."
fi

# =============================================================================
# PHASE 2: GENERATE INVENTORY
# =============================================================================

log_header "Phase 2: Generate PreprovisionedInventory"
log_step "2" "Creating inventory YAML..."

cat > "${ROOT_DIR}/preprovisioned_inventory.yaml" << EOF
---
apiVersion: infrastructure.cluster.konvoy.d2iq.io/v1alpha1
kind: PreprovisionedInventory
metadata:
  name: ${CLUSTER_NAME}-control-plane
  namespace: default
  labels:
    cluster.x-k8s.io/cluster-name: ${CLUSTER_NAME}
    clusterctl.cluster.x-k8s.io/move: ""
spec:
  hosts:
    - address: ${CONTROL_PLANE_1_ADDRESS}
    - address: ${CONTROL_PLANE_2_ADDRESS}
    - address: ${CONTROL_PLANE_3_ADDRESS}
  sshConfig:
    port: 22
    user: ${SSH_USER}
    privateKeyRef:
      name: ${SSH_PRIVATE_KEY_SECRET_NAME}
      namespace: default
---
apiVersion: infrastructure.cluster.konvoy.d2iq.io/v1alpha1
kind: PreprovisionedInventory
metadata:
  name: ${CLUSTER_NAME}-md-0
  namespace: default
  labels:
    cluster.x-k8s.io/cluster-name: ${CLUSTER_NAME}
    clusterctl.cluster.x-k8s.io/move: ""
spec:
  hosts:
    - address: ${WORKER_1_ADDRESS}
    - address: ${WORKER_2_ADDRESS}
    - address: ${WORKER_3_ADDRESS}
    - address: ${WORKER_4_ADDRESS}
  sshConfig:
    port: 22
    user: ${SSH_USER}
    privateKeyRef:
      name: ${SSH_PRIVATE_KEY_SECRET_NAME}
      namespace: default
EOF

log_success "Inventory created: ${ROOT_DIR}/preprovisioned_inventory.yaml"

# =============================================================================
# PHASE 3: CREATE BOOTSTRAP CLUSTER
# =============================================================================

log_header "Phase 3: Create Bootstrap Cluster"
log_step "3" "Creating KIND bootstrap cluster..."

# Check for existing bootstrap
if kind get clusters 2>/dev/null | grep -q "konvoy-capi-bootstrapper"; then
    log_warn "Existing bootstrap cluster found. Deleting..."
    ./nkp delete bootstrap --kubeconfig $HOME/.kube/config || true
fi

# Create bootstrap
./nkp create bootstrap --kubeconfig $HOME/.kube/config
check_error "Bootstrap cluster creation failed"

log_success "Bootstrap cluster created"

# Wait for bootstrap pods
log_info "Waiting for bootstrap pods to be ready..."
sleep 30
kubectl get pods -A --kubeconfig $HOME/.kube/config

# =============================================================================
# PHASE 4: DEPLOY MANAGEMENT CLUSTER
# =============================================================================

log_header "Phase 4: Deploy Management Cluster"
log_step "4" "Deploying self-managed NKP cluster..."

# Build the create cluster command
CREATE_CMD="./nkp create cluster preprovisioned \
  --cluster-name ${CLUSTER_NAME} \
  --control-plane-endpoint-host ${CONTROL_PLANE_ENDPOINT_HOST} \
  --control-plane-endpoint-port ${CONTROL_PLANE_ENDPOINT_PORT:-6443} \
  --pre-provisioned-inventory-file ${ROOT_DIR}/preprovisioned_inventory.yaml \
  --ssh-private-key-file ${SSH_PRIVATE_KEY_FILE} \
  --self-managed"

# Add virtual IP interface if specified
if [ -n "${VIRTUAL_IP_INTERFACE}" ]; then
    CREATE_CMD="${CREATE_CMD} --virtual-ip-interface ${VIRTUAL_IP_INTERFACE}"
fi

# Add registry mirror if specified
if [ -n "${REGISTRY_MIRROR_URL}" ] && [ -n "${REGISTRY_MIRROR_USERNAME}" ]; then
    CREATE_CMD="${CREATE_CMD} --registry-mirror-url=${REGISTRY_MIRROR_URL}"
    CREATE_CMD="${CREATE_CMD} --registry-mirror-username=${REGISTRY_MIRROR_USERNAME}"
    CREATE_CMD="${CREATE_CMD} --registry-mirror-password=${REGISTRY_MIRROR_PASSWORD}"
fi

# Add proxy if specified
if [ -n "${HTTP_PROXY}" ]; then
    CREATE_CMD="${CREATE_CMD} --http-proxy ${HTTP_PROXY}"
fi
if [ -n "${HTTPS_PROXY}" ]; then
    CREATE_CMD="${CREATE_CMD} --https-proxy ${HTTPS_PROXY}"
fi
if [ -n "${NO_PROXY}" ]; then
    CREATE_CMD="${CREATE_CMD} --no-proxy ${NO_PROXY}"
fi

log_info "Executing: ${CREATE_CMD}"
eval ${CREATE_CMD}
check_error "Cluster creation failed"

# Wait for control plane
log_info "Waiting for control plane to be ready..."
kubectl wait --for=condition=ControlPlaneReady "clusters/${CLUSTER_NAME}" --timeout=${CLUSTER_CREATE_TIMEOUT:-60m} --kubeconfig $HOME/.kube/config
check_error "Control plane did not become ready"

log_success "Management cluster deployed"

# =============================================================================
# PHASE 5: GET KUBECONFIG AND CLEANUP BOOTSTRAP
# =============================================================================

log_header "Phase 5: Finalize Cluster"
log_step "5" "Retrieving kubeconfig and cleaning up..."

# Get kubeconfig
./nkp get kubeconfig -c ${CLUSTER_NAME} > "${KUBECONFIG_PATH}"
check_error "Failed to get kubeconfig"
log_success "Kubeconfig saved to: ${KUBECONFIG_PATH}"

# Verify nodes
log_info "Verifying cluster nodes..."
kubectl get nodes --kubeconfig "${KUBECONFIG_PATH}"

# Delete bootstrap
log_info "Deleting bootstrap cluster..."
./nkp delete bootstrap --kubeconfig $HOME/.kube/config
log_success "Bootstrap cluster deleted"

# =============================================================================
# PHASE 6: CONFIGURE METALLB
# =============================================================================

log_header "Phase 6: Configure MetalLB"
log_step "6" "Setting up LoadBalancer support..."

# Wait for MetalLB to be deployed
log_info "Waiting for MetalLB pods..."
sleep 30
kubectl wait --for=condition=Ready pods -l app=metallb -n metallb-system --timeout=300s --kubeconfig "${KUBECONFIG_PATH}" || true

# Create MetalLB configuration
cat > "${ROOT_DIR}/configs/metallb-config.yaml" << EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_IP_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default
EOF

kubectl apply -f "${ROOT_DIR}/configs/metallb-config.yaml" --kubeconfig "${KUBECONFIG_PATH}"
check_error "MetalLB configuration failed"

log_success "MetalLB configured with IP range: ${METALLB_IP_RANGE}"

# =============================================================================
# PHASE 7: INSTALL KOMMANDER
# =============================================================================

log_header "Phase 7: Install Kommander"
log_step "7" "Installing management dashboard..."

# Initialize Kommander config
./nkp install kommander --init > "${ROOT_DIR}/configs/kommander.yaml"

# Install Kommander
./nkp install kommander \
  --installer-config "${ROOT_DIR}/configs/kommander.yaml" \
  --kubeconfig "${KUBECONFIG_PATH}" \
  --wait-timeout ${KOMMANDER_INSTALL_TIMEOUT:-45m}
check_error "Kommander installation failed"

log_success "Kommander installed"

# Get dashboard credentials
log_info "Retrieving dashboard credentials..."
./nkp get dashboard --kubeconfig "${KUBECONFIG_PATH}" > "${OUTPUT_DIR}/dashboard-credentials.txt"

# Rotate password
log_info "Rotating default password..."
./nkp experimental rotate dashboard-password --kubeconfig "${KUBECONFIG_PATH}" >> "${OUTPUT_DIR}/dashboard-credentials.txt"

log_success "Dashboard credentials saved to: ${OUTPUT_DIR}/dashboard-credentials.txt"

# =============================================================================
# PHASE 8: APPLY LICENSE
# =============================================================================

log_header "Phase 8: Apply License"
log_step "8" "Activating NKP license..."

if [ -n "${NKP_LICENSE_TOKEN}" ]; then
    kubectl create secret generic my-license-secret \
      --from-literal=jwt="${NKP_LICENSE_TOKEN}" \
      -n kommander \
      --kubeconfig "${KUBECONFIG_PATH}"
    
    kubectl label secret my-license-secret kommanderType=license \
      -n kommander \
      --kubeconfig "${KUBECONFIG_PATH}"
    
    log_success "License applied: ${LICENSE_TYPE}"
else
    log_warn "No license token provided. Apply license manually via UI."
fi

# =============================================================================
# PHASE 9: VERIFICATION
# =============================================================================

log_header "Phase 9: Deployment Verification"
log_step "9" "Running verification checks..."

if [ -f "${SCRIPT_DIR}/verify-deployment.sh" ]; then
    bash "${SCRIPT_DIR}/verify-deployment.sh" "${KUBECONFIG_PATH}"
else
    # Basic verification
    log_info "Checking node status..."
    kubectl get nodes --kubeconfig "${KUBECONFIG_PATH}"
    
    log_info "Checking system pods..."
    kubectl get pods -A --kubeconfig "${KUBECONFIG_PATH}" | grep -v Running | grep -v Completed || true
fi

# =============================================================================
# SUMMARY
# =============================================================================

log_header "Deployment Complete!"

echo ""
echo -e "${GREEN}=============================================="
echo -e " NKP Deployment Summary"
echo -e "==============================================${NC}"
echo ""
echo -e "Cluster Name:    ${CLUSTER_NAME}"
echo -e "Kubeconfig:      ${KUBECONFIG_PATH}"
echo -e "Control Plane:   https://${CONTROL_PLANE_ENDPOINT_HOST}:${CONTROL_PLANE_ENDPOINT_PORT:-6443}"
echo -e "MetalLB Range:   ${METALLB_IP_RANGE}"
echo ""
echo -e "Dashboard Credentials: ${OUTPUT_DIR}/dashboard-credentials.txt"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Review dashboard credentials file"
echo "2. Access the NKP UI dashboard"
echo "3. Configure identity providers (optional)"
echo "4. Deploy workload clusters (optional)"
echo ""
log_success "NKP deployment completed successfully!"

#!/usr/bin/env bash
# Orchestrated NKP deployment runner used by the UI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${ROOT_DIR}/environment.env"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${GREEN}==>${NC} $1"; }

if [[ ! -f "${ENV_FILE}" ]]; then
  log_error "Missing environment.env; copy environment.env.template and fill it out."
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

expand_path() {
  local path="$1"
  [[ -z "${path}" ]] && return
  if [[ "${path}" == "~"* ]]; then
    path="${path/#\~/${HOME}}"
  fi
  realpath -m "${path}"
}

OUTPUT_DIR="$(expand_path "${OUTPUT_DIR:-${ROOT_DIR}/nkp-output}")"
KUBECONFIG_PATH="$(expand_path "${KUBECONFIG_PATH:-${OUTPUT_DIR}/${CLUSTER_NAME}.conf}")"
DRY_RUN="${DRY_RUN:-false}"
mkdir -p "${OUTPUT_DIR}" "$(dirname "${KUBECONFIG_PATH}")"

run_or_echo() {
  local description="$1"
  shift
  local cmd="$*"
  log_step "${description}"
  if [[ "${DRY_RUN,,}" == "true" ]]; then
    echo "[DRY RUN] ${cmd}"
  else
    bash -c "${cmd}"
  fi
}

log_info "Streaming output; all command stdout will appear below."

# 1) Pull NKP artifacts and OS images
ARTIFACT_CMD=("${ROOT_DIR}/nkp-quickstart" pull --spec "${ROOT_DIR}/nkp-deployment-spec.yaml" --output "${OUTPUT_DIR}" --include-os-images)
run_or_echo "Pull NKP artifacts and OS images" "${ARTIFACT_CMD[*]}"

# 2) Upsert Prism Central project, subnet, and storage container
PRISM_AUTH="-u ${NUTANIX_USER}:${NUTANIX_PASSWORD}"
PROJECT_PAYLOAD="${OUTPUT_DIR}/prism-project.json"
cat >"${PROJECT_PAYLOAD}" <<EOF_JSON
{
  "name": "${CLUSTER_NAME}-project",
  "description": "NKP management cluster project for ${CLUSTER_NAME}",
  "resources": {}
}
EOF_JSON

SUBNET_PAYLOAD="${OUTPUT_DIR}/prism-subnet.json"
cat >"${SUBNET_PAYLOAD}" <<EOF_JSON
{
  "name": "${CLUSTER_NAME}-subnet",
  "vlan_id": 0,
  "subnet_type": "VLAN",
  "ip_config": {
    "pool_list": [
      {
        "range": "${METALLB_IP_RANGE}"
      }
    ]
  }
}
EOF_JSON

STORAGE_PAYLOAD="${OUTPUT_DIR}/prism-storage-container.json"
cat >"${STORAGE_PAYLOAD}" <<EOF_JSON
{
  "name": "${STORAGE_CONTAINER:-${CLUSTER_NAME}-container}",
  "description": "Storage container for NKP cluster ${CLUSTER_NAME}"
}
EOF_JSON

run_or_echo "Upsert Prism Central project" "curl -sS ${PRISM_AUTH} -X PUT -H 'Content-Type: application/json' '${NUTANIX_ENDPOINT}/api/prism/v4.0.b1/projects/${CLUSTER_NAME}-project' -d @${PROJECT_PAYLOAD}"
run_or_echo "Upsert Prism Central subnet" "curl -sS ${PRISM_AUTH} -X PUT -H 'Content-Type: application/json' '${NUTANIX_ENDPOINT}/api/prism/v4.0.b1/subnets/${CLUSTER_NAME}-subnet' -d @${SUBNET_PAYLOAD}"
run_or_echo "Upsert Prism Central storage container" "curl -sS ${PRISM_AUTH} -X PUT -H 'Content-Type: application/json' '${NUTANIX_ENDPOINT}/api/prism/v4.0.b1/storage_containers/${STORAGE_CONTAINER:-${CLUSTER_NAME}-container}' -d @${STORAGE_PAYLOAD}"

# 3) Render manifests from environment.env
RENDERED_INVENTORY="${OUTPUT_DIR}/preprovisioned_inventory.yaml"
run_or_echo "Render preprovisioned inventory" "envsubst < '${ROOT_DIR}/templates/preprovisioned_inventory.yaml.template' > '${RENDERED_INVENTORY}'"

# 4) Install the NKP management cluster
INSTALL_CMD=("${ROOT_DIR}/nkp-quickstart" install management --spec "${ROOT_DIR}/nkp-deployment-spec.yaml" --inventory "${RENDERED_INVENTORY}" --license "${NKP_LICENSE_TOKEN}" --timeout "${CLUSTER_CREATE_TIMEOUT:-60m}")
run_or_echo "Install NKP management cluster" "${INSTALL_CMD[*]}"

# 5) Apply CNI using provided pod/service CIDRs (Calico)
CNI_MANIFEST="${OUTPUT_DIR}/cni-calico.yaml"
cat >"${CNI_MANIFEST}" <<EOF_CNI
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: ${POD_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
  kubernetesProvider: EKS
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec:
  service:
    type: ClusterIP
    nodePort: null
EOF_CNI
run_or_echo "Apply Calico CNI" "kubectl --kubeconfig '${KUBECONFIG_PATH}' apply -f '${CNI_MANIFEST}'"

# 6) Install and configure MetalLB with provided range
run_or_echo "Install MetalLB operator" "kubectl --kubeconfig '${KUBECONFIG_PATH}' apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml"
METALLB_MANIFEST="${OUTPUT_DIR}/metallb.yaml"
cat >"${METALLB_MANIFEST}" <<EOF_METALLB
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-address-pool
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_IP_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-address-pool
EOF_METALLB
run_or_echo "Apply MetalLB configuration" "kubectl --kubeconfig '${KUBECONFIG_PATH}' apply -f '${METALLB_MANIFEST}'"

# 7) Write kubeconfig to the requested path
run_or_echo "Write kubeconfig" "${ROOT_DIR}/nkp get kubeconfig -c '${CLUSTER_NAME}' > '${KUBECONFIG_PATH}'"

log_info "Deployment run complete. Kubeconfig: ${KUBECONFIG_PATH}"

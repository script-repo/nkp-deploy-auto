# Parallelized NKP Deployment Prompts for Claude Code

This document contains prompts optimized for parallel execution using Claude Code's sub-agent capabilities. Sub-agents can dramatically reduce deployment time by running independent tasks concurrently.

---

## 🚀 MASTER ORCHESTRATION PROMPT (with Sub-Agents)

Use this prompt to orchestrate the entire deployment with maximum parallelization:

```
I need you to deploy NKP 2.16 on pre-provisioned infrastructure using parallel sub-agents where possible.

## Environment
- Cluster Name: ${CLUSTER_NAME}
- Control Plane Nodes: ${CONTROL_PLANE_1_ADDRESS}, ${CONTROL_PLANE_2_ADDRESS}, ${CONTROL_PLANE_3_ADDRESS}
- Worker Nodes: ${WORKER_1_ADDRESS}, ${WORKER_2_ADDRESS}, ${WORKER_3_ADDRESS}, ${WORKER_4_ADDRESS}
- Control Plane VIP: ${CONTROL_PLANE_ENDPOINT_HOST}
- SSH User: ${SSH_USER}
- SSH Key: ${SSH_PRIVATE_KEY_FILE}
- MetalLB Range: ${METALLB_IP_RANGE}

## Execution Strategy

### PHASE 1: Parallel Pre-flight Validation
Launch 3 sub-agents simultaneously:

**Sub-Agent A (Bastion Validation):**
- Check Docker/Podman installed and running
- Verify kubectl, helm in PATH
- Check disk space > 50GB
- Verify nkp binary exists

**Sub-Agent B (Network Validation):**
- Ping control plane VIP (should NOT respond)
- Ping first MetalLB IP (should NOT respond)
- Test DNS resolution for all node hostnames
- Port scan 6443 on VIP (should be closed)

**Sub-Agent C (Node Validation - spawn sub-task per node):**
For EACH node in parallel:
- Test SSH connectivity
- Check swap is disabled
- Verify iscsid is running
- Check disk space > 20GB
- Verify required ports available

GATE: Wait for all sub-agents. If ANY critical check fails, stop and report.

### PHASE 2: Sequential Cluster Creation
(Cannot parallelize - each step depends on previous)
1. Generate PreprovisionedInventory YAML
2. Create bootstrap cluster: nkp create bootstrap
3. Deploy cluster: nkp create cluster preprovisioned --self-managed
4. Wait for ControlPlaneReady
5. Get kubeconfig
6. Delete bootstrap

### PHASE 3: Parallel Post-Cluster Configuration
Launch 2 sub-agents simultaneously:

**Sub-Agent D (MetalLB Configuration):**
- Wait for MetalLB pods ready
- Create IPAddressPool
- Create L2Advertisement
- Test with nginx LoadBalancer service

**Sub-Agent E (Storage Validation):**
- Verify default StorageClass exists
- Create test PVC
- Verify PVC binds
- Cleanup test resources

GATE: Wait for both sub-agents to complete successfully.

### PHASE 4: Sequential Kommander Installation
(Cannot parallelize - single long-running process)
1. Initialize: nkp install kommander --init > kommander.yaml
2. Install: nkp install kommander --installer-config kommander.yaml
3. Wait for all Kommander pods ready (up to 45 minutes)

### PHASE 5: Parallel Post-Install Tasks
Launch 3 sub-agents simultaneously:

**Sub-Agent F (License & Security):**
- Apply license token
- Rotate dashboard password
- Verify license status

**Sub-Agent G (Health Verification):**
- Check all nodes Ready
- Check all pods Running/Completed
- Test LoadBalancer IP assignment
- Verify Traefik ingress

**Sub-Agent H (Documentation):**
- Get dashboard credentials
- Save kubeconfig to output directory
- Generate deployment summary report
- List all access URLs

## Reporting
After each phase, report:
- Which sub-agents completed successfully
- Any failures with specific errors
- Time taken per phase
- Overall progress percentage

On completion, provide:
- Dashboard URL
- Login credentials
- Kubeconfig path
- Any warnings or recommendations
```

---

## 📋 INDIVIDUAL PARALLELIZED PHASE PROMPTS

### Phase 1: Parallel Pre-flight Validation

```
Execute parallel pre-flight validation for NKP deployment.

Launch these sub-agents simultaneously and aggregate results:

## Sub-Agent A: Bastion Host Validation
```bash
# Check Docker
docker --version && docker info > /dev/null 2>&1 && echo "PASS: Docker" || echo "FAIL: Docker"

# Check kubectl
kubectl version --client > /dev/null 2>&1 && echo "PASS: kubectl" || echo "FAIL: kubectl"

# Check helm
helm version > /dev/null 2>&1 && echo "PASS: helm" || echo "FAIL: helm"

# Check disk space
[ $(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//') -ge 50 ] && echo "PASS: Disk" || echo "FAIL: Disk"

# Check nkp binary
[ -f "./nkp" ] || command -v nkp && echo "PASS: nkp" || echo "WARN: nkp not found"
```

## Sub-Agent B: Network Validation
```bash
# Check VIP not in use
! ping -c 1 -W 2 ${CONTROL_PLANE_ENDPOINT_HOST} > /dev/null 2>&1 && echo "PASS: VIP available" || echo "FAIL: VIP in use"

# Check MetalLB start IP
METALLB_START=$(echo ${METALLB_IP_RANGE} | cut -d'-' -f1)
! ping -c 1 -W 2 ${METALLB_START} > /dev/null 2>&1 && echo "PASS: MetalLB IP available" || echo "WARN: MetalLB IP responds"
```

## Sub-Agent C: Node Validation (parallel per node)
For each node in: ${ALL_NODES}
```bash
NODE=$1
ssh -o ConnectTimeout=5 -i ${SSH_PRIVATE_KEY_FILE} ${SSH_USER}@${NODE} "
  # Swap check
  [ \$(swapon --show | wc -l) -eq 0 ] && echo 'PASS: swap' || echo 'FAIL: swap'
  
  # iscsid check
  systemctl is-active iscsid > /dev/null 2>&1 && echo 'PASS: iscsid' || echo 'WARN: iscsid'
  
  # Disk check
  [ \$(df -BG / | awk 'NR==2 {print \$4}' | sed 's/G//') -ge 20 ] && echo 'PASS: disk' || echo 'FAIL: disk'
"
```

Aggregate all results and report:
- Total checks: X
- Passed: X
- Failed: X (list each)
- Warnings: X (list each)

Stop if any FAIL results. Proceed with warnings after acknowledgment.
```

---

### Phase 2: Parallel Node Preparation (if needed)

```
Prepare all cluster nodes in parallel for NKP deployment.

Launch a sub-agent for EACH node simultaneously:

## Template for each node sub-agent:
Node: ${NODE_ADDRESS}

```bash
ssh -i ${SSH_PRIVATE_KEY_FILE} ${SSH_USER}@${NODE_ADDRESS} "
  # Disable swap
  sudo swapoff -a
  sudo sed -i '/swap/d' /etc/fstab
  
  # Enable iscsid
  sudo systemctl enable --now iscsid
  
  # Disable firewalld (or configure)
  sudo systemctl disable --now firewalld 2>/dev/null || true
  
  # Verify
  echo 'Swap:' \$(swapon --show | wc -l)
  echo 'iscsid:' \$(systemctl is-active iscsid)
  echo 'firewalld:' \$(systemctl is-active firewalld 2>/dev/null || echo 'inactive')
"
```

Spawn sub-agents for:
- ${CONTROL_PLANE_1_ADDRESS}
- ${CONTROL_PLANE_2_ADDRESS}
- ${CONTROL_PLANE_3_ADDRESS}
- ${WORKER_1_ADDRESS}
- ${WORKER_2_ADDRESS}
- ${WORKER_3_ADDRESS}
- ${WORKER_4_ADDRESS}

Wait for ALL to complete. Report any failures with specific node and error.
```

---

### Phase 3: Parallel Post-Cluster Configuration

```
Configure MetalLB and Storage in parallel after cluster deployment.

KUBECONFIG: ${CLUSTER_NAME}.conf

Launch 2 sub-agents simultaneously:

## Sub-Agent D: MetalLB Configuration
```bash
export KUBECONFIG=${CLUSTER_NAME}.conf

# Wait for MetalLB pods
kubectl wait --for=condition=Ready pods -l app=metallb -n metallb-system --timeout=300s

# Apply configuration
cat <<EOF | kubectl apply -f -
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

# Test LoadBalancer
kubectl create deployment nginx-test --image=nginx
kubectl expose deployment nginx-test --type=LoadBalancer --port=80
sleep 15
kubectl get svc nginx-test -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
kubectl delete deployment nginx-test
kubectl delete svc nginx-test

echo "MetalLB configuration complete"
```

## Sub-Agent E: Storage Validation
```bash
export KUBECONFIG=${CLUSTER_NAME}.conf

# Check StorageClass
kubectl get storageclass
DEFAULT_SC=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
echo "Default StorageClass: ${DEFAULT_SC}"

# Test PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

sleep 30
kubectl get pvc test-pvc
kubectl delete pvc test-pvc

echo "Storage validation complete"
```

Wait for both sub-agents. Report results from each.
```

---

### Phase 5: Parallel Post-Install Tasks

```
Execute post-Kommander installation tasks in parallel.

KUBECONFIG: ${CLUSTER_NAME}.conf

Launch 3 sub-agents simultaneously:

## Sub-Agent F: License & Security
```bash
export KUBECONFIG=${CLUSTER_NAME}.conf

# Apply license (if token provided)
if [ -n "${NKP_LICENSE_TOKEN}" ]; then
  kubectl create secret generic nkp-license \
    --from-literal=jwt="${NKP_LICENSE_TOKEN}" \
    -n kommander
  kubectl label secret nkp-license kommanderType=license -n kommander
fi

# Rotate password
nkp experimental rotate dashboard-password --kubeconfig ${KUBECONFIG}

# Verify license
kubectl get license -n kommander -o yaml

echo "License and security tasks complete"
```

## Sub-Agent G: Health Verification
```bash
export KUBECONFIG=${CLUSTER_NAME}.conf

echo "=== Node Health ==="
kubectl get nodes -o wide

echo "=== Problem Pods ==="
kubectl get pods -A | grep -v "Running\|Completed" | head -20

echo "=== MetalLB Status ==="
kubectl get pods -n metallb-system
kubectl get ipaddresspool -n metallb-system

echo "=== Kommander Status ==="
kubectl get pods -n kommander | head -20

echo "=== Certificate Status ==="
kubectl get certificates -A

echo "Health verification complete"
```

## Sub-Agent H: Documentation Generation
```bash
export KUBECONFIG=${CLUSTER_NAME}.conf
OUTPUT_DIR="./nkp-output"
mkdir -p ${OUTPUT_DIR}

# Save kubeconfig
cp ${KUBECONFIG} ${OUTPUT_DIR}/

# Get dashboard info
nkp get dashboard --kubeconfig ${KUBECONFIG} > ${OUTPUT_DIR}/dashboard-credentials.txt

# Get Traefik IP
TRAEFIK_IP=$(kubectl get svc -n kommander kommander-traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

# Generate summary
cat > ${OUTPUT_DIR}/deployment-summary.md <<EOF
# NKP Deployment Summary

## Cluster Information
- **Name**: ${CLUSTER_NAME}
- **Kubeconfig**: ${OUTPUT_DIR}/${CLUSTER_NAME}.conf

## Access URLs
- **Dashboard**: https://${TRAEFIK_IP}/dkp/kommander/dashboard
- **Credentials**: See dashboard-credentials.txt

## Node Count
$(kubectl get nodes --no-headers | wc -l) nodes

## Deployment Date
$(date)
EOF

echo "Documentation generated in ${OUTPUT_DIR}"
```

Wait for all 3 sub-agents. Compile final deployment report.
```

---

## ⏱️ Time Comparison

| Deployment Type | Estimated Time |
|-----------------|----------------|
| Sequential (original) | 90-120 minutes |
| **Parallelized** | **60-80 minutes** |
| **Savings** | **~30-40 minutes** |

The biggest savings come from:
1. **Pre-flight validation**: 7 nodes checked simultaneously instead of sequentially
2. **Node preparation**: All nodes prepared at once
3. **Post-install tasks**: License, verification, and docs generated in parallel

---

## 🔧 Sub-Agent Spawn Syntax for Claude Code

When Claude Code supports explicit sub-agent spawning, use patterns like:

```
# Conceptual sub-agent spawning
spawn_subagent("bastion-check", script="validate_bastion.sh")
spawn_subagent("network-check", script="validate_network.sh")
spawn_subagent("node-check-1", script="validate_node.sh", args=["192.168.1.51"])
spawn_subagent("node-check-2", script="validate_node.sh", args=["192.168.1.52"])
# ... more nodes

await_all_subagents()
aggregate_results()
```

For now, instruct Claude Code to:
1. Open multiple terminal sessions
2. Run independent scripts concurrently
3. Monitor all outputs
4. Aggregate results when complete

---

## 💡 Tips for Parallel Execution

1. **Independent Tasks Only**: Only parallelize tasks with no dependencies
2. **Resource Contention**: Avoid parallel tasks that compete for same resources
3. **Error Handling**: Ensure one sub-agent failure doesn't corrupt others
4. **Result Aggregation**: Collect all sub-agent outputs before proceeding
5. **Timeout Handling**: Set appropriate timeouts for each sub-agent
6. **Logging**: Each sub-agent should log to separate files for debugging

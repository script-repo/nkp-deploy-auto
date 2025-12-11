# Claude Code Prompts for NKP Deployment

This document contains structured prompts designed for Claude Code to deploy Nutanix Kubernetes Platform (NKP) 2.16. Use these prompts sequentially or adapt them to your specific deployment scenario.

---

## 🎯 MASTER DEPLOYMENT PROMPT

Use this comprehensive prompt to initiate a full NKP deployment:

```
I need you to deploy Nutanix Kubernetes Platform (NKP) 2.16 on pre-provisioned infrastructure. 

## Environment Details
- Deployment Type: Pre-provisioned (VMs already exist with OS installed)
- Environment: [Non-air-gapped / Air-gapped]
- License Type: [Starter / Pro / Ultimate]

## Infrastructure
- Bastion Host: [IP or hostname]
- Control Plane Nodes: [IP1, IP2, IP3]
- Worker Nodes: [IP1, IP2, IP3, IP4]
- Control Plane VIP: [Virtual IP for API server]
- SSH User: [username with sudo access]
- SSH Key Path: [path to private key]

## Networking
- MetalLB IP Range: [start-end, e.g., 192.168.1.240-192.168.1.250]
- Pod CIDR: 10.244.0.0/16 (default)
- Service CIDR: 10.96.0.0/12 (default)

## Storage
- Storage Backend: [Nutanix CSI / Rook Ceph / Local Volume Provisioner]
- Nutanix Prism Central: [endpoint if using Nutanix CSI]
- Storage Container: [container name if using Nutanix CSI]

## Tasks
1. Read the deployment specification file at ./nkp-deployment-spec.yaml
2. Validate all prerequisites on the bastion host
3. Validate SSH connectivity to all nodes
4. Validate node prerequisites (swap disabled, iscsid running, etc.)
5. Generate the PreprovisionedInventory YAML
6. Create the bootstrap cluster
7. Deploy the management cluster with --self-managed flag
8. Configure MetalLB for LoadBalancer services
9. Install Kommander for the management dashboard
10. Apply the license
11. Verify all components are healthy
12. Provide the dashboard URL and credentials

Use the helper scripts in this directory and report progress at each step. If any step fails, provide detailed diagnostics before proceeding.
```

---

## 📋 PHASE-SPECIFIC PROMPTS

### Phase 1: Environment Validation

```
Validate my environment for NKP 2.16 deployment:

1. Check the bastion host has:
   - Docker CE 20+ or Podman 4+ installed and running
   - kubectl installed and in PATH
   - helm 3.x installed
   - At least 50GB free disk space
   - Network connectivity to all cluster nodes

2. Check each cluster node (via SSH) has:
   - Swap disabled (swapoff -a and removed from /etc/fstab)
   - iscsid service enabled and running
   - firewalld disabled or properly configured
   - Required ports open (6443, 2379-2380, 10250-10252, 30000-32767)
   - At least 15% free space on root filesystem
   - Time synchronized via NTP

3. Validate network requirements:
   - DNS resolution works for all node hostnames
   - Control plane VIP is not in use
   - MetalLB IP range is available and not in DHCP scope

SSH credentials:
- User: ${SSH_USER}
- Key: ${SSH_PRIVATE_KEY_FILE}
- Nodes: ${CONTROL_PLANE_NODES} ${WORKER_NODES}

Generate a validation report and stop if any critical requirements fail.
```

### Phase 2: NKP Binary Setup

```
Set up the NKP CLI binary on this bastion host:

1. Check if nkp binary already exists in current directory or PATH
2. If not present:
   - Download from Nutanix Support Portal (I'll provide credentials if needed)
   - OR extract from provided tarball at: ${NKP_BUNDLE_PATH}
3. Verify the binary works: ./nkp version
4. Make it executable and optionally add to PATH

For air-gapped deployment, also:
- Extract container image bundles
- Extract Helm chart bundles
- Verify all required bundles are present

Report the NKP version and confirm readiness for cluster creation.
```

### Phase 3: Bootstrap Cluster Creation

```
Create the NKP bootstrap cluster:

1. Ensure no existing bootstrap cluster is running:
   - Check for existing kind clusters: kind get clusters
   - If 'konvoy-capi-bootstrapper' exists, delete it first

2. Create the bootstrap cluster:
   nkp create bootstrap --kubeconfig $HOME/.kube/config

3. Wait for bootstrap to be ready:
   - Monitor pod status in the bootstrap cluster
   - Ensure all CAPI controllers are running

4. Verify bootstrap cluster health:
   kubectl get pods -A --kubeconfig $HOME/.kube/config

Report when bootstrap is ready for cluster deployment.
```

### Phase 4: Cluster Deployment

```
Deploy the NKP management cluster on pre-provisioned infrastructure:

Configuration:
- Cluster Name: ${CLUSTER_NAME}
- Control Plane VIP: ${CONTROL_PLANE_ENDPOINT_HOST}
- Control Plane Port: 6443
- Inventory File: ./preprovisioned_inventory.yaml
- SSH Key: ${SSH_PRIVATE_KEY_FILE}

Execute the cluster creation:
nkp create cluster preprovisioned \
  --cluster-name ${CLUSTER_NAME} \
  --control-plane-endpoint-host ${CONTROL_PLANE_ENDPOINT_HOST} \
  --control-plane-endpoint-port 6443 \
  --pre-provisioned-inventory-file preprovisioned_inventory.yaml \
  --ssh-private-key-file ${SSH_PRIVATE_KEY_FILE} \
  --self-managed

Monitor the deployment:
1. Watch for ControlPlaneReady condition
2. Check node join status
3. Report any errors immediately

After cluster is ready:
1. Get kubeconfig: nkp get kubeconfig -c ${CLUSTER_NAME} > ${CLUSTER_NAME}.conf
2. Verify nodes: kubectl get nodes --kubeconfig ${CLUSTER_NAME}.conf
3. Delete bootstrap cluster: nkp delete bootstrap

Report cluster status and node health.
```

### Phase 5: MetalLB Configuration

```
Configure MetalLB for LoadBalancer services:

IP Range: ${METALLB_IP_RANGE}
Mode: Layer 2 (default) or BGP

1. Verify MetalLB is deployed:
   kubectl get pods -n metallb-system --kubeconfig ${CLUSTER_NAME}.conf

2. Create IPAddressPool:
   - Name: default
   - Address range: ${METALLB_IP_RANGE}

3. Create L2Advertisement (for Layer 2 mode):
   - Name: default
   - Reference the IPAddressPool

4. Apply the configuration:
   kubectl apply -f metallb-config.yaml --kubeconfig ${CLUSTER_NAME}.conf

5. Verify configuration:
   kubectl get ipaddresspool,l2advertisement -n metallb-system

6. Test LoadBalancer functionality:
   - Create a test nginx deployment
   - Expose as LoadBalancer
   - Verify external IP assignment
   - Clean up test resources

Report MetalLB status and any issues.
```

### Phase 6: Kommander Installation

```
Install Kommander for NKP management dashboard:

Environment: [Non-air-gapped / Air-gapped]
Custom Domain: ${CUSTOM_DOMAIN} (optional)

1. Initialize Kommander configuration:
   nkp install kommander --init > kommander.yaml

2. Review and customize kommander.yaml if needed:
   - Storage class configuration
   - Resource limits
   - Custom domain settings

3. Install Kommander:
   nkp install kommander \
     --installer-config kommander.yaml \
     --kubeconfig ${CLUSTER_NAME}.conf \
     --wait-timeout 45m

4. Wait for all Kommander pods to be ready:
   kubectl get pods -n kommander --kubeconfig ${CLUSTER_NAME}.conf

5. Get dashboard credentials:
   nkp get dashboard --kubeconfig ${CLUSTER_NAME}.conf

6. Rotate default password:
   nkp experimental rotate dashboard-password --kubeconfig ${CLUSTER_NAME}.conf

Report dashboard URL, username, and new password.
```

### Phase 7: License Activation

```
Activate the NKP license:

License Type: ${LICENSE_TYPE}
License Token: ${NKP_LICENSE_TOKEN}

Option 1 - CLI Method:
kubectl create secret generic my-license-secret \
  --from-literal=jwt=${NKP_LICENSE_TOKEN} \
  -n kommander \
  --kubeconfig ${CLUSTER_NAME}.conf

kubectl label secret my-license-secret kommanderType=license \
  -n kommander \
  --kubeconfig ${CLUSTER_NAME}.conf

Option 2 - Instruct user to apply via UI:
1. Navigate to dashboard URL
2. Go to Settings > Licensing
3. Click "Activate License"
4. Enter license token

Verify license activation:
kubectl get license -n kommander --kubeconfig ${CLUSTER_NAME}.conf

Report license status and tier.
```

### Phase 8: Final Verification

```
Perform comprehensive deployment verification:

1. Cluster Health:
   - All nodes in Ready state
   - All system pods running
   - No pending or failed pods

2. Networking:
   - CNI pods healthy (Cilium/Calico)
   - MetalLB pods healthy
   - Test service LoadBalancer IP assignment

3. Storage:
   - Default StorageClass configured
   - Test PVC creation and binding

4. Kommander:
   - All Kommander pods running
   - Dashboard accessible
   - License valid

5. Certificates:
   - All certificates valid
   - No expiring certificates (< 30 days)

6. Platform Applications:
   - Prometheus running
   - Grafana accessible
   - Traefik ingress working

Generate a deployment summary report with:
- Cluster details
- Access URLs
- Credentials
- Any warnings or recommendations
```

---

## 🔧 TROUBLESHOOTING PROMPTS

### Bootstrap Failure

```
The NKP bootstrap cluster failed to create. Diagnose and fix:

Error message: [paste error]

Check:
1. Docker/Podman status and available resources
2. Existing kind clusters that might conflict
3. Port conflicts on 6443
4. Available disk space
5. Network connectivity

Clean up and retry if needed.
```

### Cluster Creation Timeout

```
The cluster creation is timing out. Diagnose:

Current status:
kubectl get clusters,machines,kubeadmcontrolplane -A

Check:
1. SSH connectivity to nodes
2. Node prerequisites (swap, iscsid, etc.)
3. Image pull issues on nodes
4. CAPI controller logs

Provide specific remediation steps.
```

### Kommander Installation Issues

```
Kommander installation is failing or pods are not starting. Diagnose:

Check:
1. Pending pods and their events:
   kubectl get pods -n kommander -o wide
   kubectl describe pod <pending-pod> -n kommander

2. Storage issues:
   kubectl get pvc -n kommander
   
3. Resource constraints:
   kubectl top nodes

4. Image pull issues:
   kubectl get events -n kommander --sort-by='.lastTimestamp'

Provide remediation steps.
```

### MetalLB Not Assigning IPs

```
MetalLB is not assigning external IPs to LoadBalancer services. Diagnose:

Check:
1. MetalLB pods status
2. IPAddressPool configuration
3. L2Advertisement or BGPAdvertisement exists
4. Speaker pods on each node
5. ARP/NDP responses (for L2 mode)
6. Service selector matching pods

Test:
kubectl logs -n metallb-system -l app=metallb,component=speaker

Fix configuration issues and verify IP assignment.
```

---

## 🚀 QUICK DEPLOYMENT (Single Prompt)

For experienced users who want a single comprehensive prompt:

```
Deploy NKP 2.16 to pre-provisioned infrastructure using the configuration in ./nkp-deployment-spec.yaml and ./environment.env.

Execute the full deployment workflow:
1. Source environment variables from ./environment.env
2. Validate prerequisites using ./scripts/validate-prerequisites.sh
3. Generate inventory from template
4. Create bootstrap cluster
5. Deploy self-managed cluster
6. Delete bootstrap after pivot
7. Configure MetalLB from ./configs/metallb-config.yaml
8. Install Kommander
9. Apply license
10. Run verification using ./scripts/verify-deployment.sh

At each major step, report status. On any failure, stop and provide diagnostics with the exact error and recommended fix. After successful deployment, provide the complete access information including dashboard URL, credentials, and kubeconfig location.
```

---

## 📁 CONTEXT FILES TO PROVIDE

When starting a Claude Code session for NKP deployment, provide these files:

1. `nkp-deployment-spec.yaml` - Main configuration
2. `environment.env` - Environment variables
3. `preprovisioned_inventory.yaml` - Node inventory (or template)
4. `metallb-config.yaml` - MetalLB configuration
5. `kommander.yaml` - Kommander customizations (optional)
6. SSH private key file
7. NKP license token (or file)
8. For air-gapped: paths to all bundle files

---

## 💡 TIPS FOR EFFECTIVE CLAUDE CODE USAGE

1. **Start with validation**: Always run prerequisite checks first
2. **Provide complete context**: Include all configuration files upfront
3. **Use incremental prompts**: For complex environments, use phase-specific prompts
4. **Enable verbose output**: Ask Claude Code to show command output for debugging
5. **Save state**: After each phase, confirm successful completion before proceeding
6. **Handle secrets carefully**: Use environment variables, not inline secrets
7. **Plan for rollback**: Ask Claude Code to document each step for potential rollback

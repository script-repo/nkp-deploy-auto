# NKP Deployment Quick Start for Claude Code

## 🚀 One-Command Start

```bash
# In Claude Code session:
Read the files in this directory and deploy NKP 2.16 using the Master Deployment 
Prompt from CLAUDE_CODE_PROMPTS.md. Use environment.env for configuration.
```

## 📝 Essential Configuration (environment.env)

Fill in these required values before deployment:

```bash
# Cluster Name
CLUSTER_NAME="nkp-mgmt"

# Control Plane Nodes (3 for HA)
CONTROL_PLANE_1_ADDRESS="192.168.1.51"
CONTROL_PLANE_2_ADDRESS="192.168.1.52"  
CONTROL_PLANE_3_ADDRESS="192.168.1.53"

# Worker Nodes (4+ recommended)
WORKER_1_ADDRESS="192.168.1.61"
WORKER_2_ADDRESS="192.168.1.62"
WORKER_3_ADDRESS="192.168.1.63"
WORKER_4_ADDRESS="192.168.1.64"

# API Server Virtual IP
CONTROL_PLANE_ENDPOINT_HOST="192.168.1.100"

# SSH Access
SSH_USER="konvoy"
SSH_PRIVATE_KEY_FILE="~/.ssh/id_rsa"

# LoadBalancer IPs (5-15 IPs outside DHCP range)
METALLB_IP_RANGE="192.168.1.240-192.168.1.250"
```

## 🔧 Claude Code Session Commands

```bash
# Start Claude Code in deployment directory
cd nkp-claude-code-deployment
claude

# Add context files
/add environment.env nkp-deployment-spec.yaml CLAUDE_CODE_PROMPTS.md

# Then paste the Master Deployment Prompt
```

## 📋 Phase-by-Phase Prompts

| Phase | Prompt |
|-------|--------|
| 1. Validate | "Run validate-prerequisites.sh and report any issues" |
| 2. Bootstrap | "Create the NKP bootstrap cluster" |
| 3. Deploy | "Deploy the management cluster using the inventory" |
| 4. Network | "Configure MetalLB with the specified IP range" |
| 5. Kommander | "Install Kommander dashboard" |
| 6. Verify | "Run verify-deployment.sh and report results" |

## ⚡ Key NKP Commands

```bash
# Bootstrap
nkp create bootstrap

# Deploy Cluster  
nkp create cluster preprovisioned \
  --cluster-name ${CLUSTER_NAME} \
  --control-plane-endpoint-host ${VIP} \
  --pre-provisioned-inventory-file inventory.yaml \
  --ssh-private-key-file ~/.ssh/id_rsa \
  --self-managed

# Get kubeconfig
nkp get kubeconfig -c ${CLUSTER_NAME} > ${CLUSTER_NAME}.conf

# Delete bootstrap
nkp delete bootstrap

# Install Kommander
nkp install kommander --init > kommander.yaml
nkp install kommander --installer-config kommander.yaml

# Get dashboard access
nkp get dashboard
```

## ✅ Verification Commands

```bash
# Node health
kubectl get nodes -o wide

# System pods
kubectl get pods -A | grep -v Running

# MetalLB status
kubectl get pods -n metallb-system
kubectl get ipaddresspool -n metallb-system

# Kommander status
kubectl get pods -n kommander
```

## 🚨 Common Issues & Fixes

| Issue | Fix |
|-------|-----|
| SSH fails | Check key permissions: `chmod 600 ~/.ssh/id_rsa` |
| Swap enabled | Run on each node: `swapoff -a` |
| VIP in use | Choose different unused IP |
| No LoadBalancer IP | Check MetalLB IPAddressPool and L2Advertisement |
| Pods pending | Check resources: `kubectl describe pod <name>` |

## 📁 Output Files

After deployment, find these in `./nkp-output/`:

- `${CLUSTER_NAME}.conf` - Kubeconfig
- `dashboard-credentials.txt` - UI login
- `verification-summary.txt` - Health report

## 🔗 Resources

- [NKP Docs](https://portal.nutanix.com/page/documents/details?targetId=Nutanix-Kubernetes-Platform-v2_16)
- [Claude Code Docs](https://docs.anthropic.com/claude-code)

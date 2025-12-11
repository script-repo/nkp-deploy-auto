# NKP Deployment Package for Claude Code

This package provides everything needed to deploy Nutanix Kubernetes Platform (NKP) 2.16 using Claude Code as an automated deployment agent.

## 📁 Package Contents

```
nkp-claude-code-deployment/
├── CLAUDE_CODE_PROMPTS.md      # Prompts for Claude Code
├── nkp-deployment-spec.yaml    # Main deployment specification
├── environment.env.template    # Environment variables template
├── README.md                   # This file
├── configs/
│   └── metallb-config.yaml.template
├── scripts/
│   ├── deploy-nkp.sh           # Main deployment script
│   ├── validate-prerequisites.sh
│   └── verify-deployment.sh
└── templates/
    └── preprovisioned_inventory.yaml.template
```

## 🚀 Quick Start

### Step 1: Prepare Your Environment

1. Copy `environment.env.template` to `environment.env`:
   ```bash
   cp environment.env.template environment.env
   ```

2. Edit `environment.env` with your infrastructure details:
   - Node IP addresses
   - SSH credentials
   - Network configuration
   - License token

3. Ensure your SSH key is accessible and has correct permissions:
   ```bash
   chmod 600 ~/.ssh/id_rsa
   ```

### Step 2: Start Claude Code Session

Launch Claude Code in this directory:
```bash
cd nkp-claude-code-deployment
claude
```

### Step 3: Provide Context Files

When Claude Code starts, provide the configuration files:
```
/add environment.env nkp-deployment-spec.yaml CLAUDE_CODE_PROMPTS.md
```

### Step 4: Use the Master Deployment Prompt

Copy and paste the Master Deployment Prompt from `CLAUDE_CODE_PROMPTS.md`, or use:

```
Read the CLAUDE_CODE_PROMPTS.md file and execute the Master Deployment Prompt 
using the configuration from environment.env and nkp-deployment-spec.yaml.
Deploy NKP 2.16 on pre-provisioned infrastructure with full verification.
```

## 📋 Detailed Usage

### Option A: Fully Automated Deployment

Use the master prompt for a complete hands-off deployment:

```
Deploy NKP 2.16 to my pre-provisioned infrastructure. Use the configuration 
in environment.env and nkp-deployment-spec.yaml. Execute all phases:
1. Validate prerequisites
2. Generate inventory
3. Create bootstrap cluster
4. Deploy management cluster
5. Configure MetalLB
6. Install Kommander
7. Apply license
8. Verify deployment

Report progress at each step and stop on any critical errors.
```

### Option B: Phase-by-Phase Deployment

For more control, use phase-specific prompts from `CLAUDE_CODE_PROMPTS.md`:

1. **Validation Phase**:
   ```
   Execute Phase 1 from CLAUDE_CODE_PROMPTS.md - validate all prerequisites 
   and report any issues before we proceed with deployment.
   ```

2. **Cluster Creation Phase**:
   ```
   Execute Phases 3-5 from CLAUDE_CODE_PROMPTS.md - create the bootstrap 
   cluster, deploy the management cluster, and retrieve kubeconfig.
   ```

3. **Post-Deployment Phase**:
   ```
   Execute Phases 6-8 from CLAUDE_CODE_PROMPTS.md - configure MetalLB, 
   install Kommander, apply license, and run verification.
   ```

### Option C: Manual Script Execution

Have Claude Code run the scripts directly:

```
Make the deployment scripts executable and run the full deployment:
chmod +x scripts/*.sh
./scripts/deploy-nkp.sh
```

## 🔧 Configuration Reference

### environment.env Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `CLUSTER_NAME` | Unique cluster identifier | Yes |
| `CONTROL_PLANE_*_ADDRESS` | Control plane node IPs | Yes |
| `WORKER_*_ADDRESS` | Worker node IPs | Yes |
| `CONTROL_PLANE_ENDPOINT_HOST` | API server VIP | Yes |
| `SSH_USER` | SSH username for nodes | Yes |
| `SSH_PRIVATE_KEY_FILE` | Path to SSH private key | Yes |
| `METALLB_IP_RANGE` | IP range for LoadBalancer | Yes |
| `NKP_LICENSE_TOKEN` | License token | No* |

*License can be applied via UI if not provided

### nkp-deployment-spec.yaml

The deployment spec provides a structured YAML configuration covering:
- Cluster settings
- Node inventory
- Networking (MetalLB, CNI)
- Storage configuration
- Kommander settings
- Security options

Edit this file for complex deployments or to enable optional features.

## ✅ Prerequisites Checklist

Before running the deployment:

### Bastion Host
- [ ] Docker 20+ or Podman 4+ installed
- [ ] kubectl installed
- [ ] helm 3.x installed
- [ ] 50GB+ free disk space
- [ ] Network access to all nodes

### All Cluster Nodes
- [ ] Supported OS (Rocky 9.5/9.6, RHEL 8.10, Ubuntu 22.04)
- [ ] SSH access from bastion with sudo
- [ ] Swap disabled
- [ ] iscsid service running
- [ ] firewalld disabled
- [ ] 15%+ free disk space
- [ ] NTP synchronized

### Network
- [ ] Control plane VIP not in use
- [ ] MetalLB IPs not in DHCP range
- [ ] DNS resolution working
- [ ] Required ports open (6443, 2379-2380, 10250-10252)

## 🔍 Troubleshooting

### Common Issues

**SSH Connection Failures**
```
Check SSH connectivity and report issues:
ssh -v -i ${SSH_PRIVATE_KEY_FILE} ${SSH_USER}@<node-ip>
```

**Bootstrap Cluster Fails**
```
Diagnose bootstrap failure - check Docker status, port conflicts, 
and existing kind clusters. Provide remediation steps.
```

**Pods Not Starting**
```
Check pending pods and their events. Identify root cause 
(image pull, resource constraints, storage) and fix.
```

**MetalLB Not Assigning IPs**
```
Verify MetalLB configuration - check IPAddressPool exists, 
L2Advertisement is created, and speaker pods are running.
```

### Getting Help

Ask Claude Code for diagnostics:
```
Generate a support bundle and diagnose the current deployment state.
Run: nkp diagnose --kubeconfig ${CLUSTER_NAME}.conf -o support-bundle.tar.gz
```

## 📚 Additional Resources

- [NKP 2.16 Documentation](https://portal.nutanix.com/page/documents/details?targetId=Nutanix-Kubernetes-Platform-v2_16:Nutanix-Kubernetes-Platform-v2_16)
- [Nutanix Support Portal](https://portal.nutanix.com)
- [Claude Code Documentation](https://docs.anthropic.com/claude-code)

## 📝 Output Files

After successful deployment, find these in `./nkp-output/`:

| File | Description |
|------|-------------|
| `${CLUSTER_NAME}.conf` | Kubeconfig for cluster access |
| `dashboard-credentials.txt` | NKP UI login credentials |
| `verification-summary.txt` | Deployment verification results |

## 🔐 Security Notes

1. **Protect sensitive files**:
   ```bash
   chmod 600 environment.env
   chmod 600 nkp-output/*.conf
   chmod 600 nkp-output/dashboard-credentials.txt
   ```

2. **Rotate credentials after deployment**:
   - Dashboard password is automatically rotated
   - Consider rotating SSH keys post-deployment

3. **Network security**:
   - Restrict API server access to known IPs
   - Configure network policies after deployment
   - Enable audit logging

## 📄 License

This deployment package is provided as-is for use with Nutanix Kubernetes Platform.
NKP requires a valid license from Nutanix.

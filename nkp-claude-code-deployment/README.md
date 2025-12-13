# NKP Deployment Package for Bastion UI + Scripts

This package provides everything needed to deploy Nutanix Kubernetes Platform (NKP) 2.16 from the bastion host via the bundled Flask UI or by invoking the included scripts directly.

## What it does
- Collects the minimal Prism Central details (IP, username, password) and verifies connectivity.
- Auto-discovers clusters, subnets, projects, and storage containers from Prism Central and populates dropdowns.
- Lets you save, download, and upload configuration files that drive the installation.
- Executes a strictly sequential install script that mirrors the nkp-quickstart process and streams progress to the UI.

```
nkp-claude-code-deployment/
├── environment.env.template    # Environment variables template
├── README.md                   # This file
├── configs/
│   └── metallb-config.yaml.template
├── scripts/
│   ├── deploy-nkp.sh                 # Main deployment script
│   ├── parallel-deploy-and-verify.sh # Parallelized runner with verification
│   ├── validate-prerequisites.sh
│   └── verify-deployment.sh
├── templates/
│   └── preprovisioned_inventory.yaml.template
├── ui/                          # Flask UI for configuration + deployment
└── archive/                     # Legacy prompts and agent-only runbooks
```

## 🚀 Quick Start

### Step 0: One-Command Bastion Prep + UI Launch (Rocky Linux)

On a fresh Rocky Linux bastion, run a single command to install Docker CE, kubectl, Helm 3, SSH, open the UI port (8080) when `firewalld` is active, provision Python, install UI dependencies, seed `environment.env` from the template, and start the web dashboard. Run as root or with sudo:

```bash
cd nkp-claude-code-deployment
sudo scripts/install-deps-run-ui.sh
```

When the script completes, open `http://<bastion-ip>:8080` and perform the remainder of the workflow entirely from the UI (fill in configuration, save, and launch deployments). The installer is idempotent and will skip tools that are already present.

### Step 1: Prepare Your Environment

1. Copy `environment.env.template` to `environment.env`:
   ```bash
   cd ui
   python -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt
   ```

2. Launch the UI from the repo root:
   ```bash
   chmod 600 ~/.ssh/id_rsa
   ```

### Step 2: Choose Your Automation Path

- **Use the bastion UI (recommended)**: open the dashboard, fill in the configuration form, save `environment.env`, and click **Launch Deployment** to run the parallelized workflow end to end.

- **Run scripts directly**: make the scripts executable and invoke either the end-to-end runner or the new parallelized workflow with automatic verification:
  ```bash
  cd nkp-claude-code-deployment
  chmod +x scripts/*.sh
  # Fully sequential flow
  ./scripts/deploy-nkp.sh

  # Parallel validation/prep + automated verification
  ./scripts/parallel-deploy-and-verify.sh
  ```

### Legacy agent prompts and runbooks

Previous agent-only prompts, parallel prompt sets, and the older deployment specification now live under `archive/` for reference. They are not used by the current UI or installer.

## 📋 Detailed Usage

### Option A: Fully Automated via UI

1. Run `scripts/install-deps-run-ui.sh` to prepare the bastion and start Flask.
2. Open the dashboard at `http://<bastion-ip>:8080`.
3. Fill in the configuration form, save `environment.env`, and choose **Launch Deployment** to run validation, preparation, deployment, and verification automatically.

### Option B: Automated via Parallel Runner

Make the scripts executable and use the parallel workflow without the UI:

```
cd nkp-claude-code-deployment
chmod +x scripts/*.sh
./scripts/parallel-deploy-and-verify.sh
```

### Option C: Phased Script Execution

Execute individual phases when you need granular control:

```
# Validate prerequisites in parallel
./scripts/parallel-validate.sh

# Prepare nodes in parallel
./scripts/parallel-prepare-nodes.sh

# Deploy NKP sequentially
./scripts/deploy-nkp.sh

# Verify the deployment
./scripts/verify-deployment.sh
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

Ask your agent or run directly for diagnostics:
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

## Scripted install
The installer keeps everything linear and human-readable:
1. Validate that common tools (`curl`, `kubectl`, `helm`, `ssh`) exist.
2. Prepare an output directory for artifacts and kubeconfig.
3. Follow the nkp-quickstart steps in order (fetch assets, ensure project/subnet/container, render manifests, create management cluster, configure networking and storage, write kubeconfig).

Set `DRY_RUN=true` in `environment.env` to print the commands without executing them.

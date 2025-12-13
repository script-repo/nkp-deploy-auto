# NKP Deployment Project

This project automates the deployment of Nutanix Kubernetes Platform (NKP) 2.16 on pre-provisioned infrastructure. You can drive it with any capable AI coding agent or by running the provided shell scripts directly.

## Project Context

You are helping deploy an enterprise Kubernetes cluster using NKP. The deployment involves:

1. **Pre-provisioned infrastructure**: VMs already exist with OS installed
2. **Self-managed cluster**: The management cluster manages itself via Cluster API
3. **Pre-configured networking**: MetalLB for LoadBalancer services
4. **Kommander dashboard**: Central management UI for the platform

## Key Files

- `environment.env` - Environment variables with deployment configuration
- `nkp-deployment-spec.yaml` - Detailed deployment specification
- `CLAUDE_CODE_PROMPTS.md` - Structured prompts for deployment phases (agent-friendly)
- `scripts/` - Helper scripts for deployment automation
- `configs/` - Configuration templates
- `templates/` - YAML templates

## Deployment Workflow

1. **Validate** - Check all prerequisites before deployment
2. **Bootstrap** - Create temporary KIND cluster for CAPI controllers
3. **Deploy** - Create the management cluster on pre-provisioned nodes
4. **Pivot** - Move CAPI resources to the new cluster (self-managed)
5. **Configure** - Set up MetalLB, storage, networking
6. **Install** - Deploy Kommander for management dashboard
7. **License** - Activate the NKP license
8. **Verify** - Confirm all components are healthy

## Important Commands

```bash
# Create bootstrap cluster
nkp create bootstrap --kubeconfig $HOME/.kube/config

# Deploy cluster
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
nkp install kommander --installer-config kommander.yaml --kubeconfig ${CLUSTER_NAME}.conf

# Get dashboard access
nkp get dashboard --kubeconfig ${CLUSTER_NAME}.conf
```

## Error Handling

If deployment fails:
1. Check the specific phase that failed
2. Review logs: `kubectl logs -n <namespace> <pod>`
3. Check events: `kubectl get events -A --sort-by='.lastTimestamp'`
4. For bootstrap issues: `docker logs $(docker ps -q --filter name=kind)`

## Success Criteria

Deployment is successful when:
- All nodes are in `Ready` state
- All pods are `Running` or `Completed`
- MetalLB assigns IPs to LoadBalancer services
- Kommander dashboard is accessible
- License is activated

## Output Location

All deployment artifacts are saved to `./nkp-output/`:
- Kubeconfig file
- Dashboard credentials
- Verification report

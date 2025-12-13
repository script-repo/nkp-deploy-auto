# NKP Bastion Deployment Dashboard

A production-ready Flask UI that lives on the bastion host to manage NKP deployments. It supports the fully automated workflow (parallel validation + deployment + verification) as well as phased execution when you want to run validation, preparation, deployment, and verification independently.

## Quick start (one command)

On Rocky Linux 9+, bootstrap everything and launch the UI in one step from the repository root (installs Docker, kubectl, Helm, SSH/firewall updates, Python, venv + Flask deps, seeds `environment.env`, and starts the server on 8080):

```bash
sudo scripts/install-deps-run-ui.sh
```

When the script finishes, open `http://<bastion-ip>:8080` and complete the workflow in the browser.

## Prerequisites (manual path)

- Python 3.10+
- Access to this repository on the bastion host
- SSH reachable to the bastion (installer enables and opens 22/tcp when firewalld is present)
- `environment.env` populated with your values (use the Save Configuration button to generate it)

Install the UI dependencies manually if you prefer not to use the one-command bootstrap:

```bash
cd nkp-claude-code-deployment/ui
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Then start Flask (binds to all interfaces; installer opens 8080/tcp on firewalld-hosts):

```bash
FLASK_APP=app.py flask run --host 0.0.0.0 --port 8080
```

## Generating an offline preview

If you only need a visual of the UI without running Flask (e.g., to share a screenshot), you can render a static preview page:

```bash
cd nkp-claude-code-deployment/ui
python generate_preview.py       # writes ui/static/preview.html
cd static && python -m http.server 8000
# open http://localhost:8000/preview.html
```

The preview seeds the form with default values, animates example progress, and shows sample terminal lines so you can capture a polished image even without backend connectivity.

## Features

- **Configuration form with tooltips** for every deployment variable (cluster, networking, storage, registry, air-gapped bundles, timeouts, and flags).
- **Inline validation** highlights required fields before writing to disk.
- **Save Configuration** writes a fresh `environment.env` with derived variables for the scripts.
- **Launch Deployment** starts either the automated runner or your selected phases, streaming live output into the embedded terminal.
- **Progress dashboard** shows phase status, overall percentage, and live connection health to the SSE stream.

## Notes

- Automated runs invoke `scripts/parallel-deploy-and-verify.sh` from the repo root.
- Phased runs call the individual helpers in `scripts/parallel-validate.sh`, `scripts/parallel-prepare-nodes.sh`, `scripts/deploy-nkp.sh`, and `scripts/verify-deployment.sh` in the order you select.
- All commands execute from `nkp-claude-code-deployment/` so they can find `environment.env` and supporting templates.

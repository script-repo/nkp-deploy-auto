# NKP Quick Deploy (Scripted + UI)

This repository rebuilds the previous automation package into a simple, single-threaded deployment helper inspired by the [`nkp-quickstart`](https://github.com/nutanixdev/nkp-quickstart/tree/main) reference flow. It pairs a minimal Flask UI with a scripted installer that runs every step sequentially—no parallelism, no agents.

## What it does
- Collects the minimal Prism Central details (IP, username, password) and verifies connectivity.
- Auto-discovers clusters, subnets, projects, and storage containers from Prism Central and populates dropdowns.
- Lets you save, download, and upload configuration files that drive the installation.
- Executes a strictly sequential install script that mirrors the nkp-quickstart process and streams progress to the UI.

## Quick start
1. Install UI dependencies:
   ```bash
   cd ui
   python -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt
   ```

2. Launch the UI from the repo root:
   ```bash
   cd ..
   FLASK_APP=ui/app.py flask run --host 0.0.0.0 --port 8080
   ```

3. Open `http://<bastion-ip>:8080` and:
   - Enter Prism Central IP/username/password, then click **Verify & Fetch** to pull target values.
   - Adjust the dropdowns and CIDRs.
   - Save or download the config for reuse.
   - Click **Launch Scripted Install** to run the sequential `scripts/run-deployment.sh` workflow and watch the log stream.

## Scripted install
The installer keeps everything linear and human-readable:
1. Validate that common tools (`curl`, `kubectl`, `helm`, `ssh`) exist.
2. Prepare an output directory for artifacts and kubeconfig.
3. Follow the nkp-quickstart steps in order (fetch assets, ensure project/subnet/container, render manifests, create management cluster, configure networking and storage, write kubeconfig).

Set `DRY_RUN=true` in `environment.env` to print the commands without executing them.

from __future__ import annotations

import json
import os
import queue
import subprocess
import threading
from pathlib import Path
from typing import Any, Dict

from flask import Flask, Response, jsonify, render_template, request, send_file

from scripts.prism_client import gather_inventory

BASE_DIR = Path(__file__).resolve().parents[1]
ENV_FILE = BASE_DIR / "environment.env"
CONFIG_FILE = BASE_DIR / "configs" / "deployment.json"
DEPLOY_SCRIPT = BASE_DIR / "scripts" / "run-deployment.sh"

app = Flask(__name__)
log_queue: "queue.Queue[str]" = queue.Queue()
state: Dict[str, Any] = {
    "running": False,
    "progress": 0,
    "step": "idle",
    "summary": "",
}

defaults = {
    "PRISM_CENTRAL_IP": "",
    "PRISM_CENTRAL_USERNAME": "",
    "PRISM_CENTRAL_PASSWORD": "",
    "PRISM_CENTRAL_VERIFY_SSL": False,
    "TARGET_CLUSTER": "",
    "TARGET_SUBNET": "",
    "TARGET_PROJECT": "",
    "STORAGE_CONTAINER": "",
    "NODE_CIDR": "10.240.0.0/16",
    "SERVICE_CIDR": "10.96.0.0/12",
    "METALLB_IP_RANGE": "192.168.1.240-192.168.1.250",
    "SSH_USERNAME": "ubuntu",
    "SSH_PRIVATE_KEY_PATH": "~/.ssh/id_rsa",
    "OUTPUT_DIRECTORY": "${PWD}/nkp-output",
    "KUBECONFIG_PATH": "${OUTPUT_DIRECTORY}/nkp-mgmt.conf",
    "DRY_RUN": False,
}


def load_config() -> Dict[str, Any]:
    if CONFIG_FILE.exists():
        return json.loads(CONFIG_FILE.read_text())
    if ENV_FILE.exists():
        parsed: Dict[str, Any] = {}
        for line in ENV_FILE.read_text().splitlines():
            if not line.strip() or line.strip().startswith("#"):
                continue
            if "=" in line:
                key, value = line.split("=", 1)
                parsed[key.strip()] = value.strip().strip('"')
        return {**defaults, **parsed}
    return defaults.copy()


def persist_config(data: Dict[str, Any]) -> None:
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(data, indent=2))
    env_lines = [f"{key}={value}" for key, value in data.items()]
    ENV_FILE.write_text("\n".join(env_lines) + "\n")


def enqueue(message: str) -> None:
    log_queue.put(message)


def stream_process(process: subprocess.Popen) -> None:
    for line in iter(process.stdout.readline, b""):
        if not line:
            break
        enqueue(line.decode(errors="ignore"))
    process.stdout.close()


def run_deployment() -> None:
    global state
    state.update({"running": True, "progress": 5, "step": "starting"})
    cmd = ["bash", str(DEPLOY_SCRIPT), str(ENV_FILE)]
    enqueue(f"Starting deployment using {DEPLOY_SCRIPT}\n")
    process = subprocess.Popen(
        cmd,
        cwd=BASE_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    stream_thread = threading.Thread(target=stream_process, args=(process,), daemon=True)
    stream_thread.start()
    stream_thread.join()
    return_code = process.wait()
    state["progress"] = 100 if return_code == 0 else state.get("progress", 0)
    state["running"] = False
    state["step"] = "complete" if return_code == 0 else "failed"
    enqueue(f"Deployment finished with code {return_code}\n")


@app.route("/")
def index() -> str:
    return render_template("index.html", config=load_config())


@app.route("/api/verify", methods=["POST"])
def api_verify():
    body = request.json or {}
    host = body.get("pc_ip", "").strip()
    username = body.get("username", "").strip()
    password = body.get("password", "").strip()
    verify_ssl = bool(body.get("verify_ssl", False))

    if not host or not username or not password:
        return jsonify({"error": "Prism Central IP, username, and password are required."}), 400

    try:
        inventory = gather_inventory(host, username, password, verify_ssl)
        return jsonify({"success": True, "inventory": inventory})
    except Exception as exc:  # noqa: BLE001
        return jsonify({"success": False, "error": str(exc)}), 500


@app.route("/api/save-config", methods=["POST"])
def api_save_config():
    data = request.json or {}
    merged = {**defaults, **data}
    persist_config(merged)
    return jsonify({"success": True})


@app.route("/api/download-config")
def api_download_config():
    if not ENV_FILE.exists():
        persist_config(load_config())
    return send_file(ENV_FILE, as_attachment=True, download_name="environment.env")


@app.route("/api/upload-config", methods=["POST"])
def api_upload_config():
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400
    file = request.files["file"]
    content = file.read().decode()
    parsed: Dict[str, Any] = {}
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError:
        for line in content.splitlines():
            if not line.strip() or line.strip().startswith("#"):
                continue
            if "=" in line:
                key, value = line.split("=", 1)
                parsed[key.strip()] = value.strip().strip('"')
    persist_config({**defaults, **parsed})
    return jsonify({"success": True, "config": load_config()})


@app.route("/api/run", methods=["POST"])
def api_run():
    if state.get("running"):
        return jsonify({"error": "Deployment already running"}), 409
    persist_config(request.json or load_config())
    thread = threading.Thread(target=run_deployment, daemon=True)
    thread.start()
    return jsonify({"success": True})


@app.route("/api/stream")
def api_stream():
    def event_stream():
        while True:
            try:
                message = log_queue.get(timeout=1)
                yield f"data: {json.dumps({'message': message})}\n\n"
            except queue.Empty:
                if not state.get("running"):
                    break
                continue

    return Response(event_stream(), mimetype="text/event-stream")


@app.route("/api/status")
def api_status():
    return jsonify(state)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)), debug=True)

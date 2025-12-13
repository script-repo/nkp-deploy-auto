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
DEPLOYMENT_FILE = BASE_DIR / "deployment.json"
SCRIPTS_DIR = BASE_DIR / "scripts"

app = Flask(__name__)

log_queue: "queue.Queue[dict]" = queue.Queue()
deployment_thread: threading.Thread | None = None
deployment_lock = threading.Lock()
deployment_active = False
current_mode = "automated"
SENSITIVE_FIELDS = {"PRISM_CENTRAL_PASSWORD"}

DEFAULT_CONFIG: Dict[str, str] = {
    "CLUSTER_NAME": "nkp-mgmt",
    "CONTROL_PLANE_1_ADDRESS": "192.168.1.51",
    "CONTROL_PLANE_2_ADDRESS": "192.168.1.52",
    "CONTROL_PLANE_3_ADDRESS": "192.168.1.53",
    "WORKER_1_ADDRESS": "192.168.1.61",
    "WORKER_2_ADDRESS": "192.168.1.62",
    "WORKER_3_ADDRESS": "192.168.1.63",
    "WORKER_4_ADDRESS": "192.168.1.64",
    "CONTROL_PLANE_ENDPOINT_HOST": "192.168.1.100",
    "CONTROL_PLANE_ENDPOINT_PORT": "6443",
    "VIRTUAL_IP_INTERFACE": "",
    "SSH_USER": "konvoy",
    "SSH_PRIVATE_KEY_FILE": "~/.ssh/id_rsa",
    "SSH_PRIVATE_KEY_SECRET_NAME": "nkp-mgmt-ssh-key",
    "METALLB_IP_RANGE": "192.168.1.240-192.168.1.250",
    "POD_CIDR": "10.244.0.0/16",
    "SERVICE_CIDR": "10.96.0.0/12",
    "HTTP_PROXY": "",
    "HTTPS_PROXY": "",
    "NO_PROXY": "localhost,127.0.0.1",
    "STORAGE_PROVIDER": "local-volume-provisioner",
    "NUTANIX_ENDPOINT": "",
    "NUTANIX_USER": "",
    "NUTANIX_PASSWORD": "",
    "NUTANIX_CLUSTER_UUID": "",
    "STORAGE_CONTAINER": "",
    "PRISM_CENTRAL_PASSWORD": "",
    "LICENSE_TYPE": "pro",
    "NKP_LICENSE_TOKEN": "",
    "REGISTRY_MIRROR_URL": "https://registry-1.docker.io",
    "REGISTRY_MIRROR_USERNAME": "",
    "REGISTRY_MIRROR_PASSWORD": "",
    "AIRGAPPED": "false",
    "LOCAL_REGISTRY_URL": "",
    "LOCAL_REGISTRY_CA_CERT": "",
    "LOCAL_REGISTRY_USERNAME": "",
    "LOCAL_REGISTRY_PASSWORD": "",
    "NKP_BUNDLE_PATH": "",
    "KONVOY_IMAGE_BUNDLE": "",
    "KOMMANDER_IMAGE_BUNDLE": "",
    "KOMMANDER_CHARTS_BUNDLE": "",
    "OUTPUT_DIR": "${PWD}/nkp-output",
    "KUBECONFIG_PATH": "${OUTPUT_DIR}/nkp-mgmt.conf",
    "CLUSTER_CREATE_TIMEOUT": "60m",
    "KOMMANDER_INSTALL_TIMEOUT": "45m",
    "NODE_READY_TIMEOUT": "30m",
    "VERBOSE": "false",
    "DRY_RUN": "false",
    "FIPS_MODE": "false",
}

FIELD_METADATA: Dict[str, Dict[str, str | list]] = {
    "CLUSTER_NAME": {
        "label": "Cluster name",
        "tooltip": "Unique identifier for the NKP cluster.",
        "placeholder": "nkp-mgmt",
        "required": True,
    },
    "CONTROL_PLANE_1_ADDRESS": {
        "label": "Control plane 1",
        "tooltip": "IP or hostname of the first control plane node.",
        "placeholder": "192.168.1.51",
        "required": True,
    },
    "CONTROL_PLANE_2_ADDRESS": {
        "label": "Control plane 2",
        "tooltip": "IP or hostname of the second control plane node.",
        "placeholder": "192.168.1.52",
    },
    "CONTROL_PLANE_3_ADDRESS": {
        "label": "Control plane 3",
        "tooltip": "IP or hostname of the third control plane node.",
        "placeholder": "192.168.1.53",
    },
    "WORKER_1_ADDRESS": {
        "label": "Worker 1",
        "tooltip": "IP or hostname of the first worker node.",
        "placeholder": "192.168.1.61",
        "required": True,
    },
    "WORKER_2_ADDRESS": {
        "label": "Worker 2",
        "tooltip": "IP or hostname of the second worker node.",
        "placeholder": "192.168.1.62",
    },
    "WORKER_3_ADDRESS": {
        "label": "Worker 3",
        "tooltip": "IP or hostname of the third worker node.",
        "placeholder": "192.168.1.63",
    },
    "WORKER_4_ADDRESS": {
        "label": "Worker 4",
        "tooltip": "IP or hostname of the fourth worker node.",
        "placeholder": "192.168.1.64",
    },
    "CONTROL_PLANE_ENDPOINT_HOST": {
        "label": "API VIP",
        "tooltip": "Virtual IP/hostname exposed for the Kubernetes API.",
        "placeholder": "192.168.1.100",
        "required": True,
    },
    "CONTROL_PLANE_ENDPOINT_PORT": {
        "label": "API port",
        "tooltip": "API server port, usually 6443.",
        "placeholder": "6443",
    },
    "VIRTUAL_IP_INTERFACE": {
        "label": "VIP interface",
        "tooltip": "Network interface to bind for kube-vip. Leave blank to auto-detect.",
        "placeholder": "eth0",
    },
    "SSH_USER": {
        "label": "SSH user",
        "tooltip": "User used to connect to every node.",
        "placeholder": "konvoy",
        "required": True,
    },
    "SSH_PRIVATE_KEY_FILE": {
        "label": "SSH key path",
        "tooltip": "Private key for SSH access to all nodes.",
        "placeholder": "~/.ssh/id_rsa",
        "required": True,
    },
    "SSH_PRIVATE_KEY_SECRET_NAME": {
        "label": "SSH secret name",
        "tooltip": "Kubernetes secret that will store the SSH private key.",
        "placeholder": "nkp-mgmt-ssh-key",
    },
    "METALLB_IP_RANGE": {
        "label": "MetalLB range",
        "tooltip": "Address pool used for LoadBalancer services.",
        "placeholder": "192.168.1.240-192.168.1.250",
    },
    "POD_CIDR": {
        "label": "Pod CIDR",
        "tooltip": "Cluster pod network CIDR.",
        "placeholder": "10.244.0.0/16",
    },
    "SERVICE_CIDR": {
        "label": "Service CIDR",
        "tooltip": "Cluster service network CIDR.",
        "placeholder": "10.96.0.0/12",
    },
    "HTTP_PROXY": {
        "label": "HTTP proxy",
        "tooltip": "Optional HTTP proxy URL for outbound traffic.",
        "placeholder": "http://proxy:3128",
    },
    "HTTPS_PROXY": {
        "label": "HTTPS proxy",
        "tooltip": "Optional HTTPS proxy URL for outbound traffic.",
        "placeholder": "https://proxy:3129",
    },
    "NO_PROXY": {
        "label": "No proxy",
        "tooltip": "Comma-separated hosts that bypass the proxy.",
        "placeholder": "localhost,127.0.0.1",
    },
    "STORAGE_PROVIDER": {
        "label": "Storage provider",
        "tooltip": "local-volume-provisioner, rook-ceph, or nutanix-csi.",
        "options": [
            {"label": "Local volume provisioner", "value": "local-volume-provisioner"},
            {"label": "Rook Ceph", "value": "rook-ceph"},
            {"label": "Nutanix CSI", "value": "nutanix-csi"},
        ],
    },
    "NUTANIX_ENDPOINT": {
        "label": "Nutanix endpoint",
        "tooltip": "Prism Central VIP for Nutanix CSI setups.",
        "placeholder": "https://prism.example.com",
    },
    "NUTANIX_USER": {
        "label": "Nutanix user",
        "tooltip": "Username with rights to provision storage volumes.",
    },
    "NUTANIX_PASSWORD": {
        "label": "Nutanix password",
        "tooltip": "Password for the Nutanix user.",
        "input_type": "password",
    },
    "NUTANIX_CLUSTER_UUID": {
        "label": "Nutanix cluster UUID",
        "tooltip": "Target Nutanix cluster unique ID.",
    },
    "STORAGE_CONTAINER": {
        "label": "Storage container",
        "tooltip": "Name of the storage container or volume group.",
    },
    "PRISM_CENTRAL_PASSWORD": {
        "label": "Prism Central password",
        "tooltip": "Password is required at runtime and is never written to disk by the UI.",
        "input_type": "password",
    },
    "LICENSE_TYPE": {
        "label": "License type",
        "tooltip": "starter, pro, or ultimate license tier.",
        "options": [
            {"label": "Starter", "value": "starter"},
            {"label": "Pro", "value": "pro"},
            {"label": "Ultimate", "value": "ultimate"},
        ],
    },
    "NKP_LICENSE_TOKEN": {
        "label": "License token",
        "tooltip": "NKP license token; can be empty to apply later.",
        "input_type": "password",
    },
    "REGISTRY_MIRROR_URL": {
        "label": "Registry mirror URL",
        "tooltip": "Mirror or upstream registry URL.",
        "placeholder": "https://registry-1.docker.io",
    },
    "REGISTRY_MIRROR_USERNAME": {
        "label": "Registry user",
        "tooltip": "Username for authenticated registries.",
    },
    "REGISTRY_MIRROR_PASSWORD": {
        "label": "Registry password",
        "tooltip": "Password or token for registry authentication.",
        "input_type": "password",
    },
    "AIRGAPPED": {
        "label": "Air-gapped",
        "tooltip": "Set to true when using an air-gapped bundle and registry.",
        "options": [
            {"label": "False", "value": "false"},
            {"label": "True", "value": "true"},
        ],
    },
    "LOCAL_REGISTRY_URL": {
        "label": "Local registry URL",
        "tooltip": "URL to your private/air-gapped registry.",
        "placeholder": "registry.internal:5000",
    },
    "LOCAL_REGISTRY_CA_CERT": {
        "label": "Local registry CA cert",
        "tooltip": "Path to CA certificate for the local registry.",
        "placeholder": "/etc/ssl/certs/registry-ca.pem",
    },
    "LOCAL_REGISTRY_USERNAME": {
        "label": "Local registry user",
        "tooltip": "Username for the local registry.",
    },
    "LOCAL_REGISTRY_PASSWORD": {
        "label": "Local registry password",
        "tooltip": "Password/token for the local registry.",
        "input_type": "password",
    },
    "NKP_BUNDLE_PATH": {
        "label": "NKP bundle path",
        "tooltip": "Path to the NKP bundle (air-gapped deployments).",
    },
    "KONVOY_IMAGE_BUNDLE": {
        "label": "Konvoy image bundle",
        "tooltip": "Path to the Konvoy image bundle tarball.",
    },
    "KOMMANDER_IMAGE_BUNDLE": {
        "label": "Kommander image bundle",
        "tooltip": "Path to the Kommander image bundle tarball.",
    },
    "KOMMANDER_CHARTS_BUNDLE": {
        "label": "Kommander charts bundle",
        "tooltip": "Path to the Kommander charts bundle.",
    },
    "OUTPUT_DIR": {
        "label": "Output directory",
        "tooltip": "Where generated kubeconfigs and logs are written.",
        "placeholder": "${PWD}/nkp-output",
        "required": True,
    },
    "KUBECONFIG_PATH": {
        "label": "Kubeconfig path",
        "tooltip": "Desired path for the generated kubeconfig.",
        "placeholder": "${OUTPUT_DIR}/nkp-mgmt.conf",
    },
    "CLUSTER_CREATE_TIMEOUT": {
        "label": "Cluster create timeout",
        "tooltip": "Timeout for cluster creation operations (e.g., 60m).",
        "placeholder": "60m",
    },
    "KOMMANDER_INSTALL_TIMEOUT": {
        "label": "Kommander install timeout",
        "tooltip": "Timeout for Kommander install step (e.g., 45m).",
        "placeholder": "45m",
    },
    "NODE_READY_TIMEOUT": {
        "label": "Node ready timeout",
        "tooltip": "Timeout for nodes to become Ready (e.g., 30m).",
        "placeholder": "30m",
    },
    "VERBOSE": {
        "label": "Verbose",
        "tooltip": "Enable verbose logging (true/false).",
        "options": [
            {"label": "False", "value": "false"},
            {"label": "True", "value": "true"},
        ],
    },
    "DRY_RUN": {
        "label": "Dry run",
        "tooltip": "Validate only without applying changes.",
        "options": [
            {"label": "False", "value": "false"},
            {"label": "True", "value": "true"},
        ],
    },
    "FIPS_MODE": {
        "label": "FIPS mode",
        "tooltip": "Enable FIPS mode when required by policy.",
        "options": [
            {"label": "False", "value": "false"},
            {"label": "True", "value": "true"},
        ],
    },
}

FIELD_SECTIONS: List[Dict[str, str | List[str]]] = [
    {
        "id": "cluster",
        "title": "Cluster",
        "description": "Name and node endpoints for your management cluster.",
        "fields": [
            "CLUSTER_NAME",
            "CONTROL_PLANE_1_ADDRESS",
            "CONTROL_PLANE_2_ADDRESS",
            "CONTROL_PLANE_3_ADDRESS",
            "WORKER_1_ADDRESS",
            "WORKER_2_ADDRESS",
            "WORKER_3_ADDRESS",
            "WORKER_4_ADDRESS",
        ],
    },
    {
        "id": "vip",
        "title": "Control plane endpoint",
        "description": "Kubernetes API VIP and port exposed to clients.",
        "fields": ["CONTROL_PLANE_ENDPOINT_HOST", "CONTROL_PLANE_ENDPOINT_PORT", "VIRTUAL_IP_INTERFACE"],
    },
    {
        "id": "access",
        "title": "Access & SSH",
        "description": "Connectivity used by the bastion to manage the nodes.",
        "fields": ["SSH_USER", "SSH_PRIVATE_KEY_FILE", "SSH_PRIVATE_KEY_SECRET_NAME"],
    },
    {
        "id": "network",
        "title": "Networking",
        "description": "Pod, service, and load balancer ranges.",
        "fields": ["METALLB_IP_RANGE", "POD_CIDR", "SERVICE_CIDR"],
    },
    {
        "id": "proxy",
        "title": "Proxy configuration",
        "description": "Optional proxies for outbound traffic.",
        "fields": ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"],
    },
    {
        "id": "storage",
        "title": "Storage",
        "description": "Select a storage backend and provide provider-specific values.",
        "fields": [
            "STORAGE_PROVIDER",
            "NUTANIX_ENDPOINT",
            "NUTANIX_USER",
            "NUTANIX_PASSWORD",
            "PRISM_CENTRAL_PASSWORD",
            "NUTANIX_CLUSTER_UUID",
            "STORAGE_CONTAINER",
        ],
    },
    {
        "id": "license",
        "title": "Licensing",
        "description": "Choose license tier and token (if applying now).",
        "fields": ["LICENSE_TYPE", "NKP_LICENSE_TOKEN"],
    },
    {
        "id": "registry",
        "title": "Registry",
        "description": "Mirror or upstream registry credentials.",
        "fields": ["REGISTRY_MIRROR_URL", "REGISTRY_MIRROR_USERNAME", "REGISTRY_MIRROR_PASSWORD"],
    },
    {
        "id": "airgap",
        "title": "Air-gapped options",
        "description": "Bundle and private registry settings.",
        "fields": [
            "AIRGAPPED",
            "LOCAL_REGISTRY_URL",
            "LOCAL_REGISTRY_CA_CERT",
            "LOCAL_REGISTRY_USERNAME",
            "LOCAL_REGISTRY_PASSWORD",
            "NKP_BUNDLE_PATH",
            "KONVOY_IMAGE_BUNDLE",
            "KOMMANDER_IMAGE_BUNDLE",
            "KOMMANDER_CHARTS_BUNDLE",
        ],
    },
    {
        "id": "output",
        "title": "Output paths",
        "description": "Where artifacts and kubeconfigs are written.",
        "fields": ["OUTPUT_DIR", "KUBECONFIG_PATH"],
    },
    {
        "id": "timeouts",
        "title": "Timeouts & flags",
        "description": "Operational timeouts and feature toggles.",
        "fields": [
            "CLUSTER_CREATE_TIMEOUT",
            "KOMMANDER_INSTALL_TIMEOUT",
            "NODE_READY_TIMEOUT",
            "VERBOSE",
            "DRY_RUN",
            "FIPS_MODE",
        ],
    },
]

REQUIRED_FIELDS = [
    "CLUSTER_NAME",
    "CONTROL_PLANE_1_ADDRESS",
    "WORKER_1_ADDRESS",
    "CONTROL_PLANE_ENDPOINT_HOST",
    "SSH_USER",
    "SSH_PRIVATE_KEY_FILE",
    "OUTPUT_DIR",
]

PHASE_SETS: Dict[str, List[str]] = {
    "automated": [
        "Validate & prepare",
        "Deploy NKP",
        "Verify deployment",
    ],
    "phased": [
        "Validate prerequisites",
        "Prepare nodes",
        "Deploy NKP",
        "Verify deployment",
    ],
}

PHASE_COMMANDS: Dict[str, Tuple[str, List[str]]] = {
    "Deploy NKP": (
        "Deploy NKP",
        ["/bin/bash", str(SCRIPTS_DIR / "deploy-nkp.sh")],
    ),
    "Verify deployment": (
        "Verify deployment",
        ["/bin/bash", str(SCRIPTS_DIR / "verify-deployment.sh")],
    ),
    "Validate prerequisites": (
        "Validate prerequisites",
        ["/bin/bash", str(SCRIPTS_DIR / "parallel-validate.sh")],
    ),
    "Prepare nodes": (
        "Prepare nodes",
        ["/bin/bash", str(SCRIPTS_DIR / "parallel-prepare-nodes.sh")],
    ),
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
            clean_line = line.replace("export ", "", 1)
            if "=" not in clean_line:
                continue
            key, value = clean_line.split("=", 1)
            config[key.strip()] = value.strip().strip('"')
    return config


def format_env_lines(config: Dict[str, str], skip_keys: set[str] | None = None) -> List[str]:
    skip_keys = skip_keys or set()
    section_headers = [
        ("CLUSTER CONFIGURATION", ["CLUSTER_NAME"]),
        (
            "NODE ADDRESSES",
            [
                "CONTROL_PLANE_1_ADDRESS",
                "CONTROL_PLANE_2_ADDRESS",
                "CONTROL_PLANE_3_ADDRESS",
                "WORKER_1_ADDRESS",
                "WORKER_2_ADDRESS",
                "WORKER_3_ADDRESS",
                "WORKER_4_ADDRESS",
            ],
        ),
        (
            "CONTROL PLANE ENDPOINT",
            ["CONTROL_PLANE_ENDPOINT_HOST", "CONTROL_PLANE_ENDPOINT_PORT", "VIRTUAL_IP_INTERFACE"],
        ),
        ("SSH CONFIGURATION", ["SSH_USER", "SSH_PRIVATE_KEY_FILE", "SSH_PRIVATE_KEY_SECRET_NAME"]),
        ("NETWORKING", ["METALLB_IP_RANGE", "POD_CIDR", "SERVICE_CIDR"]),
        ("PROXY CONFIGURATION", ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"]),
        (
            "STORAGE CONFIGURATION",
            [
                "STORAGE_PROVIDER",
                "NUTANIX_ENDPOINT",
                "NUTANIX_USER",
                "NUTANIX_PASSWORD",
                "PRISM_CENTRAL_PASSWORD",
                "NUTANIX_CLUSTER_UUID",
                "STORAGE_CONTAINER",
            ],
        ),
        ("LICENSE", ["LICENSE_TYPE", "NKP_LICENSE_TOKEN"]),
        (
            "REGISTRY CONFIGURATION",
            ["REGISTRY_MIRROR_URL", "REGISTRY_MIRROR_USERNAME", "REGISTRY_MIRROR_PASSWORD"],
        ),
        (
            "AIR-GAPPED CONFIGURATION",
            [
                "AIRGAPPED",
                "LOCAL_REGISTRY_URL",
                "LOCAL_REGISTRY_CA_CERT",
                "LOCAL_REGISTRY_USERNAME",
                "LOCAL_REGISTRY_PASSWORD",
                "NKP_BUNDLE_PATH",
                "KONVOY_IMAGE_BUNDLE",
                "KOMMANDER_IMAGE_BUNDLE",
                "KOMMANDER_CHARTS_BUNDLE",
            ],
        ),
        ("OUTPUT PATHS", ["OUTPUT_DIR", "KUBECONFIG_PATH"]),
        (
            "TIMINGS AND FLAGS",
            ["CLUSTER_CREATE_TIMEOUT", "KOMMANDER_INSTALL_TIMEOUT", "NODE_READY_TIMEOUT", "VERBOSE", "DRY_RUN", "FIPS_MODE"],
        ),
    ]

    lines: List[str] = ["# Generated by NKP Bastion Dashboard", "# Source this file before running deployment"]
    for title, keys in section_headers:
        lines.append("# =============================================================================")
        lines.append(f"# {title}")
        lines.append("# =============================================================================")
        for key in keys:
            if key in skip_keys:
                continue
            value = config.get(key, "")
            lines.append(f"export {key}={shlex.quote(str(value))}")
        lines.append("")
    lines.append("export CONTROL_PLANE_NODES=\"${CONTROL_PLANE_1_ADDRESS} ${CONTROL_PLANE_2_ADDRESS} ${CONTROL_PLANE_3_ADDRESS}\"")
    lines.append("export WORKER_NODES=\"${WORKER_1_ADDRESS} ${WORKER_2_ADDRESS} ${WORKER_3_ADDRESS} ${WORKER_4_ADDRESS}\"")
    lines.append("export ALL_NODES=\"${CONTROL_PLANE_NODES} ${WORKER_NODES}\"")
    lines.append("export CONTROL_PLANE_REPLICAS=$(echo ${CONTROL_PLANE_NODES} | wc -w)")
    lines.append("export WORKER_REPLICAS=$(echo ${WORKER_NODES} | wc -w)")
    lines.append("")
    return lines


def validate_config(config: Dict[str, str]) -> List[str]:
    missing = [field for field in REQUIRED_FIELDS if not str(config.get(field, "")).strip()]
    return missing


def persist_config(config: Dict[str, str]) -> Dict[str, str]:
    redacted_config = config.copy()
    for key in SENSITIVE_FIELDS:
        if key in redacted_config:
            redacted_config[key] = "<redacted>" if config.get(key) else ""

    lines = format_env_lines(config, skip_keys=SENSITIVE_FIELDS)
    ENV_FILE.write_text("\n".join(lines))
    DEPLOYMENT_FILE.write_text(json.dumps(redacted_config, indent=2))
    return redacted_config


def enqueue_event(event_type: str, message: str) -> None:
    log_queue.put({"type": event_type, "message": message})


def update_state(progress: float | None = None, status: str | None = None, step: str | None = None) -> None:
    if progress is not None:
        state["progress"] = progress
    if status is not None:
        state["status"] = status
    if step is not None:
        state["step"] = step

    enqueue_event(
        "progress",
        json.dumps(
            {
                "percent": state.get("progress", 0.0),
                "status": state.get("status", "idle"),
                "step": state.get("step", ""),
            }
        ),
    )


def build_command_sequence(mode: str, phases: List[str]) -> List[Tuple[str, List[str]]]:
    if mode == "automated":
        return [("Parallel deploy + verify", ["/bin/bash", str(SCRIPTS_DIR / "parallel-deploy-and-verify.sh")])]

    commands: List[Tuple[str, List[str]]] = []
    for phase in phases:
        mapped = PHASE_COMMANDS.get(phase)
        if not mapped:
            continue
        commands.append((mapped[0], mapped[1]))
    return commands


def detect_phase(line: str, mode: str) -> str | None:
    lower_line = line.lower()
    for keyword, phase in PHASE_KEYWORDS.items():
        if keyword in lower_line:
            return phase
    if mode == "automated" and "verify" in lower_line:
        return "Verify deployment"
    return None


def run_deployment(mode: str, phases: List[str], extra_env: Dict[str, str] | None = None) -> None:
    global deployment_active
    with deployment_lock:
        deployment_active = True

    commands = build_command_sequence(mode, phases)
    total_steps = len(commands) or 1
    start_message = f"Starting {mode} deployment flow ({total_steps} step(s))"
    enqueue_event("status", start_message)
    enqueue_event("log", start_message)
    update_state(progress=0.0, status="running", step="Initializing deployment")

    for index, (label, command) in enumerate(commands, start=1):
        step_start_percent = ((index - 1) / total_steps) * 100
        enqueue_event("phase", label)
        enqueue_event("status", f"Running {label}")
        enqueue_event("log", f"[STEP {index}/{total_steps}] Starting {label}")
        update_state(progress=step_start_percent, status="running", step=f"Starting {label}")

        process = subprocess.Popen(
            command,
            cwd=str(BASE_DIR),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env={**os.environ, **(extra_env or {})},
        )

        if process.stdout:
            for line in process.stdout:
                clean_line = line.rstrip()
                enqueue_event("log", clean_line)
                detected = detect_phase(clean_line, mode)
                if detected:
                    enqueue_event("phase", detected)

        return_code = process.wait()
        if return_code != 0:
            enqueue_event("status", f"{label} failed with exit code {return_code}")
            enqueue_event("log", f"[STEP {index}/{total_steps}] {label} failed with exit code {return_code}")
            update_state(progress=(index / total_steps) * 100, status="error", step=f"{label} failed")
            with deployment_lock:
                deployment_active = False
            return

        enqueue_event("log", f"[STEP {index}/{total_steps}] Completed {label}")
        update_state(progress=(index / total_steps) * 100, status="running", step=f"Completed {label}")

    enqueue_event("status", "Deployment flow completed")
    enqueue_event("log", "All deployment steps completed")
    update_state(progress=100.0, status="complete", step="Deployment flow completed")
    with deployment_lock:
        deployment_active = False


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

@app.route("/api/config", methods=["POST"])
def save_config() -> Response:
    payload = request.get_json(force=True)
    merged_config = DEFAULT_CONFIG.copy()
    merged_config.update({k: str(v) for k, v in payload.items()})
    missing = validate_config(merged_config)
    if missing:
        return (
            jsonify(
                {
                    "message": "Missing required fields.",
                    "missing": missing,
                }
            ),
            400,
        )
    persist_config(merged_config)
    return jsonify(
        {
            "message": f"Saved configuration to {ENV_FILE} (sensitive fields redacted)",
        }
    )


@app.route("/api/start", methods=["POST"])
def start_deployment() -> Response:
    global deployment_thread, current_mode

    if deployment_active:
        return jsonify({"message": "A deployment is already running."}), 400

    data = request.get_json(force=True)
    mode = data.get("mode", "automated")
    phases = data.get("phases", PHASE_SETS.get(mode, []))
    prism_password = data.get("prismCentralPassword") or data.get("PRISM_CENTRAL_PASSWORD") or ""

    runtime_env: Dict[str, str] = {}
    if prism_password:
        runtime_env["PRISM_CENTRAL_PASSWORD"] = str(prism_password)
    elif os.environ.get("PRISM_CENTRAL_PASSWORD"):
        runtime_env["PRISM_CENTRAL_PASSWORD"] = os.environ["PRISM_CENTRAL_PASSWORD"]
    else:
        return (
            jsonify(
                {
                    "message": "PRISM_CENTRAL_PASSWORD is required at runtime. Please provide it when prompted.",
                }
            ),
            400,
        )

    current_mode = mode
    update_state(progress=0.0, status="running", step="Queued deployment")

    deployment_thread = threading.Thread(
        target=run_deployment, args=(mode, phases, runtime_env), daemon=True
    )
    deployment_thread.start()
    return jsonify({"message": f"Started {mode} deployment", "mode": mode, "phases": phases})


@app.route("/api/status")
def get_status() -> Response:
    return jsonify({"active": deployment_active, "mode": current_mode, "state": state})


@app.route("/stream")
def stream() -> Response:
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


@app.route("/api/stream")
def api_stream() -> Response:
    return stream()


@app.route("/api/phases")
def get_phases() -> Response:
    return jsonify(PHASE_SETS)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)), debug=True)

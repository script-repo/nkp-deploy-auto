from __future__ import annotations

import html
import json
from pathlib import Path
from string import Template
from textwrap import dedent

# Static preview generator for the UI without Flask runtime dependencies.
# It renders the configuration form with defaults, phase cards, and a mocked
# progress/terminal view into static/preview.html for quick visualization.

DEFAULT_CONFIG = {
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

FIELD_METADATA = {
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
        "tooltip": "Virtual IP or DNS name for the Kubernetes API endpoint.",
        "placeholder": "192.168.1.100",
        "required": True,
    },
    "CONTROL_PLANE_ENDPOINT_PORT": {
        "label": "API port",
        "tooltip": "Port that exposes the Kubernetes API.",
        "placeholder": "6443",
        "input_type": "number",
    },
    "VIRTUAL_IP_INTERFACE": {
        "label": "VIP interface",
        "tooltip": "Network interface used for the virtual IP (optional).",
        "placeholder": "eth0",
    },
    "SSH_USER": {
        "label": "SSH user",
        "tooltip": "User the bastion uses to SSH to cluster nodes.",
        "placeholder": "konvoy",
        "required": True,
    },
    "SSH_PRIVATE_KEY_FILE": {
        "label": "SSH private key path",
        "tooltip": "Path to the SSH private key on the bastion host.",
        "placeholder": "~/.ssh/id_rsa",
        "required": True,
    },
    "SSH_PRIVATE_KEY_SECRET_NAME": {
        "label": "SSH secret name",
        "tooltip": "Kubernetes secret name holding the SSH private key.",
        "placeholder": "nkp-mgmt-ssh-key",
    },
    "METALLB_IP_RANGE": {
        "label": "MetalLB IP range",
        "tooltip": "Address range for service load balancer IPs.",
        "placeholder": "192.168.1.240-192.168.1.250",
    },
    "POD_CIDR": {
        "label": "Pod CIDR",
        "tooltip": "CIDR block for pod networking.",
        "placeholder": "10.244.0.0/16",
    },
    "SERVICE_CIDR": {
        "label": "Service CIDR",
        "tooltip": "CIDR block for service networking.",
        "placeholder": "10.96.0.0/12",
    },
    "HTTP_PROXY": {
        "label": "HTTP proxy",
        "tooltip": "HTTP proxy URL if required for outbound access.",
    },
    "HTTPS_PROXY": {
        "label": "HTTPS proxy",
        "tooltip": "HTTPS proxy URL if required for outbound access.",
    },
    "NO_PROXY": {
        "label": "No proxy",
        "tooltip": "Comma-separated hosts that bypass the proxy.",
        "placeholder": "localhost,127.0.0.1",
    },
    "STORAGE_PROVIDER": {
        "label": "Storage provider",
        "tooltip": "Select the CSI or local storage backend.",
        "options": [
            {"label": "Local volume", "value": "local-volume-provisioner"},
            {"label": "Nutanix CSI", "value": "nutanix-csi"},
        ],
    },
    "NUTANIX_ENDPOINT": {
        "label": "Nutanix endpoint",
        "tooltip": "Prism endpoint for Nutanix clusters.",
        "placeholder": "https://<prism-endpoint>",
    },
    "NUTANIX_USER": {
        "label": "Nutanix user",
        "tooltip": "Username for Nutanix Prism access.",
    },
    "NUTANIX_PASSWORD": {
        "label": "Nutanix password",
        "tooltip": "Password for Nutanix Prism access.",
        "input_type": "password",
    },
    "NUTANIX_CLUSTER_UUID": {
        "label": "Nutanix cluster UUID",
        "tooltip": "UUID of the Nutanix cluster where volumes are provisioned.",
    },
    "STORAGE_CONTAINER": {
        "label": "Storage container",
        "tooltip": "Container name for Nutanix volumes.",
    },
    "LICENSE_TYPE": {
        "label": "License type",
        "tooltip": "Choose between community or pro licensing.",
        "options": [
            {"label": "Pro", "value": "pro"},
            {"label": "Community", "value": "community"},
        ],
    },
    "NKP_LICENSE_TOKEN": {
        "label": "NKP license token",
        "tooltip": "License token applied during installation (optional).",
        "input_type": "password",
    },
    "REGISTRY_MIRROR_URL": {
        "label": "Registry mirror URL",
        "tooltip": "Mirror or upstream registry endpoint.",
        "placeholder": "https://registry-1.docker.io",
    },
    "REGISTRY_MIRROR_USERNAME": {
        "label": "Registry username",
        "tooltip": "Username for the registry mirror (if required).",
    },
    "REGISTRY_MIRROR_PASSWORD": {
        "label": "Registry password",
        "tooltip": "Password for the registry mirror (if required).",
        "input_type": "password",
    },
    "AIRGAPPED": {
        "label": "Air-gapped", 
        "tooltip": "Toggle to use a private registry and bundles.",
        "options": [
            {"label": "False", "value": "false"},
            {"label": "True", "value": "true"},
        ],
    },
    "LOCAL_REGISTRY_URL": {
        "label": "Local registry URL",
        "tooltip": "Private registry endpoint for air-gapped installs.",
    },
    "LOCAL_REGISTRY_CA_CERT": {
        "label": "Local registry CA certificate",
        "tooltip": "PEM-encoded CA certificate for the private registry.",
    },
    "LOCAL_REGISTRY_USERNAME": {
        "label": "Local registry username",
        "tooltip": "Username for the private registry.",
    },
    "LOCAL_REGISTRY_PASSWORD": {
        "label": "Local registry password",
        "tooltip": "Password for the private registry.",
        "input_type": "password",
    },
    "NKP_BUNDLE_PATH": {
        "label": "NKP bundle path",
        "tooltip": "File path to the NKP bundle tarball.",
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
        "tooltip": "Path to the Kommander charts bundle tarball.",
    },
    "OUTPUT_DIR": {
        "label": "Output directory",
        "tooltip": "Directory where artifacts are written.",
        "required": True,
    },
    "KUBECONFIG_PATH": {
        "label": "Kubeconfig path",
        "tooltip": "Path to the generated kubeconfig.",
    },
    "CLUSTER_CREATE_TIMEOUT": {
        "label": "Cluster create timeout",
        "tooltip": "Timeout when creating the management cluster.",
        "placeholder": "60m",
    },
    "KOMMANDER_INSTALL_TIMEOUT": {
        "label": "Kommander install timeout",
        "tooltip": "Timeout when installing Kommander.",
        "placeholder": "45m",
    },
    "NODE_READY_TIMEOUT": {
        "label": "Node ready timeout",
        "tooltip": "Timeout for nodes to report ready.",
        "placeholder": "30m",
    },
    "VERBOSE": {
        "label": "Verbose logging",
        "tooltip": "Enable verbose logging for scripts.",
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

FIELD_SECTIONS = [
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

PHASE_SETS = {
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

SAMPLE_LOG_LINES = [
    "[info] Bastion online — preview mode (no backend)",
    "[info] Loaded defaults from environment.env template",
    "[info] Validating configuration…",
    "[ok] SSH connectivity checks would run here",
    "[ok] Rendering deployment manifest previews",
    "[info] Ready to launch automated workflow",
]

HTML_SHELL = Template("""\
<!doctype html>
<html lang=\"en\">
<head>
    <meta charset=\"utf-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
    <title>NKP Bastion Deployment Dashboard (Preview)</title>
    <link rel=\"stylesheet\" href=\"https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap\">
    <link rel=\"stylesheet\" href=\"style.css\">
</head>
<body>
<div class=\"page\">
    <header class=\"hero\">
        <div class=\"hero-copy\">
            <p class=\"eyebrow\">Bastion-host UI</p>
            <h1>NKP Deployment Control</h1>
            <p class=\"subtitle\">Review the automated and phased workflows, capture deployment variables, and watch real-time progress without leaving your browser.</p>
            <div class=\"mode-toggle\">
                <label>
                    <input type=\"radio\" name=\"mode\" value=\"automated\" checked>
                    Automated (Parallel deploy + verify)
                </label>
                <label>
                    <input type=\"radio\" name=\"mode\" value=\"phased\">
                    Phased (run steps individually)
                </label>
            </div>
            <div class=\"inline-status\">
                <span class=\"dot green\" id=\"connection-dot\"></span>
                <span id=\"connection-label\">Preview mode — offline</span>
                <span class=\"divider\">•</span>
                <span class=\"status-pill\" id=\"status-text\">Idle</span>
            </div>
        </div>
        <div class=\"actions\">
            <button id=\"save-config\" class=\"btn ghost\" type=\"button\">💾 Save configuration</button>
            <button id=\"launch\" class=\"btn primary\" type=\"button\">🚀 Launch deployment</button>
        </div>
    </header>

    <main class=\"grid\">
        <section class=\"card form-card\">
            <div class=\"card-header\">
                <div>
                    <p class=\"eyebrow\">Configuration</p>
                    <h2>Deployment variables</h2>
                    <p class=\"muted\">All scripts draw from this form. Fields marked with <span class=\"required\">*</span> are required.</p>
                </div>
                <div class=\"header-actions\">
                    <span class=\"badge\">Hover tooltips explain every field</span>
                    <span id=\"save-status\" class=\"muted\">Preview only</span>
                </div>
            </div>
            <form id=\"config-form\">
                <div class=\"section-list\">$sections</div>
            </form>
        </section>

        <section class=\"card dashboard\">
            <div class=\"card-header space-between\">
                <div>
                    <p class=\"eyebrow\">Progress</p>
                    <h2>Deployment status</h2>
                </div>
                <div class=\"timing-shell\">
                    <div class=\"progress-shell\">
                        <div id=\"progress-bar\" class=\"progress-bar\" style=\"width: 0%\"></div>
                    </div>
                    <div class=\"timer-block\">
                        <div class=\"timer-label\">Total time</div>
                        <div class=\"timer-value\" id=\"total-timer\">--:--</div>
                    </div>
                </div>
            </div>
            <div class=\"phase-controls\" id=\"phase-toggle\"></div>
            <div class=\"phase-list\" id=\"phase-list\"></div>
            <div class=\"terminal\">
                <div class=\"terminal-header\">
                    <span class=\"dot red\"></span><span class=\"dot yellow\"></span><span class=\"dot green\"></span>
                    <span class=\"terminal-title\">Console output</span>
                    <div class=\"terminal-actions\">
                        <button class=\"pill\" id=\"clear-terminal\" type=\"button\">Clear</button>
                    </div>
                </div>
                <pre id=\"terminal-output\"></pre>
            </div>
        </section>
    </main>
</div>

<script>
    const phaseSets = $phase_sets;
    const terminalOutput = document.getElementById('terminal-output');
    const progressBar = document.getElementById('progress-bar');
    const phaseList = document.getElementById('phase-list');
    const modeInputs = document.querySelectorAll('input[name="mode"]');
    const totalTimerEl = document.getElementById('total-timer');

    let phaseTimers = {};
    let totalTimerStart = Date.now();
    let totalTimerStop = null;
    let timerInterval = null;

    function formatDuration(ms) {
        if (!ms || ms < 0) return '--:--';
        const totalSeconds = Math.floor(ms / 1000);
        const hours = Math.floor(totalSeconds / 3600);
        const minutes = Math.floor((totalSeconds % 3600) / 60);
        const seconds = totalSeconds % 60;
        if (hours > 0) {
            return `$${hours.toString().padStart(2, '0')}:$${minutes.toString().padStart(2, '0')}:$${seconds.toString().padStart(2, '0')}`;
        }
        return `$${minutes.toString().padStart(2, '0')}:$${seconds.toString().padStart(2, '0')}`;
    }

    function ensureTimerInterval() {
        if (!timerInterval) {
            timerInterval = setInterval(updateTimers, 1000);
        }
    }

    function updateTimers() {
        if (totalTimerEl) {
            const totalEnd = totalTimerStop || Date.now();
            totalTimerEl.textContent = formatDuration(totalEnd - totalTimerStart);
        }

        document.querySelectorAll('.phase-card').forEach(card => {
            const label = card.dataset.label;
            const timerEl = card.querySelector('.phase-timer');
            const timerData = phaseTimers[label];
            if (!timerEl) return;
            if (timerData && timerData.start) {
                const endTime = timerData.end || Date.now();
                timerEl.textContent = formatDuration(endTime - timerData.start);
            } else {
                timerEl.textContent = '--:--';
            }
        });
    }

    function startPhaseTimer(label) {
        phaseTimers[label] = {start: Date.now(), end: null};
        ensureTimerInterval();
        updateTimers();
    }

    function stopPhaseTimer(label) {
        if (phaseTimers[label] && !phaseTimers[label].end) {
            phaseTimers[label].end = Date.now();
            updateTimers();
        }
    }

    function renderPhases(mode) {
        phaseList.innerHTML = '';
        const phases = phaseSets[mode] || [];
        phases.forEach(phase => {
            const card = document.createElement('div');
            card.className = 'phase-card pending';
            card.dataset.label = phase;
            card.innerHTML = `<div class="phase-title">$${phase}</div><div class="phase-meta"><div class="phase-status">Pending</div><div class="phase-timer">--:--</div></div>`;
            if (mode === 'phased') {
                const checkbox = document.createElement('input');
                checkbox.type = 'checkbox';
                checkbox.checked = true;
                checkbox.dataset.phase = phase;
                checkbox.className = 'phase-checkbox';
                card.prepend(checkbox);
            }
            phaseList.appendChild(card);
        });
    }

    function updatePhaseStatus(label, status) {
        const card = Array.from(document.querySelectorAll('.phase-card')).find(c => c.dataset.label === label);
        if (!card) return;
        const statusEl = card.querySelector('.phase-status');
        statusEl.textContent = status;
        card.classList.remove('pending', 'done', 'active');
        if (status === 'Running') {
            card.classList.add('active');
            startPhaseTimer(label);
        } else if (status === 'Done') {
            card.classList.add('done');
            stopPhaseTimer(label);
        } else {
            card.classList.add('pending');
        }
    }

    function appendTerminalLine(text) {
        terminalOutput.textContent += `\n$${text}`;
        terminalOutput.scrollTop = terminalOutput.scrollHeight;
    }

    function simulate() {
        renderPhases('automated');
        setTimeout(() => updatePhaseStatus('Validate & prepare', 'Done'), 200);
        setTimeout(() => updatePhaseStatus('Deploy NKP', 'Running'), 400);
        setTimeout(() => {
            updatePhaseStatus('Deploy NKP', 'Done');
            updatePhaseStatus('Verify deployment', 'Running');
            progressBar.style.width = '72%';
        }, 800);
        setTimeout(() => {
            updatePhaseStatus('Verify deployment', 'Done');
            progressBar.style.width = '100%';
            progressBar.dataset.status = 'complete';
            document.getElementById('status-text').textContent = 'Complete (preview)';
            totalTimerStop = Date.now();
            updateTimers();
        }, 1600);
        ensureTimerInterval();
    }

    document.getElementById('clear-terminal').addEventListener('click', () => terminalOutput.textContent = '');
    modeInputs.forEach(input => input.addEventListener('change', (e) => renderPhases(e.target.value)));

    // Seed the terminal with example output.
    $terminal_lines
    simulate();
    updateTimers();
</script>
</body>
</html>
""")

def render_field(key: str) -> str:
    meta = FIELD_METADATA.get(key, {})
    label = html.escape(meta.get("label", key))
    tooltip = meta.get("tooltip")
    placeholder = html.escape(meta.get("placeholder", ""))
    required = meta.get("required", False)
    options = meta.get("options")
    input_type = meta.get("input_type", "text")
    value = html.escape(DEFAULT_CONFIG.get(key, ""))

    tooltip_html = f'<span class="tooltip" title="{html.escape(tooltip)}">?</span>' if tooltip else ""
    required_html = '<span class="required">*</span>' if required else ""

    if options:
        option_html = "".join(
            f'<option value="{html.escape(str(opt.get("value", "")))}" {"selected" if str(opt.get("value", "")) == DEFAULT_CONFIG.get(key, "") else ""}>{html.escape(str(opt.get("label", opt.get("value", ""))))}</option>'
            for opt in options
        )
        control = f"<select name=\"{key}\">{option_html}</select>"
    else:
        control = (
            f'<input type="{input_type}" name="{key}" value="{value}" '
            f'placeholder="{placeholder}">'  # noqa: E501
        )

    return dedent(
        f"""
        <div class=\"field\">
            <label>
                {label}
                {tooltip_html}
                {required_html}
            </label>
            {control}
        </div>
        """
    )

def render_sections() -> str:
    blocks = []
    for section in FIELD_SECTIONS:
        fields_html = "".join(render_field(key) for key in section["fields"])
        block = dedent(
            f"""
            <div class=\"section\">
                <div class=\"section-header\">
                    <div>
                        <p class=\"eyebrow\">{html.escape(section['title'])}</p>
                        <p class=\"muted\">{html.escape(section['description'])}</p>
                    </div>
                    <span class=\"pill\">{html.escape(section['id'])}</span>
                </div>
                <div class=\"field-grid\">
                    {fields_html}
                </div>
            </div>
            """
        )
        blocks.append(block)
    return "".join(blocks)

def render_terminal_lines() -> str:
    lines_js = "".join(f"appendTerminalLine({json.dumps(line)});" for line in SAMPLE_LOG_LINES)
    return lines_js

def build_preview() -> str:
    return HTML_SHELL.substitute(
        sections=render_sections(),
        phase_sets=json.dumps(PHASE_SETS),
        terminal_lines=render_terminal_lines(),
    )

def main() -> None:
    output_path = Path(__file__).resolve().parent / "static" / "preview.html"
    output_path.write_text(build_preview(), encoding="utf-8")
    print(f"Wrote {output_path.relative_to(Path.cwd())}")


if __name__ == "__main__":
    main()

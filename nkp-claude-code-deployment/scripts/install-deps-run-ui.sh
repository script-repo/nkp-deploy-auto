#!/usr/bin/env bash
# =============================================================================
# End-to-end bastion bootstrap for NKP UI (Rocky Linux 9+)
# - Installs Docker, kubectl, Helm, SSH, firewall openings via install-bastion-prereqs.sh
# - Ensures Python 3.10+ (installs python3.11 if needed) and sets up a venv for the UI
# - Copies environment.env from the template if missing
# - Installs Flask dependencies and launches the UI on 0.0.0.0:8080
# After running this script, continue setup entirely from the web interface.
# =============================================================================
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI_DIR="${BASE_DIR}/ui"
VENV_DIR="${UI_DIR}/.venv"
PID_FILE="${UI_DIR}/.flask-ui.pid"
LOG_FILE="${UI_DIR}/ui.log"
ENV_FILE="${BASE_DIR}/environment.env"
ENV_TEMPLATE="${BASE_DIR}/environment.env.template"
PORT="8080"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script as root (e.g., via sudo)." >&2
    exit 1
  fi
}

run_prereqs() {
  echo "[INFO] Installing bastion prerequisites..."
  "${BASE_DIR}/scripts/install-bastion-prereqs.sh"
}

python_version_ok() {
  local cmd="$1"
  local version
  version=$("${cmd}" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')
  local major minor
  IFS='.' read -r major minor _ <<<"${version}"
  [[ ${major} -gt 3 || (${major} -eq 3 && ${minor} -ge 10) ]]
}

ensure_python() {
  local candidate
  for candidate in python3.11 python3.10 python3; do
    if command -v "${candidate}" >/dev/null 2>&1 && python_version_ok "${candidate}"; then
      echo "[INFO] Using existing Python: ${candidate}"
      PY_CMD="$(command -v "${candidate}")"
      return
    fi
  done

  echo "[INFO] Installing Python 3.11 with venv/pip support..."
  if command -v dnf >/dev/null 2>&1; then
    if ! dnf -y install python3.11 python3.11-pip python3.11-venv; then
      echo "[WARN] python3.11-venv package not available; installing python3.11 and pip only (venv provided by stdlib)." >&2
      dnf -y install python3.11 python3.11-pip
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y python3.11 python3.11-venv python3.11-distutils python3-pip
  else
    echo "[ERROR] Supported package manager not found (dnf or apt-get). Install Python 3.11 manually and re-run." >&2
    exit 1
  fi
  PY_CMD="$(command -v python3.11)"
  "${PY_CMD}" -m ensurepip --upgrade
}

setup_venv() {
  mkdir -p "${UI_DIR}"
  if [[ ! -d "${VENV_DIR}" ]]; then
    echo "[INFO] Creating virtual environment in ${VENV_DIR}"
    "${PY_CMD}" -m venv "${VENV_DIR}"
  fi
  echo "[INFO] Installing UI dependencies"
  "${VENV_DIR}/bin/pip" install --upgrade pip
  "${VENV_DIR}/bin/pip" install -r "${UI_DIR}/requirements.txt"
}

seed_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    echo "[INFO] environment.env already present"
    return
  fi

  if [[ -f "${ENV_TEMPLATE}" ]]; then
    echo "[INFO] Seeding ${ENV_FILE} from template"
    cp "${ENV_TEMPLATE}" "${ENV_FILE}"
  else
    echo "[WARN] environment.env not found and no template available; the UI will start without prefilled values." >&2
  fi
}

port_in_use() {
  ss -tln "sport = :${PORT}" 2>/dev/null | grep -q ":${PORT}"
}

start_ui() {
  if [[ -f "${PID_FILE}" ]] && ps -p "$(cat "${PID_FILE}")" >/dev/null 2>&1; then
    echo "[INFO] UI already running (PID $(cat "${PID_FILE}"))"
    return
  fi

  if port_in_use; then
    echo "[ERROR] Port ${PORT} is already in use. Stop the existing service or adjust the port before rerunning." >&2
    exit 1
  fi

  echo "[INFO] Starting Flask UI on 0.0.0.0:${PORT} (logs: ${LOG_FILE})"
  (
    cd "${UI_DIR}"
    FLASK_APP=app.py "${VENV_DIR}/bin/flask" run --host 0.0.0.0 --port "${PORT}" >"${LOG_FILE}" 2>&1 &
    echo $! > "${PID_FILE}"
  )
}

print_summary() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "" 
  echo "[SUCCESS] Bastion and UI are ready. Open the dashboard in your browser:" 
  if [[ -n "${ip}" ]]; then
    echo "  http://${ip}:${PORT}" 
  else
    echo "  http://<bastion-ip>:${PORT}" 
  fi
  echo "" 
  echo "- Configuration file: ${ENV_FILE}" 
  echo "- UI log: ${LOG_FILE}" 
  if [[ -f "${PID_FILE}" ]]; then
    echo "- UI process ID: $(cat "${PID_FILE}")" 
  fi
}

main() {
  require_root
  run_prereqs
  ensure_python
  setup_venv
  seed_env_file
  start_ui
  print_summary
}

main "$@"

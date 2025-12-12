#!/usr/bin/env bash
# =============================================================================
# Install bastion prerequisites on Rocky Linux 9+
# - SSH server (enabled and opened in firewalld when present)
# - Docker CE (or updates existing install)
# - kubectl
# - Helm 3
# - Utility tooling (curl, jq, unzip, tar)
# =============================================================================
set -euo pipefail

#---------------
# Safety checks
#---------------
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run this script as root (e.g., via sudo)." >&2
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  echo "[ERROR] Unable to detect OS from /etc/os-release." >&2
  exit 1
fi

. /etc/os-release

if [[ "${ID}" != "rocky" ]]; then
  echo "[ERROR] This installer targets Rocky Linux. Detected: ${PRETTY_NAME}" >&2
  exit 1
fi

# Minimal packages required before installing Docker/Helm/kubectl
core_packages=(curl jq tar unzip yum-utils)

echo "[INFO] Updating system package metadata..."
dnf -y makecache

echo "[INFO] Installing core utilities: ${core_packages[*]}"
dnf -y install "${core_packages[@]}"

#---------------
# SSH access (sshd + firewall ports)
#---------------
if ! systemctl list-unit-files | grep -q '^sshd.service'; then
  echo "[INFO] Installing OpenSSH server"
  dnf -y install openssh-server
fi

echo "[INFO] Enabling and starting sshd"
systemctl enable sshd
systemctl start sshd

if systemctl is-active --quiet firewalld; then
  echo "[INFO] firewalld detected - opening SSH (22/tcp) and UI (8080/tcp)"
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --permanent --add-port=8080/tcp
  firewall-cmd --reload
else
  echo "[INFO] firewalld not active - skipping firewall port updates"
fi

#---------------
# Docker CE
#---------------
if ! rpm -q docker-ce &>/dev/null; then
  echo "[INFO] Adding Docker CE repository (CentOS stream compatible)..."
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
fi

echo "[INFO] Installing/updating Docker CE"
dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "[INFO] Enabling and starting Docker daemon"
systemctl enable docker
systemctl start docker

#---------------
# kubectl
#---------------
if ! command -v kubectl &>/dev/null; then
  echo "[INFO] Installing kubectl"
  KUBECTL_VERSION="${KUBECTL_VERSION:-$(curl -L -s https://dl.k8s.io/release/stable.txt)}"
  curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  chmod +x /usr/local/bin/kubectl
else
  echo "[INFO] kubectl already present: $(kubectl version --client --short 2>/dev/null || echo installed)"
fi

#---------------
# Helm 3
#---------------
if ! command -v helm &>/dev/null; then
  echo "[INFO] Installing Helm 3"
  HELM_VERSION="${HELM_VERSION:-$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')}"
  tmp_dir=$(mktemp -d)
  curl -fsSL -o "${tmp_dir}/helm.tar.gz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  tar -C "${tmp_dir}" -xzf "${tmp_dir}/helm.tar.gz"
  mv "${tmp_dir}/linux-amd64/helm" /usr/local/bin/helm
  chmod +x /usr/local/bin/helm
  rm -rf "${tmp_dir}"
else
  echo "[INFO] Helm already present: $(helm version --short 2>/dev/null || echo installed)"
fi

#---------------
# Post-checks
#---------------
cat <<'SUMMARY'
[INFO] Bastion prerequisites completed.
- SSH: $(sshd -V >/dev/null 2>&1 && echo "enabled" || echo "not available")
- Docker: $(docker --version 2>/dev/null || echo "not found")
- kubectl: $(kubectl version --client --short 2>/dev/null || echo "not found")
- Helm: $(helm version --short 2>/dev/null || echo "not found")
SUMMARY

if ! groups | grep -q '\bdocker\b'; then
  echo "[INFO] Add your user to the docker group and re-login if you want to run docker without sudo:" >&2
  echo "       sudo usermod -aG docker <username>" >&2
fi

echo "[INFO] Done."

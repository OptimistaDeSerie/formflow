#!/usr/bin/env bash
# Runs ONCE on a fresh Ubuntu VM. Installs Docker and prepares /opt/formflow.
# Usage from your computer (inside the formflow folder):
#   scp deploy/vm-setup.sh azureuser@VM_IP:/tmp/vm-setup.sh
#   ssh azureuser@VM_IP 'bash /tmp/vm-setup.sh'
# Based on the official Docker instructions for Ubuntu (apt repository method).
set -euo pipefail

APP_USER="$(id -un)"

# A brand-new VM is still busy with its own first-boot updates, which locks apt for a while.
# This waits for first boot to finish, then retries apt if it is still busy.
apt_run() {
  local i
  for i in $(seq 1 20); do
    if sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -y "$@"; then
      return 0
    fi
    echo "apt is busy or failed. Waiting 15 seconds, then trying again ($i of 20)..."
    sleep 15
  done
  echo "apt kept failing. Read the messages above." >&2
  return 1
}

echo "[0/5] Waiting for the VM's first-boot tasks to finish"
sudo cloud-init status --wait >/dev/null 2>&1 || true

echo "[1/5] Installing helper packages"
apt_run update
apt_run install ca-certificates curl

echo "[2/5] Adding Docker's package source"
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<SRC
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
SRC
apt_run update

echo "[3/5] Installing Docker Engine and the Compose plugin"
apt_run install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker

echo "[4/5] Letting $APP_USER run docker without sudo (takes effect at next login)"
sudo usermod -aG docker "$APP_USER"

echo "[5/5] Creating /opt/formflow"
sudo mkdir -p /opt/formflow
sudo chown "$APP_USER":"$APP_USER" /opt/formflow

echo
sudo docker --version
sudo docker compose version
echo "Setup finished. Log out and log back in before using docker without sudo."

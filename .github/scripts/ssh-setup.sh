#!/usr/bin/env bash
# Runs in the pipeline. Prepares SSH so that later steps can simply type
#   ssh formflow-vm '...'      and      scp file formflow-vm:/opt/formflow/
#
# It needs these environment variables. All of them come from GitHub Actions secrets:
#   VM_HOST              the VM's public IP address
#   VM_USER              the login name on the VM (azureuser)
#   VM_SSH_PRIVATE_KEY   the deploy key (the whole private key file, including the BEGIN and END lines)
#   VM_HOST_FINGERPRINT  the VM's host key fingerprint, like SHA256:8doJ... (stops a fake server taking its place)
# Optional: VM_PORT (default 22)
set -euo pipefail

need() {
  if [ -z "${!1:-}" ]; then
    echo "::error::The secret $1 is empty or missing. Add it under Settings > Secrets and variables > Actions."
    exit 1
  fi
}
need VM_HOST
need VM_USER
need VM_SSH_PRIVATE_KEY
need VM_HOST_FINGERPRINT
PORT="${VM_PORT:-22}"

# Secrets are pasted by people. Refuse anything that is not shaped like what it should be,
# so a stray space or new line can never end up inside the SSH settings file.
if ! [[ "$VM_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "::error::VM_HOST must be an IP address or a host name, with nothing else (no space or new line at the end, no http://, no port)."
  exit 1
fi
if ! [[ "$VM_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "::error::VM_USER must be a plain login name such as azureuser (no space or new line at the end)."
  exit 1
fi
if ! [[ "$VM_HOST_FINGERPRINT" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]]; then
  echo "::error::VM_HOST_FINGERPRINT must look like SHA256: followed by 43 characters, copied exactly (no space or new line at the end)."
  exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]]; then
  echo "::error::VM_PORT must be a number."
  exit 1
fi

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
umask 077

# 1. The private key.
# Remove Windows line-end characters (carriage returns) in case the key was copied on a Windows computer.
printf '%s\n' "${VM_SSH_PRIVATE_KEY//$'\r'/}" > "$SSH_DIR/deploy_key"
chmod 600 "$SSH_DIR/deploy_key"
if ! ssh-keygen -y -f "$SSH_DIR/deploy_key" >/dev/null 2>&1; then
  rm -f "$SSH_DIR/deploy_key"
  echo "::error::VM_SSH_PRIVATE_KEY is not a valid private key. Paste the whole file, including the BEGIN and END lines."
  exit 1
fi

# 2. Ask the VM for its host key and compare it with the fingerprint we trust.
HOSTKEY_FILE="$(mktemp)"
trap 'rm -f "$HOSTKEY_FILE"' EXIT
ssh-keyscan -T 15 -p "$PORT" -t ed25519 "$VM_HOST" > "$HOSTKEY_FILE" 2>/dev/null || true
if [ ! -s "$HOSTKEY_FILE" ]; then
  echo "::error::Could not reach $VM_HOST on port $PORT to read its host key. Is the VM running and is port 22 open?"
  exit 1
fi
FOUND="$(ssh-keygen -lf "$HOSTKEY_FILE" | awk '{print $2}' | head -n 1)"
if [ "$FOUND" != "$VM_HOST_FINGERPRINT" ]; then
  echo "::error::The VM presented a different host key than the one we trust. Stopping before sending anything."
  echo "Expected (secret VM_HOST_FINGERPRINT): $VM_HOST_FINGERPRINT"
  echo "Found on $VM_HOST:                     $FOUND"
  echo "If you rebuilt the VM on purpose, update the secret with the new fingerprint."
  exit 1
fi
cat "$HOSTKEY_FILE" > "$SSH_DIR/known_hosts"
echo "VM host key matches the trusted fingerprint."

# 3. A short name for the VM, so later steps stay readable and cannot mistype the address.
cat > "$SSH_DIR/config" <<CONF
Host formflow-vm
  HostName $VM_HOST
  Port $PORT
  User $VM_USER
  IdentityFile $SSH_DIR/deploy_key
  IdentitiesOnly yes
  UserKnownHostsFile $SSH_DIR/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes
  ConnectTimeout 20
  ServerAliveInterval 15
  ServerAliveCountMax 4
CONF
chmod 600 "$SSH_DIR/config"

# 4. Prove the login works now, so a key problem is reported here and not halfway through a deploy.
if ! ssh formflow-vm 'echo connected' >/dev/null 2>&1; then
  echo "::error::The VM refused the deploy key. Is the matching public key in /home/$VM_USER/.ssh/authorized_keys on the VM?"
  exit 1
fi
echo "SSH to the VM works."

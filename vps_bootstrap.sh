#!/usr/bin/env bash
set -euo pipefail

# VPS bootstrap: create 'apptology', install public keys from a URL, harden SSH,
# and move SSH to a custom port. Tested on Ubuntu/Debian.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/onek2900/odoo17/main/vps_bootstrap.sh | \
#     sudo bash -s -- --new-port 22022
#
# Optional:
#   --pubkeys-url <url>  Override default public keys URL
#   --new-port <port>    Change SSH port (default 2222)

# ====== DEFAULT CONFIG ======
PUBKEYS_URL="https://raw.githubusercontent.com/onek2900/odoo17/main/apptology_shared.pub"
NEW_PORT="2222"
USERNAME="apptology"
# ============================

# ====== ARGUMENT PARSING ======
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pubkeys-url) PUBKEYS_URL="$2"; shift 2 ;;
    --new-port) NEW_PORT="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,80p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
# ==============================

if [[ -z "$PUBKEYS_URL" ]]; then
  echo "ERROR: PUBKEYS_URL is empty" >&2
  exit 1
fi

echo "[1/7] Detecting OS and installing prerequisites..."
if [[ -f /etc/debian_version ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl sudo ufw >/dev/null
else
  echo "ERROR: This script currently supports Debian/Ubuntu." >&2
  exit 1
fi

echo "[2/7] Creating user '$USERNAME' with root (sudo) access..."
if ! id -u "$USERNAME" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$USERNAME"
  usermod -aG sudo "$USERNAME"
fi
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/$USERNAME
chmod 440 /etc/sudoers.d/$USERNAME

echo "[3/7] Installing public keys from: $PUBKEYS_URL"
install -d -m 700 -o "$USERNAME" -g "$USERNAME" /home/"$USERNAME"/.ssh
TMP_KEYS="$(mktemp)"
if ! curl -fsSL "$PUBKEYS_URL" -o "$TMP_KEYS"; then
  echo "ERROR: Could not download public keys from $PUBKEYS_URL" >&2
  exit 1
fi
# Basic sanity check: keys should start with "ssh-"
if ! grep -qE '^ssh-(ed25519|rsa)' "$TMP_KEYS"; then
  echo "ERROR: Downloaded keys file does not look like SSH public keys." >&2
  exit 1
fi
install -m 600 -o "$USERNAME" -g "$USERNAME" "$TMP_KEYS" /home/"$USERNAME"/.ssh/authorized_keys
rm -f "$TMP_KEYS"

echo "[4/7] Hardening sshd (key-only, disable root login, AllowUsers $USERNAME, Port $NEW_PORT)..."
SSHD_DIR=/etc/ssh
DROPIN_DIR="$SSHD_DIR/sshd_config.d"
mkdir -p "$DROPIN_DIR"

# One-time backup of main config
if [[ ! -f $SSHD_DIR/sshd_config.bak ]]; then
  cp "$SSHD_DIR/sshd_config" "$SSHD_DIR/sshd_config.bak"
fi

# Ensure drop-ins are included (for older configs)
if ! grep -qE '^[[:space:]]*Include[[:space:]]+sshd_config\.d/\*\.conf' "$SSHD_DIR/sshd_config"; then
  echo 'Include sshd_config.d/*.conf' >> "$SSHD_DIR/sshd_config"
fi

cat > "$DROPIN_DIR/99-hardening.conf" <<EOF
# Applied by vps_bootstrap.sh on $(date -u +%F)
Port $NEW_PORT
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PermitRootLogin no
MaxAuthTries 3
LoginGraceTime 30s
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $USERNAME
EOF

chmod 600 "$DROPIN_DIR/99-hardening.conf"
chown root:root "$DROPIN_DIR/99-hardening.conf"

# Validate config
sshd -t

echo "[5/7] Configuring firewall (UFW) to allow only SSH on $NEW_PORT..."
ufw allow "$NEW_PORT"/tcp >/dev/null
# keep 22 open during transition
ufw allow 22/tcp >/dev/null || true
yes | ufw enable >/dev/null || true
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

echo "[6/7] Reloading sshd..."
if systemctl list-unit-files | grep -q '^sshd\.service'; then
  systemctl reload sshd
elif systemctl list-unit-files | grep -q '^ssh\.service'; then
  systemctl reload ssh
fi

echo "[7/7] Test from another terminal:"
echo "  ssh -p $NEW_PORT $USERNAME@<SERVER_IP>"
echo "If it works, close port 22 with:"
echo "  sudo ufw delete allow 22/tcp"
echo
echo "✅ Done."

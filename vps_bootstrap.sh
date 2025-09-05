#!/bin/bash
set -e

# ============================================================
# VPS Bootstrap Script for Odoo17 + Secure SSH (apptology)
# ============================================================

PUBKEYS_URL_DEFAULT="https://raw.githubusercontent.com/onek2900/odoo17/main/apptology_shared.pub"
NEW_PORT_DEFAULT=22022
USERNAME="apptology"

# Allow overrides from CLI
PUBKEYS_URL="${1:-$PUBKEYS_URL_DEFAULT}"
NEW_PORT="${2:-$NEW_PORT_DEFAULT}"

echo "[1/7] Detecting OS and installing prerequisites..."
if [ -x "$(command -v apt-get)" ]; then
    sudo apt-get update -y
    sudo apt-get install -y curl ufw sudo
elif [ -x "$(command -v dnf)" ]; then
    sudo dnf install -y curl ufw sudo
else
    echo "Unsupported OS. Install curl, ufw, and sudo manually."
    exit 1
fi

echo "[2/7] Creating user '$USERNAME' with root (sudo) access..."
if ! id "$USERNAME" >/dev/null 2>&1; then
    sudo adduser --disabled-password --gecos "" "$USERNAME"
    sudo usermod -aG sudo "$USERNAME"
fi

echo "[3/7] Installing public keys from: $PUBKEYS_URL"
sudo mkdir -p /home/$USERNAME/.ssh
curl -fsSL "$PUBKEYS_URL" | sudo tee /home/$USERNAME/.ssh/authorized_keys >/dev/null
sudo chmod 700 /home/$USERNAME/.ssh
sudo chmod 600 /home/$USERNAME/.ssh/authorized_keys
sudo chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh

echo "[4/7] Hardening sshd..."
SSH_CONF_DIR="/etc/ssh/sshd_config.d"
sudo mkdir -p "$SSH_CONF_DIR"
cat <<EOF | sudo tee "$SSH_CONF_DIR/99-hardening.conf"
Port $NEW_PORT
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers $USERNAME
EOF

echo "[5/7] Configuring firewall (UFW)..."
sudo ufw allow $NEW_PORT/tcp comment "SSH (new secure port)"
sudo ufw allow 22/tcp comment "SSH (default port - temporary)"
sudo ufw allow 80/tcp comment "HTTP"
sudo ufw allow 443/tcp comment "HTTPS"
sudo ufw allow 8069/tcp comment "Odoo Web"
sudo ufw allow 8071/tcp comment "Odoo Longpolling"
sudo ufw allow 8072/tcp comment "Odoo Bus"
sudo ufw --force enable
sudo ufw reload

echo "[6/7] Reloading sshd..."
sudo sshd -t
if systemctl list-units --type=service | grep -q sshd; then
    sudo systemctl restart sshd
else
    sudo systemctl restart ssh
fi

echo "[7/7] Done!"
echo "✅ Try connecting from another terminal with:"
echo "    ssh -p $NEW_PORT $USERNAME@<SERVER_IP>"
echo "Once confirmed, you can close port 22 with:"
echo "    sudo ufw delete allow 22/tcp"

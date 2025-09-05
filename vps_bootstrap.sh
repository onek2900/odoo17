#!/bin/bash
set -e

# ============================================================
# VPS Bootstrap Script for Odoo17 + Secure SSH (apptology)
# ============================================================


# curl -fsSL https://raw.githubusercontent.com/onek2900/odoo17/main/vps_bootstrap.sh | sudo bash


PUBKEYS_URL_DEFAULT="https://raw.githubusercontent.com/onek2900/odoo17/main/apptology_shared.pub"
SSH_PORT_DEFAULT=22022
USERNAME="apptology"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --pubkeys-url) PUBKEYS_URL="$2"; shift ;;
        --new-port) SSH_PORT="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

PUBKEYS_URL="${PUBKEYS_URL:-$PUBKEYS_URL_DEFAULT}"
SSH_PORT="${SSH_PORT:-$SSH_PORT_DEFAULT}"

echo "[1/7] Installing prerequisites..."
apt-get update -y
apt-get install -y sudo curl ufw

echo "[2/7] Creating user '$USERNAME' with sudo access..."
id -u "$USERNAME" &>/dev/null || adduser --disabled-password --gecos "" "$USERNAME"
usermod -aG sudo "$USERNAME"

echo "[3/7] Installing SSH public key for $USERNAME..."
mkdir -p /home/$USERNAME/.ssh
curl -fsSL "$PUBKEYS_URL" -o /home/$USERNAME/.ssh/authorized_keys
chmod 700 /home/$USERNAME/.ssh
chmod 600 /home/$USERNAME/.ssh/authorized_keys
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh

echo "[4/7] Configuring SSH..."
SSHD_CONFIG_FILE="/etc/ssh/sshd_config.d/99-hardening.conf"
mkdir -p /etc/ssh/sshd_config.d
cat > "$SSHD_CONFIG_FILE" <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers $USERNAME
EOF

echo "[5/7] Configuring firewall..."
ufw allow "$SSH_PORT"/tcp
ufw allow 8069/tcp   # Odoo main
ufw allow 8071/tcp   # Odoo longpolling
ufw allow 8072/tcp   # Odoo live chat
ufw --force enable

echo "[6/7] Restarting SSH service..."
sshd -t
systemctl restart ssh || systemctl restart sshd

SERVER_IP=$(curl -4 -s ifconfig.co)

echo "[7/7] Setup complete!"
echo "=================================================="
echo "  VPS SETUP SUMMARY"
echo "--------------------------------------------------"
echo "  IP Address:   $SERVER_IP"
echo "  SSH Port:     $SSH_PORT"
echo "  Username:     $USERNAME"
echo "  Public Key:   $PUBKEYS_URL"
echo "--------------------------------------------------"
echo "  Odoo Ports:   8069 (main), 8071 (longpolling), 8072 (livechat)"
echo "=================================================="
echo
echo "PuTTY Login Steps:"
echo "1. Download 'apptology_shared.ppk' (converted from your private key)"
echo "2. Open PuTTY → Host Name: $SERVER_IP, Port: $SSH_PORT, Connection type: SSH"
echo "3. In PuTTY → Category → Connection → SSH → Auth → Browse → select your .ppk file"
echo "4. Click 'Open' to connect"
echo
echo "⚠️ Test new SSH port before closing port 22:"
echo "    ssh -p $SSH_PORT $USERNAME@$SERVER_IP"
echo

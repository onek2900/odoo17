#!/usr/bin/env bash
set -euo pipefail

# VPS bootstrap: create 'apptology', install public keys from a URL, harden SSH,
# and move SSH to a custom port. Tested on Ubuntu/Debian.
#
# Usage (on the VPS):
#   sudo bash vps_bootstrap.sh \
#     --pubkeys-url "https://raw.githubusercontent.com/<YOU>/infra-ssh/main/authorized_keys_apptology" \
#     --new-port 22022
#
# Or run directly from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/<YOU>/infra-ssh/main/vps_bootstrap.sh | \
#     sudo bash -s -- --pubkeys-url "https://raw.githubusercontent.com/<YOU>/infra-ssh/main/authorized_keys_apptology" --new-port 22022

PUBKEYS_URL=""
NEW_PORT="2222"     # change with --new-port
USERNAME="apptology"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pubkeys-url) PUBKEYS_URL="$2"; shift 2 ;;
    --new-port) NEW_PORT="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,80p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PUBKEYS_URL" ]]; then
  echo "ERROR: --pubkeys-url is required (point to your public keys file in GitHub)." >&2
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

echo "[2/7] Creating user

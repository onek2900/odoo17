#!/usr/bin/env bash
set -euo pipefail

read -rp "Enter your domain name (e.g., example.com): " DOMAIN
read -rp "Enter your email for SSL certificate (e.g., admin@example.com): " EMAIL

if [[ -z "${DOMAIN}" || -z "${EMAIL}" ]]; then
  echo "Domain and email are required."
  exit 1
fi

echo "Updating apt and installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y nginx cron python3-certbot-nginx

echo "Enabling and starting Nginx..."
sudo systemctl enable nginx
sudo systemctl start nginx

# --- Phase 1: minimal HTTP-only config so Certbot can solve the challenge ---
echo "Creating temporary HTTP-only Nginx config for ${DOMAIN}..."
sudo tee /etc/nginx/sites-available/odoo17.conf >/dev/null <<EOF
# Temporary HTTP-only server to obtain certificates
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    client_max_body_size 200M;
    client_body_timeout 120s;

    # Allow ACME HTTP-01 challenge
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
    }

    # You can keep the redirect; certbot --nginx will inject a challenge exception
    return 301 https://${DOMAIN}\$request_uri;
}
EOF

echo "Enabling site..."
sudo ln -sfn /etc/nginx/sites-available/odoo17.conf /etc/nginx/sites-enabled/odoo17.conf

echo "Testing Nginx config..."
sudo nginx -t
echo "Reloading Nginx..."
sudo systemctl reload nginx

# --- Phase 2: obtain certificate (now that port 80 config is live) ---
echo "Obtaining SSL Certificate for ${DOMAIN}..."
sudo certbot --nginx --non-interactive --agree-tos --email "${EMAIL}" -d "${DOMAIN}" -d "www.${DOMAIN}" --redirect

# --- Phase 3: write final HTTPS reverse-proxy config for Odoo ---
echo "Writing final HTTPS Odoo reverse-proxy config..."
sudo tee /etc/nginx/sites-available/odoo17.conf >/dev/null <<EOF
upstream odooserver {
    server 127.0.0.1:8069;
}

upstream odoo_longpolling {
    server 127.0.0.1:8072;
}

# This file is included inside 'http {}' so 'map' is valid here
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# Redirect WWW -> apex on HTTPS
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name www.${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    return 301 https://${DOMAIN}\$request_uri;
}

# HTTP -> HTTPS redirect (kept for completeness)
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    client_max_body_size 200M;
    client_body_timeout 120s;

    # ACME challenge passthrough for renewals (certbot also injects its own rules)
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
    }

    return 301 https://${DOMAIN}\$request_uri;
}

# Main Odoo server on HTTPS
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    client_max_body_size 200M;
    client_body_timeout 120s;

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    access_log /var/log/nginx/odoo_access.log;
    error_log  /var/log/nginx/odoo_error.log;

    # Common proxy settings
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;
    proxy_set_header Host               \$host;
    proxy_set_header X-Forwarded-Host   \$host;
    proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto  \$scheme;
    proxy_set_header X-Real-IP          \$remote_addr;

    # Longpolling endpoint → gevent worker (8072)
    location /longpolling/ {
        proxy_pass http://odoo_longpolling;
        proxy_read_timeout 720s;
        proxy_connect_timeout 720s;
        proxy_send_timeout 720s;
        proxy_buffering off;
    }

    # Websocket passthrough
    location /websocket {
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://odooserver;
    }

    # Main Odoo app
    location / {
        proxy_redirect off;
        proxy_pass http://odooserver;
    }

    # Static assets (cache-friendly)
    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odooserver;
    }

    gzip on;
    gzip_types text/css text/less text/plain text/xml application/xml application/json application/javascript;
}
EOF

echo "Testing Nginx config (final)..."
sudo nginx -t
echo "Reloading Nginx (final)..."
sudo systemctl reload nginx

# --- Renewals: prefer systemd timer; fall back to cron if needed ---
if systemctl list-timers | grep -q certbot.timer 2>/dev/null; then
  echo "certbot.timer is present; automatic renewals are handled by systemd."
else
  echo "Setting up cron-based auto-renewal for SSL certificates..."
  sudo crontab -l 2>/dev/null | grep -F "certbot renew" >/dev/null || \
  (sudo crontab -l 2>/dev/null; echo "0 0,12 * * * certbot renew --quiet") | sudo crontab -
fi

echo "All done! Your Odoo should be live at: https://${DOMAIN} 🚀"

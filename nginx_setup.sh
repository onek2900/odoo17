#!/usr/bin/env bash
set -euo pipefail

read -rp "Enter your domain name (e.g., example.com): " DOMAIN
read -rp "Enter your email for SSL certificate (e.g., admin@example.com): " EMAIL

if [[ -z "${DOMAIN}" || -z "${EMAIL}" ]]; then
  echo "Domain and email are required."
  exit 1
fi

WWW_DOMAIN="www.${DOMAIN}"

dns_exists() {
  getent ahosts "$1" >/dev/null 2>&1
}

if dns_exists "${WWW_DOMAIN}"; then
  USE_WWW=true
  echo "Detected DNS for ${WWW_DOMAIN} ✅ — including it."
else
  USE_WWW=false
  echo "No DNS for ${WWW_DOMAIN} ❌ — will skip it."
fi

echo "Updating apt and installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y nginx cron python3-certbot-nginx

echo "Enabling and starting Nginx..."
sudo systemctl enable nginx
sudo systemctl start nginx

echo "Removing default Nginx site (if present)..."
sudo rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default || true

# ------------------- Phase 1: HTTP-only config (for ACME) -------------------
SERVER_NAMES_HTTP="${DOMAIN}"
$USE_WWW && SERVER_NAMES_HTTP="${SERVER_NAMES_HTTP} ${WWW_DOMAIN}"

echo "Creating temporary HTTP-only Nginx config for ${SERVER_NAMES_HTTP}..."
sudo tee /etc/nginx/sites-available/odoo17.conf >/dev/null <<EOF
# Temporary HTTP -> HTTPS (keeps ACME HTTP-01 reachable)
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES_HTTP};

    client_max_body_size 200M;
    client_body_timeout 120s;

    # ACME HTTP-01 challenge
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
    }

    return 301 https://${DOMAIN}\$request_uri;
}
EOF

echo "Enabling site..."
sudo ln -sfn /etc/nginx/sites-available/odoo17.conf /etc/nginx/sites-enabled/odoo17.conf

echo "Testing Nginx config..."
sudo nginx -t
echo "Reloading Nginx..."
sudo systemctl reload nginx

# ------------------- Phase 2: Issue certificates -------------------
CERTBOT_DOMS=( -d "${DOMAIN}" )
$USE_WWW && CERTBOT_DOMS+=( -d "${WWW_DOMAIN}" )

echo "Obtaining SSL Certificate for ${DOMAIN} $( $USE_WWW && echo "and ${WWW_DOMAIN}" )..."
sudo certbot --nginx --non-interactive --agree-tos --email "${EMAIL}" "${CERTBOT_DOMS[@]}" --redirect

# ------------------- Phase 3: Final HTTPS reverse-proxy for Odoo -------------------
echo "Writing final HTTPS Odoo reverse-proxy config..."
sudo tee /etc/nginx/sites-available/odoo17.conf >/dev/null <<EOF
upstream odooserver { server 127.0.0.1:8069; }
upstream odoo_longpolling { server 127.0.0.1:8072; }

# HTTP -> HTTPS (keep ACME)
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES_HTTP};

    client_max_body_size 200M;
    client_body_timeout 120s;

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
    }

    return 301 https://${DOMAIN}\$request_uri;
}
EOF

if $USE_WWW; then
  # WWW -> apex on HTTPS (only if www DNS exists)
  sudo tee -a /etc/nginx/sites-available/odoo17.conf >/dev/null <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${WWW_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    return 301 https://${DOMAIN}\$request_uri;
}
EOF
fi

# Main HTTPS server for apex
sudo tee -a /etc/nginx/sites-available/odoo17.conf >/dev/null <<'EOF'
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name __APEX_DOMAIN__;

    client_max_body_size 200M;
    client_body_timeout 120s;

    ssl_certificate     /etc/letsencrypt/live/__APEX_DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__APEX_DOMAIN__/privkey.pem;

    access_log /var/log/nginx/odoo_access.log;
    error_log  /var/log/nginx/odoo_error.log;

    # Common proxy settings
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;
    proxy_set_header Host              $host;
    proxy_set_header X-Forwarded-Host  $host;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP         $remote_addr;

    # Longpolling (gevent on 8072)
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
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://odooserver;
    }

    # Main app
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

# Replace placeholders
sudo sed -i "s/__APEX_DOMAIN__/${DOMAIN}/g" /etc/nginx/sites-available/odoo17.conf

echo "Testing Nginx config (final)..."
sudo nginx -t
echo "Reloading Nginx (final)..."
sudo systemctl reload nginx

# ------------------- Renewals -------------------
if systemctl list-timers | grep -q certbot.timer 2>/dev/null; then
  echo "certbot.timer is active; automatic renewals are handled by systemd."
else
  echo "Setting up cron-based auto-renewal for SSL certificates..."
  sudo crontab -l 2>/dev/null | grep -F "certbot renew" >/dev/null || \
  (sudo crontab -l 2>/dev/null; echo "0 0,12 * * * certbot renew --quiet") | sudo crontab -
fi

echo "Done! Your Odoo should be live at: https://${DOMAIN} 🚀"

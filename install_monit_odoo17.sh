#!/bin/bash
set -e

echo "🔧 Creating Monit config for Odoo17..."

MONIT_MAIN_CONF="/etc/monit/monitrc"

# 1. 
# Create Monit check for Odoo17
sudo tee "/etc/monit/conf-enabled/odoo17" > /dev/null << 'EOF'
check process odoo17 with pidfile /run/odoo17/odoo17.pid
  start program = "/bin/systemctl start odoo17"
  stop program  = "/bin/systemctl stop odoo17"
  if failed port 8069 protocol http
     request "/web/login"
     with timeout 10 seconds
     then alert
  if failed port 8069 protocol http
     request "/web/login"
     with timeout 10 seconds
     then restart
  if 5 restarts within 5 cycles then timeout
EOF

# Create Monit check for NGINX
sudo tee "/etc/monit/conf-enabled/nginx" > /dev/null << 'EOF'
check process nginx with pidfile /run/nginx.pid
  start program = "/bin/systemctl start nginx"
  stop program  = "/bin/systemctl stop nginx"
  if failed host 127.0.0.1 port 80 protocol http
     then restart
  if failed port 443 type TCPSSL then restart
  if 5 restarts within 5 cycles then timeout
EOF

# 2. Enable Monit Web UI on port 2812 if not already set
echo "🔧 Ensuring Monit web interface is enabled on port 2812..."

if ! grep -q "set httpd port 2812" "$MONIT_MAIN_CONF"; then
    sudo tee -a "$MONIT_MAIN_CONF" > /dev/null <<EOF

set httpd port 2812 and
    use address localhost
    allow localhost
    allow admin:"1212Apptology"
EOF
else
    echo "✅ Web UI block already exists in monitrc — skipping append."
fi

# 3. Secure the monitrc file
echo "🔒 Setting secure permissions on monitrc..."
sudo chmod 600 "$MONIT_MAIN_CONF"

# 4. Reload Monit to apply changes
echo "🔄 Reloading Monit..."
sudo monit reload

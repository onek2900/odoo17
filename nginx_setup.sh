#!/bin/bash

# Exit immediately if a command fails
set -e

# Ask for domain name and email address
read -p "Enter your domain name (e.g., example.com): " DOMAIN
read -p "Enter your email for SSL certificate (e.g., admin@example.com): " EMAIL

echo "Installing Nginx..."
sudo apt install -y nginx

echo "Installing cron..."
sudo apt install -y cron

echo "Removing default Nginx configurations..."
sudo rm -f /etc/nginx/sites-enabled/default
sudo rm -f /etc/nginx/sites-available/default

echo "Creating Nginx configuration for Odoo..."
sudo bash -c "cat > /etc/nginx/sites-available/odoo17.conf" <<EOL
upstream odooserver {
     server 127.0.0.1:8069;
}

server {
     listen 80;
     server_name $DOMAIN;

     access_log /var/log/nginx/odoo_access.log;
     error_log /var/log/nginx/odoo_error.log;

     proxy_read_timeout 720s;
     proxy_connect_timeout 720s;
     proxy_send_timeout 720s;
     proxy_set_header X-Forwarded-Host \$host;
     proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
     proxy_set_header X-Forwarded-Proto \$scheme;
     proxy_set_header X-Real-IP \$remote_addr;

     location / {
        proxy_redirect off;
        proxy_pass http://odooserver;
     }

     location ~* /web/static/ {
         proxy_cache_valid 200 90m;
         proxy_buffering on;
         expires 864000;
         proxy_pass http://odooserver;
     }

     gzip_types text/css text/less text/plain text/xml application/xml application/json application/javascript;
     gzip on;
 }
EOL

echo "Enabling Nginx configuration..."
sudo ln -s /etc/nginx/sites-available/odoo17.conf /etc/nginx/sites-enabled/odoo17.conf

echo "Checking Nginx configuration..."
sudo nginx -t

echo "Restarting Nginx..."
sudo systemctl restart nginx

# Install Certbot for SSL
echo "Installing Certbot for Let's Encrypt SSL..."
sudo apt install -y python3-certbot-nginx

# Obtain SSL Certificate
echo "Obtaining SSL Certificate for $DOMAIN..."
sudo certbot --nginx --non-interactive --agree-tos --email $EMAIL -d $DOMAIN

echo "Configuring HTTPS redirect..."
sudo bash -c "cat > /etc/nginx/sites-available/odoo17.conf" <<EOL
upstream odooserver {
     server 127.0.0.1:8069;
}

server {
     listen [::]:80;
     listen 80;

     server_name $DOMAIN www.$DOMAIN;

     return 301 https://$DOMAIN\$request_uri;
}

server {
     listen [::]:443 ssl;
     listen 443 ssl;

     server_name www.$DOMAIN;
     client_max_body_size 200M;        # allow bigger uploads
     client_body_timeout 120s;         # optional
     ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
     ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

     return 301 https://$DOMAIN\$request_uri;
}

server {
     listen [::]:443 ssl http2;
     listen 443 ssl http2;

     server_name $DOMAIN;
     client_max_body_size 200M;        # allow bigger uploads
     client_body_timeout 120s;         # optional
     ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
     ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

     access_log /var/log/nginx/odoo_access.log;
     error_log /var/log/nginx/odoo_error.log;

     proxy_read_timeout 720s;
     proxy_connect_timeout 720s;
     proxy_send_timeout 720s;
     proxy_set_header X-Forwarded-Host \$host;
     proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
     proxy_set_header X-Forwarded-Proto \$scheme;
     proxy_set_header X-Real-IP \$remote_addr;

     location / {
        proxy_redirect off;
        proxy_pass http://odooserver;
     }

     location ~* /web/static/ {
         proxy_cache_valid 200 90m;
         proxy_buffering on;
         expires 864000;
         proxy_pass http://odooserver;
     }

     gzip_types text/css text/less text/plain text/xml application/xml application/json application/javascript;
     gzip on;
}
EOL

echo "Checking Nginx configuration again..."
sudo nginx -t

echo "Restarting Nginx..."
sudo systemctl restart nginx

# Set up automatic SSL renewal
echo "Setting up auto-renewal for SSL certificates..."
sudo crontab -l 2>/dev/null | grep -F "certbot renew" >/dev/null || \
(sudo crontab -l 2>/dev/null; echo "0 0,12 * * * certbot renew >/dev/null 2>&1") | sudo crontab -

echo "Nginx setup completed successfully!"
echo "Your Odoo is now accessible at https://$DOMAIN 🚀"

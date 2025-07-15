#!/bin/bash

# Exit immediately if a command fails
set -e

echo "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y

echo "Creating odoo17 system user..."
sudo useradd -m -d /opt/odoo17 -U -r -s /bin/bash odoo17

echo "Setting password for odoo17..."
echo "odoo17:odoo17" | sudo chpasswd

echo "Installing required dependencies..."
sudo apt install -y git python3-pip python3-dev python3-venv libxml2-dev libxslt1-dev zlib1g-dev \
    libsasl2-dev libldap2-dev build-essential libssl-dev libffi-dev libmysqlclient-dev \
    libjpeg-dev libpq-dev libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev pkg-config libcairo2-dev libgirepository1.0-dev python3-dev build-essential
sudo apt install -y npm postgresql
sudo ln -s /usr/bin/nodejs /usr/bin/node || true
sudo npm install -g less less-plugin-clean-css
sudo apt-get install -y node-less

echo "Configuring PostgreSQL..."
sudo -u postgres psql -c "CREATE USER odoo17 WITH CREATEDB PASSWORD 'odoo17';"
sudo -u postgres psql -c "ALTER USER odoo17 WITH SUPERUSER;"

echo "Downloading wkhtmltopdf..."
sudo apt-get -y install wkhtmltopdf

#cd /tmp
#sudo wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.bullseye_amd64.deb
#sudo dpkg -i wkhtmltox_0.12.6.1-2.bullseye_amd64.deb || sudo apt install -f -y


echo "Switching to odoo17 user..."
sudo -H -u odoo17 bash <<EOF
cd /opt/odoo17

echo "Cloning Odoo 17..."
git clone --depth 1 --branch 17.0 https://www.github.com/odoo/odoo odoo17

echo "Creating virtual environment..."
python3 -m venv odoo17-venv
source odoo17-venv/bin/activate

echo "Installing Python dependencies..."
pip3 install --upgrade pip
pip3 install wheel
pip3 install psycopg2-binary
pip3 install pycairo
pip3 install rlPyCairo
pip3 install -r odoo17/requirements.txt


deactivate

echo "Creating custom-addons directory..."
mkdir -p /opt/odoo17/odoo17/custom-addons

echo "Cloning custom Odoo addon..."
git config --global --add safe.directory /opt/odoo17/odoo17/custom-addons
cd /opt/odoo17/odoo17/custom-addons

# Clone the repository into a temporary folder
git clone --depth=1 https://github.com/onek2900/Apptology_Odoo.git temp_addon

# Move all files from temp_addon to the current directory
mv temp_addon/* temp_addon/.* . 2>/dev/null || true

# Remove the temporary folder and Git metadata
rm -rf temp_addon .git

EOF

echo "Creating Odoo configuration file..."
sudo bash -c 'cat <<EOL > /etc/odoo17.conf
[options]
admin_passwd = Basilboss12
db_host = False
db_port = False
db_user = odoo17
db_password = False
addons_path = /opt/odoo17/odoo17/addons,/opt/odoo17/odoo17/custom-addons
xmlrpc_port = 8069
proxy_mode = True
pidfile = /run/odoo17/odoo17.pid
#logfile = /var/log/odoo17/odoo17.log
#log_handler = DEBUG

EOL'

#create logfile location
sudo mkdir -p /var/log/odoo17
sudo chown odoo17:odoo17 /var/log/odoo17

#create pidfile location
sudo mkdir -p /run/odoo17
sudo chown odoo17:odoo17 /run/odoo17

echo "Creating Odoo systemd service..."
sudo bash -c 'cat <<EOL > /etc/systemd/system/odoo17.service
[Unit]
Description=Odoo17
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=odoo17
PermissionsStartOnly=true
User=odoo17
Group=odoo17
ExecStart=/opt/odoo17/odoo17-venv/bin/python3 /opt/odoo17/odoo17/odoo-bin -c /etc/odoo17.conf
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOL'

echo "Reloading systemd and starting Odoo service..."
sudo systemctl daemon-reload
sudo systemctl enable --now odoo17

echo "Running post-installation script..."
wget -O /tmp/post_install.sh https://raw.githubusercontent.com/onek2900/odoo17/main/post_install.sh
chmod +x /tmp/post_install.sh
sudo /tmp/post_install.sh

echo "Running NGINX-installation script..."
wget https://raw.githubusercontent.com/onek2900/odoo17/main/nginx_setup.sh -O nginx_setup.sh
chmod +x nginx_setup.sh
sudo ./nginx_setup.sh

echo "Running Monit-installation script..."
wget https://raw.githubusercontent.com/onek2900/odoo17/main/install_monit_odoo17.sh -O install_monit_odoo17.sh
chmod +x install_monit_odoo17.sh
sudo ./install_monit_odoo17.sh


echo "Installation completed successfully!"
echo "You can check logs using: sudo journalctl -u odoo17"

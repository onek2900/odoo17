#!/bin/bash

# Odoo database name
DB_NAME="odoo17_db"
ADMIN_PASS="admin_passwd"

echo "Creating Odoo database and installing addons..."

# Run Odoo shell commands
sudo -H -u odoo17 bash <<EOF
cd /opt/odoo17

# Activate virtual environment
source odoo17-venv/bin/activate

# Create database
/opt/odoo17/odoo17-venv/bin/python3 /opt/odoo17/odoo17/odoo-bin --db_host=localhost --db_user=odoo17 --db_password=odoo17 --admin_passwd=$ADMIN_PASS -d $DB_NAME --stop-after-init --init=base

echo "Database $DB_NAME created successfully!"

# Install addons (replace 'custom_module' with actual addon names)
/opt/odoo17/odoo17-venv/bin/python3 /opt/odoo17/odoo17/odoo-bin --db_host=localhost --db_user=odoo17 --db_password=odoo17 --admin_passwd=$ADMIN_PASS -d $DB_NAME --stop-after-init --init=custom_module

echo "Addons installed successfully!"

deactivate
EOF

echo "Post-installation tasks completed!"

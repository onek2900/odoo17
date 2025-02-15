# odoo17
🚀 Odoo 17 will be installed + database created + addons installed automatically! 🚀





How to Add More Addons?
Modify post_install.sh and replace:
--init=custom_module
with:
--init=module1,module2,module3



How to Run the Script
1️⃣ Run it directly from GitHub:

bash <(curl -s https://raw.githubusercontent.com/onek2900/odoo17/main/install_odoo17.sh)


2️⃣ Manually Download & Execute:

wget https://raw.githubusercontent.com/onek2900/odoo17/main/install_odoo17.sh -O install_odoo17.sh
chmod +x install_odoo17.sh
sudo ./install_odoo17.sh




📌 Odoo Web Interface: Open http://localhost:8069 in your browser.

📌 Logs: To check logs, run:
sudo journalctl -u odoo17 -f

📌 Restart Odoo Service:
sudo systemctl restart odoo17





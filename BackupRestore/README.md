Odoo Multi-Server Backup System

This setup includes:

odoo_multiserver_backup_parallel.sh – Automated parallel backup for multiple Odoo servers (PostgreSQL + filestore).

odoo_backup_doctor.sh – Diagnostic + one-off backup tool for adding/fixing a server.

1️⃣ Prerequisites
On Backup Server

Ubuntu/Debian Linux recommended.

Install required packages:

sudo apt-get update
sudo apt-get install -y openssh-client postgresql-client coreutils rsync


Create backup root:

sudo mkdir -p /opt/backups/odoo
sudo chmod 700 /opt/backups/odoo


Place both scripts in /usr/local/bin:

odoo_multiserver_backup_parallel.sh

odoo_backup_doctor.sh

Make them executable:

sudo chmod +x /usr/local/bin/odoo_multiserver_backup_parallel.sh
sudo chmod +x /usr/local/bin/odoo_backup_doctor.sh

On Each Odoo Server

Ubuntu/Debian Linux with:

PostgreSQL (postgres system user)

Odoo service installed and running

sudo installed and your SSH user must be able to run:

sudo -u postgres pg_dump, pg_dumpall, psql

sudo tar on the filestore path

2️⃣ SSH Key Setup

Generate SSH key on the backup server (if not already created):

mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C "odoo-backups"
# Press Enter for file path (~/.ssh/id_ed25519), leave passphrase empty


Copy public key to each Odoo server:

ssh-copy-id -i ~/.ssh/id_ed25519.pub root@<ODOO_SERVER_IP>


If password login is disabled, paste the contents of ~/.ssh/id_ed25519.pub
into /root/.ssh/authorized_keys (or the home .ssh of your non-root backup user).

Security recommendations:

In /etc/ssh/sshd_config on each Odoo server:

PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes


Restart SSH:

sudo systemctl restart ssh

3️⃣ Inventory CSV

The main backup script uses /etc/odoo-backups/servers.csv to know which servers to back up.

Create directory and file:

sudo mkdir -p /etc/odoo-backups
sudo nano /etc/odoo-backups/servers.csv


Format:

name,host,ssh_user,filestore_base


Example /etc/odoo-backups/servers.csv:

name,host,ssh_user,filestore_base
milano,147.79.70.28,root,/opt/odoo17/.local/share/Odoo/filestore
london,203.0.113.10,root,


name: Short alias for the server (used in backup folder names)

host: IP or DNS name of the server

ssh_user: User to connect as (usually root or backup)

filestore_base: Path to the filestore base directory

Leave blank to let the script auto-detect

4️⃣ Running the Doctor Script

Before adding a new server to the CSV, or if a backup fails, run:

sudo /usr/local/bin/odoo_backup_doctor.sh --host <IP> --user <ssh_user>


It will:

Test SSH and sudo

Detect Odoo service, config, data_dir, and filestore

Check PostgreSQL access

List databases and whether each has a filestore

Print a ready-to-paste CSV row

Optional immediate backup:

sudo /usr/local/bin/odoo_backup_doctor.sh --host <IP> --user <ssh_user> --backup-now


This runs a one-off backup without needing the server in the CSV.

5️⃣ Running the Main Backup

Manual run:

sudo /usr/local/bin/odoo_multiserver_backup_parallel.sh


Runs backups for all servers in the CSV in parallel

Keeps current and previous backups per server, deletes older ones

Logs per server: /opt/backups/odoo/<name>/backup.log

6️⃣ Automating with Cron

Edit root’s crontab:

sudo crontab -e


Example: run daily at 02:00:

0 2 * * * /usr/local/bin/odoo_multiserver_backup_parallel.sh >/dev/null 2>&1

7️⃣ Restoring

Globals (roles/privileges):

sudo -u postgres psql -f globals.sql


Database:

sudo -u postgres createdb mydb
sudo -u postgres pg_restore -Fc -d mydb mydb.dump


Filestore:

sudo tar -C /opt/odoo17/.local/share/Odoo/filestore -xzf mydb_filestore.tar.gz
sudo chown -R odoo17:odoo17 /opt/odoo17/.local/share/Odoo/filestore/mydb

8️⃣ Common Failure Scenario & Fix

Problem: Backup log shows:

Permission denied (publickey,password)


Fix:

Ensure SSH key exists on backup server:

cat ~/.ssh/id_ed25519.pub


Add it to the Odoo server’s /root/.ssh/authorized_keys or backup user’s .ssh/authorized_keys.

Set proper permissions:

chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys


Test:

ssh -o BatchMode=yes root@<ODOO_SERVER_IP> "echo OK"


Re-run the doctor script to verify:

odoo_backup_doctor.sh --host <IP> --user root


Once OK, add/update the server row in /etc/odoo-backups/servers.csv.

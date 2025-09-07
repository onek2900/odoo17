#!/usr/bin/env bash
set -euo pipefail

# ================== CONFIG (edit if you like) ==================
BACKUP_ROOT="/opt/backups/odoo"
SSH_OPTS_BASE="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
USE_PIGZ=true          # if remote has pigz, use it for faster compression
KEEP_COUNT=2           # when --backup-now is used, keep current+previous for this server
# ===============================================================

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; BOLD=$'\e[1m'; NC=$'\e[0m'

usage() {
  cat <<EOF
Usage: $0 --host <IP/NAME> --user <ssh_user> [--port 22] [--backup-now]

What it does:
  • Verifies SSH key login and sudo
  • Detects Odoo unit, config (-c), data_dir, filestore base
  • Tests PostgreSQL access as postgres (pg_dumpall/psql)
  • Lists DBs and checks each DB's filestore presence
  • Prints a ready-to-paste CSV row for /etc/odoo-backups/servers.csv
  • Optionally performs a one-off backup (DB+filestore) to ${BACKUP_ROOT}

Examples:
  $0 --host 147.79.70.28 --user root
  $0 --host 147.79.70.28 --user root --backup-now
  $0 --host my-vps --user backup --port 22022
EOF
}

HOST=""; USER=""; PORT="22"; BACKUP_NOW=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --user) USER="$2"; shift 2;;
    --port) PORT="${2:-22}"; shift 2;;
    --backup-now) BACKUP_NOW=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

[[ -z "$HOST" || -z "$USER" ]] && { usage; exit 1; }

SSH_OPTS="${SSH_OPTS_BASE} -p ${PORT}"

say() { echo "${BLUE}${BOLD}[*]${NC} $*"; }
ok()  { echo "${GREEN}${BOLD}[OK]${NC} $*"; }
warn(){ echo "${YELLOW}${BOLD}[WARN]${NC} $*"; }
err() { echo "${RED}${BOLD}[ERR]${NC} $*"; }

REMOTE() { ssh ${SSH_OPTS} "${USER}@${HOST}" "$@"; }

# --- 1) SSH sanity -----------------------------------------------------------
say "Checking SSH to ${USER}@${HOST}:${PORT} ..."
if REMOTE "echo connected"; then ok "SSH connected."; else err "SSH failed"; exit 2; fi

# --- 2) Sudo sanity ----------------------------------------------------------
say "Verifying sudo works for ${USER} ..."
if REMOTE "sudo -n true 2>/dev/null || echo NEEDPASS"; then
  if [[ "$(REMOTE 'sudo -n true 2>/dev/null; echo $?')" != "0" ]]; then
    warn "Passwordless sudo not available. That's fine if you're root; otherwise some checks may fail."
  else
    ok "Passwordless sudo OK."
  fi
fi

# --- 3) Detect Odoo unit & config -------------------------------------------
say "Detecting Odoo systemd unit and config (-c path) ..."
UNIT="$(REMOTE "systemctl list-units --type=service --all | awk '/odoo|openerp/ {print \$1; exit}'" || true)"
if [[ -z "$UNIT" ]]; then warn "No Odoo unit found via systemd. Will inspect running processes."; fi

CONF="$(REMOTE "
  set -e
  if systemctl list-units --type=service --all | grep -Eq 'odoo|openerp'; then
    systemctl cat \$(systemctl list-units --type=service --all | awk '/odoo|openerp/ {print \$1}') 2>/dev/null \
      | awk -F'-c ' '/odoo-bin/ && / -c / {print \$2}' | awk '{print \$1}' | head -n1 || true
  fi
" || true)"

if [[ -z "$CONF" ]]; then
  CONF="$(REMOTE "ps -eo args | grep -E 'odoo-bin' | grep -E ' -c ' | sed -n 's/.* -c \\([^ ]*\\).*/\\1/p' | head -n1" || true)"
fi

if [[ -n "$UNIT" ]]; then ok "Unit: ${UNIT}"; else warn "Unit: (not found)"; fi
if [[ -n "$CONF" ]]; then ok "Config: ${CONF}"; else warn "Config: (not found, will use defaults)"; fi

# --- 4) Determine data_dir & filestore base ---------------------------------
say "Determining data_dir and filestore base ..."
DATA_DIR=""
if [[ -n "$CONF" ]]; then
  DATA_DIR="$(REMOTE "awk -F= '/^\\s*data_dir\\s*=/{gsub(/^[ \\t]+|[ \\t]+$/, \"\", \$2); print \$2}' '$CONF' | head -n1" || true)"
fi

if [[ -z "$DATA_DIR" ]]; then
  # find service user
  SVC_USER="$(REMOTE "systemctl show -p User '${UNIT}' 2>/dev/null | sed 's/User=//'" || true)"
  if [[ -z "$SVC_USER" ]]; then
    SVC_USER="$(REMOTE "ps -eo user,args | awk '/odoo-bin/ {print \$1; exit}'" || true)"
  fi
  [[ -z "$SVC_USER" ]] && SVC_USER="$USER"
  SVC_HOME="$(REMOTE "getent passwd '$SVC_USER' | cut -d: -f6" || true)"
  [[ -z "$SVC_HOME" ]] && SVC_HOME="$(REMOTE 'echo $HOME')"
  DATA_DIR="${SVC_HOME}/.local/share/Odoo"
fi
ok "data_dir = ${DATA_DIR}"

FS_BASE="${DATA_DIR}/filestore"
if REMOTE "[ -d '$FS_BASE' ]"; then
  ok "filestore base detected: ${FS_BASE}"
else
  warn "Default filestore not found at ${FS_BASE}; searching ..."
  ALT="$(REMOTE "find / -maxdepth 4 -type d -name filestore 2>/dev/null | head -n1" || true)"
  if [[ -n "$ALT" ]]; then
    FS_BASE="$ALT"; ok "filestore base found: ${FS_BASE}"
  else
    warn "No filestore directory found. (Attachments may be stored in DB.)"
    FS_BASE=""
  fi
fi

# --- 5) PostgreSQL tests -----------------------------------------------------
say "Testing PostgreSQL access as postgres ..."
if REMOTE "sudo -u postgres psql -At -c 'select 1' >/dev/null"; then
  ok "psql OK."
else
  err "Cannot run psql as postgres. Ensure postgres is installed and sudo perms allow it."; exit 3
fi

# --- 6) List DBs and check filestore per DB ---------------------------------
say "Enumerating databases ..."
DBS="$(REMOTE "sudo -u postgres psql -At -c \"SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');\"")"
if [[ -z "$DBS" ]]; then warn "No databases returned."; fi

printf "%s\n" "$DBS" | while read -r DB; do
  [[ -z "$DB" ]] && continue
  if [[ -n "$FS_BASE" ]] && REMOTE "[ -d '${FS_BASE}/${DB}' ]"; then
    ok "DB=${DB} filestore present: ${FS_BASE}/${DB}"
  else
    warn "DB=${DB} filestore NOT found under ${FS_BASE:-<unknown>}"
  fi
done

# Also check attachment storage mode on first DB (if any)
FIRST_DB="$(printf "%s\n" "$DBS" | head -n1 || true)"
if [[ -n "$FIRST_DB" ]]; then
  say "Checking attachment storage mode for DB=${FIRST_DB} ..."
  LOC="$(REMOTE "sudo -u postgres psql -d '$FIRST_DB' -At -c \"SELECT coalesce((SELECT value FROM ir_config_parameter WHERE key='ir_attachment.location'),'file')\" 2>/dev/null" || true)"
  FILES_ON_DISK="$(REMOTE "sudo -u postgres psql -d '$FIRST_DB' -At -c \"SELECT COUNT(*) FROM ir_attachment WHERE store_fname IS NOT NULL\" 2>/dev/null" || echo 0)"
  IN_DB="$(REMOTE "sudo -u postgres psql -d '$FIRST_DB' -At -c \"SELECT COUNT(*) FROM ir_attachment WHERE db_datas IS NOT NULL\" 2>/dev/null" || echo 0)"
  echo "    location=${LOC:-unknown}  files_on_disk=${FILES_ON_DISK}  in_db=${IN_DB}"
fi

# --- 7) Print suggested CSV row ---------------------------------------------
say "Suggested CSV row for /etc/odoo-backups/servers.csv:"
if [[ -n "$FS_BASE" ]]; then
  echo "name,host,ssh_user,filestore_base"
  echo "<choose-name>,${HOST},${USER},${FS_BASE}"
else
  echo "name,host,ssh_user,filestore_base"
  echo "<choose-name>,${HOST},${USER},"
  warn "No filestore found — DB dumps will still work; images may be stored in DB."
fi

# --- 8) Optional one-off backup ---------------------------------------------
if $BACKUP_NOW; then
  SERVER_NAME="${HOST//./-}"  # default folder name if you don't pass one
  SERVER_DIR="${BACKUP_ROOT}/${SERVER_NAME}"
  DATE_DIR="${SERVER_DIR}/$(date +%F)"
  [[ -d "$DATE_DIR" ]] && DATE_DIR="${DATE_DIR}_$(date +%H%M%S)"
  mkdir -p "${DATE_DIR}"

  say "Running one-off backup to ${DATE_DIR} (DB + filestore if available) ..."
  # choose compression program on remote
  TAR_CMD="tar -cz"
  if $USE_PIGZ && REMOTE "command -v pigz >/dev/null 2>&1"; then
    TAR_CMD="tar --use-compress-program=pigz -c"
  fi

  # globals
  REMOTE "sudo -u postgres pg_dumpall --globals-only" > "${DATE_DIR}/globals.sql" || { err "globals dump failed"; exit 4; }

  # per DB
  for DB in $DBS; do
    say "Dumping DB: ${DB}"
    REMOTE "sudo -u postgres pg_dump -Fc \"${DB}\"" > "${DATE_DIR}/${DB}.dump"
    if [[ -n "$FS_BASE" ]] && REMOTE "[ -d '${FS_BASE}/${DB}' ]"; then
      say "Archiving filestore for ${DB}"
      REMOTE "sudo -n ${TAR_CMD} -C \"${FS_BASE}\" \"${DB}\"" > "${DATE_DIR}/${DB}_filestore.tar.gz"
    fi
  done

  ( cd "${DATE_DIR}" && sha256sum * > SHA256SUMS.txt ) || true

  # rotate current/previous
  cd "${SERVER_DIR}"
  rm -f current previous
  mapfile -t DIRS < <(find . -maxdepth 1 -type d -name "20*" -printf "%T@ %P\n" | sort -nr | awk '{print $2}')
  [[ ${#DIRS[@]} -ge 1 ]] && ln -s "${DIRS[0]}" current
  [[ ${#DIRS[@]} -ge 2 ]] && ln -s "${DIRS[1]}" previous
  if (( ${#DIRS[@]} > KEEP_COUNT )); then
    for ((i=KEEP_COUNT; i<${#DIRS[@]}; i++)); do
      rm -rf -- "${DIRS[$i]}"
    done
  fi

  ok "Backup completed. See: ${SERVER_DIR}"
fi

ok "Diagnostics finished."

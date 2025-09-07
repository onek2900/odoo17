#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
CSV_FILE="/etc/odoo-backups/servers.csv"
BACKUP_ROOT="/opt/backups/odoo"             # backups: /opt/backups/odoo/<server>/<date>/
CONCURRENCY=5                               # how many servers in parallel
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
KEEP_COUNT=2                                # keep exactly current + previous
USE_PIGZ=true                               # try pigz on remote for faster compression
LOCK_FILE="/var/lock/odoo_backups.lock"
# ========= END CONFIG =====

umask 027
mkdir -p "${BACKUP_ROOT}"

# Prevent overlapping runs
exec 9>"${LOCK_FILE}"
flock -n 9 || { echo "Another backup run is in progress. Exiting."; exit 1; }

timestamp_iso() { date -Is; }
today() { date +"%Y-%m-%d"; }
log() { echo "[$(timestamp_iso)] $*"; }

# --- Detect filestore base on remote host if not provided ---
remote_detect_filestore() {
  # $1 = SSH_USER, $2 = HOST
  local SSH_USER="$1" HOST="$2"
  local SSH="ssh ${SSH_OPTS} ${SSH_USER}@${HOST}"

  # 1) Try to get config path (-c /path/to/odoo.conf) from systemd or process list
  local CONF=""
  CONF=$($SSH "set -e;
    # From systemd: look for ExecStart lines containing odoo-bin and -c
    if systemctl list-units --type=service 2>/dev/null | grep -Eqi 'odoo|openerp'; then
      systemctl cat \$(systemctl list-units --type=service --all | awk '/odoo|openerp/ {print \$1}') 2>/dev/null \
        | awk -F'-c ' '/odoo-bin/ && / -c / {print \$2}' | awk '{print \$1}' | head -n1 || true;
    fi
    " 2>/dev/null || true)

  # If systemd didn’t reveal it, try running processes
  if [[ -z "$CONF" ]]; then
    CONF=$($SSH "ps -eo args | grep -E 'odoo-bin' | grep -E ' -c ' | sed -n 's/.* -c \\([^ ]*\\).*/\\1/p' | head -n1" 2>/dev/null || true)
  fi

  # 2) If we have a config, read data_dir from it
  if [[ -n "$CONF" ]]; then
    local DATA_DIR
    DATA_DIR=$($SSH "awk -F= '/^\\s*data_dir\\s*=/{gsub(/^[ \\t]+|[ \\t]+$/, \"\", \$2); print \$2}' \"$CONF\" | head -n1" 2>/dev/null || true)
    if [[ -n "$DATA_DIR" ]]; then
      # Verify it exists
      if $SSH "[ -d \"$DATA_DIR/filestore\" ]"; then
        echo "$DATA_DIR/filestore"
        return 0
      fi
    fi
  fi

  # 3) No explicit data_dir: use the service user’s home + default path
  #    Identify the Odoo system user from a known service (try common unit names)
  local UNIT USER HOME
  UNIT=$($SSH "systemctl list-units --type=service --all | awk '/odoo|openerp/ {print \$1; exit}'" 2>/dev/null || true)
  if [[ -n "$UNIT" ]]; then
    USER=$($SSH "systemctl show -p User \"$UNIT\" | sed 's/User=//'" 2>/dev/null || true)
  fi
  # Fallback: try to parse the running process owner
  if [[ -z "$USER" ]]; then
    USER=$($SSH "ps -eo user,args | awk '/odoo-bin/ {print \$1; exit}'" 2>/dev/null || true)
  fi
  # Last resort: assume same login user
  [[ -z "$USER" ]] && USER="$SSH_USER"

  HOME=$($SSH "getent passwd \"$USER\" | cut -d: -f6" 2>/dev/null || true)
  if [[ -z "$HOME" ]]; then
    # fallback for root if getent failed
    HOME=$($SSH 'echo $HOME' 2>/dev/null || echo "/root")
  fi

  local DEFAULT_BASE="${HOME}/.local/share/Odoo/filestore"
  if $SSH "[ -d \"$DEFAULT_BASE\" ]"; then
    echo "$DEFAULT_BASE"
    return 0
  fi

  # 4) As a last resort, search shallowly for a filestore directory
  local FOUND
  FOUND=$($SSH "find / -maxdepth 4 -type d -name filestore 2>/dev/null | head -n1" 2>/dev/null || true)
  if [[ -n "$FOUND" ]]; then
    echo "$FOUND"
    return 0
  fi

  # Nothing found
  echo ""
  return 1
}

backup_one() {
  local LINE="$1"

  # CSV: name,host,ssh_user[,filestore_base]
  IFS=',' read -r NAME HOST SSH_USER FS_BASE_OPT <<< "$LINE"
  NAME=$(echo "$NAME" | xargs); HOST=$(echo "$HOST" | xargs)
  SSH_USER=$(echo "$SSH_USER" | xargs); FS_BASE_OPT=$(echo "${FS_BASE_OPT:-}" | xargs)

  [[ -z "$NAME" || -z "$HOST" || -z "$SSH_USER" ]] && { echo "[-] Skipping invalid row: $LINE"; return 0; }

  local SERVER_DIR="${BACKUP_ROOT}/${NAME}"
  local DATE_DIR="${SERVER_DIR}/$(today)"
  [[ -d "${DATE_DIR}" ]] && DATE_DIR="${DATE_DIR}_$(date +%H%M%S)"
  mkdir -p "${DATE_DIR}"

  local LOG_FILE="${SERVER_DIR}/backup.log"
  touch "${LOG_FILE}"

  {
    log "=== Start backup: ${NAME} (${HOST}) -> ${DATE_DIR} ==="

    local REMOTE_DB="sudo -u postgres"   # run pg_* as postgres
    local REMOTE_FS="sudo -n"            # tar/ls as root (non-interactive sudo)

    # Compression tool on remote
    local TAR_CMD="tar -cz"
    if $USE_PIGZ; then
      if ssh ${SSH_OPTS} "${SSH_USER}@${HOST}" "command -v pigz >/dev/null 2>&1"; then
        TAR_CMD="tar --use-compress-program=pigz -c"
      fi
    fi

    # 0) Determine filestore base
    local FS_BASE=""
    if [[ -n "$FS_BASE_OPT" ]]; then
      # use CSV override (verify exists)
      if ssh ${SSH_OPTS} "${SSH_USER}@${HOST}" "[ -d \"$FS_BASE_OPT\" ]"; then
        FS_BASE="$FS_BASE_OPT"
      else
        log "    (CSV filestore_base not found on host: $FS_BASE_OPT) attempting auto-detect..."
      fi
    fi
    if [[ -z "$FS_BASE" ]]; then
      FS_BASE="$(remote_detect_filestore "$SSH_USER" "$HOST" || true)"
      if [[ -z "$FS_BASE" ]]; then
        log "    (could not auto-detect filestore; will still dump DBs)"
      else
        log "    Detected filestore base: $FS_BASE"
      fi
    fi

    # 1) Dump cluster globals (roles/privs)
    log "[*] Dumping PostgreSQL globals..."
    ssh ${SSH_OPTS} "${SSH_USER}@${HOST}" \
      "${REMOTE_DB} pg_dumpall --globals-only" > "${DATE_DIR}/globals.sql"

    # 2) Enumerate Odoo DBs
    log "[*] Enumerating databases..."
    DBS=$(ssh ${SSH_OPTS} "${SSH_USER}@${HOST}" \
      "${REMOTE_DB} psql -At -c \"SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');\"")

    # 3) Per-DB dump + filestore
    for DB in $DBS; do
      log "[*] Backing up DB: ${DB}"
      ssh ${SSH_OPTS} "${SSH_USER}@${HOST}" \
        "${REMOTE_DB} pg_dump -Fc \"${DB}\"" > "${DATE_DIR}/${DB}.dump"

      if [[ -n "$FS_BASE" ]]; then
        local FS_PATH="${FS_BASE}/${DB}"
        if ssh ${SSH_OPTS} "${SSH_USER}@${HOST}" "[ -d \"${FS_PATH}\" ]"; then
          log "    Archiving filestore for ${DB}"
          ssh ${SSH_OPTS} "${SSH_USER}@${HOST}" \
            "${REMOTE_FS} ${TAR_CMD} -C \"${FS_BASE}\" \"${DB}\"" > "${DATE_DIR}/${DB}_filestore.tar.gz"
        else
          log "    (no filestore at ${FS_PATH})"
        fi
      fi
    done

    # 4) Checksums
    ( cd "${DATE_DIR}" && sha256sum * > SHA256SUMS.txt ) || true
    log "[*] Checksums written"

    # 5) Symlinks & prune for this server
    cd "${SERVER_DIR}"
    rm -f current previous
    mapfile -t DIRS < <(find . -maxdepth 1 -type d -name "20*" -printf "%T@ %P\n" | sort -nr | awk '{print $2}')
    [[ ${#DIRS[@]} -ge 1 ]] && ln -s "${DIRS[0]}" current
    [[ ${#DIRS[@]} -ge 2 ]] && ln -s "${DIRS[1]}" previous
    if (( ${#DIRS[@]} > KEEP_COUNT )); then
      for ((i=KEEP_COUNT; i<${#DIRS[@]}; i++)); do
        log "[*] Deleting old backup: ${DIRS[$i]}"
        rm -rf -- "${DIRS[$i]}"
      done
    fi

    log "=== Done: ${NAME} ==="
  } >> "${LOG_FILE}" 2>&1
}

export -f backup_one log today remote_detect_filestore
export BACKUP_ROOT SSH_OPTS KEEP_COUNT USE_PIGZ

# Read CSV rows (skip header/comments/blank)
mapfile -t ROWS < <(tail -n +2 "${CSV_FILE}" | awk 'NF && $0 !~ /^#/')

# Run with simple concurrency control
pids=()
active=0
for LINE in "${ROWS[@]}"; do
  backup_one "$LINE" &
  pids+=($!)
  ((active++))
  if (( active >= CONCURRENCY )); then
    wait -n
    ((active--))
  fi
done
wait

log "All servers completed."

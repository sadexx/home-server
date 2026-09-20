#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

source ./scripts/resolve-user.sh
resolve_target_user

export RCLONE_CONFIG="${TARGET_HOME}/.config/rclone/rclone.conf"

set -a
source .env
set +a

DUMP_DIR="./data/_pg_dump"

BACKUP_PATHS=(
  "./data/portainer"
  "./data/vaultwarden"
  "./data/pihole"
  "./data/omniroute"
  "./data/nextcloud/html"
  "./data/nextcloud/data"
  "$DUMP_DIR"
)

is_rclone_remote_configured() {
  rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:$"
}

is_restic_repo_initialized() {
  restic snapshots -r "$RESTIC_REPOSITORY" > /dev/null 2>&1
}

is_restic_password_set() {
  [[ -n "${RESTIC_PASSWORD:-}" && "${RESTIC_PASSWORD}" != "CHANGE_ME" ]]
}

is_cron_job_installed() {
  command -v crontab > /dev/null || return 1
  local script_path
  script_path="$(readlink -f "${BASH_SOURCE[0]}")"

  local crontab_cmd=(crontab)
  if [[ "$(id -u)" -eq 0 && "$TARGET_USER" != "root" ]]; then
    crontab_cmd=(crontab -u "$TARGET_USER")
  fi

  "${crontab_cmd[@]}" -l 2>/dev/null | grep -qF "$script_path run"
}

check () {
  is_rclone_remote_configured && is_restic_repo_initialized && is_restic_password_set && is_cron_job_installed
}

init_restic_repo() {
  local init_output
  if init_output=$(restic init -r "$RESTIC_REPOSITORY" 2>&1); then
    echo "Repository initialized: ${RESTIC_REPOSITORY}"
    return 0
  fi

  if echo "$init_output" | grep -qi "config file already exists"; then
    echo "Repository already exists at ${RESTIC_REPOSITORY}"
    if ! is_restic_repo_initialized; then
      echo "ERROR: repository exists, but RESTIC_PASSWORD in .env does not match it"
      echo "If this is the same repository from a previous attempt, check whether the password changed"
      echo "If this is meant to be a new repository, use different path in RESTIC_REPOSITORY"
      return 1
    fi
    return 0
  fi

  echo "ERROR initializing restic repository:"
  echo "$init_output"
  return 1
}

grant_access() {
  command -v setfacl > /dev/null || { echo "setfacl not found. Install the acl tools for your distro"; return 1; }

  local dir
  for dir in ./data/nextcloud/html ./data/nextcloud/data; do
    [[ -d "$dir" ]] || continue
    echo "Granting ${TARGET_USER} read access to ${dir}..."
    sudo setfacl -R -m "u:${TARGET_USER}:rX" "$dir"
    sudo setfacl -R -d -m "u:${TARGET_USER}:rX" "$dir"
  done
}

configure() {
  command -v rclone > /dev/null || { echo "rclone not installed. sudo -v ; curl https://rclone.org/install.sh | sudo bash"; exit 1; }
  command -v restic > /dev/null || { echo "restic not installed. See https://restic.net/#installation"; exit 1; }

  if ! is_restic_password_set; then
    echo "ERROR: RESTIC_PASSWORD is not set in .env (or is still CHANGE_ME)"
    echo "Generate one with: openssl rand -base64 32"
    echo "Store the value somewhere OTHER than this server - losing it makes backups unrecoverable."
    return 1
  fi

  if ! is_rclone_remote_configured; then
    echo "Remote '${RCLONE_REMOTE}' not found. Launching rclone config..."
    rclone config
    if ! is_rclone_remote_configured; then
      echo "ERROR: remote '${RCLONE_REMOTE}' still not found after rclone config."
      echo "Check that the remote name you just created matches RCLONE_REMOTE in .env"
      return 1
    fi
  fi

  if ! is_restic_repo_initialized; then
    echo "Initializing restic-repository: ${RESTIC_REPOSITORY}"
    init_restic_repo || return 1
  fi

  grant_access || return 1

  if command -v crontab > /dev/null; then
    read -rp "Install cron-job for daily backup at 6 PM? [y/N] " ans
    if [[ "${ans:-}" == "y" ]]; then
      install_cron_job || echo "WARNING: failed to install cron job (see output above)"
    fi
  else
    echo "crontab not found - skipping schedule setup"
    echo "Install a cron package for your distro, then run ./scripts/backup.sh --configure again"
  fi

  if check; then
    echo "Configuration complete"
  else
    echo "Configuration is not fully complete. Review the messages above and run ./scripts/backup.sh --configure again"
    return 1
  fi
}

install_cron_job() {
  if ! command -v crontab > /dev/null; then
    echo "crontab not found. Install a cron package for your distro"
    return 1
  fi

  local script_path
  script_path="$(readlink -f "${BASH_SOURCE[0]}")"
  local cron_line="0 18 * * * ${script_path} run >> $(dirname "${script_path}")/backup.log 2>&1"

  local crontab_cmd=(crontab)
  if [[ "$(id -u)" -eq 0 && "$TARGET_USER" != "root" ]]; then
    crontab_cmd=(crontab -u "$TARGET_USER")
  fi

  if "${crontab_cmd[@]}" -l 2>/dev/null | grep -qF "$script_path run"; then
    echo "Cron job already exists, skipping"
    return
  fi

  ("${crontab_cmd[@]}" -l 2>/dev/null || true; echo "$cron_line") | "${crontab_cmd[@]}" -
  echo "Cron job installed for ${TARGET_USER}: every day at 6 PM. Check with: ${crontab_cmd[*]} -l"

  if ! pgrep -x 'cronie-crond' > /dev/null 2>&1 && ! pgrep -x 'crond' > /dev/null 2>&1 && ! pgrep -x 'cron' > /dev/null 2>&1; then
    echo "WARNING: crontab is installed, but no cron/crond process appears to be running"
    echo "The job will not execute until the daemon is started via your init system"
  fi
}

container_running() {
  docker ps --format '{{.Names}}' | grep -qx "$1"
}

nextcloud_maintenance() {
  container_running nextcloud || return 0
  docker exec -u www-data nextcloud php occ maintenance:mode "--$1" > /dev/null
}

dump_vaultwarden() {
  container_running vaultwarden || return 0

  echo "vaultwarden backup..."
  rm -f ./data/vaultwarden/db_*.sqlite3
  docker exec vaultwarden /vaultwarden backup > /dev/null
  mv ./data/vaultwarden/db_*.sqlite3 "${DUMP_DIR}/vaultwarden.sqlite3"
}

cleanup() {
  rm -f "${DUMP_DIR}/nextcloud_db.sql" "${DUMP_DIR}/vaultwarden.sqlite3"
  nextcloud_maintenance off || true
}

run() {
  local lock_file="/tmp/homeserver-backup.lock"
  exec 200>"$lock_file"
  flock -n 200 || { echo "Another backup run is already in progress, exiting"; exit 1; }

  mkdir -p "$DUMP_DIR"

  trap cleanup EXIT

  echo "nextcloud maintenance mode on..."
  nextcloud_maintenance on

  echo "pg_dump nextcloud_db..."
  docker exec nextcloud_db pg_dump --no-owner --no-privileges -U "${NEXTCLOUD_DB_USER}" "${NEXTCLOUD_DB_NAME}" > "${DUMP_DIR}/nextcloud_db.sql"

  dump_vaultwarden

  echo "restic backup..."
  restic backup -r "$RESTIC_REPOSITORY" "${BACKUP_PATHS[@]}"

  echo "nextcloud maintenance mode off..."
  nextcloud_maintenance off

  echo "restic forget --prune (retention: ${BACKUP_RETENTION_DAILY} days)..."
  restic forget -r "$RESTIC_REPOSITORY" --keep-daily "${BACKUP_RETENTION_DAILY}" --prune
}

case "${1:-}" in
  --check)  check ;;
  --configure)  configure ;;
  --grant-access)  grant_access ;;
  run)  run ;;
  *) echo "Usage: $0 {--check|--configure|--grant-access|run}"; exit 1 ;;
esac

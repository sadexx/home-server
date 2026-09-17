#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

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

check () {
  is_rclone_remote_configured && is_restic_repo_initialized
}

configure() {
  command -v rclone > /dev/null || { echo "rclone not installed"; exit 1; }
  command -v restic > /dev/null || { echo "restic not installed"; exit 1; }

  if ! is_rclone_remote_configured; then
    echo "Remote '${RCLONE_REMOTE}' not found. Launching rclone config..."
    rclone config
  fi

  if ! is_restic_repo_initialized; then
    echo "Initializing restic-repository: ${RESTIC_REPOSITORY}"
    restic init -r "${RESTIC_REPOSITORY}"
  fi

  read -rp "Initialize cron-job for backup at 6 PM? [y/N] " ans
  [[ "${ans:-}" == "y" ]] && install_cron_job

  echo "Installation complete"
}

install_cron_job() {
  local script_path
  script_path="$(readlink -f "${BASH_SOURCE[0]}")"
  local cron_line="0 18 * * * ${script_path} run >> $(dirname "${script_path}")/backup.log 2>&1"

  if crontab -l 2>/dev/null | grep -qF "$script_path run"; then
    echo "This cron-job already exists, skipping"
    return
  fi

  (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
  echo "Cron-job successfully initialized: every day at 6 PM. You can check: crontab -l"
}

run() {
  mkdir -p "$DUMP_DIR"

  echo "pg_dump nextcloud_db..."
  docker exec nextcloud_db pg_dump -U "${NEXTCLOUD_DB_USER}" "${NEXTCLOUD_DB_NAME}" > "${DUMP_DIR}/nextcloud_db.sql"
  
  echo "restic backup..."
  restic backup -r "$RESTIC_REPOSITORY" "${BACKUP_PATHS[@]}"

  echo "restic forget --prune (retention: ${BACKUP_RETENTION_DAILY} days)..."
  restic forget -r "$RESTIC_REPOSITORY" --keep-daily "${BACKUP_RETENTION_DAILY}" --prune

  rm -f "${DUMP_DIR}/nextcloud_db.sql"
}

case "${1:-}" in
  --check)  check ;;
  --configure)  configure ;;
  run)  run ;;
  *) echo "Usage: $0 {--check|--configure|run}"; exit 1 ;;
esac

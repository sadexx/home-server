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
DB_DUMP_FILE="${DUMP_DIR}/nextcloud_db.sql"

has_snapshots() {
  local count
  count="$(restic snapshots -r "$RESTIC_REPOSITORY" --json 2>/dev/null | grep -c '"id"' || true)"
  [[ "$count" -gt 0 ]]
}

wait_for_db_healthy() {
  local retries=30
  echo "Waiting for nextcloud-db to become healthy..."
  while (( retries > 0 )); do
    local status
    status="$(docker inspect --format '{{.State.Health.Status}}' nextcloud_db 2>/dev/null || echo "starting")"
    if [[ "$status" == "healthy" ]]; then
      return 0
    fi
    sleep 2
    ((retries--))
  done
  echo "ERROR: nextcloud-db did not became healthy in time"
  return 1
}

import_nextcloud_db() {
  if [[ ! -f "$DB_DUMP_FILE" ]]; then
    echo "No nextcloud_db.sql dump found at ${DB_DUMP_FILE}, skipping DB import"
    return 0
  fi
  
  echo "Starting nextcloud-db..."
  docker compose up -d nextcloud-db

  wait_for_db_healthy || return 1

  echo "Importing nextcloud_db.sql into nextcloud-db..."
  docker exec -i nextcloud_db psql -U "${NEXTCLOUD_DB_USER}" -d "${NEXTCLOUD_DB_NAME}" < "$DB_DUMP_FILE"

  echo "Database import complete"
  rm -f "$DB_DUMP_FILE"

  echo "Stopping nextcloud-db..."
  docker compose down nextcloud-db
}

restore() {
  if ! has_snapshots; then
    echo "No snapshots found in ${RESTIC_REPOSITORY}. Nothing to restore"
    return 1
  fi

  echo "Restoring latest snapshot from ${RESTIC_REPOSITORY} into ./data ..."
  restic restore latest -r "$RESTIC_REPOSITORY" --target .

  chown -R "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" ./data/omniroute

  import_nextcloud_db

  echo "Restore complete"
}

case "${1:-}" in
  --has-snapshots) has_snapshots ;;
  restore) restore ;;
  *) echo "Usage: $0 {--has-snapshots|restore}"; exit 1 ;;
esac

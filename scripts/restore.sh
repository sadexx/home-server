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
  # counting '"id"' occurrences instead of parsing json properly - avoids a jq dependency
  local count
  count="$(restic snapshots -r "$RESTIC_REPOSITORY" --json 2>/dev/null | grep -c '"id"' || true)"
  [[ "$count" -gt 0 ]]
}

fix_ownership() {
  echo "Fixing ownership after restore..."

  if [[ -d ./data/nextcloud_db ]]; then
    sudo chown -R 70:70 ./data/nextcloud_db  # 70 = postgres uid/gid inside postgres:16-alpine image
  fi

  sudo chown -R 33:33 ./data/nextcloud/html  # 33 = www-data uid/gid inside nextcloud:apache image
  sudo chown -R 33:33 ./data/nextcloud/data
  
  chown -R "${PUID}:${PGID}" ./data/omniroute
  chown -R "${PUID}:${PGID}" ./data/_pg_dump 2>/dev/null || true

  ./scripts/backup.sh --grant-access
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

restore_vaultwarden_db() {
  local dump="${DUMP_DIR}/vaultwarden.sqlite3"
  [[ -f "$dump" ]] || return 0

  echo "Restoring vaultwarden database from dump..."
  rm -f ./data/vaultwarden/db.sqlite3-wal ./data/vaultwarden/db.sqlite3-shm
  mv "$dump" ./data/vaultwarden/db.sqlite3
}

fix_nextcloud_db_credentials() {
  [[ -f ./data/nextcloud/html/config/config.php ]] || return 0

  # config.php in the snapshot has the OLD db password baked in and maintenance=true
  # (set by nextcloud_maintenance on during backup) - both must be corrected before
  # nextcloud can start against the freshly-imported db below
  echo "Pointing nextcloud config at database user ${NEXTCLOUD_DB_USER} and disabling maintenance mode..."
  docker compose run --rm -T --no-deps -u www-data --entrypoint php \
    -e DB_USER="$NEXTCLOUD_DB_USER" -e DB_PASS="$NEXTCLOUD_DB_PASSWORD" nextcloud \
    -r '$f = "/var/www/html/config/config.php"; include $f; $CONFIG["dbuser"] = getenv("DB_USER"); $CONFIG["dbpassword"] = getenv("DB_PASS"); $CONFIG["maintenance"] = false; file_put_contents($f, "<?php\n\$CONFIG = " . var_export($CONFIG, true) . ";\n");' \
    < /dev/null
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

  echo "Stopping containers (if running)..."
  docker compose down --remove-orphans 2>/dev/null || true

  local tmp_dir
  tmp_dir="$(mktemp -d ./.restore.XXXXXX)"

  echo "Restoring latest snapshot from ${RESTIC_REPOSITORY} into ${tmp_dir} ..."
  if ! restic restore latest -r "$RESTIC_REPOSITORY" --target "$tmp_dir"; then
    echo "ERROR: restic restore failed, ./data left untouched"
    rm -rf "$tmp_dir"
    return 1
  fi

  if [[ ! -d "$tmp_dir/data" ]]; then
    echo "ERROR: data dir not found in snapshot, ./data left untouched"
    rm -rf "$tmp_dir"
    return 1
  fi

  echo "Replacing ./data with restored data"
  if [[ -d ./data ]]; then
    rm -rf ./data 2>/dev/null || sudo rm -rf ./data
  fi
  mv "$tmp_dir/data" ./data
  rm -rf "$tmp_dir"

  fix_ownership

  restore_vaultwarden_db

  fix_nextcloud_db_credentials

  import_nextcloud_db

  echo "Restore complete"
}

case "${1:-}" in
  --has-snapshots) has_snapshots ;;
  restore) restore ;;
  *) echo "Usage: $0 {--has-snapshots|restore}"; exit 1 ;;
esac

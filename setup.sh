#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

source ./scripts/resolve-user.sh
resolve_target_user

fresh_install=0
[[ -d data ]] || fresh_install=1

mkdir -p \
  data/portainer \
  data/vaultwarden \
  data/pihole/etc-pihole \
  data/pihole/etc-dnsmasq.d \
  data/omniroute \
  data/nextcloud/html \
  data/nextcloud/data \
  data/nextcloud_db \
  data/nextcloud_redis

source .env

chown -R "${PUID}:${PGID}" data/omniroute

tailscale serve --bg --https="${PORTAINER_HTTPS_PORT}" "https+insecure://127.0.0.1:${PORTAINER_HTTPS_PORT}"
tailscale serve --bg --https="${VAULTWARDEN_HTTP_PORT}" "http://127.0.0.1:${VAULTWARDEN_HTTP_PORT}"
tailscale serve --bg --https="${PIHOLE_HTTP_PORT}" "http://127.0.0.1:${PIHOLE_HTTP_PORT}"
tailscale serve --bg --https="${OMNIROUTE_PORT}" "http://127.0.0.1:${OMNIROUTE_PORT}"
tailscale serve --bg --https="${NEXTCLOUD_HTTPS_PORT}" "http://127.0.0.1:${NEXTCLOUD_HTTP_PORT}"

if [ -t 0 ]; then
  if ! ./scripts/backup.sh --check; then
    read -rp "Backups not configured. Configure now? [y/N] " ans
    [[ "${ans:-}" == "y" ]] && ./scripts/backup.sh --configure
  fi

  if [[ "$fresh_install" == "1" ]] && ./scripts/restore.sh --has-snapshots; then
    read -rp "Existing backups found in the repository. Restore data now? [y/N] " restore_ans
    [[ "${restore_ans:-}" == "y" ]] && ./scripts/restore.sh restore
  fi
fi

docker compose pull
docker compose up -d

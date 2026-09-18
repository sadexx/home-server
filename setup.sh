#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

source ./scripts/resolve-user.sh
resolve_target_user

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

export PUID="$(id -u "$TARGET_USER")"
export PGID="$(id -g "$TARGET_USER")"
chown -R $PUID:$PGID data/omniroute

source .env

tailscale serve --bg --https="${PORTAINER_HTTPS_PORT}" "https+insecure://127.0.0.1:${PORTAINER_HTTPS_PORT}"
tailscale serve --bg --https="${VAULTWARDEN_HTTP_PORT}" "http://127.0.0.1:${VAULTWARDEN_HTTP_PORT}"
tailscale serve --bg --https="${PIHOLE_HTTP_PORT}" "http://127.0.0.1:${PIHOLE_HTTP_PORT}"
tailscale serve --bg --https="${OMNIROUTE_PORT}" "http://127.0.0.1:${OMNIROUTE_PORT}"
tailscale serve --bg --https="${NEXTCLOUD_HTTPS_PORT}" "http://127.0.0.1:${NEXTCLOUD_HTTP_PORT}"

if [ -t 0 ] && ! ./backup.sh --check; then
  read -rp "Backups not configured. Configure now? [y/N] " ans
  [[ "${ans:-}" == "y" ]] && ./scripts/backup.sh --configure
fi

docker compose pull
docker compose up

# Home Server

Self-hosted stack (Portainer, Vaultwarden, Pi-hole, Omniroute, Nextcloud), exposed only
over [Tailscale](https://tailscale.com) - no ports open to the internet. Encrypted,
off-site backups via [restic](https://restic.net) + [rclone](https://rclone.org).

## Services

| Service | Purpose | Access |
|---|---|---|
| Portainer | Docker management UI | `https://<host>.<tailnet>.ts.net:<PORTAINER_HTTPS_PORT>` |
| Vaultwarden | Bitwarden-compatible password manager | `https://<host>.<tailnet>.ts.net:<VAULTWARDEN_HTTP_PORT>` |
| Pi-hole | Network-wide DNS ad-blocking | DNS on `PIHOLE_DNS_BIND_ADDR:53`, UI on `https://<host>.<tailnet>.ts.net:<PIHOLE_HTTP_PORT>` |
| Omniroute | (see image docs) | `https://<host>.<tailnet>.ts.net:<OMNIROUTE_PORT>` |
| Nextcloud | File sync/storage | `https://<host>.<tailnet>.ts.net:<NEXTCLOUD_HTTPS_PORT>` |

Actual URLs are printed by `tailscale serve status` after setup.

## Prerequisites

- Docker + Docker Compose plugin
- [Tailscale](https://tailscale.com/download) installed and logged in (`tailscale up`),
  with [HTTPS/serve enabled](https://tailscale.com/kb/1153/enabling-https) on the tailnet
- `rclone` and `restic` (only needed to configure backups - `setup.sh` will remind you)
- `acl` package (provides `setfacl`, used to grant your user read access to backed-up
  Nextcloud data without breaking container ownership)

## First-time setup

```sh
cp .env.example .env
```

Edit `.env` and fill in every `CHANGE_ME` value:

- Domains (`*_DOMAIN`, `*_BASE_URL`, `NEXTCLOUD_TRUSTED_DOMAINS`, ...) - use your
  tailnet's `.ts.net` hostname.
- `PIHOLE_DNS_BIND_ADDR` - your host's Tailscale IP (`tailscale ip -4`), so Pi-hole's DNS
  port is only reachable over the tailnet.
- Passwords/secrets - generate with `openssl rand -base64 32` (or similar). Store a copy
  somewhere other than this server.
- `PUID`/`PGID` - your host user's uid/gid (`id -u`, `id -g`), so Omniroute's data stays
  readable/writable by you outside the container.

Then run:

```sh
sudo ./setup.sh
```

This creates `data/`, fixes ownership, registers Tailscale Serve routes for every
service, and brings the stack up. On first run it also offers to configure backups and,
if snapshots already exist in the configured restic repo, offers to restore before
starting (see below).

## Day-to-day

```sh
docker compose up -d      # start/update
docker compose down       # stop
docker compose pull       # pull newer images (also done automatically by setup.sh)
docker compose logs -f <service>
```

Config lives in `.env` (git-ignored) and `docker-compose.yml`. Data lives in `data/`
(git-ignored), one subdirectory per service.

## Backups

```sh
./scripts/backup.sh --check       # is backup fully configured?
./scripts/backup.sh --configure   # interactive: rclone remote, restic repo, cron job
./scripts/backup.sh run           # run a backup now (also runs daily at 6 PM via cron once configured)
```

A backup run: puts Nextcloud in maintenance mode, `pg_dump`s the Nextcloud DB, dumps the
Vaultwarden sqlite DB, `restic backup`s everything to the configured remote (encrypted),
takes Nextcloud out of maintenance mode, then prunes snapshots older than
`BACKUP_RETENTION_DAILY` days. A lock file prevents overlapping runs.

**`RESTIC_PASSWORD` is required to decrypt backups - losing it makes them unrecoverable.
Store it somewhere other than this server.**

## Restore

```sh
./scripts/restore.sh --has-snapshots   # any snapshots in the repo?
./scripts/restore.sh restore           # stop stack, restore latest snapshot, fix ownership, reimport DBs
```

`setup.sh` runs this automatically on a fresh install (empty `data/`) if snapshots exist
in the repo configured in `.env`. Run it manually to roll back to the latest snapshot -
**this replaces the entire `data/` directory**. After it finishes, start the stack again
with `docker compose up -d`.

## Networking notes

- Every service binds to `127.0.0.1` (or the Tailscale IP for Pi-hole DNS) - nothing is
  reachable from the LAN or internet directly. `tailscale serve` exposes each one over
  HTTPS on the tailnet only.
- Nextcloud's database and Redis sit on an `internal: true` Docker network - unreachable
  from anywhere except the Nextcloud containers themselves.

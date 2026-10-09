# Provision Trinity on Vultr

Vultr support arrived after v0.9.5 (#2282 / #3224). `start.sh --provision --cloud vultr` is rejected by v0.9.5 and earlier, so everything here needs a later release tag.

There are two ways in, and both run the same installer and end on the same hosted stack: `/opt/trinity`, prebuilt GHCR images, Caddy serving HTTPS on the server's IP, bundled PostgreSQL.

| Path | Admin account | Recorded install source |
|------|---------------|-------------------------|
| **Script install** on your own instance | Password you supply, or one generated and printed | `script` |
| **Marketplace app** (imageless; listing status unconfirmed) | First visitor to `https://<ip>` creates it | `vultr-marketplace` |

## Recommended Specs

| Resource | Value |
|----------|-------|
| Plan | 8 GB RAM minimum (`vc2-4c-8gb` is what upstream measured on). Below that the first-boot script warns and installs anyway; agents and the platform then contend for memory |
| OS | Ubuntu 24.04 (the installer adds Docker from Docker's Ubuntu repository) |
| Network | A public **IPv4** address. The certificate is issued for it |
| Architecture | x86_64. The prebuilt images are `linux/amd64` only |

## Script install

On a fresh instance, as root:

```bash
git clone --depth 1 --branch <release-tag> https://github.com/abilityai/trinity.git /opt/trinity
cd /opt/trinity
ADMIN_PASSWORD='your-password-here' ./scripts/deploy/start.sh --provision --cloud vultr --hosted --unattended
```

What it does:

1. Reads the public IP from Vultr's metadata service (`http://169.254.169.254/v1/interfaces/0/ipv4/address`). It refuses to run unless it is root on Linux and that service answers.
2. Installs Docker, Caddy and ufw (22/80/443), plus the `TRINITY-FW` container firewall: no Docker-published port is reachable off-box, and containers cannot reach the metadata service.
3. Writes `FRONTEND_PORT=8081` (Caddy owns 80 and 443) and `FRONTEND_URL=https://<ip>` to `/opt/trinity/.env`.
4. Gets a Let's Encrypt certificate for the IP and installs `trinity-ip-refresh.timer`.
5. Runs the hosted install on the bundled PostgreSQL.

Without `ADMIN_PASSWORD`, `--unattended` generates a password and prints it in the end-of-run summary. A hand-run install records provenance `script`, so the first-run "Secure this instance" card is not shown; the hardening steps still apply (`docs/user-docs/guides/deploying/hardening.md` on the server).

After signing in as `admin`, finish the **Connect Claude** step: paste a subscription token from `claude setup-token` or an Anthropic API key.

## Marketplace app (imageless)

Vultr runs `scripts/deploy/vultr-vendor-data.sh` once, as root, on a clean Ubuntu 24.04 at first boot. There is no snapshot. The same file works as plain **User Data** on any Vultr instance, which is how to try it before the listing exists; it still records `vultr-marketplace`, so use a throwaway instance.

The script:

- resolves the latest stable release (`releases/latest`, never a pre-release) and aborts if it cannot; `TRINITY_IMAGE_TAG` overrides it;
- clones that tag to `/opt/trinity`;
- exports `ADMIN_PASSWORD_SOURCE=browser`, so nothing secret sits in instance metadata;
- runs `start.sh --provision --cloud vultr --provenance vultr-marketplace --hosted --unattended`.

First boot takes about 4 minutes (apt plus a ~1.6 GB image pull).

**Open `https://<ip>` as soon as it is up.** The first person to open it creates the admin account, and until someone does, anyone who finds the address can. A never-opened instance that shows a login page instead of the create-admin form was claimed by someone else: destroy it and start again.

**Until a stable release contains `--cloud vultr`, this path cannot complete**: `releases/latest` is v0.9.5, whose `start.sh` rejects the flag.

## If first boot fails

```bash
tail -100 /var/log/trinity-install.log
ls /etc/trinity/            # ready | firstboot-failed | release | plan-warning
```

The log is appended across attempts, so an earlier `FAILED` line can sit above a later success. Read from the last `=== Trinity first boot: <timestamp> ===` header down, or trust the markers, which the script clears on every entry.

Retry by re-running the installer. The clone is guarded, so it resumes:

```bash
cd /opt/trinity && sudo ./scripts/deploy/start.sh \
    --provision --cloud vultr --provenance vultr-marketplace --hosted --unattended
```

Do **not** run `cloud-init clean`: it also re-runs Vultr's own instance configuration.

## Day two

```bash
cd /opt/trinity
docker compose -f docker-compose.hosted.yml ps     # status
./scripts/deploy/stop.sh                           # stop (never `down`)
./scripts/deploy/start.sh --hosted                 # start, and apply .env changes
```

Upgrade: pin the new release in `.env`, check out the matching tag, re-run `start.sh --hosted` (or `scripts/update.sh` from this repo, which does the last two).

Back up `/opt/trinity/.env`. It holds `CREDENTIAL_ENCRYPTION_KEY` and `POSTGRES_PASSWORD`, the only password that opens the database volume. Nightly database dumps land in `/opt/trinity/trinity-data/backups/`, on the instance's own disk: take Vultr snapshots as well.

## Point this ops agent at it

```bash
SSH_HOST=<PUBLIC_IP>
SSH_USER=root
TRINITY_PATH=/opt/trinity
COMPOSE_FILE=docker-compose.hosted.yml
FRONTEND_PORT=8081
BACKEND_PORT=8000
```

The backend port is not reachable from outside the instance (the firewall drops it). API calls from this agent go through `scripts/run.sh` against `localhost`, or via `scripts/tunnel.sh`.

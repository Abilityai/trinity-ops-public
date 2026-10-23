# Provision Trinity on DigitalOcean

## Prerequisites

```bash
# Install doctl
brew install doctl              # macOS
# or: https://docs.digitalocean.com/reference/doctl/how-to/install/

doctl auth init                 # Paste API token from cloud.digitalocean.com/api/tokens
doctl account get               # Verify auth
```

## One-command install (Trinity ≥ 0.9.5, recommended)

Upstream ships `scripts/deploy/trinity-do-create.sh` (#2380 / #2707). The user guide is at https://docs.ability.ai/getting-started/deploying/digitalocean; its source is `app/getting-started/deploying/digitalocean/page.tsx` in the `trinity-docs` repo.

**Two versions of the script are in circulation.** Fetched from the `v0.9.5` tag it asks for a Claude subscription token and registers it for you. Fetched from `v1.0.0` or later (#2867) it does not: there are three questions instead of four, the droplet's user-data carries only the admin password, and you connect Claude in the browser after signing in. A 1.0 droplet also runs on the bundled PostgreSQL (#3159) rather than SQLite. Where the two differ, both are described below.

### Before you run it

| Need | How |
|------|-----|
| `doctl`, signed in | `brew install doctl` (Linux/WSL: DigitalOcean's install guide). Create an API token with **Write** scope at cloud.digitalocean.com/account/api/tokens, then `doctl auth init`. The script checks both before asking anything. |
| Claude subscription token | Claude Pro or Max. In another terminal run `claude setup-token` and copy the **`sk-ant-oat01-…`** value. Claude Code is needed for this step (WSL on Windows). The v0.9.5 script asks for it and rejects an `sk-ant-api03-…` API key. A later script never asks: you paste the token **or** an Anthropic API key into the browser's "Connect Claude" step. |
| A password | 12+ characters, and it may **not start with** `password`, `admin`, `trinity`, `changeme` or `letmein`. Use mixed case, digits and symbols. The username is always `admin`. |
| Budget | About **$48/month** (`s-4vcpu-8gb`; hosted mode needs 8 GB) until you destroy the droplet. |

### Run

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/abilityai/trinity/<tag>/scripts/deploy/trinity-do-create.sh)
```

`<tag>` is the release you want, e.g. `v1.0.0`, and the script deploys that same tag as its default `TRINITY_IMAGE_TAG`. Use a release tag, never an `-rc` one: the pre-release rc4 **1-Click image** never served HTTPS (#2862, fixed in v0.9.5). Override the tag with `TRINITY_IMAGE_TAG=… bash <(…)`. At `v1.0.0` the script's default tag is `v1.0.0`. The live DigitalOcean 1-Click listing (`marketplace.digitalocean.com/apps/trinity`) is the other route; it lets you pick a plan below the 8 GB floor (#3009), so choose at least 8 GB.

Prompts, in order:
1. Password, then the same password again. Secrets are read with `read -rs`, so they are not echoed and stay out of shell history.
2. The subscription token (v0.9.5 script only).
3. Region: `fra1` (default), `nyc3`, `sfo3`, `lon1` or `sgp1`.
4. Droplet name (default `trinity`).
5. A summary showing the cost, answered `y/N`.

### What happens

- **On your machine:** the user-data is written to a 0600 temp file and deleted on exit. A snap-installed `doctl` gets that file under `$HOME`, because snap gives it a private `/tmp`. The script attaches every SSH key already on your DigitalOcean account, then creates an Ubuntu 24.04 `s-4vcpu-8gb` droplet.
- **On the droplet's first boot** (logged to `/var/log/trinity-install.log`):
  1. Clone `<tag>` into `/opt/trinity`.
  2. Run `start.sh --provision --cloud digitalocean --hosted --unattended`: Docker CE; Caddy (pinned 2.11.4) serving **HTTPS on the bare IP** with a short-lived (~6-day, auto-renewed) Let's Encrypt certificate; ufw on 22/80/443; the `TRINITY-FW` Docker firewall, so no published port is reachable off-box and containers cannot reach the metadata service; then the prebuilt GHCR images with `TRINITY_IMAGE_TAG` pinned in `.env`.
  3. The admin is created from your password, so there is **no browser-claim window**, unlike the Marketplace 1-Click image.
  4. v0.9.5 script only: register your token as subscription `claude-subscription` and attach it to every seeded agent. Agents created later pick it up automatically. A later script skips this and finishes with `=== Trinity is ready at https://<ip> ===`.
- **Back on your machine:** it polls `https://<ip>/` with full certificate verification. That takes about 6 minutes; after **15 minutes** it gives up and prints recovery steps.

When it finishes:
1. Open `https://<ip>` and sign in as `admin`.
2. On a later-tag droplet, complete **Connect Claude** first: it is the one blocking step. Paste a subscription token or an API key; Trinity validates it with Anthropic and hands it to every agent that has none.
3. Complete the first-run **"Secure this instance"** step.

On the box: `FRONTEND_PORT=8081` (Caddy owns 80/443) and `TRINITY_INSTALL_SOURCE=do-script`. A later-tag droplet also has a `trinity-postgres` container and `POSTGRES_PASSWORD` in `/opt/trinity/.env`: back that file up, since it holds the only password that opens the database volume.

Upgrade in three steps, because the droplet is a `--depth 1 --branch <tag>` clone and the checkout has to move with the images:

```bash
cd /opt/trinity
echo 'TRINITY_IMAGE_TAG=<new-tag>' >> .env          # the last line wins
git fetch --depth 1 origin tag <new-tag> && git checkout <new-tag>
sudo ./scripts/deploy/start.sh --hosted
```

`scripts/update.sh` in this repo does the checkout and the start once the tag is pinned. Never use `docker compose pull` or `down`. Upgrading a v0.9.5 droplet across #3159 keeps it on SQLite: `start.sh` writes an empty `DATABASE_URL=` and starts an idle `trinity-postgres` beside it. Do not delete that line.

### Custom domain (optional)

1. Point an `A` record at the droplet's IP and wait for `dig +short <domain>` to return it. On Cloudflare DNS, set the record to **DNS only** (grey cloud) unless you are putting a Cloudflare Tunnel in front.
2. In Trinity: **Settings → General → Public URL** = `https://<domain>`. Saving it **immediately** re-points Telegram webhooks and WhatsApp bindings, so make sure DNS is live first. A value that cannot work, such as `htp://…`, is rejected with a 422.
3. Open `https://<domain>` in a browser. The first request is what gets the certificate: Caddy asks `GET /api/public/tls-allowed?domain=`, which returns 200 only for the saved host. Settings reads "saved, waiting for the first visit" until that has happened.

### Hardening (recommended before real work)

Guide on the box: `docs/user-docs/guides/deploying/hardening.md` (#2692).

- **Cloudflare Tunnel:** set `TUNNEL_TOKEN=…` in `/opt/trinity/.env`, then run `sudo ./scripts/deploy/start.sh --hosted`. That starts the `tunnel` profile and records it in `.env`.
- **Tailscale:** install it only *after* provisioning, because provisioning resets ufw:
  ```bash
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale up --auth-key=tskey-auth-… --ssh --hostname=trinity   # reusable, non-ephemeral key
  # Admin console → Machines → Disable key expiry for this node (required)
  sudo ufw default deny incoming && sudo ufw default allow outgoing
  sudo ufw allow in on tailscale0 && sudo ufw delete allow 22/tcp && sudo ufw enable
  # Browse the UI over the tailnet (plain HTTP to tailnet sources only):
  echo 'PRIVATE_NETWORK_CIDRS="100.64.0.0/10 fd7a:115c:a1e0::/48"' | sudo tee -a /opt/trinity/.env
  cd /opt/trinity && sudo ./scripts/deploy/start.sh --provision --cloud digitalocean --caddy-only
  # → http://<tailnet-ip>   (container ports like :8081 stay dropped by TRINITY-FW)
  ```
- **Both:** in Cloudflare, publish only the callback paths (the path-split rules in `public-access.md`, **without** the `/` catch-all). The tailnet then carries the UI.
- **Then** close 80/443 with a DigitalOcean cloud firewall, and allow 22 from your own IP only (or use the web Console).
  - Closing 80/443 also stops Caddy renewing its local certificates.
  - These stop working without a public path: Telegram, WhatsApp, VoIP, public chat links, agent websites, webhook triggers and inbound A2A.
  - Slack keeps working, because its connection is outbound.

### Troubleshooting

| Symptom | Fix |
|---|---|
| `doctl is not installed` / `not signed in` | `brew install doctl`; `doctl auth init` with a **Write** token |
| "That is an API key, not a subscription token" (v0.9.5 script) | `claude setup-token`, use the `sk-ant-oat01-…` value |
| The script asked for no Claude token and agents cannot run | Expected on a later tag (#2867). Sign in and finish **Connect Claude** |
| After an upgrade the UI shows first-run setup on an old droplet | `/opt/trinity/.env` lost its `DATABASE_URL=` line, so the stack booted the empty bundled PostgreSQL (#3159). Add an empty `DATABASE_URL=` and re-run `start.sh --hosted`; `trinity-data/trinity.db` was not touched |
| "Too guessable" | The password starts with a reserved word (see above) |
| "did not finish within 15 minutes" | Try `https://<ip>` in a browser first. Then open the droplet's **Console** (cloud.digitalocean.com/droplets) and run `tail -50 /var/log/trinity-install.log` |
| Certificate error on the IP | `cat /etc/trinity/tls-status`, `journalctl -u caddy -n 100`; port 80 must be open for ACME |
| Droplet from the pre-release rc4 1-Click image never serves | `/etc/caddy/Caddyfile` is mode 0600 (#2862) and Trinity was never started. Recreate from a v0.9.5 image |
| UI unreachable over the tailnet | Set `PRIVATE_NETWORK_CIDRS`, then run `start.sh --provision --cloud digitalocean --caddy-only` |

### Delete

```bash
doctl compute droplet delete <name>
```

This destroys the server and **all data**, including agents and `/data/backups`. Take a droplet snapshot first if you want to keep anything.

Ops-agent `.env` for such a droplet:

```bash
SSH_HOST=<PUBLIC_IP>
SSH_USER=root
TRINITY_PATH=/opt/trinity
COMPOSE_FILE=docker-compose.hosted.yml
FRONTEND_PORT=8081
BACKEND_PORT=8000
```

Note: the backend port is not reachable from outside the box (the firewall drops it) — API calls from this agent go through `scripts/run.sh` against `localhost`, or via `scripts/tunnel.sh`.

## Manual install (source build)

## Recommended Specs

| Resource | Value | Cost |
|----------|-------|------|
| Size | `s-4vcpu-8gb` (4 vCPU, 8 GB) | $48/month |
| Region | `nyc3` or `fra1` | included |
| OS | Ubuntu 24.04 LTS | free |
| Backups | weekly automated | +$4.80/month |

**Minimum: 8 GB RAM.** Below that the agent containers and the platform services contend and turns start failing under load.

Need more headroom for a larger fleet? Step up to a 16 GB size — `doctl compute size list` shows the ones your account can create.

## Upload Your SSH Key

```bash
# List existing keys
doctl compute ssh-key list

# Add a new key
doctl compute ssh-key create trinity-key \
  --public-key "$(cat ~/.ssh/id_rsa.pub)"

# Get the key ID
KEY_ID=$(doctl compute ssh-key list --no-header --format ID,Name | grep trinity-key | awk '{print $1}')
echo "Key ID: $KEY_ID"
```

## Create the Droplet

```bash
# Cloud-init: install Docker
cat > /tmp/trinity-init.sh << 'EOF'
#!/bin/bash
set -e
apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 git curl jq
systemctl enable docker && systemctl start docker
usermod -aG docker ubuntu || true
EOF

# Create droplet
doctl compute droplet create trinity-server \
  --region nyc3 \
  --image ubuntu-24-04-x64 \
  --size s-4vcpu-8gb \
  --ssh-keys $KEY_ID \
  --user-data-file /tmp/trinity-init.sh \
  --enable-monitoring \
  --wait \
  --format Name,PublicIPv4,Status
```

## Get the IP

```bash
doctl compute droplet get trinity-server --format PublicIPv4 --no-header
```

## SSH in

```bash
PUBLIC_IP=$(doctl compute droplet get trinity-server --format PublicIPv4 --no-header)
ssh -i ~/.ssh/id_rsa root@$PUBLIC_IP
```

Note: DigitalOcean droplets use `root` by default unless you configure otherwise.

## Install Trinity on the Droplet

SSH in, then:

```bash
# Add a non-root user (recommended)
adduser --disabled-password --gecos "" trinity
usermod -aG docker trinity
usermod -aG sudo trinity

# Install Trinity
su - trinity -c "
  git clone https://github.com/abilityai/trinity.git ~/trinity
  cd ~/trinity
  cp .env.example .env
"
nano /home/trinity/trinity/.env
# Set: ADMIN_PASSWORD, SECRET_KEY, MCP_API_KEY, ANTHROPIC_API_KEY

su - trinity -c "cd ~/trinity && ./scripts/deploy/build-base-image.sh && ./scripts/deploy/start.sh"
# (start.sh, not a bare `compose up`: it generates the remaining secrets, probes DOCKER_GID,
#  chowns the data dir and refuses a dev/prod data-store mix-up, #2390)
```

## Configure the ops agent

In this agent's `.env`:

```bash
SSH_HOST=<PUBLIC_IP>
SSH_USER=root                    # or trinity if you created the user
SSH_KEY=~/.ssh/id_rsa
TRINITY_PATH=/root/trinity       # or /home/trinity/trinity
BACKEND_PORT=8000
FRONTEND_PORT=80
MCP_PORT=8180
SCHEDULER_PORT=8001
ADMIN_PASSWORD=<your-admin-password>
MCP_API_KEY=<your-mcp-key>
```

## Add a Firewall (optional but recommended)

```bash
# Create a firewall allowing only necessary ports
doctl compute firewall create \
  --name trinity-fw \
  --inbound-rules "protocol:tcp,ports:22,address:0.0.0.0/0,address:::/0 protocol:tcp,ports:80,address:0.0.0.0/0,address:::/0 protocol:tcp,ports:443,address:0.0.0.0/0,address:::/0 protocol:tcp,ports:8000,address:0.0.0.0/0,address:::/0 protocol:tcp,ports:8180,address:0.0.0.0/0,address:::/0" \
  --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0" \
  --droplet-ids $(doctl compute droplet get trinity-server --format ID --no-header)
```

## Teardown

```bash
doctl compute droplet delete trinity-server --force
```

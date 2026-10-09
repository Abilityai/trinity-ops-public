---
name: provision
description: Guide for provisioning a new Trinity server on any cloud provider or localhost.
allowed-tools: Bash, Read
argument-hint: [hetzner|gcp|aws|digitalocean|vultr|localhost]
---

# Provision a New Trinity Instance

Guide the user through provisioning and connecting a new Trinity server.

## Instructions

### 1. Determine Provider

Parse argument or ask the user which provider they want:
- `hetzner` / `h` → Hetzner Cloud (cheapest at €3.49/mo)
- `gcp` / `google` → Google Cloud
- `aws` / `amazon` → Amazon Web Services
- `digitalocean` / `do` → DigitalOcean
- `vultr` → Vultr (needs a release after v0.9.5)
- `localhost` / `local` → local machine

If not provided, present the options:

```
## Cloud Provider Options

| Provider | Size | Cost | Guide |
|----------|------|------|-------|
| Hetzner | CX23 (2 vCPU, 4GB) | €3.49/mo | provision/hetzner.md |
| DigitalOcean | s-2vcpu-4gb (manual) · s-4vcpu-8gb (one-command, hosted images) | $24 · $48/mo | provision/digitalocean.md |
| AWS | t3.medium (manual) · t3a.large 8 GiB (one-command, after v0.9.5) | ~$30/mo · more | provision/aws.md |
| Vultr | 8 GB plan (one-command, after v0.9.5) | plan price | provision/vultr.md |
| GCP | e2-medium (2 vCPU, 4GB) | ~$40/mo | provision/gcp.md |
| Localhost | Any OS with Docker | Free | provision/localhost.md |
```

**DigitalOcean has an upstream one-command path since v0.9.5** (#2380/#2707): `trinity-do-create.sh` run on the operator's machine creates the droplet, provisions Docker + Caddy (HTTPS on the bare IP) + firewalls, and installs from prebuilt images with the admin pre-provisioned. Offer it first for DO. Before the user runs it, confirm they have:
- `doctl` signed in with a **Write**-scoped API token (`doctl auth init`);
- a Claude Pro/Max token from `claude setup-token` (**`sk-ant-oat01-…`**). The v0.9.5 script asks for it and rejects an `sk-ant-api03` API key. A script from a later tag (#2867) asks three questions, not four, and never asks for it: the user pastes a token or an API key in the browser's **Connect Claude** step after signing in;
- a password of 12+ characters that does not start with password/admin/trinity/changeme/letmein;
- budget for about $48/month (`s-4vcpu-8gb`, since hosted mode needs 8 GB).

Have them run the script from a release tag (`v0.9.5` or later, never an `-rc` tag; the pre-release rc4 **1-Click image** never served HTTPS, #2862). It takes about 6 minutes and times out at 15; on a timeout the droplet Console shows `tail -50 /var/log/trinity-install.log`. Afterwards walk them through "Secure this instance", the optional custom domain (A record, DNS-only on Cloudflare, Public URL, first visit), and hardening (tunnel / Tailscale + `PRIVATE_NETWORK_CIDRS` + `start.sh --provision --cloud digitalocean --caddy-only`). Everything is in `provision/digitalocean.md` → "One-command install". Do not run the script yourself: it prompts for secrets, and the user should type them.

**AWS and Vultr have the same installer after v0.9.5** (`start.sh --provision --cloud aws|vultr --hosted --unattended`, run as root on a fresh Ubuntu 24.04 instance with 8 GB; v0.9.5 and earlier reject both values). Check the tag the user intends to clone before recommending it. Points to walk through:
- **AWS** (`provision/aws.md`): security group open on 80/443 only; with no `ADMIN_PASSWORD` the first admin is claimed in the browser with the **EC2 instance ID**; without an Elastic IP the address changes on stop/start and `trinity-ip-refresh.timer` follows it within five minutes. The Marketplace AMI and the CloudFormation Launch Stack link are not published yet.
- **Vultr** (`provision/vultr.md`): a hand-run install takes or generates an admin password; the Marketplace app is imageless and uses the first-visitor browser claim, so the user must open `https://<ip>` immediately.

Every one-command install after v0.9.5 runs on the **bundled PostgreSQL** and keeps `POSTGRES_PASSWORD` in `/opt/trinity/.env`: tell the user to back that file up.

### 2. Read the Guide

```bash
cat provision/{provider}.md
```

Walk the user through the guide step by step.

### 3. After VM is Created

Once the user has a server IP:

**SSH in and install Trinity:**
```bash
ssh user@<SERVER_IP>

git clone https://github.com/abilityai/trinity.git ~/trinity
cd ~/trinity

cp .env.example .env
nano .env
# Set: ADMIN_PASSWORD, SECRET_KEY, MCP_API_KEY, ANTHROPIC_API_KEY
```

Generate secure values:
```bash
# SECRET_KEY (show user, they paste into .env)
python3 -c "import secrets; print(secrets.token_hex(32))"

# MCP_API_KEY
python3 -c "import secrets; print('trinity_' + secrets.token_hex(16))"
```

Start Trinity — through `start.sh`, not a bare `compose up` (it generates the remaining secrets, probes `DOCKER_GID`, chowns the data dir, and refuses a dev/prod data-store mix-up, #2390):
```bash
./scripts/deploy/build-base-image.sh      # source build only; hosted mode pulls it
./scripts/deploy/start.sh                 # prod stack; or `start.sh --hosted` for prebuilt GHCR images (pin TRINITY_IMAGE_TAG in .env)
sleep 10
curl http://localhost:8000/health
```

Never stack compose files (`-f docker-compose.yml -f docker-compose.prod.yml` breaks on duplicate `group_add` / doubled frontend ports, #2557); each of dev / prod / hosted is a standalone file set.

### 4. Configure This Agent

After Trinity is running, update this agent's `.env`:

```
SSH_HOST=<SERVER_IP>
SSH_USER=<user>
SSH_KEY=~/.ssh/id_rsa          # or SSH_PASSWORD=...
TRINITY_PATH=/home/<user>/trinity    # /opt/trinity on a one-command DO / AWS / Vultr install
COMPOSE_FILE=docker-compose.prod.yml # docker-compose.hosted.yml for a hosted (prebuilt-image) install
BACKEND_PORT=8000
FRONTEND_PORT=80                     # 8081 on a --provision'd host (Caddy owns 80/443)
MCP_PORT=8180
SCHEDULER_PORT=8001
ADMIN_PASSWORD=<your-admin-password>
MCP_API_KEY=<your-mcp-key>
```

### 5. Verify Connection

```bash
./scripts/status.sh
```

Should show backend healthy and all containers running.

### 6. First Steps After Connection

Suggest to the user:
1. Open Trinity at `http://<SERVER_IP>` and log in with `admin` / your password
2. Run `/whitelist your@email.com` to add yourself
3. Create your first agent via the UI
4. Run `/subscription register` to add Claude Max credentials to agents (optional)

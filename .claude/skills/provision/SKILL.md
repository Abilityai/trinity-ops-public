---
name: provision
description: Guide for provisioning a new Trinity server on any cloud provider or localhost.
allowed-tools: Bash, Read
argument-hint: [hetzner|gcp|aws|digitalocean|localhost]
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
- `localhost` / `local` → local machine

If not provided, present the options:

```
## Cloud Provider Options

| Provider | Size | Cost | Guide |
|----------|------|------|-------|
| Hetzner | CX23 (2 vCPU, 4GB) | €3.49/mo | provision/hetzner.md |
| DigitalOcean | s-2vcpu-4gb | $24/mo | provision/digitalocean.md |
| AWS | t3.medium (2 vCPU, 4GB) | ~$30/mo | provision/aws.md |
| GCP | e2-medium (2 vCPU, 4GB) | ~$40/mo | provision/gcp.md |
| Localhost | Any OS with Docker | Free | provision/localhost.md |
```

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

Start Trinity:
```bash
docker compose -f docker-compose.prod.yml up -d
sleep 10
curl http://localhost:8000/health
```

### 4. Configure This Agent

After Trinity is running, update this agent's `.env`:

```
SSH_HOST=<SERVER_IP>
SSH_USER=<user>
SSH_KEY=~/.ssh/id_rsa          # or SSH_PASSWORD=...
TRINITY_PATH=/home/<user>/trinity
BACKEND_PORT=8000
FRONTEND_PORT=80
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

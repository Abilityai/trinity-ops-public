# Trinity Ops Agent

> A universal, single-instance operator for [Trinity](https://github.com/abilityai/trinity) — autonomous agent orchestration infrastructure.
> Manage Trinity anywhere — laptop, any VPS, any cloud — with one `.env` file.

---

## Quick Start

```bash
# 1. Copy credentials template
cp .env.example .env

# 2. Fill in connection details (see .env.example for all options)
#    Leave SSH_HOST empty for a local installation
nano .env

# 3. Test connection
./scripts/status.sh
```

Access Trinity at `http://<SSH_HOST>:<FRONTEND_PORT>` (or `http://localhost:80` if local).

---

## Connection Modes

This agent works in two modes depending on `SSH_HOST` in `.env`:

| Mode | `SSH_HOST` | How commands run |
|------|-----------|-----------------|
| **Local** | *(empty)* | `eval` directly on this machine |
| **Remote** | IP or hostname | SSH (key or password) |

For remote access, `scripts/run.sh` automatically picks key vs. password auth from `.env`.

---

## Operations Guide

### Health Check

```bash
./scripts/status.sh
```

Or ask the agent: "what's the status of my Trinity instance?"

The agent will check:
- Docker container states (`trinity-backend`, `trinity-frontend`, etc.)
- HTTP health endpoints (backend `/health`, frontend, scheduler)
- Redis ping
- Current git version

### View Logs

```bash
# Backend (most useful)
./scripts/run.sh "sudo docker logs trinity-backend --tail 100"

# Scheduler
./scripts/run.sh "sudo docker logs trinity-scheduler --tail 50"

# Agent container
./scripts/run.sh "sudo docker logs agent-myagent --tail 50"

# Errors only
./scripts/run.sh "sudo docker logs trinity-backend --tail 500 2>&1 | grep -iE 'error|exception|traceback'"
```

### Restart Services

```bash
./scripts/restart.sh

# Or a specific container
./scripts/run.sh "sudo docker restart trinity-backend"
```

### Update Trinity

Pulls the latest code, rebuilds Docker images, restarts services, and verifies health:

```bash
./scripts/update.sh
```

### Backup Database

```bash
./scripts/backup.sh
# Saves to /tmp/trinity-<timestamp>.db on the host
```

### Tunnel (remote only)

Opens SSH port-forwarding so you can browse Trinity locally while it's on a remote server:

```bash
./scripts/tunnel.sh
# Then open http://localhost:13000 (or your TUNNEL_FRONTEND port)
```

---

## Agent Management

```bash
source .env

# List agent containers
./scripts/run.sh "sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}' | grep agent-"

# Start / stop agent
./scripts/run.sh "sudo docker start agent-myagent"
./scripts/run.sh "sudo docker stop agent-myagent"

# View agent logs
./scripts/run.sh "sudo docker logs agent-myagent --tail 50"

# Exec into agent
./scripts/run.sh "sudo docker exec -it agent-myagent bash"
```

---

## API Access

```bash
source .env
HOST=${SSH_HOST:-localhost}

# Get admin token
TOKEN=$(curl -s -X POST http://$HOST:${BACKEND_PORT:-8000}/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "username=admin&password=$ADMIN_PASSWORD" | jq -r '.access_token')

# List agents
curl -s -H "Authorization: Bearer $TOKEN" http://$HOST:${BACKEND_PORT:-8000}/api/agents | jq

# Fleet health
curl -s -H "Authorization: Bearer $TOKEN" http://$HOST:${BACKEND_PORT:-8000}/api/ops/fleet/health | jq

# Host telemetry (no auth)
curl -s http://$HOST:${BACKEND_PORT:-8000}/api/telemetry/host | jq
```

---

## Database Operations

```bash
# List tables
./scripts/run.sh "sudo docker run --rm -v trinity_trinity-data:/data alpine sh -c 'apk add --quiet sqlite && sqlite3 /data/trinity.db \".tables\"'"

# Query agents
./scripts/run.sh "sudo docker run --rm -v trinity_trinity-data:/data alpine sh -c \"apk add --quiet sqlite && sqlite3 /data/trinity.db 'SELECT agent_name, owner_id FROM agent_ownership'\""
```

---

## Provisioning a New Instance

Trinity runs on any Linux VM with Docker. Choose your provider:

| Provider | Guide | Cheapest option |
|----------|-------|-----------------|
| **Hetzner** | `provision/hetzner.md` | CX23 at €3.49/month |
| **Google Cloud** | `provision/gcp.md` | e2-medium ~$40/month |
| **AWS** | `provision/aws.md` | t3.medium ~$30/month |
| **DigitalOcean** | `provision/digitalocean.md` | s-2vcpu-4gb $24/month |
| **Localhost** | `provision/localhost.md` | Free |

All guides provision Ubuntu 24.04 with Docker via cloud-init, then walk you through installing Trinity and pointing this ops agent at the instance.

### Minimum Server Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 2 GB | 4 GB |
| Disk | 20 GB | 50 GB |
| OS | Ubuntu 22.04+ | Ubuntu 24.04 |

### Installing Trinity on a Fresh Server

**One-line install (recommended):**

```bash
# SSH into the server
ssh user@<SERVER_IP>

curl -fsSL https://raw.githubusercontent.com/abilityai/trinity/main/install.sh | bash
```

**Manual install:**

```bash
# Clone Trinity
git clone https://github.com/abilityai/trinity.git ~/trinity
cd ~/trinity

# Configure
cp .env.example .env
nano .env
```

Minimum `.env` for Trinity:

```bash
# Required
ADMIN_PASSWORD=your-secure-password         # login password
SECRET_KEY=$(openssl rand -hex 32)          # JWT signing key

# For agents to run
ANTHROPIC_API_KEY=sk-ant-...
```

```bash
# Build base image and start services
./scripts/deploy/build-base-image.sh
./scripts/deploy/start.sh

# Verify
curl http://localhost:8000/health
```

On first launch, open `http://<SERVER_IP>` — the setup wizard will prompt you to set your admin password and configure API keys.

---

## Service Architecture

| Container | Port | Purpose |
|-----------|------|---------|
| `trinity-backend` | 8000 | FastAPI REST API |
| `trinity-frontend` | 80 | Vue.js Web UI |
| `trinity-mcp-server` | 8080 | MCP Protocol Server |
| `trinity-scheduler` | 8001 | Scheduled tasks |
| `trinity-redis` | 6379 | Sessions, credentials |
| `trinity-vector` | 8686 | Log aggregation |
| `agent-{name}` | — | Per-agent isolated containers |

---

## Troubleshooting

### Agent container won't start

Network reference issue — remove and recreate:

```bash
./scripts/run.sh "sudo docker rm agent-myagent"
./scripts/run.sh "sudo docker restart trinity-backend"
# Then start via UI or API
```

### Backend not responding

```bash
./scripts/run.sh "sudo docker logs trinity-backend --tail 100"
./scripts/run.sh "sudo docker restart trinity-backend"
sleep 5
./scripts/run.sh "curl -s http://localhost:${BACKEND_PORT:-8000}/health"
```

### Disk space

```bash
./scripts/run.sh "df -h /"
./scripts/run.sh "sudo docker system df"

# Clean unused Docker resources (dry run first)
./scripts/run.sh "sudo docker system prune --dry-run"
./scripts/run.sh "sudo docker system prune -f"
```

### Out of memory

```bash
./scripts/run.sh "free -h"
./scripts/run.sh "sudo docker stats --no-stream"
```

### Update broke things — rollback

```bash
source .env
HOST=${SSH_HOST:-localhost}
TRINITY=${TRINITY_PATH:-~/trinity}

# Roll back to previous commit
./scripts/run.sh "cd $TRINITY && git log --oneline -10"
./scripts/run.sh "cd $TRINITY && git checkout <prev-commit>"

# Rebuild and restart
./scripts/run.sh "cd $TRINITY && sudo docker compose -f ${COMPOSE_FILE:-docker-compose.prod.yml} build --no-cache backend frontend mcp-server scheduler"
./scripts/run.sh "cd $TRINITY && sudo docker compose -f ${COMPOSE_FILE:-docker-compose.prod.yml} up -d"
```

---

## Environment Variables Reference

### This agent's `.env`

| Variable | Default | Purpose |
|----------|---------|---------|
| `SSH_HOST` | *(empty)* | Server IP/hostname; empty = local |
| `SSH_USER` | `ubuntu` | SSH username |
| `SSH_KEY` | `~/.ssh/id_rsa` | Path to private key |
| `SSH_PASSWORD` | *(empty)* | Password auth fallback |
| `SSH_PORT` | `22` | SSH port |
| `TRINITY_PATH` | `~/trinity` | Trinity install dir on server |
| `COMPOSE_FILE` | `docker-compose.prod.yml` | Docker Compose file to use |
| `FRONTEND_PORT` | `80` | Frontend web UI port |
| `BACKEND_PORT` | `8000` | Backend API port |
| `MCP_PORT` | `8080` | MCP server port |
| `SCHEDULER_PORT` | `8001` | Scheduler health port |
| `ADMIN_PASSWORD` | — | Trinity admin login |
| `MCP_API_KEY` | — | MCP authentication key |
| `TUNNEL_FRONTEND` | `13000` | Local tunnel port for frontend |
| `TUNNEL_BACKEND` | `18000` | Local tunnel port for backend |
| `TUNNEL_MCP` | `18080` | Local tunnel port for MCP |

### Trinity server's `~/trinity/.env`

| Variable | Required | Purpose |
|----------|----------|---------|
| `ADMIN_PASSWORD` | **Yes** | Admin login |
| `SECRET_KEY` | **Yes** | JWT signing |
| `CREDENTIAL_ENCRYPTION_KEY` | **Yes** (production) | Encrypt stored tokens; loss = unrecoverable credentials |
| `INTERNAL_API_SECRET` | Recommended | Scheduler→backend auth |
| `ANTHROPIC_API_KEY` | For agents | Claude API key (or set in Settings UI) |
| `GEMINI_API_KEY` | For avatars/voice | Gemini API key |
| `GITHUB_PAT` | For GitHub templates | Access private agent template repos |
| `PUBLIC_CHAT_URL` | For public links | External URL for public chat |
| `TUNNEL_TOKEN` | For Cloudflare Tunnel | Enable `cloudflared` profile |

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/run.sh "cmd"` | Run command locally or via SSH |
| `scripts/status.sh` | Quick health check |
| `scripts/restart.sh` | Restart all Trinity services |
| `scripts/update.sh` | Pull latest, rebuild, restart |
| `scripts/backup.sh` | Backup SQLite database |
| `scripts/tunnel.sh` | SSH tunnels for local browser access |

---

*Trinity Ops Agent — manage your sovereign AI infrastructure*

# Install Trinity Locally

Run Trinity on your own machine (macOS, Linux, or WSL2 on Windows).

## Prerequisites

- Docker Desktop (macOS/Windows) or Docker Engine (Linux)
- Git
- 8 GB RAM recommended, 4 GB minimum
- 20 GB free disk

## Steps

### 1. Install Docker

**macOS**: https://www.docker.com/products/docker-desktop/
**Linux** (Ubuntu):
```bash
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 git
sudo systemctl enable docker && sudo systemctl start docker
sudo usermod -aG docker $USER  # log out and back in
```
**Windows**: Install Docker Desktop + WSL2 backend.

### 2. Clone Trinity

```bash
git clone https://github.com/abilityai/trinity.git ~/trinity
cd ~/trinity
```

### 3. Configure

```bash
cp .env.example .env
```

Edit `.env` with your values:

```bash
# Minimum required settings
ADMIN_PASSWORD=your-secure-password   # Trinity admin login
SECRET_KEY=$(openssl rand -hex 32)    # JWT signing key
MCP_API_KEY=trinity_$(openssl rand -hex 16)

ANTHROPIC_API_KEY=sk-ant-...          # For running agents
```

### 4. Start

```bash
docker compose -f docker-compose.prod.yml up -d
```

### 5. Access

Open http://localhost:80 and log in with `admin` / your `ADMIN_PASSWORD`.

MCP server: http://localhost:8180/mcp

## Configure this ops agent for localhost

In this agent's `.env`:
```bash
# Leave SSH_HOST empty for local
SSH_HOST=
FRONTEND_PORT=80
BACKEND_PORT=8000
MCP_PORT=8180
SCHEDULER_PORT=8001
ADMIN_PASSWORD=your-secure-password
MCP_API_KEY=your-mcp-api-key
```

Then run `./scripts/status.sh` to verify.

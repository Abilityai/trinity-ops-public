---
name: restart
description: Restart Trinity services (backend, scheduler, frontend, mcp, or all). Verifies health after restart.
disable-model-invocation: true
allowed-tools: Bash, Read
argument-hint: [backend|scheduler|frontend|mcp|all]
automation: gated
---

# Restart Services

## Arguments

- No args / `all` — restart all platform services via compose
- `backend` → `trinity-backend`
- `scheduler` → `trinity-scheduler`
- `frontend` → `trinity-frontend`
- `mcp` → `trinity-mcp-server`

## Instructions

### 1. Verify Context

```bash
ls -la .env scripts/run.sh 2>/dev/null
```

### 2. Load Configuration

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}
```

### 3. Execute Restart

**Specific service:**
```bash
source .env
./scripts/run.sh "sudo docker restart trinity-{service}"
```

**All services:**
```bash
source .env
./scripts/run.sh "cd $TRINITY && sudo docker compose -f $COMPOSE up -d backend frontend mcp-server scheduler"
```

### 4. Wait and Verify

```bash
sleep 8
source .env
BACKEND=$(./scripts/run.sh "curl -s -o /dev/null -w '%{http_code}' http://localhost:${BACKEND_PORT:-8000}/health" 2>/dev/null)
SCHED=$(./scripts/run.sh "sudo docker inspect trinity-scheduler --format='{{.State.Health.Status}}'" 2>/dev/null | tr -d '[:space:]')
echo "Backend: HTTP $BACKEND"
echo "Scheduler: $SCHED"
```

### 5. Report

Report which services were restarted and their health status after restart.

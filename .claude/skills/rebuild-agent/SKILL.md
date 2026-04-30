---
name: rebuild-agent
description: Rebuild agent container(s) against latest base image via Trinity's own recreate function. Preserves workspace, env, mounts, labels.
allowed-tools: Bash, Read
argument-hint: <agent-name> | --all
automation: gated
---

# Rebuild Agent Container

Rebuilds agent containers using Trinity's internal `recreate_container_with_updated_config` function — the same code path Trinity uses internally. This preserves every container field (env vars, mounts, labels, capabilities, resource limits).

**Do NOT** hand-roll `docker create` commands for agent rebuilds — that silently drops fields.

## Arguments

- `<name>` — rebuild one agent (omit the `agent-` prefix)
- `--all` — rebuild all agents on the instance

## Instructions

### 1. Verify Context

```bash
ls -la .env scripts/run.sh 2>/dev/null
```

### 2. Pre-flight Checks

```bash
source .env
# Backend healthy
./scripts/run.sh "curl -s http://localhost:${BACKEND_PORT:-8000}/health" | grep -q ok || { echo "ABORT: backend unhealthy"; exit 1; }

# Recreate function importable (confirms Trinity version supports this)
./scripts/run.sh "sudo docker exec trinity-backend python3 -c 'from services.agent_service.lifecycle import recreate_container_with_updated_config; print(\"ok\")'" | grep -q ok || { echo "ABORT: Trinity backend missing recreate_container_with_updated_config"; exit 1; }

# Base image present
./scripts/run.sh "sudo docker image inspect trinity-agent-base:latest" >/dev/null 2>&1 || { echo "ABORT: trinity-agent-base:latest not found — rebuild base image first"; exit 1; }
```

### 3. Enumerate Target Agents

```bash
source .env
if [ "$1" = "--all" ]; then
  AGENTS=$(./scripts/run.sh "sudo docker ps -a --format '{{.Names}}' | grep '^agent-' | sed 's/^agent-//'")
else
  AGENTS="$1"
  ./scripts/run.sh "sudo docker inspect agent-$AGENTS" >/dev/null 2>&1 || { echo "ABORT: agent-$AGENTS not found"; exit 1; }
fi
echo "Targets: $AGENTS"
```

### 4. Refuse if Agents Have Running Executions

```bash
source .env
TOKEN=$(./scripts/run.sh "curl -s -X POST http://localhost:${BACKEND_PORT:-8000}/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=admin&password=${ADMIN_PASSWORD}'" | jq -r '.access_token' 2>/dev/null)

for AGENT in $AGENTS; do
  RUNNING=$(./scripts/run.sh "curl -s -H 'Authorization: Bearer $TOKEN' \
    http://localhost:${BACKEND_PORT:-8000}/api/agents/$AGENT/executions?limit=50 2>/dev/null" | jq '[.[] | select(.status=="running")] | length' 2>/dev/null || echo 0)
  if [ "${RUNNING:-0}" -gt 0 ]; then
    echo "ABORT: agent $AGENT has $RUNNING running execution(s) — wait for them to finish"
    exit 1
  fi
done
```

### 5. Recreate Each Agent

```bash
source .env
for AGENT in $AGENTS; do
  echo "=== Rebuilding $AGENT ==="
  ./scripts/run.sh "sudo docker exec trinity-backend python3 -c \"
import asyncio, docker
from services.agent_service.lifecycle import recreate_container_with_updated_config
from database import db

name = '$AGENT'
client = docker.from_env()
old = client.containers.get(f'agent-{name}')

raw_owner = db.get_agent_owner(name)
if isinstance(raw_owner, dict):
    owner = raw_owner.get('owner_username') or 'admin'
elif isinstance(raw_owner, str) and raw_owner:
    owner = raw_owner
else:
    owner = 'admin'

old_image_tag = old.attrs.get('Config', {}).get('Image', 'unknown')
print(f'Recreating {name} (owner={owner}, old tag={old_image_tag})')

new = asyncio.run(recreate_container_with_updated_config(name, old, owner))
new.reload()
print(f'OK: {new.short_id} status={new.status}')
\""
done
```

### 6. Verify Each Agent

```bash
source .env
for AGENT in $AGENTS; do
  STATUS=$(./scripts/run.sh "sudo docker inspect agent-$AGENT --format '{{.State.Status}}'" | tr -d '[:space:]')
  echo "$AGENT: $STATUS"
done
```

### 7. Report

Summary table: agent / status. Flag any not in `running` state.

## Failure Handling

- **Pre-flight fails**: nothing touched. Fix the named problem and re-run.
- **Mid-recreate failure**: workspace volume is preserved. Re-run `/rebuild-agent <name>` — recreate reads config from DB even without the old container.

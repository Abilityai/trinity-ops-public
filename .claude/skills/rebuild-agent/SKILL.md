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

**When you need this skill vs. a plain stop/start (v0.9.0):** since #1809/#1860/#1816 a **cold stop → start** of an agent detects a rebuilt base image (or config drift) and recreates the container itself — `POST /api/agents/{name}/start` returns `{recreated: true, recreate_reason: "image_drift" | "config_drift"}` — and Operating Room → Restart All routes through the same lifecycle. A start of an already-*running* agent never image-recreates it, and `docker restart agent-*` adopts nothing. Reach for `/rebuild-agent` when you want a controlled wave that **preserves run state** (stopped agents stay stopped, #2092), or on a dev build between #2092 and #2186 where starting a stopped agent with drift 500s (this skill passes `require_running=False` itself, so it is the workaround there).

**What survives a recreate:** the workspace volume, env, mounts, labels, limits — and since #1704 the agent's Claude Code **plugin selection**, which is persisted as a committed, secret-free `~/.trinity/plugins.yaml` manifest and re-installed by `startup.sh` if the plugin cache is missing (a git-based reconstitution onto a fresh volume drops the gitignored `~/.claude/plugins/`). A recreate onto the same volume runs zero installs. Also picked up on recreate, not restart: `AGENT_LOG_MAX_*`, `AGENT_TMP_SIZE`, `AGENT_IDLE_FINALIZE_S`, `AGENT_TOOL_STALL_LIMIT_S`.

**Restart policy (v0.9.5, #2541):** the recreate tail bakes `restart: unless-stopped` **unconditionally** — it normalises rather than carrying the old container's policy forward. A recreated-and-left-stopped agent (`preserve_run_state`) carries Docker's manual-stop flag, so it still stays stopped across reboots. If the only goal is the policy (no image or config change), `/update` step 8c's `docker update --restart unless-stopped` sweep is cheaper than a recreate. After the wave, `docker logs agent-x | grep GUARDRAILS:` should say `registration verified` on the new image (ent#345).

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

# Record which targets are currently STOPPED. `docker ps -a` includes them, and
# a stopped agent is a deliberate operator state that a rebuild must not undo
# (abilityai/trinity#2092: an adoption wave here silently restarted two agents
# stopped eight days earlier — autonomy_enabled=0 does NOT gate inbound chat, so
# a channel binding and a public link became reachable again).
for AGENT in $AGENTS; do
  STATE=$(./scripts/run.sh "sudo docker inspect agent-$AGENT --format '{{.State.Status}}'" | tr -d '[:space:]')
  [ "$STATE" != "running" ] && echo "NOTE: $AGENT is '$STATE' — will be rebuilt and left stopped"
done
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

# #2092: recreate STARTS the replacement. Preserve the original run state
# instead — require_running=False permits a stopped target, and
# preserve_run_state=True stops the replacement again right after handoff.
# Both kwargs exist from Trinity #2155; older backends take neither, so fall
# back and refuse a stopped target rather than silently starting it.
was_running = old.status == 'running'
try:
    new = asyncio.run(recreate_container_with_updated_config(
        name, old, owner, require_running=False, preserve_run_state=True))
except TypeError:
    if not was_running:
        raise SystemExit(
            f'ABORT: {name} is {old.status!r} and this Trinity predates #2155 '
            '(no preserve_run_state) — recreating it would START it. '
            'Start it deliberately, or update Trinity.')
    new = asyncio.run(recreate_container_with_updated_config(name, old, owner))
new.reload()
print(f'OK: {new.short_id} status={new.status} (was_running={was_running})')
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

Summary table: agent / status **before** / status **after**. A rebuild must not
change run state: flag any agent whose before/after differ — a previously-running
agent now stopped is a failed rebuild, and a previously-stopped agent now running
means `preserve_run_state` did not take effect.

## Failure Handling

- **Pre-flight fails**: nothing touched. Fix the named problem and re-run.
- **Mid-recreate failure**: workspace volume is preserved. Re-run `/rebuild-agent <name>` — recreate reads config from DB even without the old container.
- **`ValueError: ... would START agent ...`**: the target is stopped and the call did not pass `require_running=False` (Trinity #2092). Step 5 passes it; seeing this means an edited/older copy of the step is running.
- **Agent stopped before, running after**: `preserve_run_state` was not honored. Stop it again immediately (`sudo docker stop agent-<name>`) — a stopped agent still answers inbound chat, channel bindings and public links once it is up; `autonomy_enabled=0` does not gate those.

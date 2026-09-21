---
name: agents
description: Manage agents - list, start, stop, view logs, or exec commands.
disable-model-invocation: true
allowed-tools: Bash, Read
argument-hint: [list|start|stop|logs|exec] [agent-name] [command]
---

# Agent Management

## Arguments

- No args / `list` — list all agents
- `start <name>` — start agent-{name}
- `stop <name>` — stop agent-{name}
- `logs <name> [lines]` — view agent logs (default 50 lines)
- `exec <name> <command>` — run command inside agent container
- `policy` — restart-policy census (v0.9.5, #2541)
- `dump <name>` — thread dump of a wedged agent server (v0.9.5, #2503)

**Restart semantics (v0.9.5, #2541):** agent containers are `restart: unless-stopped`. `docker stop` sets Docker's manual-stop flag, so a stopped agent **stays stopped** across host reboots — but only if the stop succeeded. `docker start` of a stopped agent bypasses Trinity's start ladder (drift/image adoption, MCP-key self-heal); prefer `POST /api/agents/{name}/start` when the base image or config may have changed. Containers created before 0.9.5 keep `RestartPolicy=no` until recreated or swept (`/update` step 8c).

## Instructions

### 1. Verify Context

```bash
ls -la .env scripts/run.sh 2>/dev/null
```

### 2. Load Config

```bash
source .env
```

### 3. Execute

**List:**
```bash
source .env
./scripts/run.sh "sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}' | grep agent-"
```

Show total count: running vs stopped.

**Start:**
```bash
source .env
./scripts/run.sh "sudo docker start agent-{name}"
sleep 3
./scripts/run.sh "sudo docker ps --format '{{.Names}}\t{{.Status}}' | grep agent-{name}"
```

**Stop:**
```bash
source .env
./scripts/run.sh "sudo docker stop agent-{name}"
./scripts/run.sh "sudo docker ps -a --format '{{.Names}}\t{{.Status}}' | grep agent-{name}"
```

**Logs:**
```bash
source .env
./scripts/run.sh "sudo docker logs agent-{name} --tail ${LINES:-50}"
```

**Exec:**
```bash
source .env
./scripts/run.sh "sudo docker exec agent-{name} {command}"
```

**Policy** (name · restart policy · restart count — `no` = pre-0.9.5 container, dies on reboot; a climbing count is a crash loop re-running `startup.sh` each retry):
```bash
source .env
./scripts/run.sh "for c in \$(sudo docker ps -a --format '{{.Names}}' | grep '^agent-'); do echo \"\$c \$(sudo docker inspect -f '{{.HostConfig.RestartPolicy.Name}} restarts={{.RestartCount}} state={{.State.Status}}' \$c)\"; done"
```

**Dump** (SIGUSR1 → every thread's stack to the container log, frames only, no restart; `[Diagnostics] EVENT LOOP STALLED` lines mean the agent server's loop is wedged):
```bash
source .env
./scripts/run.sh "sudo docker exec agent-{name} kill -USR1 1; sleep 1; sudo docker logs agent-{name} --tail 300 2>&1 | grep -A60 'THREAD DUMP' | tail -80"
```

### 4. Handle Errors

If agent doesn't exist, list available agents:
```bash
source .env
./scripts/run.sh "sudo docker ps -a --format '{{.Names}}' | grep '^agent-'"
```

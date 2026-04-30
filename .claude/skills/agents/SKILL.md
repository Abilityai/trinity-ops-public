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

### 4. Handle Errors

If agent doesn't exist, list available agents:
```bash
source .env
./scripts/run.sh "sudo docker ps -a --format '{{.Names}}' | grep '^agent-'"
```

---
name: logs
description: View logs from any Trinity service (backend, scheduler, frontend, mcp, redis, vector, or agent-*).
disable-model-invocation: true
allowed-tools: Bash, Read
argument-hint: <service> [lines] [errors]
---

# View Service Logs

## Arguments

- `$0` — Service: `backend`, `scheduler`, `frontend`, `mcp`, `redis`, `vector`, or agent name like `myagent`
- `$1` — Optional: line count (default: 50)
- `$2` — Optional: `errors` to filter for errors only

## Examples

- `/logs backend` — Last 50 backend lines
- `/logs backend 200 errors` — Errors only
- `/logs myagent` — Agent logs (prefix `agent-` is added automatically)

## Service → Container Map

| Service | Container |
|---------|-----------|
| backend | trinity-backend |
| scheduler | trinity-scheduler |
| frontend | trinity-frontend |
| mcp | trinity-mcp-server |
| redis | trinity-redis |
| vector | trinity-vector |
| anything else | `agent-{name}` |

## Instructions

### 1. Verify Context

```bash
ls -la .env scripts/run.sh 2>/dev/null
```

### 2. Parse Arguments and Map Container

Parse service name from arguments; default to `backend`. Map to container name per the table above. If the service doesn't match any platform service, treat it as an agent name and prepend `agent-`.

### 3. Fetch Logs

**Normal:**
```bash
source .env
./scripts/run.sh "sudo docker logs $CONTAINER --tail $LINES"
```

**Errors only** (when `errors` arg is set):
```bash
source .env
./scripts/run.sh "sudo docker logs $CONTAINER --tail $LINES 2>&1 | grep -iE 'error|exception|failed|traceback'"
```

### 4. Output

Display logs. If the container doesn't exist, list available containers:
```bash
source .env
./scripts/run.sh "sudo docker ps -a --format '{{.Names}}' | grep -E 'trinity|agent'"
```

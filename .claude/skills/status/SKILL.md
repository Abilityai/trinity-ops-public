---
name: status
description: Show Trinity instance health - backend, scheduler, containers, version. Run from the agent root directory.
disable-model-invocation: true
allowed-tools: Bash, Read
---

# Instance Status Check

Show the current health and status of the Trinity instance.

## Instructions

### 1. Verify Context

```bash
ls -la .env scripts/run.sh 2>/dev/null
```

If either is missing, stop and tell the user to run from the ops-agent root directory (where `.env` is).

### 2. Load Configuration

```bash
source .env
HOST=${SSH_HOST:-localhost}
echo "Host: $HOST"
```

### 3. Check Backend Health

```bash
source .env
./scripts/run.sh "curl -s http://localhost:${BACKEND_PORT:-8000}/health"
```

Report: ✓ if `{"status":"ok"}`, ✗ if unreachable.

### 4. Check Scheduler Health

```bash
source .env
./scripts/run.sh "sudo docker inspect trinity-scheduler --format='{{.State.Health.Status}}' 2>/dev/null || echo 'not found'"
```

Report: ✓ if "healthy", ✗ otherwise.

### 4b. Check for Scheduler 403 Errors (INTERNAL_API_SECRET)

```bash
source .env
RECENT_403=$(./scripts/run.sh "sudo docker logs trinity-scheduler --since 10m 2>&1 | grep -c '403 Forbidden'" | tr -d '[:space:]')
if [ "${RECENT_403:-0}" -gt 0 ] 2>/dev/null; then
  echo "CRITICAL: $RECENT_403 scheduler 403 errors in last 10 min — INTERNAL_API_SECRET missing or mismatched"
fi
```

### 5. Container Status

```bash
source .env
./scripts/run.sh "sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'trinity|agent' | head -20"
```

### 6. Current Version

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
./scripts/run.sh "cd $TRINITY && git log -1 --oneline"
```

### 7. Summary Output

```
## Trinity Status
**Host**: {SSH_HOST or localhost}

### Health
| Service | Status |
|---------|--------|
| Backend | ✓/✗ |
| Scheduler | ✓/✗ (INTERNAL_API_SECRET OK/MISSING) |

### Version
{commit}

### Containers
{table}
```

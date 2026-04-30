---
name: diagnose
description: Comprehensive error analysis across all Trinity services - errors, restarts, resources, and database health.
disable-model-invocation: true
allowed-tools: Bash, Read
---

# Diagnose Instance

Run a comprehensive health and error analysis.

## Instructions

### 1. Verify Context

```bash
ls -la .env scripts/run.sh 2>/dev/null
```

### 2. Service Health

```bash
source .env
./scripts/run.sh "curl -s http://localhost:${BACKEND_PORT:-8000}/health"
./scripts/run.sh "sudo docker inspect trinity-scheduler --format='{{.State.Health.Status}}' 2>/dev/null || echo 'not found'"
```

### 3. Recent Backend Errors

```bash
source .env
./scripts/run.sh "sudo docker logs trinity-backend --tail 500 2>&1 | grep -iE 'error|exception|failed|traceback' | tail -20"
```

### 4. Recent Scheduler Errors

```bash
source .env
./scripts/run.sh "sudo docker logs trinity-scheduler --tail 200 2>&1 | grep -iE 'error|exception|failed' | tail -10"
```

### 5. Container Restart / Exit Status

```bash
source .env
./scripts/run.sh "sudo docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -E 'Restarting|Exited' | grep -E 'trinity|agent'"
```

### 6. Disk Space

```bash
source .env
./scripts/run.sh "df -h | grep -E '/$|/var' | awk '{if (\$5+0 > 80) print \"WARNING: \" \$0; else print \$0}'"
```

### 7. Docker Disk Usage

```bash
source .env
./scripts/run.sh "sudo docker system df"
```

### 8. Container Resources

```bash
source .env
./scripts/run.sh "sudo docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' | grep -E 'trinity|agent'"
```

### 9. Database Integrity

```bash
source .env
./scripts/run.sh "sudo docker run --rm -v trinity_trinity-data:/data alpine sh -c 'apk add --quiet sqlite && sqlite3 /data/trinity.db \"PRAGMA integrity_check\"'"
```

### 10. Network Check

```bash
source .env
./scripts/run.sh "sudo docker network ls | grep trinity"
```

### 11. Summary Report

```
## Diagnostic Report

### Health Status
| Service | Status |
|---------|--------|
| Backend | ✓/✗ |
| Scheduler | ✓/✗ |

### Issues Found
**Errors**: {count}
{top error types}

**Container Issues**: {any restarting/exited}

**Resource Warnings**: {disk/memory}

**Database**: {integrity result}

### Recommendations
{Specific next steps based on findings}
```

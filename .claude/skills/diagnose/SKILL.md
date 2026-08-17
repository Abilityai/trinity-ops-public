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

### 9b. Silent Maintenance-Job Failures (v0.9.0+)

Two jobs whose failure mode is "healthy container, nothing happening" — the class behind #1478/#1871/#2205/#2216. Both need an admin token (see CLAUDE.md → API Access).

```bash
source .env
# Admin token minted ON the host (ADMIN_PASSWORD from this agent's .env) so the query needs no tunnel
./scripts/run.sh "TOKEN=\$(curl -s -X POST http://localhost:${BACKEND_PORT:-8000}/token -H 'Content-Type: application/x-www-form-urlencoded' -d 'username=admin&password=$ADMIN_PASSWORD' | jq -r .access_token); \
  curl -s -H \"Authorization: Bearer \$TOKEN\" http://localhost:${BACKEND_PORT:-8000}/api/settings/retention | jq -c '.backup, {blocked_sweeps, pending_acknowledgements}'"
# Nightly DB backup (#2216): status/last success/age/artifact count. enabled:false ⇒ DB_BACKUP_ENABLED=false.
./scripts/run.sh "sudo docker exec trinity-backend ls -lh /data/backups/ 2>/dev/null | tail -5"
# Log archival (#2205): the archives dir must be 1000:1000 and writable, else /data/logs grows unbounded
./scripts/run.sh "sudo docker exec trinity-backend sh -c 'ls -ld /data /data/logs /data/archives; touch /data/archives/.perm-probe && rm /data/archives/.perm-probe && echo archives-writable'"
./scripts/run.sh "sudo docker exec trinity-backend du -sh /data/logs /data/archives /data/backups 2>/dev/null"
# Platform alarms filed under sentinel names (_db-backup, _log-archive) — pending items are actionable
./scripts/run.sh "sudo docker logs trinity-backend --tail 2000 2>&1 | grep -E '\[DBBackup\]|\[ArchiveStorage\]|REFUSED' | tail -10"
```

Flag: `.backup.last_status` ≠ `ok`, newest success > 3 days old, `blocked_sweeps` non-empty, `/data/archives` not writable, or `/data/logs` far larger than `LOG_RETENTION_DAYS` should allow.

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

**Maintenance jobs**: backups {ok/failed/stale/disabled, last success}, archives {writable/NOT}, retention {blocked sweeps}

### Recommendations
{Specific next steps based on findings}
```

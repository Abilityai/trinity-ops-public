---
name: rollback
description: Rollback Trinity to a previous git commit with optional database restore.
disable-model-invocation: true
allowed-tools: Bash, Read, Write
argument-hint: [commit|HEAD~N] [backup-filename]
automation: gated
---

# Rollback Trinity

## Arguments

- `$0` — Commit hash or `HEAD~N` (default: `HEAD~1`)
- `$1` — Optional: backup file to restore from `~/backups/` (e.g. `trinity-20260101-120000.db`)

## Examples

- `/rollback` — Rollback one commit
- `/rollback HEAD~3` — Rollback 3 commits
- `/rollback abc1234` — Rollback to specific commit
- `/rollback HEAD~1 trinity-20260101.db` — Rollback code and restore database

## Instructions

### 1. Verify Context

```bash
ls -la .env scripts/run.sh 2>/dev/null
```

### 2. Load Config and Show Current State

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}
echo "Current version:"
./scripts/run.sh "cd $TRINITY && git log -1 --oneline"
```

### 3. Determine Target and Validate

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
TARGET="${TARGET_COMMIT:-HEAD~1}"
./scripts/run.sh "cd $TRINITY && git rev-parse --verify $TARGET 2>/dev/null" || { echo "Invalid commit: $TARGET"; exit 1; }
./scripts/run.sh "cd $TRINITY && git log -1 --oneline $TARGET"
```

### 4. Show Changes That Will Be Reverted

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
./scripts/run.sh "cd $TRINITY && git log --oneline $TARGET..HEAD | head -10"
```

### 5. STOP — Confirm with User

```
The following will happen:
1. Create pre-rollback database backup
2. Reset Trinity to: {target_commit}
3. {If backup specified: Restore database from {backup_file}}
4. Rebuild containers
5. Restart services

Confirm? (say "yes" to proceed)
```

**Do not proceed without explicit user confirmation.**

### 6. Pre-Rollback Backup

```bash
source .env
BACKUP="trinity-pre-rollback-$(date +%Y%m%d-%H%M%S).db"
./scripts/run.sh "mkdir -p ~/backups && sudo docker run --rm -v trinity_trinity-data:/data -v ~/backups:/backup alpine cp /data/trinity.db /backup/$BACKUP"
echo "Pre-rollback backup: ~/backups/$BACKUP"
```

### 7. Git Reset

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
./scripts/run.sh "cd $TRINITY && git fetch origin && git reset --hard $TARGET"
./scripts/run.sh "cd $TRINITY && git log -1 --oneline"
```

### 8. Restore Database (if specified)

```bash
source .env
./scripts/run.sh "sudo docker run --rm -v trinity_trinity-data:/data -v ~/backups:/backup alpine cp /backup/{backup_file} /data/trinity.db"
```

### 9. Rebuild and Restart

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}
./scripts/run.sh "cd $TRINITY && sudo docker compose -f $COMPOSE build --no-cache backend frontend mcp-server scheduler"
./scripts/run.sh "cd $TRINITY && sudo docker compose -f $COMPOSE up -d backend frontend mcp-server scheduler"
sleep 10
```

### 10. Verify Health

```bash
source .env
BACKEND=$(./scripts/run.sh "curl -s -o /dev/null -w '%{http_code}' http://localhost:${BACKEND_PORT:-8000}/health" 2>/dev/null)
echo "Backend: HTTP $BACKEND"
```

### 11. Write Deploy Log

Create `deploys/rollback-YYYY-MM-DD-HHMMSS.md` with: date, previous version, target version, pre-rollback backup, DB restored, health result, SUCCESS/FAILED.

### 12. Report

```
## Rollback Complete
**Previous**: {old_commit}
**Current**: {new_commit}
**Pre-rollback Backup**: {filename}
**Database Restored**: {yes/no}
| Backend | {status} |
```

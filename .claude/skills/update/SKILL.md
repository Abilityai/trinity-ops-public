---
name: update
description: Update Trinity to latest version - backup DB, git pull, rebuild containers, restart, verify health. Options: --wait to wait for running executions, --force to skip the check.
disable-model-invocation: true
allowed-tools: Bash, Read, Write
automation: gated
---

# Update Trinity

Pull latest code, rebuild containers, restart services, and verify health. Logs everything to `deploys/YYYY-MM-DD-HHMMSS.md`.

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
BRANCH=${TRINITY_BRANCH:-main}
echo "Target branch: $BRANCH"
```

### 3. Check Running Executions

```bash
source .env
TOKEN=$(./scripts/run.sh "curl -s -X POST http://localhost:${BACKEND_PORT:-8000}/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=admin&password=${ADMIN_PASSWORD}'" | jq -r '.access_token' 2>/dev/null)

RUNNING=$(./scripts/run.sh "curl -s -H 'Authorization: Bearer $TOKEN' \
  http://localhost:${BACKEND_PORT:-8000}/api/executions?status=running 2>/dev/null" | jq '.executions | length' 2>/dev/null || echo 0)
echo "Running executions: $RUNNING"
```

- With `--force`: log and proceed
- Without args and executions running: ask user to wait, proceed, or cancel

### 4. Initialize Deploy Log

```bash
mkdir -p deploys
DEPLOY_FILE="deploys/$(date +%Y-%m-%d-%H%M%S).md"
```

Start log with header: date, host, branch, operator (Claude Code).

### 5. Backup Database

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}
BACKUP="trinity-$(date +%Y%m%d-%H%M%S).db"

# Auto-detect: bind mount or Docker volume
MOUNT_TYPE=$(./scripts/run.sh "sudo docker inspect trinity-backend --format '{{json .Mounts}}' 2>/dev/null | jq -r '.[] | select(.Destination == \"/data\") | .Type'" 2>/dev/null | tr -d '[:space:]')

if [ "$MOUNT_TYPE" = "bind" ]; then
  ./scripts/run.sh "mkdir -p ~/backups && sudo cp $TRINITY/trinity-data/trinity.db ~/backups/$BACKUP"
else
  ./scripts/run.sh "mkdir -p ~/backups && sudo docker run --rm -v trinity_trinity-data:/data -v ~/backups:/backup alpine cp /data/trinity.db /backup/$BACKUP"
fi
```

Log backup filename. Abort on failure.

### 6. Check Current Version

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
BEFORE=$(./scripts/run.sh "cd $TRINITY && git log -1 --oneline")
BEHIND=$(./scripts/run.sh "cd $TRINITY && git fetch origin ${BRANCH:-main} && git rev-list HEAD..origin/${BRANCH:-main} --count" 2>/dev/null | tr -d '[:space:]')
echo "Current: $BEFORE"
echo "Behind: $BEHIND commits"
```

If 0 commits behind, log "Already up to date" and exit with summary.

### 7. Pull Latest

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
BRANCH=${TRINITY_BRANCH:-main}
./scripts/run.sh "cd $TRINITY && git fetch origin $BRANCH && git checkout $BRANCH && git pull origin $BRANCH"
AFTER=$(./scripts/run.sh "cd $TRINITY && git log -1 --oneline")
echo "New version: $AFTER"
```

Log full git output, files changed, new commit hash.

### 8. Rebuild Containers

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}
./scripts/run.sh "cd $TRINITY && sudo docker compose -f $COMPOSE build --no-cache backend frontend mcp-server scheduler"
```

### 9. Restart Services

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}
./scripts/run.sh "cd $TRINITY && sudo docker compose -f $COMPOSE up -d backend frontend mcp-server scheduler"

# If Cloudflare tunnel is running, restart it too
TUNNEL=$(./scripts/run.sh "sudo docker ps --format '{{.Names}}' | grep trinity-cloudflared" | tr -d '[:space:]')
if [ -n "$TUNNEL" ]; then
  ./scripts/run.sh "cd $TRINITY && sudo docker compose -f $COMPOSE --profile tunnel up -d"
fi
```

### 10. Clean Up Build Cache

```bash
source .env
./scripts/run.sh "sudo docker image prune -f"
./scripts/run.sh "sudo docker builder prune -f"
```

### 11. Verify Health

```bash
sleep 10
source .env
BACKEND=$(./scripts/run.sh "curl -s -o /dev/null -w '%{http_code}' http://localhost:${BACKEND_PORT:-8000}/health" 2>/dev/null)
SCHED=$(./scripts/run.sh "sudo docker inspect trinity-scheduler --format='{{.State.Health.Status}}'" 2>/dev/null | tr -d '[:space:]')
./scripts/run.sh "sudo docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'trinity|agent'"
```

### 12. Check INTERNAL_API_SECRET

```bash
source .env
SCHED_SECRET=$(./scripts/run.sh "sudo docker exec trinity-scheduler printenv INTERNAL_API_SECRET 2>/dev/null" | tr -d '[:space:]')
BACKEND_SECRET=$(./scripts/run.sh "sudo docker exec trinity-backend printenv INTERNAL_API_SECRET 2>/dev/null" | tr -d '[:space:]')

if [ -z "$SCHED_SECRET" ] || [ -z "$BACKEND_SECRET" ]; then
  echo "CRITICAL: INTERNAL_API_SECRET missing — scheduled executions will 403"
elif [ "$SCHED_SECRET" != "$BACKEND_SECRET" ]; then
  echo "CRITICAL: INTERNAL_API_SECRET mismatch between scheduler and backend"
else
  echo "INTERNAL_API_SECRET: OK"
fi
```

### 13. Write Deploy Summary

Write to `$DEPLOY_FILE`:

```markdown
## Summary
| Item | Value |
|------|-------|
| Previous Version | {before} |
| New Version | {after} |
| Branch | {branch} |
| Backup | {filename} |
| Backend | {HTTP 200 / failed} |
| Scheduler | {healthy / unhealthy} |
| INTERNAL_API_SECRET | {OK / CRITICAL} |
| Tunnel | {restarted / not present} |

## Result
{SUCCESS / FAILED}
```

### 14. Report to User

Concise summary: old → new version, health status, path to deploy log, any warnings.

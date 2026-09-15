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
- `$1` — Optional: backup file to restore — a manual copy in `~/backups/` (e.g. `trinity-20260101-120000.db`) **or** one of the platform's own artifacts inside the data volume (v0.9.0+, #2216): `/data/backups/trinity-backup-YYYYMMDD.db` (nightly) or `/data/backups/pre-migration-YYYYMMDD-HHMMSS.db` (taken at boot right before the migration you are rolling back from). Pass the `/data/backups/...` path verbatim to use one of those.

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

Safe online copy (sqlite3 backup API, bind-mount/volume + SQLite/PG auto-detected) — never `cp` a live DB:

```bash
./scripts/backup.sh     # → ~/backups/trinity-<ts>.db (or trinity-pg-<ts>.dump)
```

Record the filename as the pre-rollback backup. List the platform's own artifacts too, so the user can pick one for step 8 if they did not name a file:

```bash
./scripts/run.sh "sudo docker exec trinity-backend ls -lh /data/backups/ 2>/dev/null || echo '(no /data/backups — pre-v0.9.0 build)'"
```

### 7. Git Reset

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
./scripts/run.sh "cd $TRINITY && git fetch origin && git reset --hard $TARGET"
./scripts/run.sh "cd $TRINITY && git log -1 --oneline"
```

### 8. Restore Database (if specified)

Restore with **both DB writers stopped** — backend AND scheduler (stopping only the backend leaves a live writer holding the file) — and with stale `-wal`/`-shm`/`-journal` sidecars removed beside the target first (a leftover journal from the *old* database beside a restored `.db` is a corruption hazard; harmless if absent). This is the sequence upstream's own `restore-database.sh` follows since #2216.

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}

# 8a. Stop the writers
./scripts/run.sh "cd $TRINITY && sudo docker compose -f $COMPOSE stop backend scheduler"

# 8b. Data mount: bind (prod) or named volume (dev)
DATA_MOUNT=$(./scripts/run.sh "sudo docker inspect trinity-backend --format '{{range .Mounts}}{{if eq .Destination \"/data\"}}{{if eq .Type \"bind\"}}{{.Source}}{{else}}trinity_trinity-data{{end}}{{end}}{{end}}'" | tr -d '[:space:]')
DATA_MOUNT=${DATA_MOUNT:-trinity_trinity-data}

# 8c. Source: a manual copy in ~/backups (mounted at /backup) or a platform artifact already inside /data/backups
#     {backup_file} = trinity-20260101-120000.db          → SRC=/backup/{backup_file}
#     {backup_file} = /data/backups/trinity-backup-*.db   → SRC={backup_file}
./scripts/run.sh "sudo docker run --rm -v $DATA_MOUNT:/data -v ~/backups:/backup:ro alpine sh -c 'apk add --quiet sqlite && sqlite3 {SRC} "PRAGMA quick_check;" && rm -f /data/trinity.db-wal /data/trinity.db-shm /data/trinity.db-journal && cp {SRC} /data/trinity.db && chown 1000:1000 /data/trinity.db'"
```

Abort (and restart the services with step 9's `up -d`) if `quick_check` prints anything but `ok`. **PostgreSQL** instances: `pg_restore` the `.dump` into an empty database while backend+scheduler are stopped, then point `DATABASE_URL` at it — see CLAUDE.md → Backup Database.

### 9. Rebuild and Restart

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}
./scripts/run.sh "cd $TRINITY && sudo docker compose -f $COMPOSE build --no-cache backend frontend mcp-server scheduler"
./scripts/run.sh "cd $TRINITY && sudo docker compose -f $COMPOSE up -d backend frontend mcp-server scheduler"
sleep 10
```

Rolling back across a version that changed `docker/base-image/` leaves agents on the *newer* base image; that is safe (agents degrade forward-compatibly) but if you need the older runtime, rebuild the base image at the target commit and let agents adopt on a cold stop/start (see `/update` step 8b).

**Rolling back across v0.9.5's secret-settings migration (ent#435 / #2330) needs the pre-update database.** The migration *deletes* the plaintext `anthropic_api_key` / `github_pat` / `google_api_key` / `slack_*` rows after wrapping them into `<key>_encrypted`; pre-0.9.5 code reads only the plaintext rows, so on a post-migration DB it silently falls back to the env-var values (or nothing). Restore the pre-update artifact (`/data/backups/pre-migration-<ts>.db` or the `/update` backup) in step 8, or re-enter those credentials in Settings after the rollback. Rolling *forward* again is safe: the read path lazily re-encrypts any plaintext it finds.

**Hosted installs** (`docker-compose.hosted.yml`, #2280): there is nothing to build — set `TRINITY_IMAGE_TAG` in the server `.env` to the previous release tag (`v0.9.0`, `0.9.0`, or the exact `sha-<short>`) and re-run `start.sh --hosted`, which also pulls that release's agent base image. The `git reset` in step 7 only matters for the bind-mounted `config/` tree.

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

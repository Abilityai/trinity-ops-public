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
case "$COMPOSE" in *hosted*) echo "MODE: hosted (prebuilt GHCR images, #2280)";; *) echo "MODE: source build";; esac
```

**Hosted installs** (`COMPOSE_FILE=docker-compose.hosted.yml`, v0.9.5) do not build: the upgrade is `start.sh --hosted`, which pulls the four platform images **and** the agent base image (retagged `trinity-agent-base:latest`) and brings the stack up. Never `docker compose pull` alone — it leaves every agent on the old runtime. The release is selected by `TRINITY_IMAGE_TAG` in the server `.env`; check it is pinned before proceeding (`latest` moves on every release, so an unpinned tag makes this an unscheduled major upgrade):

```bash
./scripts/run.sh "grep -E '^TRINITY_IMAGE_TAG=' ${TRINITY_PATH:-~/trinity}/.env || echo 'TRINITY_IMAGE_TAG UNSET (= latest)'"
```

### 2b. Pre-check `CREDENTIAL_ENCRYPTION_KEY` (v0.9.5, ent#435)

```bash
./scripts/run.sh "grep -cE '^CREDENTIAL_ENCRYPTION_KEY=.+' ${TRINITY_PATH:-~/trinity}/.env"
```

`0` ⇒ **stop**. The 0.9.5 secret-settings migration (#2330) encrypts six credential rows in `system_settings` at first boot and the backend refuses to start without the key when such rows exist. Set it (`openssl rand -hex 32`) and only then continue. Note for the summary: after this upgrade the operator must **rotate every credential that was entered via Settings** — old backups still hold plaintext.

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

Use the safe online-backup primitive — **never `cp` a live `trinity.db`** (a raw copy mid-write, ignoring its journal, can be torn or stale; upstream retired its own `cp`-based script for this reason, #2216). `scripts/backup.sh` auto-detects bind mount vs named volume and SQLite vs bundled PostgreSQL:

```bash
./scripts/backup.sh          # → ~/backups/trinity-<ts>.db (SQLite, sqlite3 .backup + quick_check)
                             #   or ~/backups/trinity-pg-<ts>.dump (bundled PG, pg_dump -Fc)
```

Exit code 2 = the instance runs a **managed/external PostgreSQL** — take the backup with `pg_dump -Fc` against the host (or the provider's snapshot) before continuing; do not skip.

Since v0.9.0 the backend also writes `/data/backups/pre-migration-<ts>.db` at boot whenever a schema migration is pending, and the nightly job keeps `trinity-backup-YYYYMMDD.*` there — list them with `./scripts/run.sh "sudo docker exec trinity-backend ls -lh /data/backups/"` if you ever need a second recovery point.

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

### 8. Rebuild Containers (source build) — or pull (hosted)

**Source build:**

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}
./scripts/run.sh "cd $TRINITY && sudo docker compose -f $COMPOSE build --no-cache backend frontend mcp-server scheduler"
```

This step is load-bearing (#1814): `start.sh` never rebuilds platform images, so a bare `git pull` leaves the previous build running the new code. Step 11 verifies it took (`version` == `image_version`). Since v0.9.5 the frontend builds on `node:26-alpine` and the backend image needs `src/backend/shared_sessions` (rooms in OSS core, ent#443) — a custom Dockerfile without that `COPY` dies at import.

**Hosted:** skip the build and step 9 — one command pulls and starts everything:

```bash
./scripts/run.sh "cd ${TRINITY_PATH:-~/trinity} && sudo ./scripts/deploy/start.sh --hosted --unattended"
```

`manifest unknown` = `TRINITY_IMAGE_TAG` names an unpublished tag; `denied` = the GHCR package is private (report upstream, do not `docker login` around it). `start.sh` also refuses to bring a dev-stack database up under hosted (or vice versa) — bring the stack up with the file set it was installed with, or copy the data across with the recipe it prints (#2390).

### 8b. Agent Base Image — did the pulled range touch it?

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
BEFORE_SHA=${BEFORE%% *}; AFTER_SHA=${AFTER%% *}
./scripts/run.sh "cd $TRINITY && git diff --name-only $BEFORE_SHA $AFTER_SHA -- docker/base-image/ | head -30"
```

If anything is listed, the fleet is on a stale agent runtime until the base image is rebuilt **and each agent is recreated**:

```bash
./scripts/run.sh "cd $TRINITY && ./scripts/deploy/build-base-image.sh"
```

Adoption rules (v0.9.0, #1809 / #1860 / #1816): a **cold stop → start** of an agent detects the rebuilt image and recreates the container (`recreate_reason: "image_drift"`); Operating Room → **Restart All** routes through the same lifecycle; `trinity-system` adopts on its next stop/start. A start of an already-*running* agent never image-recreates it. For a controlled wave that preserves run state (stopped agents stay stopped), use `/rebuild-agent` — do **not** run `docker restart agent-*` (a plain restart adopts nothing). Report which path you took and whether the user wants the wave now; the base-image rebuild itself is safe to run immediately.

**Crossing 0.9.0 → 0.9.5 the rebuild + wave is not optional** — arm64 native binary (#2537), guardrail hooks in `/etc/claude-code/managed-settings.json` (ent#345), pre-installed Trinity plugin (ent#411), Codex `auth.json` (#2333), wedge diagnostics (#2503), the 11-tool deny list (#2476), the sanitizer ReDoS fix (#2398), parked-call tracking (#2435), the `git-credential-trinity` helper (ent#615), the lock-free `git status` read (#2742) and the comma-separated `allowed-tools` parse (#2850) all ship in the image. Hosted installs got the new base image from `start.sh --hosted` in step 8; the wave is still needed. After the wave:

```bash
# every agent should log `GUARDRAILS: registration verified`; ERROR = still on the old image (and NO hooks run)
./scripts/run.sh "for c in \$(sudo docker ps --format '{{.Names}}' | grep '^agent-'); do echo \"\$c: \$(sudo docker logs \$c 2>&1 | grep -m1 'GUARDRAILS:')\"; done"
```

### 8c. Agent Restart-Policy Sweep (v0.9.5, #2541 — once)

Agents created on ≥ 0.9.5 are `unless-stopped`; pre-upgrade containers keep `RestartPolicy=no` until recreated and still die on a host reboot. `docker update` on a **stopped** container changes the policy without starting it, so this preserves run state:

```bash
./scripts/run.sh "for c in \$(sudo docker ps -a --format '{{.Names}}' | grep '^agent-'); do [ \"\$(sudo docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' \$c)\" = no ] && sudo docker update --restart unless-stopped \$c; done"
```

Runbook on the server: `docs/migrations/AGENT_RESTART_POLICY_2026-09.md`. Tell the user: from now on **never `docker compose down`** on this host (a recreated agent network sends every agent into a dockerd restart loop) — `stop.sh` / `compose stop` instead.

### 8d. Git Remote Token Scrub (v0.9.5, ent#615 — automatic, verify only)

The backend rewrites every agent's remote without the token, starting about 20s after boot. Old-image containers are covered too, because it installs the credential helper into them. Nothing to run. After step 11, check the report:

```bash
./scripts/run.sh "sudo docker logs trinity-backend --tail 3000 2>&1 | grep 'ent#615: remote-token sweep' | tail -20"
```

Flag any report with:
- `refused` > 0 — the agent needs its own token (Git tab);
- `gitmodules_hits` > 0 — rotating the platform token becomes **mandatory**;
- `root_readable=0` — the sweep could not look, so check that agent's remotes by hand.

Also flag operator-queue items `ent615-git-token-scrub-*`. See CLAUDE.md → Troubleshooting → "Git fetch/push fails…".

**Tell the user to rotate the platform GitHub token** (Settings → GitHub, then revoke the old one on GitHub). It used to sit in `.git/config`, process listings, log archives and `/data/skills-library/*/.git/config`, so old backups still hold it. Runbook: `docs/migrations/GIT_REMOTE_TOKEN_SCRUB_2026-09.md`.

Also mention for 0.9.5:
- `WORKSPACE_ENABLED` is retired; delete it from `.env`.
- Users must re-login and reconnect MCP clients.
- The first headroom sweep may file critical `_sub-headroom` items for over-limit subscriptions (#2419).

### 9. Restart Services (source build only)

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
# #1814: version = code in service, image_version = build it runs inside. Different ⇒ step 8 did not take.
./scripts/run.sh "curl -s http://localhost:${BACKEND_PORT:-8000}/api/version | jq '{version, image_version, git_commit_short}'"
# #2216: the backend takes a pre-migration copy at boot when a migration was pending — confirm it landed
./scripts/run.sh "sudo docker logs trinity-backend --tail 500 2>&1 | grep '\[DBBackup\]' | tail -5"
# ent#435: the secret-settings migration logs what it encrypted (and tells you to rotate); a refusal names MissingEncryptionKeyError
./scripts/run.sh "sudo docker logs trinity-backend --tail 500 2>&1 | grep -E 'ent#435|MissingEncryptionKeyError' | tail -3"
# PostgreSQL only: exactly ONE alembic head. Two ⇒ `upgrade head` applied nothing (0043/0044 fork; 0045 merges)
./scripts/run.sh "sudo docker exec trinity-backend alembic heads 2>/dev/null || echo '(sqlite — n/a)'"
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
| Mode | {source build / hosted @ TRINITY_IMAGE_TAG} |
| Version / image | {version} / {image_version} — {match / STALE IMAGE} |
| Base image changed | {no / yes — rebuilt + adoption path, or PENDING} |
| Restart-policy sweep | {n agents moved to unless-stopped / already done} |
| Secret-settings migration | {not applicable / ran — ROTATE Settings-entered credentials / REFUSED (key missing)} |
| INTERNAL_API_SECRET | {OK / CRITICAL} |
| Tunnel | {restarted / not present} |

## Result
{SUCCESS / FAILED}
```

### 14. Report to User

Concise summary: old → new version, health status, path to deploy log, any warnings.

# Trinity Ops Agent

> A universal, single-instance operator for [Trinity](https://github.com/abilityai/trinity) — autonomous agent orchestration infrastructure.
> Manage Trinity anywhere — laptop, any VPS, any cloud — with one `.env` file.

---

## Quick Start

```bash
# 1. Copy credentials template
cp .env.example .env

# 2. Fill in connection details (see .env.example for all options)
#    Leave SSH_HOST empty for a local installation
nano .env

# 3. Test connection
./scripts/status.sh
```

Access Trinity at `http://<SSH_HOST>:<FRONTEND_PORT>` (or `http://localhost:80` if local).

---

## Connection Modes

This agent works in two modes depending on `SSH_HOST` in `.env`:

| Mode | `SSH_HOST` | How commands run |
|------|-----------|-----------------|
| **Local** | *(empty)* | `eval` directly on this machine |
| **Remote** | IP or hostname | SSH (key or password) |

For remote access, `scripts/run.sh` automatically picks key vs. password auth from `.env`.

---

## Operations Guide

### Health Check

```bash
./scripts/status.sh
```

Or ask the agent: "what's the status of my Trinity instance?"

The agent will check:
- Docker container states (`trinity-backend`, `trinity-frontend`, etc.)
- HTTP health endpoints (backend `/health`, frontend, scheduler)
- Redis ping
- Current git version

### View Logs

```bash
# Backend (most useful)
./scripts/run.sh "sudo docker logs trinity-backend --tail 100"

# Scheduler
./scripts/run.sh "sudo docker logs trinity-scheduler --tail 50"

# Agent container
./scripts/run.sh "sudo docker logs agent-myagent --tail 50"

# Errors only
./scripts/run.sh "sudo docker logs trinity-backend --tail 500 2>&1 | grep -iE 'error|exception|traceback'"
```

### Restart Services

```bash
./scripts/restart.sh

# Or a specific container
./scripts/run.sh "sudo docker restart trinity-backend"
```

### Update Trinity

Pulls the latest code, rebuilds Docker images, restarts services, and verifies health:

```bash
./scripts/update.sh
```

**v0.9.0 upgrade notes (#1814 / #1809 / #1860 / #1816):** `start.sh` never rebuilds platform images, so an in-place `git pull` leaves the *previous* build running the *new* code. `update.sh` rebuilds the four platform images for you; check `GET /api/version` afterwards — `version` is the code in service, `image_version` the build it runs inside, and **if they differ the image is stale**. The agent **base image** is separate: when `docker/base-image/` changed in the pulled range, run `./scripts/deploy/build-base-image.sh` on the server, then **stop and start** each agent (or Operating Room → Restart All / `/rebuild-agent`). Since v0.9.0 a cold stop/start detects the rebuilt image and recreates the container itself (`recreate_reason: "image_drift"`); a start of an already-*running* agent never image-recreates it. `update.sh` prints a reminder when the pulled range touched the base image.

### Backup Database

**Trinity backs up its own database since v0.9.0 (#2216)** — nightly at **03:30 UTC**, both backends, default ON, zero setup:

| What | Value |
|------|-------|
| Where | `/data/backups/` in the backend container — `trinity_trinity-data` volume (dev) or `${TRINITY_DATA_PATH}/backups` (prod bind mount) |
| SQLite | `trinity-backup-YYYYMMDD.db` — consistent online copy via SQLite's backup API, `PRAGMA quick_check`-verified before it is kept |
| PostgreSQL | `trinity-backup-YYYYMMDD.dump` — `pg_dump -Fc` (the backend image now bakes `postgresql-client-17`; restore with `pg_restore`) |
| Pre-migration | `pre-migration-YYYYMMDD-HHMMSS.db` — extra boot-time copy taken automatically when a schema migration is about to run (SQLite) |
| Retention | ops setting `backup_retention_days` (default **14**, bounds 1–3650; `0` is *rejected*) via `PUT /api/settings/ops/config`; the newest **3** artifacts are always kept |
| Disable | `DB_BACKUP_ENABLED=false` (turns off the nightly job AND the boot pre-migration copy) |
| Failure visibility | A failed/skipped run raises an operator-queue item under the platform sentinel `_db-backup`; a "backups stale" alarm re-fires weekly while the newest success is > 3 days old |
| Scope | **Same-disk** — protects against corruption, a bad migration, a fat-fingered delete; **not** disk/host loss. Ship `/data/backups/` off-host (rsync/cron after 03:30 UTC, or disk snapshots) for DR |

```bash
# Backup status — last run, last success + age, artifact count/bytes, scope
curl -s -H "Authorization: Bearer $TOKEN" http://$HOST:${BACKEND_PORT:-8000}/api/settings/retention | jq .backup

# List the artifacts on the host
./scripts/run.sh "sudo docker exec trinity-backend ls -lh /data/backups/"
```

**Manual on-demand backup** (before something unusually risky):

```bash
./scripts/backup.sh
# Saves ~/backups/trinity-<timestamp>.db on the host (SQLite, via sqlite3 .backup)
# or ~/backups/trinity-pg-<timestamp>.dump when the instance runs the bundled PostgreSQL
```

`backup.sh` uses the SQLite online-backup API — **never `cp` a live `trinity.db`** (a raw copy mid-write, ignoring its journal, can be torn or stale). On a **managed/external PostgreSQL** (`DATABASE_URL` pointing off-box) use your provider's snapshot tooling or `pg_dump -Fc` against the host.

Also back up **`~/trinity/.env` manually** — it holds `CREDENTIAL_ENCRYPTION_KEY`; a database artifact alone does not cover it.

**Restore (SQLite)** — stop **both** DB writers, remove stale journal sidecars, copy the artifact in, start:

```bash
./scripts/run.sh "cd ${TRINITY_PATH:-~/trinity} && sudo docker compose -f ${COMPOSE_FILE:-docker-compose.prod.yml} stop backend scheduler"
./scripts/run.sh "sudo docker run --rm -v trinity_trinity-data:/data -v ~/backups:/backup alpine sh -c 'rm -f /data/trinity.db-wal /data/trinity.db-shm /data/trinity.db-journal && cp /backup/<artifact>.db /data/trinity.db && chown 1000:1000 /data/trinity.db'"
#   (prod bind mount: -v ${TRINITY_DATA_PATH}:/data; an automatic artifact is already inside the volume at /data/backups/<artifact>.db)
./scripts/run.sh "cd ${TRINITY_PATH:-~/trinity} && sudo docker compose -f ${COMPOSE_FILE:-docker-compose.prod.yml} start backend scheduler"
```

`/rollback [commit] [backup]` runs this sequence for you. **PostgreSQL:** `pg_restore` the `.dump` into an empty database with backend+scheduler stopped, then point `DATABASE_URL` at it.

### Tunnel (remote only)

Opens SSH port-forwarding so you can browse Trinity locally while it's on a remote server:

```bash
./scripts/tunnel.sh
# Then open http://localhost:13000 (or your TUNNEL_FRONTEND port)
```

---

## Agent Management

```bash
source .env

# List agent containers
./scripts/run.sh "sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}' | grep agent-"

# Start / stop agent
./scripts/run.sh "sudo docker start agent-myagent"
./scripts/run.sh "sudo docker stop agent-myagent"

# View agent logs
./scripts/run.sh "sudo docker logs agent-myagent --tail 50"

# Exec into agent
./scripts/run.sh "sudo docker exec -it agent-myagent bash"
```

File sharing is disabled per agent by default. Enable it via the Sharing panel in AgentDetail UI, or via API:

```bash
# Enable file sharing for an agent
curl -s -X PATCH http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"file_sharing_enabled": true}'
```

---

## File Sharing (FILES-001)

Agents can publish files to users via token-scoped download URLs. The file must exist in the agent's `/home/developer/public/` directory.

**From inside an agent** (via MCP tool):
```
share_file — publishes a file and returns a download URL (7-day default expiry)
```

**Ops tasks:**

```bash
source .env
HOST=${SSH_HOST:-localhost}

# Enable file sharing for an agent (also available in AgentDetail > Sharing panel)
curl -s -X PATCH http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"file_sharing_enabled": true}'

# List all shared files for an agent
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/files | jq

# Revoke a shared file
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/files/<file_id> | jq
```

Download URLs follow the form: `http://<host>:<BACKEND_PORT>/api/files/<id>?token=<download_token>`

Files expire after 7 days. One-time files are consumed on first download.

---

## API Access

```bash
source .env
HOST=${SSH_HOST:-localhost}

# Get admin token
TOKEN=$(curl -s -X POST http://$HOST:${BACKEND_PORT:-8000}/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "username=admin&password=$ADMIN_PASSWORD" | jq -r '.access_token')

# List agents
curl -s -H "Authorization: Bearer $TOKEN" http://$HOST:${BACKEND_PORT:-8000}/api/agents | jq

# Fleet health
curl -s -H "Authorization: Bearer $TOKEN" http://$HOST:${BACKEND_PORT:-8000}/api/ops/fleet/health | jq

# Host telemetry (no auth)
curl -s http://$HOST:${BACKEND_PORT:-8000}/api/telemetry/host | jq

# Mint a WebSocket auth ticket (required before opening /ws)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/ws/ticket | jq

# Download a shared file (token from share_file MCP tool response)
curl -s http://$HOST:${BACKEND_PORT:-8000}/api/files/<file_id>?token=<download_token> -o file.bin

# List shared files for an agent
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/files | jq

# Set Slack DM-default agent for a workspace
curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/slack/channel/dm-default | jq

# Audit log (SEC-001 / #20) — list, stats, verify, export
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://$HOST:${BACKEND_PORT:-8000}/api/audit-log?limit=50" | jq
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/audit-log/stats | jq
# verify is TRI-STATE since #1985: valid=true verified, false tampered,
# null unverifiable. Read `status` (verified / verified_partial / tampered /
# unverifiable / empty_range) — it used to answer valid:true, checked:0 for a
# log with no hashes at all, which is the default on any install that never
# enabled hashing. `skipped_unhashed` counts a late-enabled chain's prefix.
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/audit-log/verify | jq    # hash-chain integrity check
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://$HOST:${BACKEND_PORT:-8000}/api/audit-log/export?format=csv" -o audit.csv

# Canary invariant violations (CANARY-001 / #411)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/canary/violations | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/canary/run-cycle | jq    # manual cycle trigger
# Canary RUN-STATE (#2217) — zero violations from a harness that is OFF is
# byte-identical to a clean fleet; this answers enabled / last cycle / sink.
# status = disabled | ok | stale | unknown (fail-open: never `stale` when off).
# Public feature flags also carry a `canary_enabled` boolean for any authed user.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/canary/status | jq

# Version in service vs. image built (#1810/#1814) — `version` is the code
# executing, `image_version` the build it runs inside; DIFFERENT = stale image,
# rebuild the platform images (see Update Trinity)
curl -s http://$HOST:${BACKEND_PORT:-8000}/api/version | jq '{version, image_version, git_commit_short, edition}'

# Admin recovery for soft-deleted agents/schedules (#834)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/admin/soft-deleted/agents | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/admin/soft-deleted/agents/myagent/recover | jq

# A2A v1.0 Agent Card (per agent — public endpoint, no auth)
curl -s http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/a2a/agent-card | jq

# Session Tab — start session, list, message, reset (#685, feature-gated).
# ABSORBED into Workspace in v0.9.0 (#2120 / ent#358; the Sessions page and its
# nav entry are retired, ent#381): the endpoints still exist and still work, but
# the surface lives inside Workspace chats (`?tab=session` redirects to /workspace).
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/session | jq

# Fleet executions dashboard (#18 / #852) — list + summary stats
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://$HOST:${BACKEND_PORT:-8000}/api/executions?limit=50" | jq
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/executions/stats | jq

# Per-schedule execution analytics (#868 / #932)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/analytics | jq

# Per-agent dispatch circuit breaker (#526) — view + configure. Two-tier gate
# (#1487/#1717): the global DISPATCH_BREAKER_ENABLED env must ALSO be true
# (default false) or this per-agent toggle no-ops. Breaker state no longer
# blocks agent autonomy features (#1571).
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/circuit-breaker | jq
curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/circuit-breaker \
  -d '{"enabled": true}' | jq

# Agent runtime-data export / import (#1169) — portability for an agent's
# /home/developer/data dir. Owner/admin only; serialized per agent by a Redis
# lock (409 on contention). Export streams a tar (capped at AGENT_DATA_EXPORT_MAX_BYTES,
# 413 on overflow); import restores into data/ with a data/** allowlist (rejects ../absolute paths).
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/data/export -o myagent-data.tar
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -F 'file=@myagent-data.tar' \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/data/import | jq

# Agent compatibility report / auto-fix (#668) — server-side workspace checks
# (hard/soft/info), surfaced non-blocking in Agent Detail Overview. Read is
# agent-scoped; fix mutates the workspace so it's owner/admin-only (idempotent,
# Redis-locked). Results cached in agent_compatibility_results.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/compatibility | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/compatibility/fix | jq

# Agent structured reports (#918) — agents publish typed reports (JSON payload +
# display_hint) via the `report` MCP tool; operators read them per-agent or fleet-wide.
# Creation rate-limited by REPORT_RATE_LIMIT (30/agent/60s). Stored in agent_reports.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/reports | jq       # per-agent list
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://$HOST:${BACKEND_PORT:-8000}/api/reports?limit=50" | jq           # fleet-wide list
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/reports/stats | jq                # summary stats

# Public webhook trigger (#291 / #1023 / #1424) — fire an agent from an external
# system. PUBLIC (no bearer): auth is the per-agent webhook_token in the path.
# Rate-limited (WEBHOOK_RATE_LIMIT per token, WEBHOOK_IP_RATE_LIMIT per IP, both /60s)
# and body-capped (WEBHOOK_MAX_BODY_BYTES → 413). Returns 202 Accepted.
curl -s -X POST -H 'Content-Type: application/json' \
  http://$HOST:${BACKEND_PORT:-8000}/api/webhooks/<webhook_token> \
  -d '{"message": "run now"}'

# Agent self-reminders (#1296) — one-shot deferred self-triggers set by the
# agent's `set_reminder` MCP tool; operators list and cancel. Caps via REMINDER_* env
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/reminders | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/reminders/<reminder_id>/cancel | jq

# Per-agent MCP connector "Expose via MCP" (#1555) — publish an agent's playbooks
# as MCP tools to external clients; status, enable, mint/revoke connector key.
# One-click "Copy connection config" also available in the UI panel (#1585).
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/connector | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/connector/key | jq   # returns the secret ONCE

# Agent display label (#1642/#1676) — human-facing name; the slug (agent_name)
# stays immutable so container/volume/API identity never moves
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/label -d '{"label": "My Agent"}' | jq

# Effective data-retention windows + approve an over-threshold prune (#1039/#1644/#1709)
# Since v0.9.0 the response also carries `backup` (the #2216 automatic-backup status
# block) and `blocked_sweeps` (#2146: sweeps the guard refuses for a NON-approvable
# reason — count_uninterpretable / count_negative / ack_lookup_failed — which used
# to render as a clean "nothing pending"). `pending_acknowledgements` stays the
# approvable list.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/retention | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/retention/acknowledge \
  -d '{"key": "<sweep_key>", "window_days": <days>}' | jq   # human-only; agent-scoped keys rejected. 409 unless window_days matches the window in force
# Ops settings incl. the row-retention windows and `backup_retention_days` (#2216;
# 1-3650, `0` REJECTED — disabling backups is DB_BACKUP_ENABLED=false, never keep-forever)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/ops/config | jq
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/ops/config -d '{"backup_retention_days": 30}' | jq

# Fleet telemetry-sharing consent (#1723) — opt-in aggregate sharing; default off
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/telemetry-sharing | jq

# Proactive-message rate limits (#1609) — admin-tunable channel send caps
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/proactive-rate-limits | jq

# Per-agent schedule freeze while git sync is failing (#1808) — view + toggle
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/git/freeze-schedules-if-failing | jq

# Credential env drift (#1999 / #2010) — per-key divergence between the agent's
# .env and the env its executions actually receive. The ONE view that shows it:
# /proc/<pid>/environ and `docker exec` both agree with the FILE and disagree
# with what a spawn gets. Owner/admin AND human-only (agent-scoped keys rejected)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/credentials/env-drift | jq

# Per-agent Trinity MCP key (#1854) — status / config-truth probe / rotate.
# verify runs one `docker exec` returning only sha256(bearer) per .mcp.json entry
# (token never crosses the container boundary). regenerate returns METADATA only,
# never plaintext, and recreates the container to deliver the new key.
# Owner/admin + human-only + rate-limited per agent AND per actor.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/mcp-key | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/mcp-key/verify | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/mcp-key/regenerate | jq

# Fleet execution timeline (#1983) — bucketed rollups over a rolling window
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://$HOST:${BACKEND_PORT:-8000}/api/executions/timeline?group_by=day&hours=168" | jq
#   group_by = hour | day | trigger | agent · hours = rolling window (default 168)
#   &agent=myagent to scope to one agent · &split=trigger (ent#96, v0.9.0) adds a
#   second dimension over a TIME grouping only (hour|day) — 422 on trigger/agent

# A2A INBOUND server (#1628) — Trinity serves the A2A protocol so EXTERNAL agents
# can task yours. PUBLIC, no auth, but per-agent opt-in: nothing is served unless
# agent_ownership.a2a_exposed = 1 (default 0). Set it with the `set_agent_a2a_exposure`
# MCP tool. The per-caller inbound allow-list is an entitled feature.
curl -s http://$HOST:${BACKEND_PORT:-8000}/a2a/myagent/.well-known/agent-card.json | jq
#   POST /a2a/myagent  — JSON-RPC (message/send, tasks/get) + SSE

# A2A OUTBOUND (#736) — your agent tasking an EXTERNAL A2A agent. Default OFF.
# Two independent gates: A2A_OUTBOUND_ENABLED (env; a system_settings row wins
# and needs no restart) AND at least one endpoint registered below. Agents pick a
# target by NAME and can never supply a URL. Registering an endpoint IS a trust
# decision — a cooperating remote can return its own payload to the calling agent.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/a2a-endpoints | jq   # creds never returned
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/a2a-endpoints \
  -d '{"name": "partner-bot", "url": "https://...", "credentials": "..."}' | jq
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/a2a-endpoints/<ref> | jq
#   Runtime call paths: POST /api/agents/{name}/a2a/call (sync) and .../a2a/task (async)

# Skills library sources (#1901) — the library is MULTI-SOURCE: a bundled community
# repo plus per-instance custom repos. Sources CRUD + on-demand sync.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/skills/sources | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/skills/sources/<source_id>/sync | jq
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/skills/library/status | jq
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/skills/assignments | jq   # which agents have which skill

# Skills-library lifecycle automation (#1883) — auto-sync + fleet re-inject, both
# default OFF. GET also reports last_sync_status / last_sync_error / last fleet
# re-inject report: the loop runs on ONE leader worker, so this is where a FAILING
# auto-sync is visible. Blast radius bounded by SKILLS_RECONCILE_MAX_REMOVALS.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/skills-library | jq

# Remote template registry (#2033) — the GitHub half of the agent-template catalog,
# fetched at runtime. Default ON (outbound egress on a default install). GET is the
# ONLY place a failing fetch is visible: every failure mode degrades to the bundled
# list silently by design. `hard_disabled` = TEMPLATE_REGISTRY_ENABLED=false, which
# no DB row can override. An admin-curated GitHub list suppresses the fetch entirely.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/template-registry | jq

# Bundled system manifests (#1911) — the cards on Library -> Install a system.
# Directory selected by TRINITY_MANIFESTS_DIR; an unreadable path yields an EMPTY
# catalog rather than an error, so the directory must be bind-mounted too.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/systems/manifests | jq

# Bind an agent to a GitHub repo you own (#1947) — post-creation ownership retrofit
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/git/bind-to-own-repo/status | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/git/bind-to-own-repo \
  -d '{"repo": "owner/name"}' | jq

# Behavioral evaluations (#1752) — referee surface over completed executions
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/evaluations | jq
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/evaluations | jq              # fleet-wide

# Workspace / client portal (#2084) — OSS core since v0.9.0 (it was an entitled
# enterprise module). Route prefix stays /api/enterprise/client-portal for
# compatibility with existing API-only integrations; it is NOT edition-gated.
# Clients sign in with a verified email and no platform account.
curl -s http://$HOST:${BACKEND_PORT:-8000}/api/enterprise/client-portal/auth/request \
  -X POST -H 'Content-Type: application/json' -d '{"email": "client@example.com"}'
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/enterprise/client-portal/agents/myagent/clients | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/enterprise/client-portal/agents/myagent/clients/<email>/logout | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/enterprise/client-portal/agents/myagent/clients/<email>/block | jq

# Workspace session policy actually in force (#2099) — sessions SLIDE (idle +
# absolute windows) rather than expiring at a fixed 12h. READ is available in every
# edition, like GET /api/settings/retention; only the setter is entitled.
# `sources` distinguishes db-row (an operator chose it) from code-default.
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/portal-session-policy | jq
```

---

## Database Operations

> **Backend depends on `DATABASE_URL`.** The `sqlite3` recipes below target the **default SQLite** backend (file in the `trinity_trinity-data` volume). If the instance runs on **PostgreSQL** (see [Database Backend](#database-backend-sqlite-default--postgresql-300)), query it with `psql` instead — e.g. `./scripts/run.sh "sudo docker exec trinity-postgres psql -U trinity -d trinity -c 'SELECT agent_name, owner_id FROM agent_ownership'"`. Schema is identical across both backends.

```bash
# List tables
./scripts/run.sh "sudo docker run --rm -v trinity_trinity-data:/data alpine sh -c 'apk add --quiet sqlite && sqlite3 /data/trinity.db \".tables\"'"

# Query agents
./scripts/run.sh "sudo docker run --rm -v trinity_trinity-data:/data alpine sh -c \"apk add --quiet sqlite && sqlite3 /data/trinity.db 'SELECT agent_name, owner_id FROM agent_ownership'\""

# Query shared files (FILES-001)
./scripts/run.sh "sudo docker run --rm -v trinity_trinity-data:/data alpine sh -c \"apk add --quiet sqlite && sqlite3 /data/trinity.db 'SELECT agent_name, filename, size_bytes, expires_at, revoked_at FROM agent_shared_files ORDER BY created_at DESC LIMIT 20'\""
```

Key tables:

| Table | Purpose |
|-------|---------|
| `agent_ownership` | Agent registry + per-agent flags (`file_sharing_enabled`, `deleted_at` for soft-delete, `circuit_breaker_enabled` #526, `display_label` #1676 — human-facing name over the immutable slug, `volume_base_name` #1666 — data-volume identity frozen at rename, `a2a_exposed` #1628 — A2A inbound-server opt-in, default 0). The free-text `type` column is **gone** (#2104/#2115) — it carried no behavior and most agents wore a stale default |
| `agent_schedules` | Cron schedules + `deleted_at` for soft-delete (#834) |
| `agent_shared_files` | Outbound file shares — token-scoped download URLs with expiry |
| `agent_sessions` / `agent_session_messages` | Session Tab persistent chat (SESSION_TAB_2026-04, feature-gated). Surface being absorbed into Workspace (#2120); tables and endpoints still live |
| `agent_events` / `agent_event_subscriptions` | Event bus (EVT-001) — emit/subscribe between agents |
| `agent_loops` / `agent_loop_runs` | Sequential agent loops (#740) — `run_agent_loop` MCP tool + web UI |
| `idempotency_keys` | Dedup at execution-trigger boundaries (#525) — prevents double-dispatch |
| `voip_bindings` / `voip_call_logs` | VoIP telephony (VOIP-001 / #1056) — per-agent Twilio creds + outbound call log |
| `audit_log` | Audit trail with hash chain (SEC-001 / #20). Pruned to 365 days automatically |
| `canary_violations` | Orchestration-invariant violations (CANARY-001 / #411) |
| `agent_compatibility_results` | Cached per-agent workspace compatibility checks (#668) — populated by `/api/agents/{name}/compatibility` |
| `agent_reports` | Agent structured reports (#918) — `report_type`, `title`, `payload` (JSON), `display_hint`, optional `period_start`/`period_end`. Written by the `report` MCP tool; read fleet-wide via `/api/reports` |
| `public_user_memory` | Per-user memory written by `write_user_memory` MCP tool (MEM-001 / #888) |
| `public_chat_sessions` / `public_chat_messages` | Public-link chat sessions |
| `slack_channels` | Slack workspace↔agent bindings + DM default routing |
| `agent_reminders` | Agent self-reminders (#1296) — one-shot deferred self-triggers set via the `set_reminder` MCP tool; listed/cancelled via `/api/agents/{name}/reminders` |
| `product_events` | Local product-event capture (#1721) — activation-funnel events; stays on-instance unless telemetry sharing is explicitly enabled |
| `enterprise_connectors` | Per-agent MCP connector state (#1555, "Expose via MCP") — enabled flag + exposed playbooks; table name kept for compatibility |
| `skill_sources` | Multi-source skills library (#1901) — one row per library source (bundled community repo + per-instance custom repos). `agent_skills.source_id` names which source a skill came from |
| `agent_evaluations` | Behavioral evaluations (#1752) — referee verdicts over completed executions; read via `/api/evaluations` |
| `enterprise_portal_sessions` / `enterprise_portal_messages` / `enterprise_portal_chat_state` / `enterprise_client_blocks` | Workspace / client portal (#2084) — **OSS core**, not entitled. Client sessions (sliding idle+absolute windows, #2099), thread messages, per-chat star/unread state, and per-agent client blocks. `enterprise_` prefix kept for compatibility |

**Channel columns (#2 channels wave):** `telegram_bindings.progress_indicator_enabled` (per-binding in-flight reaction ack, default 1), `telegram_group_configs.allow_proactive` (per-group proactive send consent, default 1), and `schedule_executions.source_channel_agent` (which channel-bound agent originated a run, for completion report-back).

**Soft-delete (#834):** `agent_ownership` and `agent_schedules` have `deleted_at` columns; rows aren't physically removed on delete. Retention sweep purges rows past TTL. Use `/api/admin/soft-deleted/*` to list and recover.

---

## Provisioning a New Instance

Trinity runs on any Linux VM with Docker. Choose your provider:

| Provider | Guide | Cheapest option |
|----------|-------|-----------------|
| **Hetzner** | `provision/hetzner.md` | CX23 at €3.49/month |
| **Google Cloud** | `provision/gcp.md` | e2-medium ~$40/month |
| **AWS** | `provision/aws.md` | t3.medium ~$30/month |
| **DigitalOcean** | `provision/digitalocean.md` | s-2vcpu-4gb $24/month |
| **Localhost** | `provision/localhost.md` | Free |

All guides provision Ubuntu 24.04 with Docker via cloud-init, then walk you through installing Trinity and pointing this ops agent at the instance.

### Minimum Server Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 2 GB | 4 GB |
| Disk | 20 GB | 50 GB |
| OS | Ubuntu 22.04+ | Ubuntu 24.04 |

### Installing Trinity on a Fresh Server

**One-line install (recommended):**

```bash
# SSH into the server
ssh user@<SERVER_IP>

curl -fsSL https://raw.githubusercontent.com/abilityai/trinity/main/install.sh | bash
```

**Manual install:**

```bash
# Clone Trinity
git clone https://github.com/abilityai/trinity.git ~/trinity
cd ~/trinity

# Configure
cp .env.example .env
nano .env
```

Minimum `.env` for Trinity:

```bash
# Required — you must set this; no sensible default
ADMIN_PASSWORD=your-secure-password         # login password (12+ chars)

# For agents to run
ANTHROPIC_API_KEY=sk-ant-...
```

Everything else (`SECRET_KEY`, `CREDENTIAL_ENCRYPTION_KEY`, `INTERNAL_API_SECRET`, `REDIS_PASSWORD`, `REDIS_BACKEND_PASSWORD`, `AGENT_AUTH_SECRET`) is **auto-generated by `start.sh` on first run** (#443, #589, #1159). `DOCKER_GID` is auto-detected by probing the GID a container sees on the Docker socket (#1131) — works on native Linux, Docker Desktop, Colima and rootless (not just `getent group docker`).

```bash
# Build base image and start services
./scripts/deploy/build-base-image.sh
./scripts/deploy/start.sh

# Verify
curl http://localhost:8000/health
```

**Unattended install (#1708):** `./scripts/deploy/start.sh --unattended` (or `TRINITY_UNATTENDED=1`) removes the interactive hard-stops — a missing `ADMIN_PASSWORD` is auto-generated and printed in the end-of-run summary instead of blocking on a prompt. Use for scripted/agent-driven installs.

On first launch, open `http://<SERVER_IP>` — the setup wizard will prompt you to set your admin password and configure API keys. After first-time setup, a genuinely fresh install auto-deploys a bundled starter fleet once (#1764); set `TRINITY_DEFAULT_SYSTEM_MANIFEST=disabled` beforehand to skip it, or point it at your own manifest file.

**Outbound egress on a default install (#2033):** the agent-template catalog fetches a vendor-published `registry.yaml` at runtime, and `TEMPLATE_REGISTRY_ENABLED` defaults to **true**. It sends nothing about the operator (it is a package-index read, like npm or Homebrew) and is deliberately *not* covered by `DO_NOT_TRACK`, but it is still a network call. For air-gapped or policy-strict installs set `TEMPLATE_REGISTRY_ENABLED=false` before first start — that is a hard kill switch no admin toggle or DB row can override. Curating your own GitHub template list in Settings also suppresses the fetch entirely.

---

## Service Architecture

| Container | Port (host:container) | Purpose |
|-----------|----------------------|---------|
| `trinity-backend` | 8000:8000 | FastAPI REST API — runs as UID 1000 (#874). Image bakes `postgresql-client-17` since v0.9.0 (#2216) for the nightly `pg_dump` arm — major-pinned so an unrelated rebuild can never move it; a PG server major above 17 fails the backup **loudly** (operator alarm), never silently |
| `trinity-frontend` | 80:8080 | Vue.js Web UI — unprivileged nginx (#874) |
| `trinity-mcp-server` | 8080:8080 | MCP Protocol Server |
| `trinity-scheduler` | 8001:8001 | Scheduled tasks — runs as UID 1000 |
| `trinity-redis` | 6379:6379 | Sessions, credentials, WS auth tickets — ACL-protected, two users (#589) |
| `trinity-vector` | 8686:8686 | Log aggregation — runs as root but joins GID 1000 via `group_add` (#1799) so its file sink can write the UID-1000-owned `/data/logs`; `cap_drop: ALL` strips `CAP_DAC_OVERRIDE`, so without the group root's writes fail *silently* (healthcheck stays green) |
| `trinity-logs-init` | — | One-shot `alpine` init (#1478): `chown 1000:1000 /data/logs` so UID-1000 Vector retention can write. Backend `depends_on` it (`service_completed_successfully`); exits immediately, `restart: no` |
| `trinity-archives-init` | — | **Dev compose only** — the missed sibling of `logs-init` (#2205, v0.9.0): `chown 1000:1000 && chmod 775 /data/archives` on the named `trinity-archives` volume, which Docker creates root-owned, so the UID-1000 backend could never write it and log archival died silently on every run. Runs on every `up` (repairs existing installs, idempotent); backend `depends_on` it. **Prod needs none**: `/data/archives` lives inside the `${TRINITY_DATA_PATH}` bind mount that `start.sh` chowns recursively |
| `trinity-postgres` | 5432:5432 | **Optional** PostgreSQL backend (#300) — dev-compose only, behind `--profile postgres`. Off by default (SQLite). See [Database Backend](#database-backend-sqlite-default--postgresql-300). |
| `agent-{name}` | — | Per-agent isolated containers |

**Container log rotation (#1871):** Docker's `json-file` driver has **no** size cap by default, so every container log under `/var/lib/docker/containers/` grew forever — silently, until the Docker data root filled and dockerd wedged. Two mechanisms, because the two container kinds are created two different ways:

- **Platform services** — a shared `x-logging` anchor in both compose files, interpolated from `CONTAINER_LOG_MAX_SIZE` / `CONTAINER_LOG_MAX_FILE`. Adopted on the next `docker compose up`.
- **Agent containers** — created through the Docker SDK, not compose, so compose's `logging:` can never reach them. Capped from `AGENT_LOG_MAX_SIZE` / `AGENT_LOG_MAX_FILE`, read by the **backend** at import time. Existing agents adopt a change when **recreated**, not merely restarted.

Defaults are 10m × 3 = 30 MB per container (~4 days for a busy agent). An invalid or out-of-range value logs a warning and falls back to the default, so a typo can never leave a container uncapped. The raw Docker log is a secondary copy — Vector's aggregate at `/data/logs` is the primary, queryable one and has its own `LOG_RETENTION_DAYS`. Its archival into `/data/archives` (`LOG_ARCHIVE_ENABLED`) was **dead on every dev install before v0.9.0** (#2205, root-owned archives volume) — expect the first archival pass after upgrading to reclaim a backlog, and an unwritable archive dir now raises an operator-queue alarm under the `_log-archive` sentinel instead of failing into the very logs it cannot prune.

**Network topology (#589):** Two bridges replace the old single network.
- `trinity-platform-network` — Redis, scheduler, backend, mcp-server, vector, otel, **postgres**. Agents NEVER join (so agents can never reach the database).
- `trinity-agent-network` — agents, frontend, plus bridges (backend, mcp-server, otel, cloudflared). Name preserved for backward compatibility.

---

## Database Backend (SQLite default / PostgreSQL #300)

Trinity selects its database from a single env var, `DATABASE_URL`, resolved at backend startup. **SQLite is the zero-config default and its behavior is unchanged** — PostgreSQL is experimental and entirely opt-in.

| `DATABASE_URL` | Backend |
|----------------|---------|
| *unset* or empty | **SQLite** at `TRINITY_DB_PATH` (default `/data/trinity.db`) |
| `sqlite:////data/trinity.db` | SQLite (explicit) |
| `postgresql://user:pass@host:5432/dbname` | **PostgreSQL** |

Both the backend and the standalone scheduler read the same `DATABASE_URL`, so they always agree on the store. The flag is **not sticky** — switching is non-destructive (the two stores are independent volumes); comment it out and the next restart is back on SQLite.

**Dev vs prod is the key ops distinction:**
- **Dev `docker-compose.yml`** bundles a `postgres:16-alpine` service (container `trinity-postgres`) gated behind the `postgres` **compose profile**. Enable with `POSTGRES_PASSWORD` set, then `docker compose --profile postgres up -d`.
- **Prod `docker-compose.prod.yml` ships NO postgres service.** A `postgresql://` URL in prod must point at an **operator-managed** PostgreSQL (RDS, Cloud SQL, a separate VM). The backend/scheduler/agent containers must be able to reach that host:port.

**On first (cold) start** against an empty Postgres, the backend runs `alembic upgrade head` — the `0001_baseline` revision builds the ~61 base tables plus append-only audit-log triggers, the incremental revisions on top of it (30+ as of v0.8.5, e.g. `agent_reminders`, `product_events`) bring the schema to head, then the admin user is seeded from `ADMIN_PASSWORD`. The instance starts in first-run setup (`setup_required` on login is expected, not an error). Alembic owns the PG schema; **SQLite keeps its separate `db/migrations.py` runner** — the two coexist during the transition.

**Migrating an existing SQLite instance:** upstream's `init_database()` only *bootstraps* a fresh PG DB — it has no SQLite→PG data copy. This ops agent ships the **`/migrate-to-postgres`** skill (`.claude/skills/migrate-to-postgres/`) to close that gap: it stands up Postgres alongside the running instance, trial-copies + validates the data via a dialect-aware ETL, then cuts over in a short downtime window with one-line rollback (the SQLite file is never written). Gated at every state-changing step.

**Limitations:**
- A brand-new Postgres DB (no `/migrate-to-postgres` run) is *fresh and empty* — enabling `DATABASE_URL` alone copies no data.
- Experimental — not yet the recommended production default. New SQL must stay dialect-portable.

> **SQLite end-of-support: September 1, 2026 (#1278).** Upstream has announced PostgreSQL as the forward path: SQLite installs keep working after the date but stop receiving schema migrations and fixes, so staying on SQLite past EOL means pinning a pre-EOL Trinity release. Plan the `/migrate-to-postgres` cutover before then. Announcement: `docs/migrations/SQLITE_TO_POSTGRES.md` on the server.

**Backups:** automatic for **both** backends since v0.9.0 (#2216) — nightly `trinity-backup-YYYYMMDD.db` (SQLite backup API) or `.dump` (`pg_dump -Fc`, client baked into the backend image) under `/data/backups`, plus a boot-time `pre-migration-*.db` when a migration is pending. Manual: `scripts/backup.sh` (SQLite `.backup` / bundled-PG `pg_dump -Fc`). See [Backup Database](#backup-database).

**Rollback to SQLite:** comment out `DATABASE_URL`, `docker compose up -d` — the Postgres volume is untouched and can be re-enabled later.

Full guide on the server: `docs/POSTGRESQL_SETUP.md` (covers verification, pooling tunables, dialect gotchas). Selector code: `src/backend/db/engine.py`.

---

## Security Notes

### Trust model & prompt-injection boundary (Issue #1523)

This agent operates a live Trinity instance, so treat its decisions as suggestions and keep **enforcement separate**. The model deciding to invoke a skill — even a state-changing one like `/migrate-to-postgres` — is **not** a security boundary, and neither are the `[APPROVAL GATE]` lines or `automation: gated` frontmatter inside a skill: those are instructions to a cooperative model, and a prompt injection that fabricates "approval already given" walks straight past them. "Operator-only" constrains *who drives* the agent, not *what it reads* — content the agent ingests while working is a second-order injection channel. What actually holds the line (and survives a subverted model):

- **No live database handle.** The agent holds no production `DATABASE_URL` and issues no queries. Every effect is a shell command over SSH whose key lives on *your* machine — the boundary is credential custody plus the per-command gate below, not a sandbox (over SSH the ops role is privileged; see the least-privilege note).
- **Harness per-command approval is the enforced gate.** Claude Code prompts *you* to approve each `Bash`/SSH tool call, outside the model's context, so an injection can't forge or skip it. This is only as strong as your tool-permission allowlist — keep it least-privilege and **do not broadly auto-allow remote-execution commands**, or you leave a path around the prompt.
- **Destructive skills are non-destructive by construction.** `/migrate-to-postgres` reads the live DB strictly read-only, stands PostgreSQL up *alongside* it, and cuts over by appending one env var (rollback = deleting it); `/rollback` and `/update` snapshot first. The blast radius of a fully-hijacked run is bounded and reversible, and these skills take almost no free-form arguments to poison.
- **Ingested content is untrusted input.** Skills that read externally-influenceable text — access-request emails, container/execution logs, error text, in-app bug reports — are an injection surface even though only operators drive this agent. Treat that content as data, not instructions, and be extra deliberate with any skill that runs autonomously (no per-command gate).

Further hardening is tracked in [`abilityai/trinity#1523`](https://github.com/abilityai/trinity/issues/1523).

### Admin gates reject agent-scoped principals (v0.9.0, ent#297)

`require_admin` / `assert_admin` now refuse **any agent-scoped MCP key**, even one owned by an admin. Before this, an admin-owned agent's `TRINITY_MCP_API_KEY` was admin on every admin-gated route (~114 of them) — the root cause of four prior escalations, including a fleet-wide prompt-injection path via `PUT /api/settings/skills_library_url` (ent#293/#346). **If automation drove admin endpoints with an *agent's* key, it now 403s — switch it to a user-scoped key** (`/api/settings/api-keys`). Agent self-check flows (heartbeat, reports, result callbacks, `set_reminder`, `report`) are unaffected. This is the general rule behind the per-endpoint "human-only" notes elsewhere in this file.

### Access-control tightening (CSO 2026-08-09, #2081)

Three gates moved up a tier. If a workflow that used to work now 403s, this is why:

- **Agent terminal WebSocket is owner/admin, not accessor tier.** A chat-only shared collaborator could open `/bin/bash` in the container and read `CLAUDE_CODE_OAUTH_TOKEN`, `TRINITY_MCP_API_KEY` and `.env`. It now mirrors the deliberately admin-only SSH endpoint.
- **Schedule enable / disable / trigger are owner-only**, matching update/delete — shared users can no longer flip owner-intent schedule state.
- **`GET /api/event-subscriptions/{id}`** now runs the same ownership check its `PUT`/`DELETE` siblings already enforced.

Also in this pass: `npm install` → `npm ci` in the mcp-server and frontend prod Dockerfiles (restores the tracked lockfile as a supply-chain control), and `permissions: contents: read` on the build/deploy workflows.

### MCP Inline Email Auth (Issue #848)

Off by default (`MCP_INLINE_AUTH_ENABLED=false`), and worth understanding before turning on: with it off, an unauthenticated MCP connection is refused outright. With it on, a connection carrying **no** `Authorization` header opens an anonymous session that can sign in with a 6-digit email code and then use the connector playbooks of agents shared with that address. An *invalid* key is still rejected either way.

**Expose the MCP port over TLS only when this is on (#2035).** A keyless session is held by the `Mcp-Session-Id` header, which the client resends on every request — for this tier that header **is** the credential, and anyone who can read it off the wire has the signed-in session until it expires. A keyless session ends only by expiring (30 min idle / 4 h absolute) or by an mcp-server restart; there is no logout, and clearing the conversation in an MCP client does not end the transport session. Keyed connector clients are unaffected.

Requires `INTERNAL_API_SECRET` — the mcp-server relays login and the resulting agent calls over `/api/internal/mcp-auth/*`, which the backend gates on the verified email's own access per call. See the `INTERNAL_API_SECRET` row in the env reference.

### Outbound A2A is a trust decision (Issue #736)

`A2A_OUTBOUND_ENABLED` turns on the platform's first backend-executed, credentialed, agent-triggerable outbound fetcher. The design bounds it — agents pick a target by **name** from an admin-registered list and can never supply a URL, and stored credentials are never returned by any read — but registering an endpoint grants the remote a channel back into the calling agent: a cooperating remote can return its own payload, and no sanitiser can stop a transformed secret. Register only endpoints you would trust with the agent's context.

### Redis ACL (Issue #589)

Redis runs `requirepass` + per-user ACLs. Two passwords are mandatory; compose refuses to render without both:

- `REDIS_PASSWORD` — admin (`default` ACL user). Recovery and ad-hoc ops.
- `REDIS_BACKEND_PASSWORD` — runtime user (`backend` ACL). Used by backend + scheduler containers. `-@dangerous` denied (no `FLUSHALL`/`CONFIG`/`SHUTDOWN`).

`REDIS_URL` is composed at render time and embeds `backend:<pwd>` — **do not set it manually** in `.env`. The healthcheck pings as the `backend` user so a typo'd ACL keeps Redis unhealthy and gates dependents.

Existing prod deployments must follow `docs/migrations/REDIS_AUTH.md` before upgrading — re-keying populated Redis without that path locks the backend out.

### Agent Auth Secret (Issue #1159)

`AGENT_AUTH_SECRET` is the master from which the backend derives each agent's in-container `:8000` auth token. `start.sh` auto-generates it on first boot if blank (`openssl rand -hex 32`).

- **Stability is critical:** rotating it 401s the entire running fleet until every agent container is recreated. Treat it like `CREDENTIAL_ENCRYPTION_KEY` — set once, don't change.
- **Prod forwards it explicitly:** `docker-compose.prod.yml` passes `AGENT_AUTH_SECRET=${AGENT_AUTH_SECRET:-}` into the backend — a bare `.env` value is inert in prod without it. The backend hard-fails on the first agent call if the secret is unset.

### Credential Key Rotation (Issue #267)

`CREDENTIAL_ENCRYPTION_KEY` encrypts all stored OAuth/MCP/subscription credentials — losing it is unrecoverable, so it's normally set once and never touched. When you *must* rotate it (suspected exposure), the DB still holds ciphertext under the old key, so you need a two-key window:

1. Put the **new** key in `CREDENTIAL_ENCRYPTION_KEY` and the **previous** key in `CREDENTIAL_ENCRYPTION_KEY_SECONDARY` (decrypt-only fallback).
2. Run `scripts/deploy/rotate-credential-key.py --apply` on the server — it re-encrypts every stored credential under the new key.
3. Remove `CREDENTIAL_ENCRYPTION_KEY_SECONDARY` and restart.

Leave `CREDENTIAL_ENCRYPTION_KEY_SECONDARY` empty in normal operation. Full guide on the server: `docs/migrations/CREDENTIAL_KEY_ROTATION.md`.

### Non-root containers (Issue #874)

Backend, scheduler, and frontend nginx all run as UID 1000.

- **Backend → Docker socket:** backend joins the socket's owning group via compose's `group_add: ${DOCKER_GID:-999}`. The GID to join is whatever a *container* sees on `/var/run/docker.sock`: a Linux bind mount exposes the host `docker` group (Debian/Ubuntu 999, RHEL ~991, Arch 990); **Docker Desktop / Colima / Rancher / rootless present it root-group-owned (GID 0)**. `start.sh` auto-detects on first run by probing the GID a throwaway container sees on the socket (correct on every runtime), falling back to host `getent group docker` only offline. Docker Desktop does **not** ignore `group_add` — assuming it did was the #1131 regression, so the value matters on every runtime.
- **Frontend nginx:** binds 8080 in-container (unprivileged). Host port mapping is `80:8080`, so external URLs are unchanged. `NET_BIND_SERVICE`/`CHOWN`/`SETGID`/`SETUID` removed.
- **Data directory:** `start.sh` chowns `${TRINITY_DATA_PATH:-./trinity-data}` to 1000:1000 on Linux before compose up (otherwise Docker creates it root-owned and UID 1000 can't write `trinity.db`).

### WebSocket Authentication

WebSocket connections use single-use tickets instead of JWT-in-URL. Browser clients must:
1. Call `POST /api/ws/ticket` (with JWT in `Authorization` header) to mint a 30-second opaque ticket
2. Open `/ws?ticket=<ticket>` — the ticket is consumed on first use

Tickets live in Redis (`trinity-redis`). If Redis is down, WebSocket connections will fail.

### MCP Config Validation

`.mcp.json` files written via credential inject are validated by `mcp_validator.py` before reaching the agent container. This prevents RCE-by-config attacks (AISEC-C2). The validator enforces:
- Command allowlist, no shell metachars, no path separators
- HTTPS-only for HTTP/SSE transports with SSRF guard — loopback, RFC 1918, link-local/IMDS, multicast, and since v0.9.0 the RFC 6598 CGNAT range `100.64.0.0/10`, plain and IPv4-mapped (ent#393/#394)
- Env var reference allowlist (no `PATH`, `LD_PRELOAD`, API keys, etc.)
- Bounded: 64KB max, 32 servers max

### Protected Files

The following files cannot be written via `PUT /api/agents/{name}/files` or credential inject:
`.mcp.json.template`, `.credentials.enc`, `.env*`, `.ssh/*`, `.aws/*`, `.gcp/*`, `.claude/settings*`, `.trinity/*`, `.git/*`

---

## Troubleshooting

### Agent container won't start

Network reference issue — remove and recreate:

```bash
./scripts/run.sh "sudo docker rm agent-myagent"
./scripts/run.sh "sudo docker restart trinity-backend"
# Then start via UI or API
```

### Backend not responding

```bash
./scripts/run.sh "sudo docker logs trinity-backend --tail 100"
./scripts/run.sh "sudo docker restart trinity-backend"
sleep 5
./scripts/run.sh "curl -s http://localhost:${BACKEND_PORT:-8000}/health"
```

### Backend flaps to `unhealthy` during scheduled-batch windows

Issue #1230 — with only 2 uvicorn workers, scheduled-batch windows leave them GIL-contended, so a `/health` probe can wait out the timeout and 3 aborts would flip the container to `unhealthy` even though `/health` served 200s throughout. A consumer of Docker health (autoheal, `depends_on: service_healthy`, LB drain) could then restart the backend mid-batch and orphan in-flight executions. The prod healthcheck is now relaxed — `timeout: 30s`, `retries: 5`, `start_period: 60s` — to absorb the spike while a genuine outage (all probes fail) still trips after ~5 intervals. If you see brief `unhealthy` flaps that self-recover, confirm the probe is using these values rather than the old 10s timeout.

### Whole fleet returns 401 after a config change

Issue #1159 — every agent's in-container `:8000` token is derived from `AGENT_AUTH_SECRET`. If that secret was rotated, regenerated, or (in prod) not forwarded into the backend, **all** running agents 401 at once.

```bash
./scripts/run.sh "grep -E '^AGENT_AUTH_SECRET=' ~/trinity/.env"
./scripts/run.sh "sudo docker logs trinity-backend --tail 100 2>&1 | grep -iE 'agent_auth|401|auth secret'"
```

Restore the original secret if it was changed; recreating the agent containers re-derives tokens from the current secret. See [Agent Auth Secret](#agent-auth-secret-issue-1159).

### Disk space

```bash
./scripts/run.sh "df -h /"
./scripts/run.sh "sudo docker system df"

# Clean unused Docker resources (dry run first)
./scripts/run.sh "sudo docker system prune --dry-run"
./scripts/run.sh "sudo docker system prune -f"
```

### Out of memory

```bash
./scripts/run.sh "free -h"
./scripts/run.sh "sudo docker stats --no-stream"
```

### Redis won't start or backend can't connect

Issue #589 — Redis requires both `REDIS_PASSWORD` and `REDIS_BACKEND_PASSWORD`. Compose fails to render without them.

```bash
./scripts/run.sh "sudo docker logs trinity-redis --tail 30"
./scripts/run.sh "grep -E '^REDIS_(PASSWORD|BACKEND_PASSWORD)=' ~/trinity/.env"
```

- **Empty values:** re-run `./scripts/deploy/start.sh` on a **fresh install** to auto-generate them.
- **Empty values with an existing `redis-data` volume:** see `docs/migrations/REDIS_AUTH.md`. Re-keying populated Redis locks the backend out.
- **`WRONGPASS` in healthcheck:** the `backend` ACL user can't authenticate. Check that `REDIS_URL` in backend env matches `REDIS_BACKEND_PASSWORD` (compose builds it automatically; don't override).

### Backend can't reach Docker socket

Issue #874 / #1131 — backend runs as UID 1000 and joins the socket's group via `group_add`. If `DOCKER_GID` is wrong, Docker SDK calls fail silently. The GID must match what a *container* sees on the socket, not just the host `docker` group — on Docker Desktop / Colima / Rancher / rootless that's **GID 0**, not 999.

```bash
# What GID does a container actually see on the socket? (authoritative on every runtime)
./scripts/run.sh "sudo docker run --rm -v /var/run/docker.sock:/var/run/docker.sock alpine stat -c '%g' /var/run/docker.sock"
# Host docker group (matches the above only on a native Linux daemon)
./scripts/run.sh "getent group docker | cut -d: -f3"
# Compare with .env
./scripts/run.sh "grep DOCKER_GID ~/trinity/.env"
```

Re-run `start.sh` to auto-detect (it probes the container's socket GID), or set `DOCKER_GID=<gid>` manually and `docker compose up -d` again.

### Scheduled runs silently skipped while git sync is failing

Issue #1808 — the per-agent `freeze_schedules_if_sync_failing` flag is now actually enforced: when an agent's git sync is red and the flag is on, the scheduler pauses that agent's scheduled executions (previously the flag existed but did nothing). The hold is surfaced in the Schedules tab (#1798) and in reminder dispatch (#1807). If an agent's schedules stop firing:

```bash
# Is the freeze flag on, and is sync actually failing?
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/git/freeze-schedules-if-failing | jq
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/git/status | jq
```

Fix the sync failure (or toggle the flag off via `PUT` on the same endpoint) and schedules resume.

### Vector healthy but no log files written

Issue #1799 — `/data/logs` is chowned to 1000:1000 mode 775 (#1478), and Vector's `cap_drop: ALL` strips `CAP_DAC_OVERRIDE` — the capability that lets root ignore file permissions. Root-run Vector then falls through to "other" (`r-x`) and **every file-sink write fails silently**: sink errors don't fail the `:8686` healthcheck, so the container reports healthy while writing nothing. Fixed by adding `group_add: ["1000"]` to the Vector service (v0.8.5). If `/data/logs` is empty on an older deployment:

```bash
./scripts/run.sh "sudo docker logs trinity-vector --tail 50 2>&1 | grep -i 'permission denied'"
# Fix: update Trinity (v0.8.5+), or add group_add: ["1000"] to the vector service and re-up
```

### Retention prune blocked / operator-queue alarm about a mass deletion

Issue #1644/#1709 — the retention sweep refuses a prune that would delete most of a table (blast-radius guard, e.g. after a retention window was accidentally shrunk). The guard raises an informational operator-queue alarm, but responding to that alarm authorizes nothing — the only gate is `POST /api/settings/retention/acknowledge` (see API Access), which is **human-only** (agent-scoped MCP keys are rejected even with admin role), single-use, and bound to the exact `window_days` in force. Check effective windows first with `GET /api/settings/retention`; widen the window if the shrink was accidental, or acknowledge to let the prune run once.

Since v0.9.0 (#2146 / #1833 / #1834) the guard **refuses instead of raising** on a count it cannot interpret (`None`, a string, a negative error sentinel), and such a sweep appears under `blocked_sweeps` in `GET /api/settings/retention` — *blocked, not pending*: an acknowledgement cannot clear it (the count itself is broken, look at the backend logs for `REFUSED`), and before this fix the same input 500'd the whole retention panel while the sweep sat silently blocked in `cleanup_service`. A refusal alarm that fails to write is now **retried every cycle** rather than marked seen (#1834). Note that `blocked_sweeps` only covers the two ack-gated sweeps; a refusal on the other windows reaches you only through the operator-queue alarm.

### Long-running agent task killed at 60min

Default execution timeout was bumped 15min → 60min (#665). The deadline is now the **per-agent** `execution_timeout_seconds` (clamped by the schedule cap, #929) — the scheduler honors it (#913 / #922). The old **per-task `timeout_seconds` override is deprecated** (#1068): still honored-but-clamped this release, removed in a follow-up. To extend the wall, raise the agent's `execution_timeout_seconds` (Agent Detail → Settings, or `PATCH /api/agents/{name}`) rather than passing a per-task override. **Workspace chat turns** honour the same per-agent timeout since v0.9.0 (#2214) — before that they were hard-capped at 300s regardless of the agent's setting.

### Fan-out turn recorded SUCCESS but the subagents' work is missing

Issue #2127 / #1870 (v0.9.0) — `claude --print` emits one `result` line per turn *segment* and deliberately stays alive between segments to await background subagents. The old early-completion treated the first `result` as the end of the turn and SIGTERMed the process group 2s later with exit 0 — so a fan-out was killed mid-wait, recorded **success**, billed, and stored "I'll wait for the notification" as the response (or surfaced as `error_during_execution` when the timing differed, #1870). Early-finalize now requires all three: a result seen **and** no waited background tasks in the ledger **and** stdout silent for `AGENT_IDLE_FINALIZE_S` (default 300s; ≤0 refused). Consequences: fan-outs now run to completion, so they spend more and can newly hit `--max-turns`; agents with an execution timeout under ~300s lose the early finalize (an honest 504 instead of a rescued success). **Requires a base-image rebuild plus a cold agent recreate** — a fleet on the old image still has the bug. Tune `AGENT_IDLE_FINALIZE_S` from the longest silence a healthy run produces (one long assistant message is a single stdout line, measured ~40s of dead air for ~10k chars); bias generous — too low silently truncates a finished deliverable and calls it success.

### PostgreSQL backend won't connect

Only relevant when `DATABASE_URL` is set to a `postgresql://` URL (see [Database Backend](#database-backend-sqlite-default--postgresql-300)).

```bash
# Is the backend actually on Postgres?
./scripts/run.sh "sudo docker exec trinity-backend python -c \"import db.engine as e; print('sqlite:', e.is_sqlite())\""
./scripts/run.sh "sudo docker logs trinity-backend --tail 50 2>&1 | grep -iE 'postgres|alembic|database'"
```

- **`could not translate host name \"postgres\"`** — dev: the `postgres` profile isn't up (`docker compose --profile postgres up -d postgres`). Prod: there is no bundled service — point `DATABASE_URL` at a reachable operator-managed host (not `localhost`).
- **Password mismatch** — the password in `DATABASE_URL` must equal `POSTGRES_PASSWORD` (bundled service) or the managed DB's role password.
- **`{"detail":"setup_required"}` on login** — expected first-run gate on any fresh DB (there's no SQLite→PG data migration; a new Postgres DB starts empty). Complete the setup wizard.
- Rollback is non-destructive: comment out `DATABASE_URL`, `docker compose up -d` → back on SQLite.

### Credential inject rejected for `.mcp.json`

Trinity validates `.mcp.json` content before writing it (AISEC-C2 hardening). A 400 error means the content failed the MCP validator. Common causes:

- `command` not in allowlist (`npx`, `uvx`, `python`, `python3`, `node`, `bun`, `deno`, `docker`)
- Shell metacharacters (`&`, `;`, `|`, `$()`, backticks) in `command` or `args`
- HTTP/SSE server URL is not HTTPS or resolves to a private/loopback/CGNAT (`100.64.0.0/10`, ent#394) address (SSRF guard)
- Server named `trinity` (reserved — auto-injected by platform)
- Env var references to reserved names (`PATH`, `LD_PRELOAD`, `ANTHROPIC_API_KEY`, etc.)
- Content exceeds 64KB or more than 32 servers defined

The error message from the API (`detail` field) identifies the specific rule that failed.

### Agent ignores a credential you changed / subscription auth keeps breaking

Issue #1999 / #2114 — two distinct failures with the same symptom.

**Stale env at spawn.** The spawn env is rebuilt per spawn from `.env`, so a key you *removed* stops applying — but a key you left behind keeps applying. `/proc/<pid>/environ` and `docker exec` both agree with the **file** and disagree with what an execution actually receives, which is what made this expensive to diagnose. The one view that shows the divergence:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/credentials/env-drift | jq
```

**Subscription auth shadowed by an API key.** A stale `ANTHROPIC_API_KEY` (or `ANTHROPIC_AUTH_TOKEN`) on the workspace volume shadows `CLAUDE_CODE_OAUTH_TOKEN` at every spawn — Claude Code prefers the key — so subscription auth silently never engages and health checks skip-list every healthy subscription in turn. Fixed in two places (#2119): the backend sends `remove_api_key=True` on token reload for Claude-runtime agents, and the agent server force-unsets both names at boot. Non-Claude agents keep the key, where it never shadows. The reload response now reports `env_shadow` naming any offending key still in the file — clean it out of the agent's `.env` so a later recreate doesn't reintroduce it.

### Audit verify says valid but checked 0 entries

Issue #1984/#1985 and #2015/#2026 — two defects that compounded.

`POST /api/audit-log/verify` used to answer `valid: true, checked: 0` for a log where **no** entry carried a hash, which is the default on any install that never enabled hashing. `valid` is now tri-state — `true` verified, `false` tampered, **`null` unverifiable** — and `status` carries the precise verdict (`verified`, `verified_partial`, `tampered`, `unverifiable`, `empty_range`), with `skipped_unhashed` counting a late-enabled chain's permanent unhashed prefix.

Separately, the hash-chain **toggle** wrote nothing and nothing restored it at boot, so every backend restart silently switched the integrity control back off; and the chain head lived in process memory, so multiple uvicorn workers each kept their own head and `verify_chain` could report an untampered log as **tampered**. Both are now DB-backed (`system_settings` + chain head read from the DB). If you enabled hashing before v0.9.0, expect a `verified_partial` range spanning old restarts — that is history, not tampering.

### Docker data root filling up / dockerd wedged

Issue #1871 — before this, Docker's `json-file` driver ran with **no** size cap, so every container log under `/var/lib/docker/containers/` grew forever until the data root hit 100%.

```bash
./scripts/run.sh "sudo du -sh /var/lib/docker/containers/* | sort -rh | head -10"
./scripts/run.sh "sudo docker inspect trinity-backend --format '{{json .HostConfig.LogConfig}}'"
./scripts/run.sh "sudo docker inspect agent-myagent --format '{{json .HostConfig.LogConfig}}'"
```

An empty `{}` means the container predates the cap. Platform services adopt it on the next `docker compose up`; **agents adopt it on recreate, not restart** (`/rebuild-agent`). Tune with `CONTAINER_LOG_*` / `AGENT_LOG_*`. The raw Docker log is only a secondary copy — `/data/logs` is the primary aggregate and has its own `LOG_RETENTION_DAYS`.

### Agent's MCP tools 401 / Trinity MCP key drifted

Issue #1854 — an agent's own `scope='agent'` Trinity MCP key can drift from what the platform believes it holds (stale `.mcp.json` after a restore, a rotated key that never reached the container). Since v0.9.0 this **self-heals at start**: a start-time drift predicate detects the mismatch and re-delivers, unattended, on the agent's next start. `trinity-system` and ephemeral agents are exempt.

```bash
# What does the platform think, and what does the container actually hold?
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/mcp-key | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/mcp-key/verify | jq
# Deliberate rotation (recreates the container; returns metadata, never plaintext)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/mcp-key/regenerate | jq
```

`verify` is a config-truth probe: one `docker exec` returning only `sha256(bearer)` per `.mcp.json` entry, so the token never crosses the container boundary. Self-heal writes an `agent_key_self_heal` audit row. Both paths are owner/admin + human-only and rate-limited per agent **and** per actor — on a default admin-owned install an unthrottled rotate loop is a fleet-wide container-recreate storm.

### Rebuilding agents restarted ones I had deliberately stopped

Issue #2092 — `recreate_container_with_updated_config` always started the replacement, and the precondition ("caller must check the container is running") lived only at each call site. A base-image adoption wave run from outside the repo therefore restarted agents that had been stopped for days; `autonomy_enabled=0` gates cron fires and reminders but **not** human-initiated inbound chat, so a channel binding or an enabled public link becomes reachable again.

Current Trinity refuses with a `ValueError` unless you pass `require_running=False`, and `preserve_run_state=True` leaves the replacement stopped. This repo's `/rebuild-agent` skill passes both. If you drive a rebuild by hand, do the same — and always compare run state before and after.

**Follow-on (#2186, fixed in v0.9.0):** the #2092 guard defaulted `require_running=True` and `start_agent_internal` — the one caller whose *job* is to start a stopped container — inherited it, so on dev builds between #2092 and #2186 `POST /api/agents/{name}/start` returned an opaque **500 for any stopped agent with config or image drift**, and cold-start base-image adoption (#1809, which fires *only* for stopped containers) was unreachable: every stopped agent failed to start after any `build-base-image.sh` run. On such a build, `/rebuild-agent` (which passes `require_running=False` itself) is the workaround; on v0.9.0 a start of a stopped agent recreates and reports `{recreated: true, recreate_reason: "config_drift" | "image_drift"}`.

### Update broke things — rollback

```bash
source .env
HOST=${SSH_HOST:-localhost}
TRINITY=${TRINITY_PATH:-~/trinity}

# Roll back to previous commit
./scripts/run.sh "cd $TRINITY && git log --oneline -10"
./scripts/run.sh "cd $TRINITY && git checkout <prev-commit>"

# Rebuild and restart
./scripts/run.sh "cd $TRINITY && sudo docker compose -f ${COMPOSE_FILE:-docker-compose.prod.yml} build --no-cache backend frontend mcp-server scheduler"
./scripts/run.sh "cd $TRINITY && sudo docker compose -f ${COMPOSE_FILE:-docker-compose.prod.yml} up -d"
```

If the update ran a **schema migration** you also need the pre-update database: `/update` takes one (`~/backups/trinity-<ts>.db`), and since v0.9.0 the backend itself writes `/data/backups/pre-migration-<ts>.db` at boot whenever a migration is pending (#2216). Restore with backend **and scheduler** stopped and stale `-wal/-shm/-journal` sidecars removed first — see [Backup Database](#backup-database); `/rollback <commit> <backup>` does the whole sequence.

### Nightly database backup failed / "backups are stale" alarm

Issue #2216 (v0.9.0) — the daily 03:30 UTC job writes durable status to `system_settings` and raises an operator-queue item under the platform sentinel `_db-backup` on the ok→failed edge (`failed` | `skipped_no_space`), then re-alarms **weekly** while the newest success is older than 3 days. Free-space preflight *skips loudly* and never prunes-to-make-room, so `skipped_no_space` means the disk is genuinely tight (see [Disk space](#disk-space)).

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://$HOST:${BACKEND_PORT:-8000}/api/settings/retention | jq .backup
./scripts/run.sh "sudo docker logs trinity-backend --tail 2000 2>&1 | grep '\[DBBackup\]' | tail -20"
./scripts/run.sh "sudo docker exec trinity-backend ls -lh /data/backups/"
```

- `enabled: false` — `DB_BACKUP_ENABLED=false` in the server `.env` (or the var not forwarded — both compose files forward it since v0.9.0).
- PostgreSQL `failed` with a `pg_dump` version error — the baked client is v17 and dumps servers ≤ 17; a newer managed server needs a newer image or your provider's tooling.
- The job is day-keyed and idempotent (today's artifact exists → skip with INFO), and correctness never depends on the Redis `db_backup:running` lease — a Redis outage cannot corrupt an artifact.

### Log archival dead — `/data/logs` growing, `/data/archives` empty

Issue #2205 (v0.9.0) — on the **dev compose**, `trinity-archives` is a named volume Docker creates root-owned, and the UID-1000 backend could never write it: `archive_storage.__init__`'s `mkdir(exist_ok=True)` succeeded on someone else's directory, so only the first *write* failed, with `[Errno 13] Permission denied` written into the very log files archival exists to prune (measured on a real instance: 8.5 GB of logs, one 4.6 GB file, failing for months). Same silent class as #1478 and #1871.

```bash
./scripts/run.sh "sudo docker exec trinity-backend ls -ld /data /data/archives /data/logs"     # want 1000:1000 (trinity) on all three
./scripts/run.sh "sudo docker exec trinity-backend sh -c 'touch /data/archives/.perm-probe && rm /data/archives/.perm-probe && echo writable'"
./scripts/run.sh "sudo du -sh /var/lib/docker/volumes/trinity_trinity-logs/_data 2>/dev/null"
```

Fix: update to v0.9.0 — the new `trinity-archives-init` one-shot chowns the volume on **every** `up` (repairs existing installs), and an unwritable dir now raises an operator-queue alarm under `_log-archive`. On an older build: `sudo docker run --rm -v trinity_trinity-archives:/data/archives alpine sh -c 'chown 1000:1000 /data/archives && chmod 775 /data/archives'`. Prod is unaffected (the directory lives inside the `start.sh`-chowned bind mount). Expect the first archival pass afterwards to reclaim the backlog.

### Operator-queue items from `_db-backup` / `_log-archive`

Those are not agents. Platform maintenance jobs file their alarms directly (bypassing the #1632 agent-ingestion caps by construction) under uncreatable sentinel names — `_db-backup` (#2216), `_log-archive` (#2205), plus the reserved id prefixes `db-backup-`, `log-archive-`, `alert-budget-` — so an agent can neither pre-create nor silence them. Responding to one authorizes nothing; it is a pointer to the runbook entries above. Related: platform alert emitters that an *agent* can influence (e.g. the unknown-slash-command alert) are now depth-budgeted per (agent, type) by `OPERATOR_ALERT_MAX_PENDING_PER_TYPE` (#1677, default 5) — at the cap you get one cooldown-gated `alert-budget-<agent>-<type>` episode item instead of a flood.

---

## Environment Variables Reference

### This agent's `.env`

| Variable | Default | Purpose |
|----------|---------|---------|
| `SSH_HOST` | *(empty)* | Server IP/hostname; empty = local |
| `SSH_USER` | `ubuntu` | SSH username |
| `SSH_KEY` | `~/.ssh/id_rsa` | Path to private key |
| `SSH_PASSWORD` | *(empty)* | Password auth fallback |
| `SSH_PORT` | `22` | SSH port |
| `TRINITY_PATH` | `~/trinity` | Trinity install dir on server |
| `COMPOSE_FILE` | `docker-compose.prod.yml` | Docker Compose file to use |
| `FRONTEND_PORT` | `80` | Frontend web UI port |
| `BACKEND_PORT` | `8000` | Backend API port |
| `MCP_PORT` | `8080` | MCP server port |
| `SCHEDULER_PORT` | `8001` | Scheduler health port |
| `ADMIN_PASSWORD` | — | Trinity admin login |
| `MCP_API_KEY` | — | MCP authentication key |
| `TUNNEL_FRONTEND` | `13000` | Local tunnel port for frontend |
| `TUNNEL_BACKEND` | `18000` | Local tunnel port for backend |
| `TUNNEL_MCP` | `18080` | Local tunnel port for MCP |

### Trinity server's `~/trinity/.env`

`start.sh` auto-generates all `*_KEY` / `*_SECRET` / `REDIS_*PASSWORD` secrets on first run; only `ADMIN_PASSWORD` is operator-chosen.

| Variable | Required | Purpose |
|----------|----------|---------|
| `ADMIN_PASSWORD` | **Yes** | Admin login (12+ chars; no sensible default — operator must set) |
| `SECRET_KEY` | **Yes** (auto-gen) | JWT signing — generated by `start.sh` if blank |
| `CREDENTIAL_ENCRYPTION_KEY` | **Yes** (auto-gen) | Encrypt stored tokens; loss = unrecoverable credentials |
| `INTERNAL_API_SECRET` | **Yes** (auto-gen) | Scheduler→backend auth. **Set it explicitly in prod — do not rely on the `SECRET_KEY` fallback.** #848 widened its blast radius: with `MCP_INLINE_AUTH_ENABLED` on, a holder can assert any verified email over `/api/internal/mcp-auth/*`. That grants nothing beyond what internal-secret compromise already grants (god-mode over `/api/internal/*`), but it should be rotated and scoped on its own terms rather than inheriting `SECRET_KEY`'s lifecycle |
| `REDIS_PASSWORD` | **Yes** (auto-gen) | Redis admin (`default` ACL user) — #589 |
| `REDIS_BACKEND_PASSWORD` | **Yes** (auto-gen) | Redis runtime user — embedded in `REDIS_URL` at compose render |
| `AGENT_AUTH_SECRET` | **Yes** (auto-gen) | Master from which the backend derives each agent's in-container `:8000` token (#1159). Keep stable — rotating it 401s the whole fleet until every agent is recreated. Prod compose forwards it explicitly. See [Agent Auth Secret](#agent-auth-secret-issue-1159) |
| `DOCKER_GID` | All runtimes (auto-detect) | GID the backend joins to reach `/var/run/docker.sock` (#874/#1131). `start.sh` probes the GID a container sees on the socket — host `docker` group on native Linux (999/991/990), **0 on Docker Desktop/Colima/Rancher/rootless**. Compose falls back to 999 if unset |
| `TRINITY_DATA_PATH` | Recommended (prod) | Host bind-mount for `/data` (holds `trinity.db`, archives, shares) |
| `HOST_TEMPLATES_PATH` | Optional | Read-only mount for `/agent-configs/templates` (default `${PWD}/config/agent-templates`) |
| `ANTHROPIC_API_KEY` | For agents | Claude API key (or set in Settings UI) |
| `GEMINI_API_KEY` | For avatars/voice | Gemini API key |
| `GOOGLE_API_KEY` | For Gemini-powered agents | Fallback for `GEMINI_API_KEY`; injected into agent containers |
| `GITHUB_PAT` | For GitHub templates | Access private agent template repos |
| `PUBLIC_CHAT_URL` | For public links | External URL for public chat |
| `TUNNEL_TOKEN` | For Cloudflare Tunnel | Enable `cloudflared` profile |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USER` / `SMTP_PASSWORD` | For SMTP email | When `EMAIL_PROVIDER=smtp` (#771) |
| `SENDGRID_API_KEY` | For SendGrid email | When `EMAIL_PROVIDER=sendgrid` (#771) |
| `SLACK_SOCKET_CONNECTION_COUNT` | Optional | Concurrent Slack Socket Mode connections (default 2, range 1–10) |
| `LOG_RETENTION_DAYS` | Optional | Days to keep Vector logs (default **5** since v0.8.5 — community retention floor #1065; was 90). The floor is applied by *seeding* fresh installs, not clamping (#1645) — existing configured values are preserved, and any admin may widen windows. Check effective windows: `GET /api/settings/retention` |
| `LOG_ARCHIVE_ENABLED` | Optional | Compress to `/data/archives` instead of delete (default true) |
| `LOG_CLEANUP_HOUR` | Optional | UTC hour for daily cleanup job (default 3) |
| `DB_BACKUP_ENABLED` / `DB_BACKUP_HOUR` / `DB_BACKUP_MINUTE` / `DB_BACKUP_PG_DUMP_TIMEOUT_SECONDS` | Optional (#2216, defaults `true` / `3` / `30` / `1800`) | Automatic nightly database backup, **both backends**, default ON — artifacts under `/data/backups` (same-disk scope). `false` disables both the nightly job and the boot-time pre-migration copy. Time is UTC (03:30 sits before the 04:15/04:30 destructive maintenance jobs); malformed/out-of-range values fall back with a WARNING. Forwarded by both compose files (an unforwarded var is inert, #1486 class). Retention is deliberately NOT an env var — it is the ops setting `backup_retention_days` (default 14, min-keep 3), see [Backup Database](#backup-database) |
| `CANARY_ENABLED` | Staging/dev | Run 5-min invariant watcher loop (default 0). **Now forwarded by `docker-compose.prod.yml` (#1876)** — before that the knob was inert in prod, so the watcher was un-enableable on the very instance it exists to watch. One cycle per fleet, not one per uvicorn worker (#1881) |
| `CANARY_SLACK_WEBHOOK_URL` | Optional | Slack webhook for canary green→red transitions |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Optional | OpenTelemetry collector endpoint |
| `DATABASE_URL` | Optional (#300) | DB selector. Unset/empty → SQLite at `/data/trinity.db`; `postgresql://…` → PostgreSQL. Prod ships no bundled DB — point at a managed Postgres. See [Database Backend](#database-backend-sqlite-default--postgresql-300) |
| `DB_POOL_SIZE` / `DB_MAX_OVERFLOW` | PostgreSQL only | Pool size (10) / burst overflow (20). Ignored on SQLite |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | dev `postgres` profile | Bundled `trinity-postgres` creds. `POSTGRES_PASSWORD` required when the profile is enabled; must match the password in `DATABASE_URL` |
| `VOIP_ENABLED` | Optional (VOIP-001 / #1056) | Outbound phone calls via Twilio Media Streams over Gemini Live. Default OFF; per-agent `voip_bindings` still required to place calls. `VOIP_MAX_CALL_DURATION`/`VOIP_DEFAULT_DAILY_CALL_CAP`/`VOIP_CALL_RATE_LIMIT`/`VOIP_CALL_RATE_WINDOW`/`VOIP_*_TTL_SECONDS` are spend/abuse controls |
| `VOICE_ENABLED` / `VOICE_MODEL` | Optional (VOICE-001) | Voice chat over Gemini Live (default ON). Leave `VOICE_MODEL` commented — an empty value shadows the default and breaks voice (#1076) |
| `WORKSPACE_ENABLED` | Optional (BETA #860) | Voice Workspace canvas (default false). **Name collision warning:** this is *not* the Workspace / client portal (#2084), which is OSS core, always on, and has no enable flag — its knobs are the `PORTAL_*` vars |
| `GEMINI_TEXT_MODEL` / `GEMINI_TRANSCRIPTION_MODEL` | Optional (#1130) | Override built-in Gemini defaults. Leave commented unless overriding (#1076) |
| `PUBLIC_ACCESS_REQUESTS_ENABLED` | Optional (default false) | Default-deny public self-signup on `POST /api/access/request`; whitelist stays authoritative unless `true` |
| `DISPATCH_ASYNC` | Optional (#1083) | Fire-and-forget dispatch for autonomous turns (default false; safe to flip — non-202 falls back to sync) |
| `DISPATCH_TIMEOUT` / `PRE_CHECK_TIMEOUT` | Optional (#1022) | Scheduler→backend dispatch (30s) / pre-check (70s) deadlines |
| `BACKEND_URL` | For OAuth | Backend's public origin used to build OAuth redirect URIs (default `http://localhost:8000`) |
| `EXTRA_CORS_ORIGINS` | Optional | Comma-separated extra allowed CORS origins |
| `TELEMETRY_CONTAINER_STATS_TTL` / `TELEMETRY_DOCKER_POOL_SIZE` | Optional (#1096) | `/api/telemetry/containers` cache freshness in s (10) / max concurrent Docker stat fetches (16) |
| `AGENT_TMP_SIZE` | Optional (#1231) | Size of each agent container's `/tmp` RAM-backed tmpfs (e.g. `512m`, `2g`; default `512m`). `noexec,nosuid` always applied; counts against the agent memory cgroup. Picked up on recreate, not restart |
| `MCP_AGENT_CHAT_PULL_ENABLED` | Optional (#946, default false) | Pull-pilot experiment — routes sequential agent→agent `chat_with_agent` through the durable async `/task` path instead of sync `/chat`. Read by BOTH mcp-server (the gate) and backend (observability) from this one key |
| `OPERATOR_INTAKE_ENABLED` / `OPERATOR_INTAKE_URL` | Optional (default true / `intake.abilityai.dev`) | First-run **opt-in**: on the operator's explicit consent, their email + company are submitted ONCE to a hosted Ability.ai intake endpoint (fire-and-forget; a blocked POST never breaks setup). Honors `DO_NOT_TRACK`; set false for air-gapped/privacy-strict installs. Non-2xx delivery now logged at WARNING (#1678) |
| `DO_NOT_TRACK` | Optional (default 0) | Cross-tool convention (consoledonottrack.com): ANY value other than 0/empty/false disables both the operator-intake POST and fleet telemetry sharing — the one-var air-gap/privacy switch |
| `TELEMETRY_SHARING_ENABLED` (+ `TELEMETRY_SHARING_URL`, `TELEMETRY_SHARING_INTERVAL_HOURS`, `TELEMETRY_SHARING_BACKFILL_DEFAULT_DAYS`) | Optional (#1723) | **Opt-in** fleet telemetry sharing: anonymized aggregate counts egress ONLY after explicit admin consent in Settings (default off) AND this flag. `false` (or `DO_NOT_TRACK`) is the hard kill switch — the consent toggle then 409s. Consent state: `GET/PUT /api/settings/telemetry-sharing`. Defaults: hosted intake URL / 24h heartbeat / 30-day backfill window |
| `AGENT_DATA_EXPORT_MAX_BYTES` / `AGENT_DATA_INLINE_MAX_BYTES` | Optional (#1169) | Caps for agent runtime-data export/import (default 5 GB / 10 MB). Export 413s on overflow |
| `ELEVENLABS_API_KEY` / `ELEVENLABS_MODEL_ID` / `TTS_MAX_CHARS` | Optional (#24/#25) | Outbound voice replies across channels (Telegram, etc.). Empty key = feature off (adapters deliver text). `ELEVENLABS_MODEL_ID` defaults `eleven_multilingual_v2` — leave non-empty (#1076); `TTS_MAX_CHARS` (1500) delivers longer replies as text to cap synth cost. Since #1549 the key can also be set at runtime via `PUT /api/settings/elevenlabs` (no restart), with per-agent voice config and per-channel allow flags |
| `REPORT_RATE_LIMIT` | Optional (#918) | Max structured reports an agent may create per 60s window (default 30). Backs the `report` MCP tool / `agent_reports` table |
| `WEBHOOK_RATE_LIMIT` / `WEBHOOK_IP_RATE_LIMIT` / `WEBHOOK_MAX_BODY_BYTES` | Optional (#1023/#1424) | Public webhook-trigger hardening: triggers per token/60s (10), pre-auth requests per IP/60s (60, unknown-token flood guard), request-body cap in bytes (16384 → 413). Windows fixed in code. Guards `POST /api/webhooks/{token}` |
| `REDELIVERY_GOVERNOR_ENABLED` (+ `REDELIVERY_FLEET_LIMIT`/`_WINDOW_SECONDS`, `REDELIVERY_AGENT_LIMIT`/`_WINDOW_SECONDS`, `CORRELATED_FAILURE_THRESHOLD`/`_WINDOW_SECONDS`, `CORRELATED_PAUSE_TTL_SECONDS`, `REDELIVERY_PAUSE_RETRY_AFTER_SECONDS`) | Optional (#1085) | Backend re-delivery rate caps + shared-cause (AUTH/BILLING) fleet pause on the #1083 fire-and-forget callback path. Default **OFF**; fail-open (a Redis blip degrades to allow, never block/drop); Redis-only state, no schema change. Flipping back to false is the whole rollback |
| `CREDENTIAL_ENCRYPTION_KEY_SECONDARY` | Optional (#267) | Decrypt-only fallback used ONLY during credential-key rotation — set to the PREVIOUS key while `CREDENTIAL_ENCRYPTION_KEY` holds the new one, run `rotate-credential-key.py --apply`, then remove. Empty in normal operation. See [Credential Key Rotation](#credential-key-rotation-issue-267) |
| `VITE_BUG_REPORTING_ENABLED` / `VITE_BUG_INTAKE_URL` | Optional (#1116/#1489) | Frontend **build-time** (baked into the world-readable client bundle — rebuild the frontend image to apply; never put a secret in a `VITE_*` var). In-app bug/feedback widget on/off (default true) and its intake endpoint (default `intake.abilityai.dev`). Repointing the URL also needs a CSP `connect-src` change (nginx + vite config) |
| `DISPATCH_BREAKER_ENABLED` | Optional (#526/#1487, default false) | GLOBAL gate for the per-agent dispatch circuit breaker that fast-fails NEW executions (503) when an agent is auth-dead instead of poisoning the backlog. Two-tier: this flag AND the per-agent toggle (`PUT /api/agents/{name}/circuit-breaker`) must BOTH be on — with this off, the per-agent toggle no-ops |
| `REMINDER_MESSAGE_MAX_CHARS` / `REMINDER_MIN_DELAY_SECONDS` / `REMINDER_MAX_DELAY_SECONDS` / `MAX_PENDING_REMINDERS_PER_AGENT` / `MAX_REMINDERS_PER_AGENT_PER_DAY` / `REMINDER_RATE_LIMIT` | Optional (#1296) | Agent self-reminder caps: message 4000 chars, fire window 60s–30d, 25 pending + 100/day per agent, 30 `set_reminder` calls/agent/60s. All have working code defaults |
| `OPERATOR_QUEUE_*` (14 caps: `_MAX_PENDING_PER_AGENT`, `_CREATE_RATE_LIMIT`/`_WINDOW`, `_FLEET_CREATE_RATE_LIMIT`, `_MAX_SCAN_PER_CYCLE`, `_MAX_FILE_BYTES`, `_TITLE_MAX`, `_QUESTION_MAX`, `_CONTEXT_MAX_BYTES`, `_OPTIONS_MAX_BYTES`, `_ID_MAX`, `_EXECUTION_ID_MAX`, `_FLOOD_ALERT_COOLDOWN_SECONDS`) | Optional (#1632) | Ingestion caps bounding a compromised/runaway agent flooding `~/.trinity/operator-queue.json` — depth (25 pending/agent), rate (60/agent + 300/fleet per 60s), file-size (2 MB skip), field-size truncation, one flood alert per agent per 5 min. Generous by design: cap abuse, not use |
| `OPERATOR_ALERT_MAX_PENDING_PER_TYPE` | Optional (#1677, default 5) | Per-(agent, alert-type) pending-depth budget for **platform** operator-queue emitters an agent can influence (the #1632 caps only bound the agent-authored *file* seam; direct-DB platform creates were exempt — e.g. an unknown slash-command alert minted one `priority:high` row per distinct command at dispatch throughput). At the cap: one cooldown-gated `alert-budget-<agent>-<type>` episode item; every failure arm fail-closed (suppresses the alert only — the FAILED execution row remains the primary surface) |
| `PULL_MODE_PILOT_AGENTS` / `MAX_REDELIVERY` | Optional (#1081, default empty / 3) | Pull/work-stealing pilot (dark by default): comma-separated agent names opted into the agent-side pull worker pool. Backend-only process-env — needs a backend restart AND the agent recreated to engage. `MAX_REDELIVERY` = re-deliveries of an expired pull lease before the row is poison-parked to the operator queue |
| `TRINITY_DEFAULT_SYSTEM_MANIFEST` | Optional (#1764, default empty) | First-run starter-fleet seed: on a genuinely fresh install, Trinity auto-deploys the bundled `config/manifests/default-system.yaml` once after setup. Set to a path (bind-mounted into the backend) for a custom manifest, or `disabled` to skip seeding |
| `TRINITY_MANIFESTS_DIR` | Optional (#1911, default empty) | Directory the bundled-manifest catalog reads (`GET /api/systems/manifests` — the cards on Library → Install a system). Empty = the image's own `config/manifests`. An unreadable path yields an **empty catalog, not an error**, so the directory must be bind-mounted as well — setting this alone silently lists nothing |
| `CONTAINER_LOG_MAX_SIZE` / `CONTAINER_LOG_MAX_FILE` | Optional (#1871, default `10m` / `3`) | json-file log cap for the **platform services**, via the shared `x-logging` compose anchor. Adopted on the next `docker compose up`. Sizes accept `<int>k\|m\|g` (max 1g); counts 1–10. Invalid/out-of-range logs a warning and falls back — a typo can never leave a container uncapped |
| `AGENT_LOG_MAX_SIZE` / `AGENT_LOG_MAX_FILE` | Optional (#1871, default `10m` / `3`) | Same cap for **agent** containers. Read by the backend at import time, because agents are SDK-created and compose's `logging:` can never reach them. Existing agents adopt a change on **recreate**, not restart |
| `AGENT_IDLE_FINALIZE_S` | Optional (#2127, blank = agent-side default 300) | How long a headless turn's stdout must be **silent** before the executor may finalize early once a `result` line has been seen and no waited background subagents remain — the third leg of the fix for fan-out turns being killed mid-wait and recorded as success. Set from the longest silence a HEALTHY run produces (~40s measured for a ~10k-char reply, so 300 is ~7×); too LOW silently truncates a finished deliverable, too high only delays lingering-child recovery — bias generous. `<= 0` is refused → default. Baked at create/recreate: existing agents pick up a change on **recreate**, not restart. Only worth lowering for agents with an execution timeout under ~5 min |
| `A2A_OUTBOUND_ENABLED` | Optional (#736, default false) | Lets an agent task an **external** A2A agent (Google ADK, LangChain, Bedrock, a remote Trinity) — the platform's first backend-executed, credentialed, agent-triggerable outbound fetcher. Also requires ≥1 endpoint registered via `PUT /api/settings/a2a-endpoints`; agents choose a target by **name** and can never supply a URL. A `system_settings` row wins over this var at runtime (no restart) |
| `MCP_A2A_TIMEOUT_MS` | Optional (#736, default 40000) | mcp-server-only ceiling for outbound-A2A fetches. Must stay **below** the MCP client's 30–60s gateway abort: if the gateway gives up first, the agent sees `fetch failed` while the credentialed call completes anyway, with no `task_id` to poll |
| `MCP_INLINE_AUTH_ENABLED` | Optional (#848, default false) | Keyless MCP sign-in: a request with **no** `Authorization` header opens an anonymous session that may `request_login` / `verify_login` with a 6-digit email code, then use connector playbooks of agents shared with that address. A posture change on a network-exposed port — see [MCP Inline Email Auth](#mcp-inline-email-auth-issue-848). Requires `INTERNAL_API_SECRET`. Read by BOTH mcp-server (session gate) and backend (404s `/api/internal/mcp-auth/*` when off) |
| `MCP_INLINE_AUTH_TIMEOUT_MS` | Optional (#848, default 15000) | mcp-server-only ceiling for the backend relay fetches on the inline-auth path, so a hung backend returns a structured error instead of an open socket |
| `ASK_TRINITY_ENDPOINT` | Optional (#1981, default empty) | Endpoint backing the `ask_trinity` MCP docs-Q&A tool. Empty = the public Cloud Function. Point at an internal mirror, or at an unreachable URL to effectively disable it — it degrades to a structured error rather than crashing the call |
| `TEMPLATE_REGISTRY_ENABLED` / `TEMPLATE_REGISTRY_URL` | Optional (#2033, **default true** / vendor URL) | The GitHub half of the agent-template catalog is fetched at runtime from a vendor-published `registry.yaml`. It only **adds** entries; every failure mode degrades to the bundled list. `false` is the HARD kill switch — no admin toggle or `system_settings` row can re-enable it, and it is the air-gap answer. **Not** coupled to `DO_NOT_TRACK` (a registry fetch is a package-index read, like npm), but it *is* outbound egress on a default install. URL is HTTPS-only, SSRF-validated, redirects refused |
| `TRINITY_DEFAULT_SKILL_SOURCE` / `_REF` | Optional (#1901, default community repo @ a pinned tag) | Bundled community skills source, seeded on **fresh installs only**. Pinned to a tag, never a branch head — the catalog takes public PRs and skills carry executables. Set the URL to `""` to disable the seed. Compose passes these **bare** (not `${VAR:-}`) precisely so an explicit empty value still means "disabled" |
| `SKILLS_RECONCILE_MAX_REMOVALS` / `SKILLS_FLEET_INJECT_CONCURRENCY` | Optional (#1883, default 10 / 5) | Skills-library lifecycle automation: blast-radius cap (a start-path reconcile refuses above this many removals per agent) and parallelism of a fleet re-inject sweep. The auto-sync / auto-re-inject **toggles** live in Settings (`system_settings`), not here; the loop runs on one Redis-leader worker |
| `PORTAL_CHAT_BURST_LIMIT` / `PORTAL_CHAT_HOURLY_LIMIT` / `PORTAL_UPLOAD_BURST_LIMIT` / `PORTAL_UPLOAD_HOURLY_LIMIT` / `PORTAL_TITLE_MODEL` / `PORTAL_TITLE_TIMEOUT_SECONDS` | Optional (#2084, defaults 20 / 300 / 20 / 100 / `claude-haiku-4-5-20251001` / 15) | Workspace (client portal) rate limits and thread-title model. The limits are **enforced at these defaults whether or not the vars are set** — these only tune them |
| `TRINITY_INSTANCE_NAME` | Optional (#1997, default empty) | Label naming THIS instance in outbound canary alerts, so instances sharing one Slack webhook stay tellable apart (`[eu2] 🚨 S-01 …`). Unset is the norm: the resolver falls back to the first DNS label of `FRONTEND_URL`, then the first 8 chars of the installation id. Truncated to 32 hostname-shaped chars |

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/run.sh "cmd"` | Run command locally or via SSH |
| `scripts/status.sh` | Quick health check |
| `scripts/restart.sh` | Restart all Trinity services |
| `scripts/update.sh` | Pull latest, rebuild, restart |
| `scripts/backup.sh` | Manual on-demand DB backup to `~/backups/` on the host — SQLite via `sqlite3 .backup` (never a raw `cp`), bundled-PG via `pg_dump -Fc`. The platform also backs itself up nightly (#2216) |
| `scripts/tunnel.sh` | SSH tunnels for local browser access |

---

*Trinity Ops Agent — manage your sovereign AI infrastructure*

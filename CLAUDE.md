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

### Backup Database

```bash
./scripts/backup.sh
# Saves to /tmp/trinity-<timestamp>.db on the host
```

`backup.sh` copies the SQLite file. **If the instance runs on PostgreSQL** (`DATABASE_URL` set — see [Database Backend](#database-backend-sqlite-default--postgresql-300)), back up with `pg_dump` instead:

```bash
./scripts/run.sh "sudo docker exec trinity-postgres pg_dump -U \${POSTGRES_USER:-trinity} trinity" > trinity-pg-backup.sql
```

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
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/audit-log/verify | jq    # hash-chain integrity check
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://$HOST:${BACKEND_PORT:-8000}/api/audit-log/export?format=csv" -o audit.csv

# Canary invariant violations (CANARY-001 / #411)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/canary/violations | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/canary/run-cycle | jq    # manual cycle trigger

# Admin recovery for soft-deleted agents/schedules (#834)
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/admin/soft-deleted/agents | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/admin/soft-deleted/agents/myagent/recover | jq

# A2A v1.0 Agent Card (per agent — public endpoint, no auth)
curl -s http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/a2a/agent-card | jq

# Session Tab — start session, list, message, reset (#685, feature-gated)
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
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/retention | jq
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/retention/acknowledge \
  -d '{"key": "<sweep_key>", "window_days": <days>}' | jq   # human-only; agent-scoped keys rejected. 409 unless window_days matches the window in force

# Fleet telemetry-sharing consent (#1723) — opt-in aggregate sharing; default off
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/telemetry-sharing | jq

# Proactive-message rate limits (#1609) — admin-tunable channel send caps
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/proactive-rate-limits | jq

# Per-agent schedule freeze while git sync is failing (#1808) — view + toggle
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/agents/myagent/git/freeze-schedules-if-failing | jq
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
| `agent_ownership` | Agent registry + per-agent flags (`file_sharing_enabled`, `deleted_at` for soft-delete, `circuit_breaker_enabled` #526, `display_label` #1676 — human-facing name over the immutable slug, `volume_base_name` #1666 — data-volume identity frozen at rename) |
| `agent_schedules` | Cron schedules + `deleted_at` for soft-delete (#834) |
| `agent_shared_files` | Outbound file shares — token-scoped download URLs with expiry |
| `agent_sessions` / `agent_session_messages` | Session Tab persistent chat (SESSION_TAB_2026-04, feature-gated) |
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

---

## Service Architecture

| Container | Port (host:container) | Purpose |
|-----------|----------------------|---------|
| `trinity-backend` | 8000:8000 | FastAPI REST API — runs as UID 1000 (#874) |
| `trinity-frontend` | 80:8080 | Vue.js Web UI — unprivileged nginx (#874) |
| `trinity-mcp-server` | 8080:8080 | MCP Protocol Server |
| `trinity-scheduler` | 8001:8001 | Scheduled tasks — runs as UID 1000 |
| `trinity-redis` | 6379:6379 | Sessions, credentials, WS auth tickets — ACL-protected, two users (#589) |
| `trinity-vector` | 8686:8686 | Log aggregation — runs as root but joins GID 1000 via `group_add` (#1799) so its file sink can write the UID-1000-owned `/data/logs`; `cap_drop: ALL` strips `CAP_DAC_OVERRIDE`, so without the group root's writes fail *silently* (healthcheck stays green) |
| `trinity-logs-init` | — | One-shot `alpine` init (#1478): `chown 1000:1000 /data/logs` so UID-1000 Vector retention can write. Backend `depends_on` it (`service_completed_successfully`); exits immediately, `restart: no` |
| `trinity-postgres` | 5432:5432 | **Optional** PostgreSQL backend (#300) — dev-compose only, behind `--profile postgres`. Off by default (SQLite). See [Database Backend](#database-backend-sqlite-default--postgresql-300). |
| `agent-{name}` | — | Per-agent isolated containers |

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

**Backups:** SQLite = copy `trinity.db` (`scripts/backup.sh`); PostgreSQL = `pg_dump` (see [Backup Database](#backup-database)).

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
- HTTPS-only for HTTP/SSE transports with SSRF guard
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

### Long-running agent task killed at 60min

Default execution timeout was bumped 15min → 60min (#665). The deadline is now the **per-agent** `execution_timeout_seconds` (clamped by the schedule cap, #929) — the scheduler honors it (#913 / #922). The old **per-task `timeout_seconds` override is deprecated** (#1068): still honored-but-clamped this release, removed in a follow-up. To extend the wall, raise the agent's `execution_timeout_seconds` (Agent Detail → Settings, or `PATCH /api/agents/{name}`) rather than passing a per-task override.

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
- HTTP/SSE server URL is not HTTPS or resolves to a private/loopback address (SSRF guard)
- Server named `trinity` (reserved — auto-injected by platform)
- Env var references to reserved names (`PATH`, `LD_PRELOAD`, `ANTHROPIC_API_KEY`, etc.)
- Content exceeds 64KB or more than 32 servers defined

The error message from the API (`detail` field) identifies the specific rule that failed.

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
| `INTERNAL_API_SECRET` | **Yes** (auto-gen) | Scheduler→backend auth |
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
| `CANARY_ENABLED` | Staging/dev | Run 5-min invariant watcher loop (default 0) |
| `CANARY_SLACK_WEBHOOK_URL` | Optional | Slack webhook for canary green→red transitions |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Optional | OpenTelemetry collector endpoint |
| `DATABASE_URL` | Optional (#300) | DB selector. Unset/empty → SQLite at `/data/trinity.db`; `postgresql://…` → PostgreSQL. Prod ships no bundled DB — point at a managed Postgres. See [Database Backend](#database-backend-sqlite-default--postgresql-300) |
| `DB_POOL_SIZE` / `DB_MAX_OVERFLOW` | PostgreSQL only | Pool size (10) / burst overflow (20). Ignored on SQLite |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | dev `postgres` profile | Bundled `trinity-postgres` creds. `POSTGRES_PASSWORD` required when the profile is enabled; must match the password in `DATABASE_URL` |
| `VOIP_ENABLED` | Optional (VOIP-001 / #1056) | Outbound phone calls via Twilio Media Streams over Gemini Live. Default OFF; per-agent `voip_bindings` still required to place calls. `VOIP_MAX_CALL_DURATION`/`VOIP_DEFAULT_DAILY_CALL_CAP`/`VOIP_CALL_RATE_LIMIT`/`VOIP_CALL_RATE_WINDOW`/`VOIP_*_TTL_SECONDS` are spend/abuse controls |
| `VOICE_ENABLED` / `VOICE_MODEL` | Optional (VOICE-001) | Voice chat over Gemini Live (default ON). Leave `VOICE_MODEL` commented — an empty value shadows the default and breaks voice (#1076) |
| `WORKSPACE_ENABLED` | Optional (BETA #860) | Voice Workspace canvas (default false) |
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
| `PULL_MODE_PILOT_AGENTS` / `MAX_REDELIVERY` | Optional (#1081, default empty / 3) | Pull/work-stealing pilot (dark by default): comma-separated agent names opted into the agent-side pull worker pool. Backend-only process-env — needs a backend restart AND the agent recreated to engage. `MAX_REDELIVERY` = re-deliveries of an expired pull lease before the row is poison-parked to the operator queue |
| `TRINITY_DEFAULT_SYSTEM_MANIFEST` | Optional (#1764, default empty) | First-run starter-fleet seed: on a genuinely fresh install, Trinity auto-deploys the bundled `config/manifests/default-system.yaml` once after setup. Set to a path (bind-mounted into the backend) for a custom manifest, or `disabled` to skip seeding |

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/run.sh "cmd"` | Run command locally or via SSH |
| `scripts/status.sh` | Quick health check |
| `scripts/restart.sh` | Restart all Trinity services |
| `scripts/update.sh` | Pull latest, rebuild, restart |
| `scripts/backup.sh` | Backup SQLite database |
| `scripts/tunnel.sh` | SSH tunnels for local browser access |

---

*Trinity Ops Agent — manage your sovereign AI infrastructure*

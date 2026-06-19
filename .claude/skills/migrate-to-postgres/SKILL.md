---
name: migrate-to-postgres
description: Migrate this Trinity instance's database from SQLite to PostgreSQL (#300) — provision a parallel postgres container, trial-copy and validate the data, then cut over in a short downtime window with instant rollback. Gated at every state-changing step.
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit
automation: gated
argument-hint: (no args — runs against the instance configured in .env)
metadata:
  version: "1.2"
  updated: 2026-06-19
  changelog:
    - "1.2: Adapted for the public single-instance ops agent — single root .env + scripts/run.sh (local or remote), auto-detect bind-mount vs named volume (trinity_trinity-data), deploy log under deploys/, host backups under ~/backups/. Removed fleet-only machinery (multi-instance layout, external secret vault, external monitoring). Schema bootstrap stays init_schema_postgres (DDL-only); on first boot the backend stamps Alembic over the pre-existing schema (#1183)."
    - "1.1: Snapshots run as root (--user 0:0); ETL skips EMPTY orphan tables (process_* are scheduler-created, not in schema.py) and hard-fails only on NON-EMPTY drift; local expansion of $ADMIN_PASSWORD in the post-cutover check; downtime estimate includes the snapshot."
    - "1.0: Initial version."
---

# Migrate this instance to PostgreSQL

Move a Trinity instance from SQLite to PostgreSQL using the configurable backend seam (Trinity #300, PR #1093). Upstream ships **no migration tool** — `docs/POSTGRESQL_SETUP.md` covers *new* instances only. This skill closes that gap with a parallel-validate-then-switch flow.

## Purpose

Stand up PostgreSQL **next to** the running instance, prove the data pipeline on a trial copy, and only then cut over — with the SQLite file untouched throughout so rollback is always one line.

## Design Facts (read before running)

- **The live SQLite file is never written.** Every copy reads from a cold snapshot taken with the `sqlite3` backup API. Rollback to SQLite is always available.
- **Two-pass copy.** The trial pass (Phase 2) proves schema bootstrap + ETL + connectivity and times the copy. The cutover pass (Phase 3) re-copies from a fresh quiescent snapshot — the trial data is discarded. Never "top up" a trial copy.
- **No parallel "green" backend.** A second backend would share Redis and the Docker socket, and its cleanup/watchdog services would act on *real* agents and slots based on half-empty PG data. Validation is data-fidelity-level; app-level validation happens immediately post-cutover with rollback armed.
- **Schema comes from Trinity's own code** (`db.schema.init_schema_postgres()` — schema.py is the single DDL source). The ETL copies **data only**, never DDL. `init_schema_postgres` builds the tables *empty* (no admin seed), which is what the ETL needs. On first boot the backend's `init_database()` runs the Alembic runner, which detects the pre-existing schema and **stamps `0001_baseline`** rather than rebuilding (#1183) — so no schema conflict. On PG there is **no `schema_migrations` table** (that is SQLite-only); Alembic state lives in `alembic_version`. This is correct, not a fault.
- **Backend selection is one env var.** `DATABASE_URL` set → PostgreSQL (backend *and* scheduler); unset → SQLite. Non-sticky, non-destructive in both directions.
- **The dispatch-window caveat:** anything written to PG between cutover and a later rollback stays in PG only (preserved in the volume, not merged back). Keep the post-cutover validation window short and deliberate.
- **Agents never touch the DB** — agent containers are unaffected. Redis, Vector, frontend, MCP server are unaffected (MCP talks to the backend over HTTP). Postgres joins `trinity-platform-network` only, so agents cannot route to it (#589).

## State Dependencies

| Source | Location | Read | Write | Description |
|--------|----------|------|-------|-------------|
| Ops-agent config | `./.env` | Yes | Yes | SSH/local access; gains a `# PostgreSQL backend (#300)` block (`TRINITY_PG_PASSWORD` + `DATABASE_URL`) at the end |
| Remote Trinity env | `${TRINITY_PATH:-~/trinity}/.env` | Yes | Yes | Gains `DATABASE_URL` at cutover (config-only change — allowed) |
| PG credentials file | `${TRINITY_PATH:-~/trinity}/.env.pg-credentials` (host, 600) | Yes | Yes | Generated password; never passes through local shell args |
| SQLite snapshots | `~/backups/pg-{trial,cutover}-*.db` (host) | Yes | Yes | ETL sources; also serve as backups |
| Postgres container | `trinity-postgres` + `trinity-postgres-data` volume | Yes | Yes | Created by Phase 1 |
| ETL script | `.claude/skills/migrate-to-postgres/scripts/sqlite_to_pg_etl.py` | Yes | No | Shipped to the host at `/tmp/sqlite_to_pg_etl.py` per run |
| Migration log | `deploys/<ts>-postgres-migration.md` | No | Yes | Full report: rowcounts, timings, snapshots, decisions |
| Ops CLAUDE.md | `./CLAUDE.md` | Yes | Yes | Gains a "This instance runs PostgreSQL" note post-cutover |

## Prerequisites

- Run from the ops-agent root (`.env` + `scripts/run.sh` present). Works in both modes: `SSH_HOST` empty = local, otherwise remote over SSH.
- Instance on `${COMPOSE_FILE:-docker-compose.prod.yml}` with Trinity code **and rebuilt images** ≥ #1093 (`06af50cd`). Phase 0 verifies both — a checkout newer than the running image is the classic trap; run `/update` first if so.
- Enough disk for: PG volume (~2× SQLite size) + 2 snapshots + pg_dump.
- An agreed downtime window for Phase 3 (typically 2–10 min; Phase 2 measures it).
- If you front Trinity with external uptime monitoring, expect it to alert during the cutover window.

> **Local installs (`SSH_HOST` empty):** commands below use `sudo docker` to match the rest of this ops agent. On a Docker Desktop laptop where your user is already in the docker group, `sudo` is harmless but you may drop it.

---

## Process

### Phase 0: Pre-flight (read-only — safe to run anytime)

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}

# 1. Instance healthy?
./scripts/run.sh "curl -s http://localhost:${BACKEND_PORT:-8000}/health"

# 2. Code includes #1093?
./scripts/run.sh "cd $TRINITY && git merge-base --is-ancestor 06af50cd HEAD && echo code-ok || echo 'MISSING #1093 — run /update first'"

# 3. Compose wires DATABASE_URL through (backend + scheduler)?
./scripts/run.sh "grep -c 'DATABASE_URL' $TRINITY/$COMPOSE"   # expect >= 2

# 4. IMAGES rebuilt post-#1093? (psycopg2 + the PG schema builder must import)
./scripts/run.sh "sudo docker exec trinity-backend python3 -c 'import psycopg2; from db.schema import init_schema_postgres; from db.engine import get_engine; print(\"backend-image-ok\")'"
./scripts/run.sh "sudo docker exec trinity-scheduler python3 -c 'import psycopg2; print(\"scheduler-image-ok\")'"
# If either fails: the image predates #1093 — /update (rebuild) first. Do not proceed.

# 5. Disk + DB size baseline
./scripts/run.sh "df -h /"
./scripts/run.sh "sudo docker run --rm -v trinity_trinity-data:/data alpine ls -lh /data/trinity.db 2>/dev/null || true"

# 6. Canary must be OFF (its snapshot reader is SQLite-only — known #300 gap)
./scripts/run.sh "sudo docker exec trinity-backend printenv CANARY_ENABLED || echo 'unset (ok)'"

# 7. Platform network present?
./scripts/run.sh "sudo docker network ls --format '{{.Name}}' | grep platform"   # expect: trinity-platform-network
```

Abort conditions: unhealthy backend, missing #1093 (code OR image), `CANARY_ENABLED=1`, <3× SQLite size free disk.

**[APPROVAL GATE 1]** Present: pre-flight results, DB size, estimated trial-copy time, the downtime model, and the rollback story. Proceed only on explicit approval.

### Phase 1: Provision PostgreSQL (additive — Trinity untouched)

Generate the password **on the host** (never through local shell args) and start the container. This mirrors the dev-compose `postgres` profile service (`postgres:16-alpine`, platform network only — agents cannot route there, #589). We run it standalone because prod compose ships no postgres service, and patching the on-instance compose file is forbidden (diverges `~/trinity`, breaks `/update`).

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}

./scripts/run.sh "test -f $TRINITY/.env.pg-credentials && echo 'credentials file already exists — reusing' || (umask 077 && echo \"TRINITY_PG_PASSWORD=\$(openssl rand -hex 24)\" > $TRINITY/.env.pg-credentials && echo created)"

./scripts/run.sh "source $TRINITY/.env.pg-credentials && sudo docker run -d --name trinity-postgres --restart unless-stopped \
  --network trinity-platform-network --network-alias postgres \
  -e POSTGRES_DB=trinity -e POSTGRES_USER=trinity -e POSTGRES_PASSWORD=\$TRINITY_PG_PASSWORD \
  -v trinity-postgres-data:/var/lib/postgresql/data \
  --label trinity.platform=infrastructure --label trinity.service=postgres \
  --security-opt no-new-privileges:true \
  postgres:16-alpine"

# Wait for ready
./scripts/run.sh "for i in \$(seq 1 30); do sudo docker exec trinity-postgres pg_isready -U trinity -d trinity && break || sleep 2; done"

# Isolation sanity: an agent container must NOT resolve 'postgres'
./scripts/run.sh "A=\$(sudo docker ps --format '{{.Names}}' | grep '^agent-' | head -1); [ -z \"\$A\" ] && echo 'no agents to test' || (sudo docker exec \$A getent hosts postgres && echo 'WARNING: agent can resolve postgres!' || echo isolation-ok)"
```

If a future Trinity release adds the `postgres` profile to the prod compose file, prefer `sudo docker compose -f $COMPOSE --profile postgres up -d postgres` over the standalone container (check with `grep -A3 'postgres:' $TRINITY/$COMPOSE | grep profiles`).

### Phase 2: Trial copy + validation (idempotent — re-run freely)

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
TS=$(date +%Y%m%d-%H%M%S)

# Auto-detect the data mount (bind-mount via TRINITY_DATA_PATH, else named volume).
MOUNT_TYPE=$(./scripts/run.sh "sudo docker inspect trinity-backend --format '{{json .Mounts}}' 2>/dev/null | jq -r '.[] | select(.Destination == \"/data\") | .Type'" | tr -d '[:space:]')
if [ "$MOUNT_TYPE" = "bind" ]; then DATA_MOUNT="$TRINITY/trinity-data"; else DATA_MOUNT="trinity_trinity-data"; fi
echo "data mount: $DATA_MOUNT ($MOUNT_TYPE)"

# 1. Online snapshot of the LIVE SQLite (backup API is WAL-safe; db opened mode=ro).
#    --user 0:0 (root) sidesteps host/data-dir ownership mismatches and matches /backup.
#    `time` it: in Phase 3 the snapshot runs INSIDE the downtime window (after writers
#    stop), so projected downtime = trial snapshot + trial ETL + ~1–2 min recreation.
time ./scripts/run.sh "mkdir -p ~/backups && sudo docker run --rm --user 0:0 -v $DATA_MOUNT:/data -v ~/backups:/backup trinity-backend python3 -c \"import sqlite3; s=sqlite3.connect('file:/data/trinity.db?mode=ro',uri=True); d=sqlite3.connect('/backup/pg-trial-$TS.db'); s.backup(d); d.close(); s.close(); print('snapshot ok')\""

# 2. Wipe PG to a clean slate (makes this phase idempotent)
./scripts/run.sh "sudo docker exec trinity-postgres psql -U trinity -d trinity -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'"

# 3. Bootstrap schema with TRINITY'S OWN code. `docker exec -e` scopes the env
#    override to this one process — the live backend stays on SQLite.
./scripts/run.sh "source $TRINITY/.env.pg-credentials && sudo docker exec -e DATABASE_URL=postgresql://trinity:\$TRINITY_PG_PASSWORD@postgres:5432/trinity trinity-backend python3 -c 'from db.engine import get_engine; from db.schema import init_schema_postgres; init_schema_postgres(get_engine()); print(\"schema ok\")'"

# 4. Ship the ETL script and run the trial copy (time it — that is the downtime estimate)
SKILL_DIR="$(git rev-parse --show-toplevel)/.claude/skills/migrate-to-postgres"
cat "$SKILL_DIR/scripts/sqlite_to_pg_etl.py" | ./scripts/run.sh "cat > /tmp/sqlite_to_pg_etl.py"
time ./scripts/run.sh "source $TRINITY/.env.pg-credentials && sudo docker run --rm -i --network trinity-platform-network -v ~/backups:/backup:ro -e SQLITE_PATH=/backup/pg-trial-$TS.db -e PG_URL=postgresql://trinity:\$TRINITY_PG_PASSWORD@postgres:5432/trinity trinity-backend python3 - < /tmp/sqlite_to_pg_etl.py"

# 5. Spot checks beyond rowcounts
./scripts/run.sh "sudo docker exec trinity-postgres psql -U trinity -d trinity -tAc \"SELECT 'users='||count(*) FROM users; SELECT 'agents='||count(*) FROM agent_ownership WHERE deleted_at IS NULL; SELECT 'schedules='||count(*) FROM agent_schedules WHERE deleted_at IS NULL; SELECT 'audit='||count(*) FROM audit_log; SELECT tgname FROM pg_trigger WHERE tgname LIKE 'audit_log%'\""
```

The ETL exits non-zero on any rowcount mismatch, **non-empty** schema drift, or coercion failure — and refuses to load into non-empty tables. **Empty** SQLite tables absent from the PG schema are skipped + logged (a fresh PG instance wouldn't have them either) — only *non-empty* drift hard-fails. On failure, fix the cause (usually: instance needs `/update`, or an anomalous value needs investigating) and re-run this phase from step 2.

> **Expected skip — `process_schedules` / `process_schedule_executions`.** These two tables are **created by the scheduler at startup** (`Process schedules tables ensured` in its log), not by `schema.py` — so they are absent from the PG bootstrap and the ETL will log `skipping empty orphaned tables` for them. This is correct: the scheduler recreates them fresh on PG when it restarts on the new backend (verify post-cutover with `\dt process*`). If either is **non-empty**, the ETL hard-fails (exit 3) — investigate before proceeding.

**[APPROVAL GATE 2]** Present: full rowcount table, spot checks, and **trial snapshot + ETL duration → projected downtime** (snapshot + ETL + ~1–2 min container recreation — the snapshot counts because in Phase 3 it runs after writers stop). Decide: proceed to cutover / re-run / abort (abort = Phase A cleanup below; the running instance was never touched).

### Phase 3: Cutover (downtime window)

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}

# 1. In-flight work check — get operator ack if nonzero (running executions
#    will be orphaned by the stop and marked failed by the cleanup service)
./scripts/run.sh "sudo docker exec trinity-backend python3 -c \"import sqlite3; c=sqlite3.connect('file:/data/trinity.db?mode=ro',uri=True); print('running executions:', c.execute(\\\"SELECT count(*) FROM schedule_executions WHERE status='running'\\\").fetchone()[0])\""

# 2. Fresh PG slate + schema (backend still up — exec needs it running)
./scripts/run.sh "sudo docker exec trinity-postgres psql -U trinity -d trinity -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'"
./scripts/run.sh "source $TRINITY/.env.pg-credentials && sudo docker exec -e DATABASE_URL=postgresql://trinity:\$TRINITY_PG_PASSWORD@postgres:5432/trinity trinity-backend python3 -c 'from db.engine import get_engine; from db.schema import init_schema_postgres; init_schema_postgres(get_engine()); print(\"schema ok\")'"

# 3. STOP writers — downtime starts
./scripts/run.sh "cd $TRINITY && sudo docker compose -f $COMPOSE stop backend scheduler"

# 4. Final quiescent snapshot (also the rollback-grade SQLite backup; --user 0:0, see Phase 2).
#    `docker inspect` works on the now-stopped backend, so mount detection is unchanged.
TS=$(date +%Y%m%d-%H%M%S)
MOUNT_TYPE=$(./scripts/run.sh "sudo docker inspect trinity-backend --format '{{json .Mounts}}' 2>/dev/null | jq -r '.[] | select(.Destination == \"/data\") | .Type'" | tr -d '[:space:]')
if [ "$MOUNT_TYPE" = "bind" ]; then DATA_MOUNT="$TRINITY/trinity-data"; else DATA_MOUNT="trinity_trinity-data"; fi
./scripts/run.sh "sudo docker run --rm --user 0:0 -v $DATA_MOUNT:/data -v ~/backups:/backup trinity-backend python3 -c \"import sqlite3; s=sqlite3.connect('file:/data/trinity.db?mode=ro',uri=True); d=sqlite3.connect('/backup/pg-cutover-$TS.db'); s.backup(d); d.close(); s.close(); print('snapshot ok')\""

# 5. Authoritative ETL from the quiescent snapshot
./scripts/run.sh "source $TRINITY/.env.pg-credentials && sudo docker run --rm -i --network trinity-platform-network -v ~/backups:/backup:ro -e SQLITE_PATH=/backup/pg-cutover-$TS.db -e PG_URL=postgresql://trinity:\$TRINITY_PG_PASSWORD@postgres:5432/trinity trinity-backend python3 - < /tmp/sqlite_to_pg_etl.py"
# MUST print "ETL OK". Non-zero exit => do NOT switch; restart on SQLite
# (docker compose up -d backend scheduler) and return to Phase 2.

# 6. Flip the selector
./scripts/run.sh "source $TRINITY/.env.pg-credentials && grep -q '^DATABASE_URL=' $TRINITY/.env && echo 'DATABASE_URL already set — STOP and inspect' || echo \"DATABASE_URL=postgresql://trinity:\$TRINITY_PG_PASSWORD@postgres:5432/trinity\" >> $TRINITY/.env"

# 7. Recreate with the new env (env changes need recreation, not restart)
./scripts/run.sh "cd $TRINITY && sudo docker compose -f $COMPOSE up -d backend scheduler"
```

**Post-cutover validation (immediately, rollback armed):**

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}

# Backend on PG and healthy
./scripts/run.sh "curl -s http://localhost:${BACKEND_PORT:-8000}/health"
./scripts/run.sh "sudo docker exec trinity-backend python3 -c 'import db.engine as e; print(\"is_sqlite:\", e.is_sqlite())'"   # expect False
# Scheduler on PG (logs the backend explicitly since #300). NB: the scheduler also prints a
# static `Database: /data/trinity.db` line right before `Scheduler database: PostgreSQL (via
# DATABASE_URL)` — the SECOND line is authoritative; the first is a cosmetic default, not a fault.
./scripts/run.sh "sudo docker logs trinity-scheduler --tail 30 2>&1 | grep -i 'postgres\|database'"
# Data intact + admin login works. NOTE: $ADMIN_PASSWORD is a LOCAL .env var — expand it
# LOCALLY (no backslash) so the value is baked into the remote command; \$ADMIN_PASSWORD would
# expand on the host where it is unset, yielding an empty password and "Could not validate credentials".
TOKEN=$(./scripts/run.sh "curl -s -X POST http://localhost:${BACKEND_PORT:-8000}/token -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'username=admin' --data-urlencode 'password=$ADMIN_PASSWORD'" | jq -r .access_token)
echo "token length: ${#TOKEN}"   # expect ~140+, NOT 4
./scripts/run.sh "curl -s -H 'Authorization: Bearer $TOKEN' http://localhost:${BACKEND_PORT:-8000}/api/agents" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("agents via API:", len(d) if isinstance(d,list) else d)'
# Writes land in PG, not SQLite — admin login itself writes an `authentication` audit_log row.
# Confirm audit_log grew on PG AND the sqlite file mtime is frozen at cutover:
./scripts/run.sh "sudo docker exec trinity-postgres psql -U trinity -d trinity -tAc \"SELECT count(*)||' audit rows; latest: '||COALESCE(max(created_at),'') FROM audit_log\""
```

**[APPROVAL GATE 3]** Verdict: **keep PostgreSQL** (→ Phase 4) or **ROLLBACK**:

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}
# Rollback — one line, SQLite file was never touched
./scripts/run.sh "sed -i '/^DATABASE_URL=/d' $TRINITY/.env && cd $TRINITY && sudo docker compose -f $COMPOSE up -d backend scheduler"
./scripts/run.sh "sudo docker exec trinity-backend python3 -c 'import db.engine as e; print(\"is_sqlite:\", e.is_sqlite())'"   # expect True
# Anything written during the PG window stays in the trinity-postgres-data volume (not merged back).
```

### Phase 4: Post-cutover hardening

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}

# 1. First PostgreSQL backup, immediately
./scripts/run.sh "sudo docker exec trinity-postgres pg_dump -U trinity trinity | gzip > ~/backups/trinity-pg-$(date +%Y%m%d-%H%M%S).sql.gz && ls -lh ~/backups/ | tail -3"

# 2. Credentials home. Pull BOTH values (value only — NOT the whole KEY= line) so they can be
#    recorded in your password manager and in this ops agent's .env (gitignored). Do not echo
#    the secrets to the transcript.
PGPW=$(./scripts/run.sh "grep '^TRINITY_PG_PASSWORD=' $TRINITY/.env.pg-credentials | cut -d= -f2-")
DBURL=$(./scripts/run.sh "grep '^DATABASE_URL=' $TRINITY/.env | cut -d= -f2-")
```

Then, without printing the secrets:

3. **Record credentials.** Append a `# PostgreSQL backend (#300)` block with `TRINITY_PG_PASSWORD` and `DATABASE_URL` to this ops agent's `./.env` (it is gitignored), and store both in your password manager. The authoritative copy lives on the host at `${TRINITY_PATH:-~/trinity}/.env` (selector) and `.env.pg-credentials` (password, mode 600).
4. **Documentation** (do both):
   - Append a **"This instance runs PostgreSQL"** note to `./CLAUDE.md` (under the *Database Backend* section): psql access (`sudo docker exec trinity-postgres psql -U trinity -d trinity`), the `pg_dump` backup command, an explicit warning that the SQLite recipes in *Database Operations* and the `/backup` / `/rollback` skills' DB steps **do not apply** until adapted, that canary stays disabled, and the frozen SQLite file's location + cutover date.
   - Write the migration log to `deploys/<ts>-postgres-migration.md`: rowcount table, timings, snapshot filenames, gate decisions, validation evidence.
5. **Do NOT delete** the SQLite database — it is the rollback artifact. It goes stale from cutover; label it in `./CLAUDE.md`. Revisit removal after ~30 days of stable PG operation.
6. **Follow-ups:** `/backup`, `/update` (its pre-update backup step), and `/rollback` still assume SQLite — until they are adapted to PG, take `pg_dump` backups manually (step 1 above).

---

## Abort / Cleanup (Phase A — before cutover only)

Nothing in Phases 0–2 touches the running instance. To abort cleanly:

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
./scripts/run.sh "sudo docker rm -f trinity-postgres && sudo docker volume rm trinity-postgres-data && rm -f $TRINITY/.env.pg-credentials /tmp/sqlite_to_pg_etl.py"
# Snapshots in ~/backups can stay (they are valid backups) or be pruned.
```

## Error Recovery

| Failure | State | Action |
|---------|-------|--------|
| Phase 0 check fails | Nothing changed | Fix prerequisite (usually `/update` for code+images), re-run |
| Phase 1 container won't start | Additive only | `sudo docker logs trinity-postgres`; fix; `docker rm -f` and retry |
| Phase 2 ETL fails (drift/coercion/mismatch) | PG dirty, instance untouched | Investigate the printed table/column/row context; re-run Phase 2 from the wipe step |
| Phase 3 ETL fails | Backend+scheduler stopped, SQLite intact, `DATABASE_URL` not yet set | `docker compose up -d backend scheduler` → back on SQLite; return to Phase 2 |
| Phase 3 validation fails | On PG, rollback armed | Gate 3 ROLLBACK path; instance back on SQLite in ~1 min |
| Discovered broken days after cutover | PG live, SQLite stale | Rollback still works but **loses all writes since cutover** — prefer fixing forward |
| Session dies mid-run | Varies | All phases are resumable: container, credentials file, and snapshots persist; check what exists and continue from there |

## Completion Checklist

- [ ] Pre-flight passed (code + **images** ≥ #1093, disk, canary off)
- [ ] Gate 1: plan approved
- [ ] trinity-postgres up, healthy, agent-isolation verified
- [ ] Trial ETL: "ETL OK", all rowcounts match, downtime projected
- [ ] Gate 2: validation approved
- [ ] Cutover ETL from quiescent snapshot: "ETL OK"
- [ ] Backend `is_sqlite: False`, scheduler on PG, health 200
- [ ] Admin login works; SQLite file mtime frozen at cutover
- [ ] Gate 3: keep decision recorded
- [ ] pg_dump backup taken; credentials in `.env` + password manager
- [ ] `./CLAUDE.md` + deploy log updated
- [ ] SQLite rollback artifact preserved + labeled

## Self-Improvement

After completing this skill's primary task, consider tactical improvements:

- [ ] **Review execution**: friction points, unclear steps, inefficiencies?
- [ ] **Identify improvements**: clearer error handling, step ordering, instructions?
- [ ] **Scope check**: tactical/execution changes only — NOT the core purpose.
- [ ] **Apply** (if identified): edit this SKILL.md or `scripts/sqlite_to_pg_etl.py`, minimal and focused.
- [ ] **Version control** (if in git):
  - [ ] `git add .claude/skills/migrate-to-postgres/`
  - [ ] `git commit -m "refactor(migrate-to-postgres): <brief improvement>"`

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

### 5b. Agent Restart Policy, Guardrails, Wedges, Parked Calls (v0.9.5)

```bash
source .env
# #2541: `no` = pre-0.9.5 container (dies on reboot — sweep with /update step 8c); a climbing RestartCount is a crash loop
./scripts/run.sh "for c in \$(sudo docker ps -a --format '{{.Names}}' | grep '^agent-'); do echo \"\$c \$(sudo docker inspect -f '{{.HostConfig.RestartPolicy.Name}} restarts={{.RestartCount}}' \$c)\"; done"
# ent#345: every agent should say `GUARDRAILS: registration verified`; ERROR = stale base image, NO hooks run
./scripts/run.sh "for c in \$(sudo docker ps --format '{{.Names}}' | grep '^agent-'); do echo \"\$c: \$(sudo docker logs \$c 2>&1 | grep -m1 'GUARDRAILS:' || echo 'no GUARDRAILS line (pre-0.9.5 image)')\"; done"
# #2503: auto thread dumps / event-loop stalls in agent servers
./scripts/run.sh "for c in \$(sudo docker ps --format '{{.Names}}' | grep '^agent-'); do n=\$(sudo docker logs \$c --since 24h 2>&1 | grep -c '\[Diagnostics\] \(THREAD DUMP\|EVENT LOOP STALLED\)'); [ \"\$n\" != 0 ] && echo \"\$c: \$n diagnostics events (24h)\"; done; true"
# #904/#2433: outbound agent calls parked over BACKEND_AGENT_CALL_LIMIT (raise it on a busy fleet); watchdog recoveries
./scripts/run.sh "sudo docker logs trinity-backend --since 24h 2>&1 | grep -cE '\[InflightDispatch\]|recovered by watchdog' || true"
# ent#615: no agent remote may carry a credential (prints only agent names — never the URL)
./scripts/run.sh "for c in \$(sudo docker ps --format '{{.Names}}' | grep '^agent-'); do sudo docker exec \$c git -C /home/developer config --get-regexp 'remote\..*\.(url|pushurl)' 2>/dev/null | grep -qE 'https?://[^/]*@' && echo \"\$c: remote still carries a credential\"; done; true"
# ent#615 sweep reports with refused / gitmodules_hits / root_readable=0 worth acting on
./scripts/run.sh "sudo docker logs trinity-backend --tail 3000 2>&1 | grep 'ent#615: remote-token sweep' | grep -E \"'refused': [1-9]|'gitmodules_hits': [1-9]|'root_readable': 0\" | tail -5; true"
# #2742 / #2800: sync-health poller errors (PG `integer out of range` = pre-0063 schema)
./scripts/run.sh "sudo docker logs trinity-backend --since 24h 2>&1 | grep -iE 'sync.?health.*(error|failed)|integer out of range' | tail -5; true"
# v1.0.0 (#3113 / ent#752): the agent server's own /health reports the guardrail and
# skill-gate registration (the Skills tab reads skill_gate_hook since v1.0.0: "not enforced").
# A null means an old image.
./scripts/run.sh "for c in \$(sudo docker ps --format '{{.Names}}' | grep '^agent-'); do echo \"\$c \$(sudo docker exec \$c curl -s -m 5 localhost:8000/health 2>/dev/null | jq -c '[.guardrails_registration, .skill_gate_hook]' 2>/dev/null)\"; done"
# v1.0.0: image pins (Opus 5.5 needs Claude Code >= 2.1.280), pull loop, retained results
./scripts/run.sh "for c in \$(sudo docker ps --format '{{.Names}}' | grep '^agent-' | head -5); do echo \"\$c \$(sudo docker exec \$c claude --version 2>/dev/null | head -1) pull_loop=\$(sudo docker logs \$c 2>&1 | grep -c 'pull loop started')\"; done"
# v1.0.0: upgrade-time notices worth reading once (cleared sign-in emails, capped CPU,
# unlabelled orphan volumes, refused agent self-changes, chain-depth refusals)
./scripts/run.sh "sudo docker logs trinity-backend --since 24h 2>&1 | grep -E 'ent#720|\[#2318\]|\[#3214\]|capability_refused|inter_agent_depth_exceeded|effect_unguarded' | tail -10; true"
# v1.0.0: SUB-003 walking subscriptions (#3470 — 'image predates it' = old agent image),
# completed_at clamps (#3589)
./scripts/run.sh "sudo docker logs trinity-backend --since 24h 2>&1 | grep -E '\[#3470\]|\[#3589\]' | tail -10; true"
```

v1.0.0 access checks (admin token): peer-skill calls refused since the upgrade, and `user`-role accounts that now get 403 `workspace_only` on operator routes:

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://$HOST:${BACKEND_PORT:-8000}/api/skills/peer-grants/drift | jq
curl -s -H "Authorization: Bearer $TOKEN" http://$HOST:${BACKEND_PORT:-8000}/api/users | jq -r '.[] | select(.role=="user") | .username'
```

Flag: any `guardrails_registration` or `skill_gate_hook` other than `ok` (a `null` pair means the agent is still on a pre-pin base image), any `ent#720 duplicate sign-in email` line (that account lost email sign-in), repeated `capability_refused` (an orchestrator agent needs a grant — CLAUDE.md → Self-change grants), any `no` policy, any `GUARDRAILS: ERROR`, any `did not apply the per-spawn credential` (#3470, old image), a non-empty peer-skill drift list (grant or accept the refusals — CLAUDE.md → Peer skill grants), a `user` account that operates agents (raise it to `operator`), any diagnostics events, a non-trivial parked/recovered count, any agent whose remote still carries a credential, or any sweep report with `refused` > 0, `gitmodules_hits` > 0 (**rotate the platform token**) or `root_readable` 0.

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

Backend-aware, and read through the backend's own `/data` mount so it is right for the dev named volume and for a prod or hosted bind mount alike. A hosted install on v1.0.0 runs the bundled PostgreSQL unless it predates #3159.

```bash
source .env
DB_URL=$(./scripts/run.sh "sudo docker exec trinity-backend printenv DATABASE_URL 2>/dev/null" 2>/dev/null | tr -d '[:space:]' || true)
if [[ "$DB_URL" == postgresql://* ]]; then
    # One head expected; two means migrations are silently not applying
    ./scripts/run.sh "sudo docker exec trinity-backend alembic heads"
    ./scripts/run.sh "sudo docker ps --format '{{.Names}}' | grep -qx trinity-postgres && sudo docker exec trinity-postgres pg_isready -h 127.0.0.1 -U trinity -d trinity || echo 'external PostgreSQL — check it with your provider tooling'"
else
    ./scripts/run.sh "sudo docker exec trinity-backend python3 -c \"import sqlite3; c=sqlite3.connect('file:/data/trinity.db?mode=ro',uri=True); print(c.execute('PRAGMA integrity_check').fetchone()[0])\""
    # Hosted on SQLite after #3159: the selector must be an EMPTY line, never absent
    ./scripts/run.sh "grep -q 'container_name: trinity-postgres' ${TRINITY_PATH:-~/trinity}/${COMPOSE_FILE:-docker-compose.prod.yml} && (grep -qE '^DATABASE_URL=' ${TRINITY_PATH:-~/trinity}/.env && echo 'hosted selector ok' || echo 'WARNING: hosted compose bundles PostgreSQL and .env has no DATABASE_URL line — the next compose up boots an EMPTY PostgreSQL'); true"
fi
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

**Agent runtime (v0.9.5+)**: restart policy {n agents still `no`}, guardrails {verified / n ERROR; /health registration ok / n not ok / n old image}, wedge diagnostics {n events}, parked calls {n}, git remotes {clean / n with credential; sweep refused/gitmodules/unreadable}, sync-health {ok / errors}

### Recommendations
{Specific next steps based on findings}
```

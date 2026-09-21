---
name: cleanup
description: Clean up Docker resources (dangling images, build cache) and old backup files. Dry run by default, --execute to apply.
disable-model-invocation: true
allowed-tools: Bash, Read
argument-hint: [--execute]
automation: gated
---

# Docker and Backup Cleanup

## Arguments

- No args — dry run: show what would be cleaned
- `--execute` — actually perform the cleanup

## Instructions

### 1. Verify Context

```bash
ls -la .env scripts/run.sh 2>/dev/null
```

### 2. Analyze Current State

**Docker disk usage:**
```bash
source .env
./scripts/run.sh "sudo docker system df"
```

**Dangling images:**
```bash
source .env
./scripts/run.sh "sudo docker images -f 'dangling=true' -q | wc -l"
./scripts/run.sh "sudo docker images -f 'dangling=true' --format '{{.Repository}}:{{.Tag}} {{.Size}}' | head -10"
```

**Old backups** (manual copies in `~/backups/` beyond the 10 most recent — `.db` and `.dump`):
```bash
source .env
./scripts/run.sh "ls -t ~/backups/*.db ~/backups/*.dump 2>/dev/null | tail -n +11 | wc -l"
```

Do **not** touch the platform's own artifacts under `/data/backups/` (v0.9.0+, #2216) — the backend prunes those itself by `backup_retention_days` (default 14, newest 3 always kept). If they are eating the disk, widen/narrow that setting via `PUT /api/settings/ops/config`, never `rm`. Likewise `/data/archives` (log archives) is governed by `LOG_RETENTION_DAYS`.

Also out of scope for `docker image prune`: on a **hosted** install the pulled `ghcr.io/abilityai/trinity-*` images and the retagged `trinity-agent-base:latest` are the running release — a dangling older digest is safe to prune, the tagged ones are not. Two v0.9.5 tables have **no** retention sweep by design (`enterprise_rooms*` — closed rooms persist; `agent_canvas_shares` — expired/revoked links persist); they are not disk-relevant, do not hand-delete them.

### 3. Dry Run Output

```
## Cleanup Analysis

### Would Be Cleaned
| Category | Count |
|----------|-------|
| Dangling images | {n} |
| Old backups (keeping 10) | {n} files |

### Protected (Never Cleaned)
- trinity_* volumes (platform data)
- agent-* volumes (agent workspaces)
- 10 most recent backups

Run `/cleanup --execute` to apply.
```

### 4. Execute Cleanup (only if --execute flag present)

```bash
source .env
# Remove dangling images
./scripts/run.sh "sudo docker image prune -f"

# Clear build cache
./scripts/run.sh "sudo docker builder prune -f"

# Remove old backups (keep latest 10)
./scripts/run.sh "cd ~/backups && ls -t *.db *.dump 2>/dev/null | tail -n +11 | xargs -r rm -v"
```

### 5. Post-Cleanup Status

```bash
source .env
./scripts/run.sh "sudo docker system df"
./scripts/run.sh "df -h / | tail -1"
```

Report space recovered.

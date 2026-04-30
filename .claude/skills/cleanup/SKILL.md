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

**Old backups** (files beyond 10 most recent):
```bash
source .env
./scripts/run.sh "ls -t ~/backups/*.db 2>/dev/null | tail -n +11 | wc -l"
```

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
./scripts/run.sh "cd ~/backups && ls -t *.db 2>/dev/null | tail -n +11 | xargs -r rm -v"
```

### 5. Post-Cleanup Status

```bash
source .env
./scripts/run.sh "sudo docker system df"
./scripts/run.sh "df -h / | tail -1"
```

Report space recovered.

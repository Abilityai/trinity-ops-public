---
name: sync-ops-knowledge
description: Review recent Trinity codebase changes and update ops-agent instructions, skills, and CLAUDE.md to stay current
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Agent
automation: gated
user-invocable: true
---

# Sync Ops Knowledge

## Purpose
SSH into a Trinity instance, review recent git changes in the Trinity codebase, analyze new features/APIs/config changes, and determine if CLAUDE.md or skills need updating. Presents proposed changes for approval before applying.

## State Dependencies

| Source | Location | Read | Write | Description |
|--------|----------|------|-------|-------------|
| Trinity git history | Remote instance via SSH | Yes | No | Recent commits and diffs |
| CLAUDE.md | `./CLAUDE.md` | Yes | Yes | Main ops-agent instructions |
| Skills | `.claude/skills/*/SKILL.md` | Yes | Yes | Operational skills |
| Last sync state | `.claude/skills/sync-ops-knowledge/last-sync.json` | Yes | Yes | Tracks last reviewed commit |

## Prerequisites
- `.env` configured with SSH credentials (or `SSH_HOST` empty for local)

## Inputs
- `$0`: Number of days to look back (default: 7), or `--since <commit>` to review since a specific commit

---

## Process

### Step 1: Load Configuration

Load credentials from the root `.env`:

```bash
source .env
```

Read the last sync state to determine the starting point:

```bash
cat .claude/skills/sync-ops-knowledge/last-sync.json 2>/dev/null || echo '{"last_commit": "none", "last_sync_date": "never"}'
```

### Step 2: Gather Recent Changes from Trinity Codebase

SSH into the instance and collect git history:

```bash
# If we have a last_commit, use it; otherwise use --since N days
DAYS="${0:-7}"

# Get recent commits (summary)
./scripts/run.sh "cd ~/trinity && git log --oneline --since='$DAYS days ago' | head -50"

# Get the full diff stats
./scripts/run.sh "cd ~/trinity && git log --stat --since='$DAYS days ago' | head -200"
```

If a `last_commit` exists in `last-sync.json`, prefer:
```bash
./scripts/run.sh "cd ~/trinity && git log --oneline $LAST_COMMIT..HEAD"
./scripts/run.sh "cd ~/trinity && git log --stat $LAST_COMMIT..HEAD | head -200"
```

Record the current HEAD commit hash for later:
```bash
./scripts/run.sh "cd ~/trinity && git rev-parse HEAD"
```

### Step 3: Analyze Changes by Category

For each area of significant change, pull detailed diffs. Focus on these categories:

**API Changes** — new/modified endpoints:
```bash
./scripts/run.sh "cd ~/trinity && git diff $SINCE..HEAD --stat -- src/backend/routers/ src/backend/main.py"
# For files with changes, get the actual diff (or grep @router.* for new endpoint definitions)
./scripts/run.sh "cd ~/trinity && grep -rE '^@router\\.(get|post|put|delete)' src/backend/routers/"
```

**Database Schema** — new tables, columns:
```bash
./scripts/run.sh "cd ~/trinity && git diff $SINCE..HEAD -- src/backend/db_models.py src/backend/db/migrations.py src/backend/db/schema.py"
```

**Docker / Infrastructure** — compose changes, new services:
```bash
./scripts/run.sh "cd ~/trinity && git diff $SINCE..HEAD -- docker-compose*.yml docker/backend/Dockerfile docker/base-image/Dockerfile"
```

**Configuration / Environment** — new env vars, settings:
```bash
./scripts/run.sh "cd ~/trinity && git diff $SINCE..HEAD -- .env.example src/backend/config.py"
```

**Frontend Features** — new pages, major UI changes:
```bash
./scripts/run.sh "cd ~/trinity && git diff $SINCE..HEAD --stat -- src/frontend/src/views/ src/frontend/src/components/"
```

**Agent System** — changes to agent container setup, templates:
```bash
./scripts/run.sh "cd ~/trinity && git diff $SINCE..HEAD --stat -- src/backend/services/ docker/base-image/"
```

**MCP Server** — new tools, protocol changes:
```bash
./scripts/run.sh "cd ~/trinity && git diff $SINCE..HEAD --stat -- src/mcp-server/"
# List all MCP tool names:
./scripts/run.sh "cd ~/trinity && grep -rE 'name: \"[a-z_]+\"' src/mcp-server/src/tools/"
```

**Scheduler** — execution, task changes:
```bash
./scripts/run.sh "cd ~/trinity && git diff $SINCE..HEAD --stat -- src/backend/scheduler_app/ src/scheduler/"
```

### Step 4: Cross-Reference with Current Documentation

Read the current CLAUDE.md and identify sections that may be affected:

1. Read `./CLAUDE.md` — check API Reference, Architecture, Database tables, Environment variables, Features list
2. Read relevant `SKILL.md` files for any skills that touch changed areas
3. Compare what's documented vs what the code now shows

Build a change report with these sections:

```markdown
## Change Report: Trinity $SINCE..$HEAD

### New Features
- [list features with commit refs]

### API Changes
- New endpoints: [list]
- Modified endpoints: [list]
- Removed endpoints: [list]

### Database Changes
- New tables: [list]
- New columns: [list]

### Configuration Changes
- New env vars: [list with purpose]
- Changed defaults: [list]

### Infrastructure Changes
- Docker compose changes: [summary]
- New services: [list]

### Impact on Ops Agent
- CLAUDE.md sections to update: [list sections]
- Skills to update: [list skills and what changed]
- New skills needed: [list if any]
- No changes needed: [list areas reviewed but unchanged]
```

### Step 5: Propose Updates

[APPROVAL GATE] — Review proposed changes before applying

Present the change report to the user with specific proposed edits:

**For each proposed change, show:**
1. **What changed** in Trinity (commit ref + summary)
2. **What needs updating** in ops-agent (file + section)
3. **Proposed edit** (before/after or new content)

**User options:**
1. **Approve all** — Apply all proposed changes
2. **Approve selectively** — Choose which changes to apply
3. **Request modifications** — Adjust proposed edits
4. **Skip** — No changes needed right now

If changes requested, revise proposals and return to this gate.

### Step 6: Apply Approved Changes

For each approved change:

1. Edit `CLAUDE.md` with updated sections (API tables, feature lists, env vars, etc.)
2. Edit affected `SKILL.md` files
3. Create new skills if approved

### Step 7: Update Sync State

Write the new sync state:

```json
{
  "last_commit": "<HEAD commit hash>",
  "last_sync_date": "<ISO date>",
  "instance_used": "local",
  "changes_applied": ["<list of changes made>"],
  "changes_skipped": ["<list of changes reviewed but not applied>"]
}
```

Save to `.claude/skills/sync-ops-knowledge/last-sync.json`.

### Step 8: Summary

Present final summary:
- Commits reviewed: N
- Changes applied: N (list)
- Changes skipped: N (list)
- Files modified: [list]
- Next sync will start from: `<new HEAD>`

---

## Outputs
- Updated `CLAUDE.md` (if changes approved)
- Updated skill files (if changes approved)
- Updated `last-sync.json` with current position
- Change report (displayed to user)

## Error Recovery

**If SSH fails:**
- Verify `.env` SSH credentials (`SSH_HOST`, `SSH_USER`, `SSH_KEY`)
- For local installs, confirm `SSH_HOST` is empty

**Before approval gate:**
- No state changes made
- Safe to re-run

**After approval, mid-edit:**
- Check git diff to see partial changes
- Complete manually or re-run (edits are idempotent)

## Completion Checklist
- [ ] SSH/local connection verified
- [ ] Git history collected since last sync
- [ ] Changes categorized (API, DB, config, infra, features)
- [ ] Current documentation cross-referenced
- [ ] Change report presented to user
- [ ] Approval gate passed
- [ ] Approved changes applied
- [ ] Sync state updated
- [ ] Summary presented

## Self-Improvement

After completing this skill's primary task, consider tactical improvements:

- [ ] **Review execution**: Were there friction points, unclear steps, or inefficiencies?
- [ ] **Identify improvements**: Could error handling, step ordering, or instructions be clearer?
- [ ] **Scope check**: Only tactical/execution changes—NOT changes to core purpose or goals
- [ ] **Apply improvement** (if identified):
  - [ ] Edit this SKILL.md with the specific improvement
  - [ ] Keep changes minimal and focused
- [ ] **Version control** (if in a git repository):
  - [ ] Stage: `git add .claude/skills/sync-ops-knowledge/SKILL.md`
  - [ ] Commit: `git commit -m "refactor(sync-ops-knowledge): <brief improvement description>"`

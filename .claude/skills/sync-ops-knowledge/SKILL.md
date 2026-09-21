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

**Source selection.** This repo has no `.env` when it is used purely as a docs/skills repo, and the Trinity source of truth may be a local checkout rather than a deployed instance. Resolve in this order, and record which was used in `last-sync.json`:

1. A local Trinity checkout (e.g. `~/Dropbox/trinity/trinity`) — read diffs directly with `git -C <path>`, no `scripts/run.sh`. Confirm the branch first (`git branch --show-current`): a `from dev` argument means the **dev** branch, which is ahead of the deployed instance.
2. `.env` + `scripts/run.sh` against the configured instance.

Verify the recorded `last_commit` is still an ancestor of HEAD before diffing (`git merge-base --is-ancestor <last_commit> HEAD`) — a force-push or branch switch invalidates the range and the review must fall back to `--since N days`.

**`from main` when the last sync was on `dev`:** upstream releases land on `main` as one squash commit (`Release: vX.Y.Z (#NNNN)`) and `dev` is then re-synced, so a dev-side `last_commit` is *not* an ancestor of `main` even though nothing was lost. Do not fall back to `--since`. Instead: (1) confirm the trees match — `git diff --stat origin/main origin/dev` empty — then (2) take the **content** delta as `git diff <last_commit> origin/main` and the **commit messages** from dev's granular history `git log --no-merges <last_commit>..origin/dev` (the squash commit on main has no per-change bodies). Read `docs/releases/<version>.md` from the release commit first — its "Behavior changes / upgrade notes" section is the operator-facing summary and lists every new env var. Record the main SHA as `last_commit` (it is an ancestor of dev too, so the next `from dev` sync ranges cleanly).

**`from dev` after a `from main` sync — range from the dev tip, not the main SHA.** The squash commit on `main` is an ancestor of `dev` only through the re-sync merge, so `git log <main_sha>..origin/dev` lists *all* of dev's granular history behind that release (the 2026-09 run listed 743 commits when the true delta was 308). Always record the **dev tip whose tree matched** as `dev_tip` in `last-sync.json` alongside `last_commit`, and range the next dev sync from `dev_tip` (`git diff --stat <dev_tip> <last_commit>` must be empty — that is the proof they are interchangeable). Verify with `git merge-base --is-ancestor <dev_tip> origin/dev`.

**Read `origin/<branch>`, never the working tree.** The local checkout is often on a release branch (e.g. `chore/release-X.Y.Z`) with uncommitted work: a bumped `VERSION`, or a draft `docs/releases/<ver>.md` / `v<ver>-freeze-plan.md`. `git fetch` first, then range and read with `git log`/`git show origin/dev:<path>`. An untracked draft release doc is still the best summary of operator changes (upgrade notes, full list of new env vars, Alembic range), but cite code from `origin/dev`, and tell the user the draft was used. Typing short SHAs by hand is error-prone (`unknown revision`), so copy them from the `git log` output.

**User-facing install pages live outside this repo.** docs.ability.ai is built from the sibling `trinity-docs` repo (`app/getting-started/deploying/<provider>/page.tsx`). Upstream's own guides are in `docs/user-docs/guides/deploying/*.md` (hardening, public-access, upgrading). When the user links a docs page, compare it with the script it wraps (`git show origin/dev:scripts/deploy/<script>`), and report any drift such as a stale pinned tag. Fix only this repo; mention the drift in the summary.

**Large ranges (> ~150 non-trivial commits): fan out.** Dump `git log --no-merges --format='%h %s'` to a scratch file and filter out `docs(`, `chore(deps`, `test`, `ci`, `chore(submodule`, `chore(.claude`, `chore(enterprise`, `chore(metrics`. Then launch parallel research subagents by **area** — (1) install/deploy/compose, (2) auth/security/credentials, (3) agent containers/base image/execution lifecycle, (4) platform features with ops surfaces (tables, env, endpoints, sentinels), (5) verification of every runbook claim + version/release picture — each told the exact range, told to read commit bodies with `--grep='(#NNNN)'`, and asked for a terse operator deliverable (commands, env vars + which compose files forward them, endpoints with auth tier, symptom→check→fix rows). Verify in the main context any endpoint path or request-body shape the agents disagree on (`git show origin/dev:<file>` — quote the `${T}:path` form in zsh) before writing it into CLAUDE.md. Also diff route decorators, `CREATE TABLE` names and MCP tool `name:` strings mechanically between the two commits — cheaper than reading and catches removals.

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

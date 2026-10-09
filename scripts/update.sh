#!/bin/bash
# Update Trinity - pull latest, rebuild, restart
#
# Two install modes (v0.9.5, #2280):
#   source build  — COMPOSE_FILE=docker-compose.prod.yml (default) or docker-compose.yml:
#                   git pull, rebuild the four platform images, compose up.
#   hosted        — COMPOSE_FILE=docker-compose.hosted.yml: prebuilt GHCR images; the
#                   upgrade IS `start.sh --hosted` (it pulls the platform images AND the
#                   agent base image and retags it; a bare `docker compose pull` leaves
#                   every agent on the old runtime). TRINITY_IMAGE_TAG in the server
#                   .env selects the release — pin it. The checkout must move with it
#                   (compose file + mounted config/), so a pinned tag is checked out
#                   rather than pulled: marketplace and one-command installs are
#                   `--depth 1 --branch <tag>` clones with a detached HEAD.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

run() { "$SCRIPT_DIR/run.sh" "$1"; }
HOST=${SSH_HOST:-localhost}
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}
BRANCH=${TRINITY_BRANCH:-main}
HOSTED=0
case "$COMPOSE" in *hosted*) HOSTED=1 ;; esac

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo ""
echo -e "${BLUE}══════════════════════════════════════${NC}"
echo -e "${BLUE}   Trinity Update - ${HOST}${NC}"
echo -e "${BLUE}══════════════════════════════════════${NC}"
[ "$HOSTED" = 1 ] && echo -e "  mode: ${YELLOW}hosted${NC} (prebuilt images, TRINITY_IMAGE_TAG from server .env)"

# 0. Pre-check: CREDENTIAL_ENCRYPTION_KEY (ent#435 / #2330, v0.9.5). The secret-settings
#    migration refuses to boot the backend when the key is empty and credential rows
#    exist. Cheap to check before we touch anything.
CEK=$(run "grep -E '^CREDENTIAL_ENCRYPTION_KEY=.+' $TRINITY/.env 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]' || echo 0)
if [ "${CEK:-0}" = "0" ]; then
    echo -e "\n  ${RED}✗${NC} CREDENTIAL_ENCRYPTION_KEY is empty in $TRINITY/.env"
    echo -e "    v0.9.5 encrypts credential rows in system_settings at boot and REFUSES to start"
    echo -e "    without the key (ent#435). Set it first:  openssl rand -hex 32"
    exit 1
fi

# 1. Backup (sqlite3 online-backup API — never a raw cp of a live DB; PG-aware)
#    Trinity v0.9.0+ also writes /data/backups/pre-migration-*.db itself at boot
#    when a migration is pending (#2216); this is the belt to that suspenders.
echo -e "\n${YELLOW}[1/5] Backing up database...${NC}"
if "$SCRIPT_DIR/backup.sh"; then
    echo -e "  ${GREEN}✓${NC} backup done"
else
    echo -e "  ${RED}✗${NC} backup failed — aborting update"
    exit 1
fi

# 2. Pull (source build) / check out the pinned release tag (hosted)
BEFORE=$(run "cd $TRINITY && git log -1 --oneline")
if [ "$HOSTED" = 1 ]; then
    # Last TRINITY_IMAGE_TAG line wins (upstream's upgrade guide appends a new one).
    TAG=$(run "grep -E '^TRINITY_IMAGE_TAG=' $TRINITY/.env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\"'" 2>/dev/null | tr -d '[:space:]')
    ON_BRANCH=$(run "cd $TRINITY && git symbolic-ref -q --short HEAD || true" 2>/dev/null | tr -d '[:space:]')
    if [[ "$TAG" =~ ^v?[0-9]+\.[0-9]+ ]]; then
        GIT_TAG="v${TAG#v}"
        echo -e "\n${YELLOW}[2/5] Checking out $GIT_TAG (TRINITY_IMAGE_TAG=$TAG)...${NC}"
        # --depth 1 only on a shallow clone; on a full clone it would truncate history.
        if ! run "cd $TRINITY && D=''; [ \"\$(git rev-parse --is-shallow-repository)\" = true ] && D='--depth 1'; git fetch \$D origin tag $GIT_TAG && git checkout -q $GIT_TAG"; then
            # A moving image tag such as 0.9 has no git tag; a wrong one fails at the image pull below.
            echo -e "  ${YELLOW}⚠${NC} could not check out $GIT_TAG — the checkout stays at ${BEFORE%% *}; the compose file and config/ may not match the images"
        fi
    elif [ -n "$ON_BRANCH" ]; then
        echo -e "\n${YELLOW}[2/5] Pulling $BRANCH (TRINITY_IMAGE_TAG is '${TAG:-unset}', not a release tag)...${NC}"
        run "cd $TRINITY && git pull origin $BRANCH"
    else
        echo -e "\n${YELLOW}[2/5] Checkout left as is${NC}"
        echo -e "  ${YELLOW}⚠${NC} detached HEAD and TRINITY_IMAGE_TAG='${TAG:-unset}' — nothing to check out."
        echo -e "    Pin a release tag in $TRINITY/.env so the compose file and config/ move with the images."
    fi
else
    echo -e "\n${YELLOW}[2/5] Pulling $BRANCH...${NC}"
    run "cd $TRINITY && git pull origin $BRANCH"
fi
AFTER=$(run "cd $TRINITY && git log -1 --oneline")
if [ "$BEFORE" = "$AFTER" ]; then
    echo -e "  ${YELLOW}⚠${NC} Already up to date"
else
    echo -e "  ${GREEN}✓${NC} $AFTER"
fi
# Did the pulled range touch the agent base image? (#1809/#1860/#1816 — a
# rebuilt base image is adopted on each agent's next cold stop/start, never
# by a running agent; platform images are rebuilt below.)
BEFORE_SHA=${BEFORE%% *}; AFTER_SHA=${AFTER%% *}
BASE_CHANGED=$(run "cd $TRINITY && git diff --name-only $BEFORE_SHA $AFTER_SHA -- docker/base-image/ 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]' || echo 0)

if [ "$HOSTED" = 1 ]; then
    # 3+4. Hosted: start.sh --hosted pulls platform images + agent base (retagged
    #      trinity-agent-base:latest) and brings the stack up. Never `compose pull`.
    echo -e "\n${YELLOW}[3/5] Pulling prebuilt images + starting (start.sh --hosted)...${NC}"
    [ -z "$TAG" ] && echo -e "  ${YELLOW}⚠${NC} TRINITY_IMAGE_TAG unset — 'latest' moves on every release; pin it in $TRINITY/.env" || echo "  TRINITY_IMAGE_TAG=$TAG"
    run "cd $TRINITY && sudo ./scripts/deploy/start.sh --hosted --unattended"
    echo -e "  ${GREEN}✓${NC} hosted stack up"
    echo -e "\n${YELLOW}[4/5] (no local build in hosted mode)${NC}"
    BASE_CHANGED=hosted   # the base image was re-pulled; agents still adopt on cold stop/start
else
    # 3. Rebuild — load-bearing (#1814): start.sh never rebuilds platform images
    echo -e "\n${YELLOW}[3/5] Rebuilding containers...${NC}"
    run "cd $TRINITY && sudo docker compose -f $COMPOSE build --no-cache backend frontend mcp-server scheduler"
    echo -e "  ${GREEN}✓${NC} Build complete"

    # 4. Restart. NEVER `compose down` here (#2541): agents are unless-stopped and a
    #    recreated network sends every one of them into a dockerd restart loop.
    echo -e "\n${YELLOW}[4/5] Starting services...${NC}"
    run "cd $TRINITY && sudo docker compose -f $COMPOSE up -d"
fi
echo "  Waiting 10s..."
sleep 10

# 5. One-shot agent restart-policy sweep (#2541, v0.9.5). Containers created before
#    0.9.5 keep RestartPolicy=no until recreated; `docker update` on a STOPPED
#    container changes the policy without starting it, so run state is preserved.
echo -e "\n${YELLOW}[5/5] Agent restart-policy sweep (#2541)...${NC}"
SWEPT=$(run "n=0; for c in \$(sudo docker ps -a --format '{{.Names}}' | grep '^agent-'); do if [ \"\$(sudo docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' \$c)\" = no ]; then sudo docker update --restart unless-stopped \$c >/dev/null && n=\$((n+1)); fi; done; echo \$n" 2>/dev/null | tr -d '[:space:]' || echo "?")
echo -e "  ${GREEN}✓${NC} agents moved to unless-stopped: ${SWEPT:-?}"

# Verify
BACKEND=$(run "curl -s -o /dev/null -w '%{http_code}' http://localhost:${BACKEND_PORT:-8000}/health" 2>/dev/null)
SCHED=$(run "sudo docker inspect trinity-scheduler --format='{{.State.Health.Status}}'" 2>/dev/null | tr -d '\r')
# #1814: `version` = code in service, `image_version` = build it runs inside. Different = stale image.
VER_JSON=$(run "curl -s http://localhost:${BACKEND_PORT:-8000}/api/version" 2>/dev/null || true)
VER=$(echo "$VER_JSON" | jq -r '.version // "?"' 2>/dev/null || echo "?")
IMG_VER=$(echo "$VER_JSON" | jq -r '.image_version // "?"' 2>/dev/null || echo "?")
# ent#435: did the secret-settings migration run / complain?
ENC_LOG=$(run "sudo docker logs trinity-backend --tail 500 2>&1 | grep -E 'ent#435|MissingEncryptionKeyError' | tail -2" 2>/dev/null || true)
# PostgreSQL only: two alembic heads means `upgrade head` silently applied nothing (0043/0044 fork, merged by 0045)
HEADS=$(run "sudo docker exec trinity-backend alembic heads 2>/dev/null | grep -c head" 2>/dev/null | tr -d '[:space:]' || echo 0)
# ent#615 (v0.9.5): the git remote token scrub runs ~20s after each backend boot and logs
# one counts-only report per running git agent. Wait for it (up to 30s), then pick out
# the reports that rewrote something (→ rotate the platform token) or need a human
# (refused / unreadable workspace / token in a tracked .gitmodules).
SCRUB_LOG='sudo docker logs trinity-backend --since 10m 2>&1'
SCRUBBED=$(run "for i in 1 2 3 4 5 6; do $SCRUB_LOG | grep -q 'ent#615: remote-token sweep for' && break; sleep 5; done; $SCRUB_LOG | grep 'ent#615: remote-token sweep for' | grep -cE \"'(remotes_scrubbed|harvested)': [1-9]\"" 2>/dev/null | tr -d '[:space:]' || echo 0)
# Post-0.9.5 dev. ent#720 (Alembic 0085): duplicate sign-in emails are cleared at boot — those
# accounts lose email sign-in until they re-bind. #3159: on a hosted stack that bundles
# PostgreSQL, an ABSENT DATABASE_URL line means "bundled PostgreSQL"; a SQLite keeper must
# carry an empty `DATABASE_URL=`.
EMAIL_CLEARED=$(run "sudo docker logs trinity-backend --since 10m 2>&1 | grep -c 'ent#720.*duplicate sign-in email'" 2>/dev/null | tr -d '[:space:]' || echo 0)
DB_KIND=$(run "sudo docker exec trinity-backend printenv DATABASE_URL 2>/dev/null | grep -q '^postgresql' && echo postgresql || echo sqlite" 2>/dev/null | tr -d '[:space:]')
SELECTOR_MISSING=0
if [ "$HOSTED" = 1 ]; then
    SELECTOR_MISSING=$(run "grep -q 'container_name: trinity-postgres' $TRINITY/$COMPOSE && ! grep -qE '^[[:space:]]*(export[[:space:]]+)?DATABASE_URL=' $TRINITY/.env && [ -f ${TRINITY}/trinity-data/trinity.db ] && echo 1 || echo 0" 2>/dev/null | tr -d '[:space:]')
fi
SCRUB_BAD=$(run "$SCRUB_LOG | grep -E \"ent#615: remote-token sweep for .*('refused': [1-9]|'root_readable': 0)|ent#615: .*TRACKED .gitmodules\" | sed -E 's/^.*ent#615: (remote-token sweep for )?([^ :]+).*/\2/' | sort -u | tr '\n' ' '" 2>/dev/null || true)

echo ""
echo -e "${BLUE}══════════════════════════════════════${NC}"
if [ "$BACKEND" = "200" ]; then
    echo -e "  ${GREEN}✓${NC} Backend:   healthy"
else
    echo -e "  ${RED}✗${NC} Backend:   HTTP $BACKEND"
    [ -n "$ENC_LOG" ] && echo -e "  ${RED}✗${NC} $ENC_LOG"
fi
echo -e "  Scheduler: $SCHED"
echo -e "  Version:   $VER (image: $IMG_VER)"
echo -e "  Database:  ${DB_KIND:-?}"
if [ "${SELECTOR_MISSING:-0}" = "1" ]; then
    echo -e "  ${RED}✗${NC} trinity-data/trinity.db exists but $TRINITY/.env has no DATABASE_URL line."
    echo -e "    On this hosted stack that selects the EMPTY bundled PostgreSQL (#3159). To stay on"
    echo -e "    SQLite add an empty 'DATABASE_URL=' line and re-run start.sh --hosted."
fi
if [ "${EMAIL_CLEARED:-0}" -gt 0 ] 2>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC} ent#720 cleared a duplicate sign-in email on $EMAIL_CLEARED account(s) — they must re-bind it:"
    echo -e "    docker logs trinity-backend 2>&1 | grep 'ent#720'"
fi
if [ -n "$IMG_VER" ] && [ "$IMG_VER" != "?" ] && [ "$IMG_VER" != "null" ] && [ "${IMG_VER%%+*}" != "$VER" ]; then
    echo -e "  ${YELLOW}⚠${NC} image_version differs from version — platform image is stale; re-run the build step"
fi
if [ "${HEADS:-0}" -gt 1 ] 2>/dev/null; then
    echo -e "  ${RED}✗${NC} alembic reports $HEADS heads — migrations are NOT applying (need the 0045 merge revision)"
fi
if [ "${SCRUBBED:-0}" -gt 0 ] 2>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC} Git token scrub (ent#615) rewrote remotes on $SCRUBBED agent(s)."
    echo -e "    → rotate the platform GitHub token (Settings → GitHub), then revoke the old one;"
    echo -e "      it sat in .git/config, process listings, log archives and old backups"
fi
if [ -n "${SCRUB_BAD// /}" ]; then
    echo -e "  ${RED}✗${NC} Git token scrub needs attention: ${SCRUB_BAD}"
    echo -e "    (refused / unreadable workspace / token in tracked .gitmodules — CLAUDE.md → 'Git fetch/push fails')"
fi
if [ -n "$ENC_LOG" ] && [ "$BACKEND" = "200" ]; then
    echo -e "  ${YELLOW}⚠${NC} $ENC_LOG"
    echo -e "    → rotate every credential that was entered via Settings; old backups still hold plaintext"
fi
if [ "${BASE_CHANGED:-0}" = "hosted" ]; then
    echo -e "\n  ${YELLOW}⚠${NC} Hosted: the agent base image was re-pulled. Agents adopt it on a cold stop/start"
    echo -e "    (Operating Room -> Restart All, or /rebuild-agent). Then: docker logs agent-x | grep GUARDRAILS:"
elif [ "${BASE_CHANGED:-0}" != "0" ]; then
    echo -e "\n  ${YELLOW}⚠${NC} docker/base-image/ changed in this update ($BASE_CHANGED files)."
    echo -e "    Rebuild it and let agents adopt it on a cold stop/start:"
    echo -e "      ./scripts/run.sh \"cd $TRINITY && ./scripts/deploy/build-base-image.sh\""
    echo -e "      then stop+start each agent (Operating Room -> Restart All, or /rebuild-agent)"
    echo -e "      afterwards: docker logs agent-x | grep GUARDRAILS:   (ERROR = still on the old image)"
fi

if [ "$BACKEND" = "200" ]; then
    echo -e "\n${GREEN}Update complete!${NC}"
else
    echo -e "\n${RED}Update may have issues — check logs.${NC}"
    exit 1
fi

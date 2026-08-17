#!/bin/bash
# Update Trinity - pull latest, rebuild, restart

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

run() { "$SCRIPT_DIR/run.sh" "$1"; }
HOST=${SSH_HOST:-localhost}
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}
BRANCH=${TRINITY_BRANCH:-main}

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo ""
echo -e "${BLUE}══════════════════════════════════════${NC}"
echo -e "${BLUE}   Trinity Update - ${HOST}${NC}"
echo -e "${BLUE}══════════════════════════════════════${NC}"

# 1. Backup (sqlite3 online-backup API — never a raw cp of a live DB; PG-aware)
#    Trinity v0.9.0+ also writes /data/backups/pre-migration-*.db itself at boot
#    when a migration is pending (#2216); this is the belt to that suspenders.
echo -e "\n${YELLOW}[1/4] Backing up database...${NC}"
if "$SCRIPT_DIR/backup.sh"; then
    echo -e "  ${GREEN}✓${NC} backup done"
else
    echo -e "  ${RED}✗${NC} backup failed — aborting update"
    exit 1
fi

# 2. Pull
echo -e "\n${YELLOW}[2/4] Pulling $BRANCH...${NC}"
BEFORE=$(run "cd $TRINITY && git log -1 --oneline")
run "cd $TRINITY && git pull origin $BRANCH"
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

# 3. Rebuild
echo -e "\n${YELLOW}[3/4] Rebuilding containers...${NC}"
run "cd $TRINITY && sudo docker compose -f $COMPOSE build --no-cache backend frontend mcp-server scheduler"
echo -e "  ${GREEN}✓${NC} Build complete"

# 4. Restart
echo -e "\n${YELLOW}[4/4] Starting services...${NC}"
run "cd $TRINITY && sudo docker compose -f $COMPOSE up -d"
echo "  Waiting 10s..."
sleep 10

# Verify
BACKEND=$(run "curl -s -o /dev/null -w '%{http_code}' http://localhost:${BACKEND_PORT:-8000}/health" 2>/dev/null)
SCHED=$(run "sudo docker inspect trinity-scheduler --format='{{.State.Health.Status}}'" 2>/dev/null | tr -d '\r')
# #1814: `version` = code in service, `image_version` = build it runs inside. Different = stale image.
VER_JSON=$(run "curl -s http://localhost:${BACKEND_PORT:-8000}/api/version" 2>/dev/null || true)
VER=$(echo "$VER_JSON" | jq -r '.version // "?"' 2>/dev/null || echo "?")
IMG_VER=$(echo "$VER_JSON" | jq -r '.image_version // "?"' 2>/dev/null || echo "?")

echo ""
echo -e "${BLUE}══════════════════════════════════════${NC}"
if [ "$BACKEND" = "200" ]; then
    echo -e "  ${GREEN}✓${NC} Backend:   healthy"
else
    echo -e "  ${RED}✗${NC} Backend:   HTTP $BACKEND"
fi
echo -e "  Scheduler: $SCHED"
echo -e "  Version:   $VER (image: $IMG_VER)"
if [ -n "$IMG_VER" ] && [ "$IMG_VER" != "?" ] && [ "$IMG_VER" != "null" ] && [ "${IMG_VER%%+*}" != "$VER" ]; then
    echo -e "  ${YELLOW}⚠${NC} image_version differs from version — platform image is stale; re-run the build step"
fi
if [ "${BASE_CHANGED:-0}" != "0" ]; then
    echo -e "\n  ${YELLOW}⚠${NC} docker/base-image/ changed in this update ($BASE_CHANGED files)."
    echo -e "    Rebuild it and let agents adopt it on a cold stop/start:"
    echo -e "      ./scripts/run.sh \"cd $TRINITY && ./scripts/deploy/build-base-image.sh\""
    echo -e "      then stop+start each agent (Operating Room -> Restart All, or /rebuild-agent)"
fi

if [ "$BACKEND" = "200" ]; then
    echo -e "\n${GREEN}Update complete!${NC}"
else
    echo -e "\n${RED}Update may have issues — check logs.${NC}"
    exit 1
fi

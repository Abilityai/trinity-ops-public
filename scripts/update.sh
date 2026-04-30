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

# 1. Backup
echo -e "\n${YELLOW}[1/4] Backing up database...${NC}"
BACKUP="trinity-$(date +%Y%m%d-%H%M%S).db"
run "sudo docker run --rm -v trinity_trinity-data:/data -v /tmp:/backup alpine cp /data/trinity.db /backup/$BACKUP"
echo -e "  ${GREEN}✓${NC} /tmp/$BACKUP"

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

echo ""
echo -e "${BLUE}══════════════════════════════════════${NC}"
if [ "$BACKEND" = "200" ]; then
    echo -e "  ${GREEN}✓${NC} Backend:   healthy"
else
    echo -e "  ${RED}✗${NC} Backend:   HTTP $BACKEND"
fi
echo -e "  Scheduler: $SCHED"

if [ "$BACKEND" = "200" ]; then
    echo -e "\n${GREEN}Update complete!${NC}"
else
    echo -e "\n${RED}Update may have issues — check logs.${NC}"
    exit 1
fi

#!/bin/bash
# Trinity Quick Status Check

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

HOST=${SSH_HOST:-localhost}

echo "=== Trinity Status (${HOST}) ==="
echo ""

run() { "$SCRIPT_DIR/run.sh" "$1"; }

echo "--- Containers ---"
run "sudo docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'trinity|agent'"

echo ""
echo "--- Health ---"

BACKEND=$(run "curl -s -o /dev/null -w '%{http_code}' http://localhost:${BACKEND_PORT:-8000}/health" 2>/dev/null)
FRONTEND=$(run "curl -s -o /dev/null -w '%{http_code}' http://localhost:${FRONTEND_PORT:-80}" 2>/dev/null)
REDIS=$(run "sudo docker exec trinity-redis redis-cli ping" 2>/dev/null | tr -d '\r')
SCHED=$(run "sudo docker inspect trinity-scheduler --format='{{.State.Health.Status}}'" 2>/dev/null | tr -d '\r')

echo "Backend:   HTTP $BACKEND"
echo "Frontend:  HTTP $FRONTEND"
echo "Redis:     $REDIS"
echo "Scheduler: $SCHED"

echo ""
echo "--- Version ---"
run "cd ${TRINITY_PATH:-~/trinity} && git log -1 --oneline"

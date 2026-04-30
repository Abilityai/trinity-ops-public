#!/bin/bash
# Restart Trinity services

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

run() { "$SCRIPT_DIR/run.sh" "$1"; }
HOST=${SSH_HOST:-localhost}
TRINITY=${TRINITY_PATH:-~/trinity}
COMPOSE=${COMPOSE_FILE:-docker-compose.prod.yml}

echo "Restarting Trinity on ${HOST}..."

run "cd $TRINITY && sudo docker compose -f $COMPOSE restart"

echo "Waiting 8s for services..."
sleep 8

echo ""
echo "Health check:"
BACKEND=$(run "curl -s -o /dev/null -w '%{http_code}' http://localhost:${BACKEND_PORT:-8000}/health" 2>/dev/null)
SCHED=$(run "sudo docker inspect trinity-scheduler --format='{{.State.Health.Status}}'" 2>/dev/null | tr -d '\r')
echo "Backend:   HTTP $BACKEND"
echo "Scheduler: $SCHED"
echo "Done."

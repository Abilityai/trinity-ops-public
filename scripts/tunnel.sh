#!/bin/bash
# Open SSH tunnels for local browser access to a remote Trinity instance
# Not needed when SSH_HOST is empty (local install)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

if [ -z "$SSH_HOST" ]; then
    echo "SSH_HOST not set — Trinity is local, no tunnel needed."
    echo "Access directly at http://localhost:${FRONTEND_PORT:-80}"
    exit 0
fi

SSH_OPTS="-o StrictHostKeyChecking=no -p ${SSH_PORT:-22}"
if [ -n "$SSH_KEY" ] && [ -f "${SSH_KEY/#\~/$HOME}" ]; then
    SSH_AUTH="-i ${SSH_KEY/#\~/$HOME}"
elif [ -n "$SSH_PASSWORD" ]; then
    SSH_AUTH=""  # sshpass handles it below
fi

TFRONT=${TUNNEL_FRONTEND:-13000}
TBACK=${TUNNEL_BACKEND:-18000}
TMCP=${TUNNEL_MCP:-18180}

echo "Opening SSH tunnels to $SSH_HOST..."
pkill -f "ssh.*$SSH_HOST.*-L" 2>/dev/null || true

if [ -n "$SSH_PASSWORD" ] && [ -z "$SSH_KEY" ]; then
    sshpass -p "$SSH_PASSWORD" ssh $SSH_OPTS $SSH_AUTH -N \
        -L ${TFRONT}:localhost:${FRONTEND_PORT:-80} \
        -L ${TBACK}:localhost:${BACKEND_PORT:-8000} \
        -L ${TMCP}:localhost:${MCP_PORT:-8180} \
        "$SSH_USER@$SSH_HOST" &
else
    ssh $SSH_OPTS $SSH_AUTH -N \
        -L ${TFRONT}:localhost:${FRONTEND_PORT:-80} \
        -L ${TBACK}:localhost:${BACKEND_PORT:-8000} \
        -L ${TMCP}:localhost:${MCP_PORT:-8180} \
        "$SSH_USER@$SSH_HOST" &
fi

TUNNEL_PID=$!
echo ""
echo "Tunnels open (PID $TUNNEL_PID):"
echo "  Frontend: http://localhost:${TFRONT}"
echo "  Backend:  http://localhost:${TBACK}"
echo "  MCP:      http://localhost:${TMCP}"
echo ""
echo "Ctrl+C to close"
wait $TUNNEL_PID

#!/bin/bash
# Run a command locally or on the remote Trinity instance
# Usage: ./run.sh "command"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

if [ -z "$1" ]; then
    echo "Usage: $0 \"command\""
    echo "Example: $0 \"sudo docker ps\""
    exit 1
fi

if [ -z "$SSH_HOST" ]; then
    # Local mode
    eval "$1"
else
    # Remote mode - prefer key over password
    SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${SSH_PORT:-22}"

    if [ -n "$SSH_KEY" ] && [ -f "${SSH_KEY/#\~/$HOME}" ]; then
        ssh $SSH_OPTS -i "${SSH_KEY/#\~/$HOME}" "$SSH_USER@$SSH_HOST" "$1"
    elif [ -n "$SSH_PASSWORD" ]; then
        sshpass -p "$SSH_PASSWORD" ssh $SSH_OPTS "$SSH_USER@$SSH_HOST" "$1"
    else
        ssh $SSH_OPTS "$SSH_USER@$SSH_HOST" "$1"
    fi
fi

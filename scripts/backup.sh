#!/bin/bash
# Backup Trinity SQLite database

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

run() { "$SCRIPT_DIR/run.sh" "$1"; }
HOST=${SSH_HOST:-localhost}
BACKUP="trinity-$(date +%Y%m%d-%H%M%S).db"

echo "Backing up Trinity database on ${HOST}..."
run "sudo docker run --rm -v trinity_trinity-data:/data -v /tmp:/backup alpine cp /data/trinity.db /backup/$BACKUP"
echo "Saved to /tmp/$BACKUP on ${HOST}"

#!/bin/bash
# Manual on-demand Trinity database backup → ~/backups/ on the host.
#
# NOTE: since Trinity v0.9.0 (#2216) the platform backs itself up nightly
# (03:30 UTC) into /data/backups — verified, retention-pruned, both backends.
# This script is for the extra copy you want RIGHT NOW (before something risky).
#
# SQLite: uses sqlite3's online-backup API — never a raw `cp` of a live
#         trinity.db, which can be torn or stale (journal ignored mid-write).
# PostgreSQL (bundled trinity-postgres): pg_dump -Fc (restore with pg_restore).
# Managed/external PostgreSQL: not handled here — use pg_dump against the host
#         or your provider's snapshot tooling.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.env"

run() { "$SCRIPT_DIR/run.sh" "$1"; }
HOST=${SSH_HOST:-localhost}
TRINITY=${TRINITY_PATH:-~/trinity}
TS=$(date +%Y%m%d-%H%M%S)

echo "Backing up Trinity database on ${HOST}..."
run "mkdir -p ~/backups"

# Which backend? Read DATABASE_URL from the running backend container.
DB_URL=$(run "sudo docker exec trinity-backend printenv DATABASE_URL 2>/dev/null" 2>/dev/null | tr -d '[:space:]' || true)

if [[ "$DB_URL" == postgresql://* ]]; then
    BACKUP="trinity-pg-${TS}.dump"
    if run "sudo docker ps --format '{{.Names}}' | grep -qx trinity-postgres"; then
        # POSTGRES_USER/POSTGRES_DB are resolved INSIDE the postgres container (compose sets them there)
        run "sudo docker exec trinity-postgres sh -c 'pg_dump -U \"\${POSTGRES_USER:-trinity}\" -Fc \"\${POSTGRES_DB:-trinity}\"' > ~/backups/$BACKUP"
        run "head -c 5 ~/backups/$BACKUP | grep -q PGDMP && echo '  verified: PGDMP magic OK'"
    else
        echo "Instance runs PostgreSQL at an external host (DATABASE_URL set, no bundled trinity-postgres)."
        echo "Back it up with your provider's tooling or: pg_dump -Fc '<DATABASE_URL>' > ~/backups/$BACKUP"
        exit 2
    fi
else
    BACKUP="trinity-${TS}.db"
    # Bind mount (prod) or named volume (dev)?
    MOUNT=$(run "sudo docker inspect trinity-backend --format '{{range .Mounts}}{{if eq .Destination \"/data\"}}{{.Type}}:{{.Source}}{{end}}{{end}}' 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
    case "$MOUNT" in
        bind:*)  DATA_MOUNT="${MOUNT#bind:}" ;;
        volume:*) DATA_MOUNT="trinity_trinity-data" ;;
        *)       DATA_MOUNT="trinity_trinity-data" ;;   # backend not running: assume the default volume
    esac
    run "sudo docker run --rm -v $DATA_MOUNT:/data -v ~/backups:/backup alpine sh -c 'apk add --quiet sqlite && sqlite3 /data/trinity.db \".backup /backup/$BACKUP\" && sqlite3 /backup/$BACKUP \"PRAGMA quick_check;\"'"
fi

echo "Saved to ~/backups/$BACKUP on ${HOST}"
run "ls -lh ~/backups/$BACKUP"
echo
echo "Platform's own nightly artifacts (v0.9.0+): sudo docker exec trinity-backend ls -lh /data/backups/"

#!/usr/bin/env bash
set -euo pipefail
FILE="${1:?Usage: ./scripts/restore_db.sh backups/cfhub_TIMESTAMP.sql.gz}"
gunzip -c "$FILE" | docker compose exec -T postgres psql -U "${POSTGRES_USER:-cfhub}" "${POSTGRES_DB:-cfhub}"
echo "Database restored from $FILE"

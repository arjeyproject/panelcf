#!/usr/bin/env bash
set -euo pipefail
STAMP=$(date -u +"%Y%m%dT%H%M%SZ")
mkdir -p backups
docker compose exec -T postgres pg_dump -U "${POSTGRES_USER:-cfhub}" "${POSTGRES_DB:-cfhub}" | gzip > "backups/cfhub_${STAMP}.sql.gz"
echo "Backup created: backups/cfhub_${STAMP}.sql.gz"

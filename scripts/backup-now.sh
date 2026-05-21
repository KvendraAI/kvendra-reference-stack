#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# backup-now.sh — trigger an immediate backup, bypassing the cron schedule.
#
# Runs the same pg_dump command the kvendra-backup sidecar uses, but right
# now instead of waiting for the next cron tick. Useful before a destructive
# operation (re-pull, prune, drop).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Load .env for credentials (no secrets logged).
set -a
# shellcheck disable=SC1091
. ./.env
set +a

mkdir -p "$ROOT/backups"

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUTFILE="$ROOT/backups/db-manual-$TIMESTAMP.sql.gz"

echo "backup-now: dumping $POSTGRES_DB to $OUTFILE"

docker compose exec -T kvendra-backup \
  /bin/sh -c "PGPASSWORD=$POSTGRES_PASSWORD pg_dump -h kvendra-db -U $POSTGRES_USER $POSTGRES_DB" \
  | gzip >"$OUTFILE"

SIZE=$(du -h "$OUTFILE" | awk '{print $1}')
echo "backup-now: ok. $OUTFILE ($SIZE)"

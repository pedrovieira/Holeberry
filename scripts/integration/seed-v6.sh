#!/usr/bin/env bash
# Seed the v6 integration lane with version-correct Pi-hole CLI commands.
#
# The harness passes the selected Compose project as the only argument. This
# script never handles credentials, never changes the Docker context and never
# performs its own polling or cleanup.

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  printf '%s phase=fixtures-v6 status=failed detail="seed-v6.sh requires the selected Compose project"\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  exit 1
fi

project="$1"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
compose=(docker compose --file "${script_dir}/compose.yml" --project-name "$project")

"${compose[@]}" exec -T pihole-v6 pihole allow -q \
  allowed.holeberry.test \
  xn--bcher-kva.holeberry.test
"${compose[@]}" exec -T pihole-v6 pihole deny -q denied.holeberry.test
"${compose[@]}" exec -T pihole-v6 pihole --regex -q '(^|\.)regex\.holeberry\.test$'

"${compose[@]}" exec -T pihole-v6 pihole-FTL sqlite3 /etc/pihole/gravity.db <<'SQL'
UPDATE adlist SET enabled = 0;
INSERT INTO adlist (address, enabled, comment)
VALUES ('http://fixture:8080/hosts', 1, 'holeberry integration fixture')
ON CONFLICT(address, type) DO UPDATE SET enabled = 1, comment = excluded.comment;
SQL

"${compose[@]}" exec -T pihole-v6 pihole -g

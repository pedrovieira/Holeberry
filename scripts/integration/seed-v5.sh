#!/usr/bin/env bash
# Seed the v5 integration lane with version-correct Pi-hole CLI commands.
#
# The harness passes the selected Compose project as the only argument. This
# script never handles credentials, never changes the Docker context and never
# performs its own polling or cleanup.

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  printf '%s phase=fixtures-v5 status=failed detail="seed-v5.sh requires the selected Compose project"\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  exit 1
fi

project="$1"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
compose=(docker compose --file "${script_dir}/compose.yml" --project-name "$project")

"${compose[@]}" exec -T pihole-v5 pihole -w -q \
  allowed.holeberry.test \
  xn--bcher-kva.holeberry.test
"${compose[@]}" exec -T pihole-v5 pihole -b -q denied.holeberry.test
"${compose[@]}" exec -T pihole-v5 pihole --regex -q '(^|\.)regex\.holeberry\.test$'

# Keep query metadata numeric: FTL otherwise renders loopback clients as a name.
"${compose[@]}" exec -T pihole-v5 sh -c '
  touch /etc/pihole/pihole-FTL.conf
  sed -i "/^RESOLVE_IPV4=/d; /^RESOLVE_IPV6=/d" /etc/pihole/pihole-FTL.conf
  printf "\nRESOLVE_IPV4=false\nRESOLVE_IPV6=false\n" >> /etc/pihole/pihole-FTL.conf
'

"${compose[@]}" exec -T pihole-v5 sqlite3 /etc/pihole/gravity.db <<'SQL'
UPDATE adlist SET enabled = 0;
DELETE FROM adlist WHERE address = 'http://fixture:8080/hosts';
INSERT INTO adlist (address, enabled, comment)
VALUES ('http://fixture:8080/hosts', 1, 'holeberry integration fixture');
SQL

"${compose[@]}" exec -T pihole-v5 pihole -g
"${compose[@]}" exec -T pihole-v5 pihole restartdns

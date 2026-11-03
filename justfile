# Project test commands. Run `just` to list them.
set shell := ["bash", "-euo", "pipefail", "-c"]

integration := "Packages/HoleberryCore/Tests/HoleberryCoreIntegrationTests"
compose := "docker compose --file " + integration + "/Containers/compose.yml"

default:
    @just --list

# Run core unit tests without requiring Docker.
test:
    swift test --package-path Packages/HoleberryCore --filter HoleberryCoreTests

# Start all Pi-holes, wait for HTTP, and seed the local gravity fixture.
integration-up:
    #!/usr/bin/env bash
    set -euo pipefail

    if ! command -v docker >/dev/null 2>&1; then
      echo "The Docker CLI is required; install it and configure a Docker-compatible container runtime" >&2
      exit 1
    fi

    {{ compose }} up -d

    wait_for_http() {
      local base="$1"
      for _ in $(seq 1 180); do
        if curl -s --connect-timeout 2 --max-time 5 -o /dev/null "$base/admin/api.php?version"; then
          return 0
        fi
        sleep 1
      done
      echo "Pi-hole did not answer at $base" >&2
      return 1
    }

    wait_for_http http://127.0.0.1:18085
    wait_for_http http://127.0.0.1:18086
    wait_for_http http://127.0.0.1:18087

    # Replace the default blocklists with the local fixture on both versions.
    {{ compose }} exec -T pihole-v5 sqlite3 /etc/pihole/gravity.db <<'SQL'
    UPDATE adlist SET enabled = 0;
    DELETE FROM adlist WHERE address = 'http://fixture:8080/hosts';
    INSERT INTO adlist (address, enabled, comment)
    VALUES ('http://fixture:8080/hosts', 1, 'holeberry integration fixture');
    SQL
    {{ compose }} exec -T pihole-v5 pihole -g
    {{ compose }} exec -T pihole-v5 pihole restartdns

    seed_v6_gravity() {
      local service="$1"
      {{ compose }} exec -T "$service" pihole-FTL sqlite3 /etc/pihole/gravity.db <<'SQL'
    UPDATE adlist SET enabled = 0;
    INSERT INTO adlist (address, enabled, comment)
    VALUES ('http://fixture:8080/hosts', 1, 'holeberry integration fixture')
    ON CONFLICT(address, type) DO UPDATE SET enabled = 1, comment = excluded.comment;
    SQL
      {{ compose }} exec -T "$service" pihole -g
    }

    seed_v6_gravity pihole-v6
    seed_v6_gravity pihole-v6-open

    cat <<'EOF'
    Pi-hole integration containers are ready.
      v5:      http://127.0.0.1:18085
      v6:      http://127.0.0.1:18086 (password: holeberry-integration)
      v6-open: http://127.0.0.1:18087 (password: none)
    Run the suite:
      just integration-test
    Stop and remove the containers and volumes:
      just integration-down
    EOF

# Run the 17 opt-in cases against the running containers.
integration-test:
    TZ=UTC HOLEBERRY_INTEGRATION=1 swift test --package-path Packages/HoleberryCore --filter HoleberryCoreIntegrationTests

# Remove this integration project's containers, network, and volumes.
integration-down:
    {{ compose }} down --volumes --remove-orphans

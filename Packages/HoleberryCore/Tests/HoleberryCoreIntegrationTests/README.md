# Pi-hole integration tests

End-to-end tests for the production service layer against disposable Pi-hole v5,
v6 and password-less v6 containers. The container suite runs only when
`HOLEBERRY_INTEGRATION=1` is set, regardless of Docker availability. A plain
`swift test` compiles it and skips the container scenarios; support-helper tests
still run without Docker.

## Prerequisites

- macOS 14+ with a Swift 6 toolchain.
- Docker or a Docker-compatible container runtime, with the Docker CLI and
  Docker Compose installed and configured to connect to it.
- [just](https://just.systems/), installed with `brew install just`.
- About 2.5 GB of disk for the pinned Pi-hole images.

The containers are disposable. The v5 and v6 lanes use the public fixture
password `holeberry-integration`; the third v6 lane has no password. Do not
reuse their volumes for a real Pi-hole.

## Commands

```bash
# Run from the repository root
# List the available commands
just

# Start all three Pi-holes, wait for HTTP, build gravity from the local fixture
just integration-up

# Run the 17 opt-in cases (TZ=UTC keeps v5 timestamps aligned with the containers)
just integration-test

# Remove the containers, network and volumes
just integration-down
```

The single `justfile` lives at the repository root. Recipes always run from that
directory, including when invoked from a subdirectory. `just test` runs only core
unit tests and does not require Docker.

`just integration-test` is equivalent to the following command from the repository root:

```bash
TZ=UTC HOLEBERRY_INTEGRATION=1 swift test \
  --package-path Packages/HoleberryCore \
  --filter HoleberryCoreIntegrationTests
```

Compose publishes fixed URLs: `http://127.0.0.1:18085` (v5),
`http://127.0.0.1:18086` (v6) and `http://127.0.0.1:18087` (password-less v6).
These ports must be free before running `just integration-up`.

`HOLEBERRY_V5_URL`, `HOLEBERRY_V6_URL` and `HOLEBERRY_V6_OPEN_URL` override only
the Swift HTTP endpoints; they do not change Compose's published ports or
`just integration-up`'s readiness checks. Use them only with manual forwarding to the same
Compose containers, because CLI and DNS checks still run inside those containers.
The v5 API token is read from the container's `setupVars.conf`; the v6 password
is the fixture password in `Containers/compose.yml`; the password-less lane uses an empty
credential.

`ContainerCLI` resolves `docker` through `PATH` plus `/opt/homebrew/bin`,
`/usr/local/bin`, `~/.orbstack/bin` and `~/.docker/bin`, so Xcode test runs with
a minimal environment can still find it.

## What the tests cover

The five shared scenarios run against all three targets. Logout runs against
authenticated and password-less v6, for 17 cases in total.

| Scenario | Prerequisites | Assertions |
| --- | --- | --- |
| `detection` | `dig example.com` for query-log data | Version detection, enabled blocking, positive summary count, wrong credential cannot add a domain; the password-less lane asserts `isPasswordless` instead |
| `logout` (v6 only) | CLI: `pihole api auth/sessions` | Login creates one app session; logout removes it and preserves existing sessions. Password-less v6 creates no session. The CLI's own observer session is excluded. |
| `domains` | CLI: allow, deny, IDN and regex entries | Exact lists contain the seeded entries; regex stays out of them; add with comment, duplicate add, delete twice; the CLI lists agree after add and delete |
| `blocking` | CLI deny entries | DNS oracle: a denied domain resolves to `0.0.0.0` while blocking is enabled, stops doing so while disabled, and does so again after enable and after a 10-second timed disable |
| `managed unblock` | None | A 10-second owned allowance has the `via holeberryapp.com / ` comment and a local record; the CLI list agrees (including the comment on v6); both disappear; a pre-existing allowance keeps its comment |
| `query and gravity` | Fixture adlist from `just integration-up`; `dig gravity.holeberry.test` | Summary counts, gravity-blocked domain in the query log, v6 matching and excluded client filters, v5 reports `.unsupported`, v6 gravity update restores a removed fixture row and DNS blocking |

The split is deliberate:

- **Seed** through the Pi-hole CLI (`pihole -w`, `pihole -b`, `pihole deny`,
  `pihole --regex`, `dig`).
- **Act** through the production factory and service, with a real ephemeral
  `URLSession`.
- **Assert** through the client for its read contract, and independently through
  DNS or the CLI list where correlated failures would otherwise hide a bug.

## How the fixtures work

`Containers/compose.yml` runs three Pi-holes plus a `python:3.13-alpine` server that serves
`Containers/fixtures/hosts`, which contains `0.0.0.0 gravity.holeberry.test`. `just integration-up`
registers that URL as the only enabled adlist and rebuilds gravity on every
lane, so the gravity test does not depend on public blocklists. DNS queries are
generated inside the containers; no DNS port is published.

To prove that the v6 API actually rebuilds gravity, the test removes only
`gravity.holeberry.test` from the compiled `gravity` table and verifies its
absence through SQLite. The source adlist stays intact. After the API update,
the row must exist again and DNS must block the domain. A no-op update fails
even if DNS has a cached blocked answer. If the check fails, the test attempts
a CLI gravity rebuild to repair the shared fixture before reporting the failure.

The password-less lane uses `FTLCONF_webserver_api_password: ""`; an empty
string is a real empty password, while omitting the key means unset. Its
`/api/auth` response reports `"message":"no password set"`.

All containers, the network and the three volumes use the fixed Compose project
`holeberry-integration`. `just integration-down` removes only that project.

## Limitations

- v5 uses a static API token and has no server-side API session to revoke, so the logout scenario runs on v6 only.
- The suite is serialized: blocking state, lists and gravity are shared server
  state.
- v5's API ignores the `client` filter in `getRecentBlocked`, and the production
  service does not post-filter. The client-filter assertions therefore run on
  v6 only.
- A deny entry is not enough for `getRecentBlocked` on v6: the service asks for
  `status=GRAVITY`, so the gravity fixture remains necessary for that assertion.
- CI does not run this suite yet. The core package imports AppKit, Carbon and
  Keychain, so it cannot build on a Linux runner with GitHub service
  containers.
- `just integration-up` pulls new images only when the pinned tags are absent. Update the tags in
  `Containers/compose.yml` deliberately.

This technical note is English-only; translations are pending.

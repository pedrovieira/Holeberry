# Pi-hole integration test proposal

Start with Docker Compose on the laptop, then run the same harness in a separate Intel macOS CI job with Colima.

Research date: 2026-10-25. This is a proposal, not an installed test harness. The Compose and workflow examples below describe the implementation to add.

## What fits Holeberry

Run Swift Testing on macOS against two disposable official Pi-hole containers. Seed the containers through the Pi-hole CLI, then exercise Holeberry through its production service factory and a real `URLSession`.

No application architecture change is needed for this first version:

- [`HTTPRequestable`](../Packages/HoleberryCore/Sources/HoleberryCore/Networking/HTTPRequestable.swift) already has a `URLSession` implementation.
- [`ConcretePiholeServiceFactory`](../Packages/HoleberryCore/Sources/HoleberryCore/Services/Pihole/PiholeServiceFactory.swift) builds v5/v6 services with the temporary-unblock decorator. Use this factory for integration tests too.
- [`PiholeVersionDetector`](../Packages/HoleberryCore/Sources/HoleberryCore/Services/Pihole/PiholeVersionDetector.swift) can probe each real server before the tests construct its service.
- [`HoleberryCore`](../Packages/HoleberryCore/Package.swift) requires macOS 14 and Swift 6. It also imports AppKit, Carbon, Combine, OSLog and Keychain dependencies. A Linux runner cannot build the current package unchanged.
- [Current CI](../.github/workflows/ci.yml) runs on `xcode-27`. Keep those unit-test and lint jobs; add an independent integration job.

## Image selection

| Test lane | Image | Policy |
| --- | --- | --- |
| Final v5 | `pihole/pihole:2024.07.0` | Fixed compatibility baseline; this is the last v5 Docker release. |
| Current v6 | `pihole/pihole:2026.10.0` | Current release at research time; pin its digest after the first successful run. |
| Moving v6 | `pihole/pihole:latest` | Optional scheduled/manual job to detect upstream changes early. |

Pi-hole's [migration documentation](https://docs.pi-hole.net/docker/upgrading/v5-v6/) identifies the final v5 image. The current v6 image is documented in the [2026.10.0 release](https://github.com/pi-hole/docker-pi-hole/releases/tag/2026.10.0). Docker tags are separate from the versions of Core, Web and FTL inside the image.

Recommendation: use pinned v5 and v6 images for PR checks, and pull `latest` in a scheduled v6 compatibility check. If every run must cover the newest v6, use `latest` for that lane and accept that an upstream release can change the result without a Holeberry change. Record the resolved digest, platform, and `pihole version` output with each run.

## Local environment

Use Docker Desktop or Colima with Docker Compose. Both Pi-holes use a private Compose network. Publish only their web ports to loopback, at `http://127.0.0.1:18085` and `http://127.0.0.1:18086`. Do not set either container as the laptop's DNS server. Generate DNS traffic inside the containers, so port 53 does not need to be published.

Minimal environment sketch, before adding readiness and fixture initialization:

```yaml
services:
  pihole-v5:
    image: pihole/pihole:2024.07.0
    environment:
      TZ: UTC
      WEBPASSWORD: holeberry-test-only
      DNSMASQ_LISTENING: all
    ports:
      - "127.0.0.1:18085:80"

  pihole-v6:
    image: ${PIHOLE_V6_IMAGE:-pihole/pihole:2026.10.0}
    environment:
      TZ: UTC
      FTLCONF_webserver_api_password: holeberry-test-only
      FTLCONF_dns_listeningMode: all
    ports:
      - "127.0.0.1:18086:80"
```

The environment-variable names changed between versions; see [Pi-hole's migration table](https://docs.pi-hole.net/docker/upgrading/v5-v6/). The password above is a public fixture credential for disposable containers, never a real server credential. Do not share persistent `/etc/pihole` storage between versions or test runs.

Use a Compose project name unique to the run or worktree. Fixed ports are useful for manual app testing; automated runs should accept configurable ports, or discover dynamically published loopback ports with `docker compose port`. This allows two worktrees to run at the same time. [Docker documents published ports and loopback bindings](https://docs.docker.com/engine/network/port-publishing/).

Proposed entry points:

| Command to implement | Result |
| --- | --- |
| `scripts/integration/up` | Start fresh containers, wait for readiness, seed fixtures, print both URLs. Leave them running for app testing. |
| `scripts/integration/test` | Create an isolated environment, run the Swift integration suite, save diagnostics, remove its containers and storage on exit. |
| `scripts/integration/down` | Remove only the selected integration project's resources. |

The cleanup contract must be explicit: only disposable resources created by this harness. No global Docker pruning or changes to existing Pi-hole containers.

## Seed data through the CLI

Keep fixtures independent of Holeberry's write methods. For exact allow/deny entries, invoke the CLI with `docker compose exec -T`:

```sh
docker compose exec -T pihole-v5 pihole -w allowed.holeberry.test
docker compose exec -T pihole-v5 pihole -b denied.holeberry.test

docker compose exec -T pihole-v6 pihole allow allowed.holeberry.test
docker compose exec -T pihole-v6 pihole deny denied.holeberry.test
```

The CLI also supports regex entries and gravity rebuilds. Use version-specific setup helpers rather than assuming the same command spelling works on both generations. The commands above are defined in the [v5 controller](https://raw.githubusercontent.com/pi-hole/pi-hole/v5.18.3/pihole) and [v6 controller](https://raw.githubusercontent.com/pi-hole/pi-hole/v6.5/pihole).

Verify the seeded entries after each command. The v6 CLI uses its own API client internally, and its controller exits successfully after invoking the list script, so an exit code alone is insufficient. It still exercises a different client from Holeberry. See the [v6 list implementation](https://raw.githubusercontent.com/pi-hole/pi-hole/v6.5/advanced/Scripts/list.sh). Keep mutable test settings, such as blocking state, out of v6 environment variables: these settings become read-only, as explained in [Docker configuration](https://docs.pi-hole.net/docker/configuration/).

### Gravity and query history need another fixture

Adding a deny entry does not create query history. Send actual DNS queries, for example `dig @127.0.0.1 denied.holeberry.test A`, inside the relevant Pi-hole container. Use unique names or a flushed cache when generating repeat queries, and wait for FTL to expose them through its API.

There is a specific Holeberry constraint: [`PiholeV6Service.getRecentBlocked`](../Packages/HoleberryCore/Sources/HoleberryCore/Services/Pihole/PiholeV6Service.swift) requests `status=GRAVITY`. An exact deny fixture has a different block reason and cannot prove that method returns blocked domains. The v5 service accepts a wider set of block reasons.

For the cross-version query test:

1. Serve a checked-in hosts file from a small fixture HTTP service on the Compose network. Include `0.0.0.0 gravity.holeberry.test`. Use a pinned fixture-server image.
2. Configure that URL as the only adlist in a fresh Pi-hole environment, then build gravity with `pihole -g`.
3. Send a DNS query to `gravity.holeberry.test` inside each Pi-hole container. Capture the query window and observed client address.
4. Poll Holeberry's `getRecentBlocked` until the fixture appears, with a bounded deadline. Assert its domain and client filtering, not a fixed total query count.

There is no general adlist-registration CLI shared by v5 and v6. One option is first-boot initialization through `/etc/pihole/adlists.list` while `gravity.db` is absent. The [v6 startup helper](https://raw.githubusercontent.com/pi-hole/docker-pi-hole/2026.10.0/src/bash_functions.sh) preserves that file and runs gravity; the [gravity script](https://raw.githubusercontent.com/pi-hole/pi-hole/v6.5/gravity.sh) imports it. This remains an implementation check, especially on v5. The fallback is a narrow fixture-only step using `pihole-FTL sqlite3 /etc/pihole/gravity.db` to disable default adlists and register the fixture URL, followed by `pihole -g`. Keep that setup isolated from the tests and use the [documented database schema](https://docs.pi-hole.net/database/gravity/). Domain seeding, gravity rebuilds and DNS traffic can all stay in the CLI.

Keep the fixture HTTP service ready before Pi-hole's first initialization. Copying the file into a stopped container or a prepared disposable volume avoids a bind mount to a file that first-boot migration may move. A local hosts fixture removes dependence on public blocklist content; it does not prove the whole startup is offline. Pi-hole's setup/gravity scripts can still perform external DNS checks.

### Authentication is different

| Version | Fixture setup | Credential passed to Holeberry |
| --- | --- | --- |
| v5 | `WEBPASSWORD` sets the web password. | Read `WEBPASSWORD` from the initialized container's `/etc/pihole/setupVars.conf`; that stored value is the legacy API token. Do not pass the plaintext web password as the token. |
| v6 | `FTLCONF_webserver_api_password` sets the password. | Pass that password to the normal `AuthV6SessionProvider`; it creates and refreshes the API session. |

Pass the v5 token into the test process without printing it. Keep a separate real HTTP session per service because logout invalidates its session. Log out successful v6 sessions during cleanup; repeated leaked sessions can exhaust the server's session limit.

Sources: [v5 password storage](https://raw.githubusercontent.com/pi-hole/pi-hole/v5.18.3/advanced/Scripts/webpage.sh), [v5 API authentication](https://raw.githubusercontent.com/pi-hole/web/v5.21/api.php), [v6 session authentication](https://docs.pi-hole.net/api/auth/).

## First integration suite

Add `Tests/HoleberryCoreIntegrationTests` as a separate SwiftPM test target. Build services using `ConcretePiholeServiceFactory(authSessionFactory: ConcreteAuthSessionFactory())`, a real ephemeral `URLSession`, a fresh server UUID, and an isolated defaults suite. No app launch, Keychain entry or production preferences are needed.

| Scenario | Assertions against each real server |
| --- | --- |
| Detection and authentication | Detect the correct major version, log in, read blocking status and summary; wrong credentials fail on an authenticated operation. v5 `login()` itself is a no-op. |
| Domain lifecycle | Read CLI-seeded entries, add an entry with a comment, read it back, add it again, verify `.alreadyPresent` and preserved comment, delete it twice, verify absence. Include an IDN and regex fixture to check exact-list filtering. |
| Blocking controls | Disable, observe disabled status, enable, observe enabled status; test short timed disable and eventual re-enable separately. Restore enabled state on failure. |
| Managed unblocking | Add a short temporary allowance through the factory-created service, verify the ownership comment and local record, then poll for real cleanup. Verify a pre-existing allowance survives. |
| DNS query path and gravity | Generate a gravity-blocked query, read it and a nonempty summary through Holeberry; verify v6 API gravity update against the fixture list and v5's explicit unsupported result. |

Opt in with `HOLEBERRY_INTEGRATION=1` using a suite-level enabled condition. Plain `swift test` must continue to work with no Docker daemon. When the flag is present, require both URLs and credentials and fail if either server is missing; never turn a broken CI environment into a successful skip. Select the suite explicitly with `swift test --filter HoleberryCoreIntegrationTests` and ensure it actually ran.

Serialize the integration suite because blocking state, gravity and domain lists are shared server state. `@MainActor` alone does not prevent async tests interleaving. Swift Testing's [serialization trait](https://raw.githubusercontent.com/swiftlang/swift-testing/main/Sources/Testing/Traits/ParallelizationTrait.swift) only orders tests within its scope, so put all shared-container tests under one serialized parent suite. [Conditional traits](https://raw.githubusercontent.com/swiftlang/swift-testing/main/Sources/Testing/Traits/ConditionTrait.swift) support the opt-in gate.

Use wall-clock deadlines for external readiness and expiry: for example, 120 seconds for startup, 15 seconds for query visibility, and a 3-second temporary allowance with a 15-second cleanup deadline. These are proposed limits to tune from measured runs. The unit-test helper `waitUntil` only yields actor turns; it is not an external-service readiness wait. Keep retries around observing eventual state, not around failed assertions that could hide a regression.

## Readiness and failure evidence

Compose considers a running process different from a ready service; [Docker documents healthchecks and readiness ordering](https://docs.docker.com/compose/how-tos/startup-order/). The harness should verify the whole path:

1. FTL responds to a DNS query and the configured HTTP endpoint responds.
2. Authenticated status/list requests return the expected data, not just HTTP 200. Legacy v5 can return an empty object for unauthorized requests.
3. Fixture entries and the gravity-blocked DNS response are visible before starting Swift tests.

On failure, collect container logs, component versions, resolved image digests, test output, and redacted HTTP responses before cleanup. Avoid persisting API tokens, v6 SIDs, auth response bodies or URLs containing the v5 `auth` query parameter.

## CI approach

**Recommended first CI implementation: a separate `macos-15-intel` job with Colima.** Colima's own [macOS integration workflow](https://raw.githubusercontent.com/abiosoft/colima/main/.github/workflows/macos-integration.yml) selects this runner, and its [Docker workflow](https://raw.githubusercontent.com/abiosoft/colima/main/.github/workflows/_docker.yml) starts Colima and runs real containers. This is upstream evidence for the approach; Holeberry still needs a successful CI run before treating it as proven here.

The Core test target needs Swift 6 and macOS 14+, rather than the app target's macOS 27 SDK. Verify the selected Intel runner's Swift version and compile the package there first. The existing `xcode-27` app checks can stay as they are.

Workflow sketch, dependent on the proposed scripts:

```yaml
integration:
  runs-on: macos-15-intel
  timeout-minutes: 20
  steps:
    - uses: actions/checkout@v7
    - name: Check Swift
      run: swift --version
    - name: Install container tools
      run: brew install colima docker docker-compose
    - name: Start Docker
      run: colima start --runtime docker --cpus 2 --memory 4
    - name: Run integration flow
      run: scripts/integration/test
    # Add always-run diagnostic upload and Colima stop steps.
    # The harness owns cleanup of its Compose project on success/failure.
```

Confirm `docker compose version` during setup. Homebrew's Compose package may need its CLI-plugin directory configured; follow [Colima's installation instructions](https://colima.run/docs/installation/). Use loopback HTTP forwarding and generate DNS inside the containers to avoid host-to-VM UDP routing requirements.

Do not put `services:` directly on the current macOS job: [GitHub service containers require Linux](https://docs.github.com/en/actions/tutorials/use-containerized-services/use-docker-service-containers). GitHub also documents [no nested virtualization on its hosted arm64 macOS runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#limitations-for-arm64-macos-runners), including the M1 `xcode-27` lane. Installing Docker tooling there alone is insufficient.

Alternatives if the Intel job fails or becomes unavailable:

| Option | Trade-off |
| --- | --- |
| Dedicated macOS runner with Docker/Colima | Reuses the local harness without changing the package. Requires runner maintenance and isolation for untrusted PRs. |
| Hosted macOS tests against an isolated remote Linux Docker host | Preserves the current package, but needs container lifecycle management, an authenticated tunnel and per-run allocation. A separate Linux job does not automatically share its localhost with macOS. |
| Extract a portable Pi-hole networking target, then test on Linux | Enables standard GitHub service containers. Requires a deliberate package boundary for Apple-only code and dependencies; broader than the first integration-test task. |

Recommendation: prove the Intel job before taking on remote infrastructure or a portability refactor.

## Implementation order and effort

1. Add Compose, version-specific CLI seed scripts and an `up` command. Prove detection/authentication manually on both images. Estimate: 3–4 engineering hours with a working Docker runtime.
2. Add the opt-in Swift Testing target and the five scenarios above, including local gravity fixtures and cleanup. Estimate: 4–8 engineering hours, depending on first-boot and FTL timing differences.
3. Add the Intel/Colima CI job, diagnostics and pinned image digests. Measure startup time before making it required. Estimate: 2–4 engineering hours if the runner supports the package toolchain without changes.

These are implementation estimates, not measured execution times. Initial CI timeout: 20 minutes; reduce it after successful runs. Open the project's required issue before substantial implementation.

## Validation performed

Inspected Holeberry's package, real services, factory/decorator, authentication, current tests and CI. Checked upstream documentation and source for the Docker/CLI and CI paths. Validated the minimal Compose example with the installed Compose parser.

The laptop has Docker and Colima CLIs, but no active Docker daemon: the default socket is absent and `colima status` reports stopped. No containers were started, no live Pi-hole requests were made, and no CI run was performed. First-boot fixture import, native image platforms, timing limits, and the Intel toolchain remain explicit implementation checks.

This technical research note is English-only; translation is pending. README files are unchanged.

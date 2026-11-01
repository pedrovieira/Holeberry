# Integration test dependency lifecycle research

Checked 2026-11-01. This is a small comparison of established open-source
projects, not a survey of which approach is most common. Sources are the
projects' own current default-branch code and documentation; links can change.
No example was executed locally.

## Swift examples: PostgresNIO and Fluent PostgreSQL Driver

Vapor's PostgresNIO CI uses GitHub Actions PostgreSQL service containers on
Linux, then runs `swift test --filter ^IntegrationTests`. Its macOS workflow
instead installs PostgreSQL through Homebrew, initializes the database, starts
it with `pg_ctl ... --wait`, and runs the tests. The repository also has a
Compose file for local PostgreSQL instances.
[Source: test workflow](https://github.com/vapor/postgres-nio/blob/main/.github/workflows/test.yml),
[source: docker-compose.yml](https://github.com/vapor/postgres-nio/blob/main/docker-compose.yml)

Vapor's Fluent PostgreSQL Driver uses the same broad CI split: PostgreSQL
service containers on Linux; Homebrew, `initdb`, `pg_ctl`, and `createdb` on
macOS. Dependency startup lives in CI configuration rather than in Swift test
setup code.
[Source: test workflow](https://github.com/vapor/fluent-postgres-driver/blob/main/.github/workflows/test.yml)

**Relevant pattern:** established Swift database clients use external dependency
provisioning. CI service containers, Compose, and native database processes can
all support the same Swift tests.

## redis-py: Python Invoke tasks over Docker Compose

The Python Redis client exposes named development commands through Invoke.
`devenv` first calls `clean`, then runs
`docker compose --profile <endpoints> up -d --build`. `clean` runs
`docker compose --profile all rm -s -f`. The `tests` task dispatches the
fixed-client, standalone, and cluster pytest suites.
[Source: tasks.py](https://github.com/redis/redis-py/blob/master/tasks.py)

The contributor guide documents `invoke devenv`, `invoke tests`,
`invoke clean`, and `invoke -l` for command discovery. Its development mode
deliberately leaves dependencies running. The guide also says each test run
starts/stops Docker; the inspected `tests` task itself only dispatches pytest,
so that statement should not be treated as proof of automatic lifecycle ownership.
[Source: CONTRIBUTING.md](https://github.com/redis/redis-py/blob/master/CONTRIBUTING.md)

Readiness can live in Compose: its second-cluster service checks
`cluster_state:ok`, and other services use Redis PING or an HTTP health endpoint.
The second-cluster comment explicitly explains readiness for `compose up --wait`;
the inspected Invoke `devenv` command itself does not pass `--wait`.
[Source: docker-compose.yml](https://github.com/redis/redis-py/blob/master/docker-compose.yml)

**Relevant pattern:** a discoverable task interface can replace loose scripts
while preserving Compose and an explicit development environment.

## Spring PetClinic: both test-managed Testcontainers and Compose

The MySQL integration test declares a static `MySQLContainer` with `@Container`,
`@Testcontainers(disabledWithoutDocker = true)`, and `@ServiceConnection`.
The lifecycle is delegated to Testcontainers/JUnit instead of custom up/down
scripts. The test source does not define a custom wait strategy.
[Source: MySqlIntegrationTests.java](https://github.com/spring-projects/spring-petclinic/blob/main/src/test/java/org/springframework/samples/petclinic/MySqlIntegrationTests.java)

The PostgreSQL integration test takes another approach: it enables Spring Boot's
Docker Compose support during tests and passes startup arguments selecting
PostgreSQL with `--force-recreate` and `--renew-anon-volumes`. It checks Docker
availability before tests. The project's README explicitly describes this split
between MySQL Testcontainers and PostgreSQL Compose.
[Source: PostgresIntegrationTests.java](https://github.com/spring-projects/spring-petclinic/blob/main/src/test/java/org/springframework/samples/petclinic/PostgresIntegrationTests.java),
[source: README](https://github.com/spring-projects/spring-petclinic/blob/main/README.md#test-applications)

**Relevant pattern:** automatic test lifecycle does not require abandoning
Compose; a test framework can own its startup/shutdown.

## OpenTelemetry Collector Contrib: Go Testcontainers with explicit readiness

Its PostgreSQL receiver integration tests construct `testcontainers.ContainerRequest`
values, copy SQL fixtures into PostgreSQL's initialization directory, expose
the database port, start containers, and register cleanup with
`testcontainers.CleanupContainer`. Connection configuration uses the mapped
host port instead of assuming a fixed published port.
[Source: integration_test.go](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/receiver/postgresqlreceiver/integration_test.go)

The readiness strategy waits for the database-ready log message twice, with
a two-minute startup timeout. The accompanying comment explains why: the
Postgres image temporarily starts a database to run initialization scripts,
so an open port alone is insufficient. This distinguishes dependency
readiness from merely starting a container.
[Source: readiness strategy](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/receiver/postgresqlreceiver/integration_test.go#L155-L163)

**Relevant pattern:** test code can own images, fixtures, real readiness checks,
connection information, and cleanup together. This is established evidence for
test-managed containers in Go; it does not establish equivalent Swift library
maturity.

## Implications for Holeberry

Retaining Compose is a reasonable default: it already describes the three
Pi-hole lanes and their shared fixture server. The choice of who owns the
lifecycle is separate from the choice of implementation language. Explicit
up/down commands, a named task runner, or test-managed setup are all supported
by the examples above; they optimize different contributor workflows.

Recommendation (inference): keep Compose and decide whether contributors need
one self-contained test command or a persistent environment they can inspect.
Only then choose shell, Swift subprocess code, or a task runner to expose that
workflow. These examples do not justify introducing another language or a
container library solely to replace the existing small scripts.

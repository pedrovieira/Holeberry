# Configurable query statistics widget

Status: implemented after user approval on 2026-11-22; final review completed,
with manual widget-host checks still pending.

## Intent

Let a person show statistics for one saved Pi-hole server using the existing
Holeberry widget. The user wants the same statistics and layout, with a choice
of which server supplies the data. No additional metrics are needed.

## Approaches

The user accepted making the existing widget configurable.

- **Chosen: one configurable widget.** A Server picker selects All servers or one
  saved server. This keeps one gallery item and reuses the existing scoped data
  path and view.
- **Alternative: a second widget for individual servers.** This makes the two
  scopes separate gallery items, but still needs a server picker and duplicates
  the same widget purpose. It adds no needed capability.

## User behavior

1. The widget gallery shows one small widget named **Query statistics**, with the
   description **Block rate and query totals for all Pi-hole servers or one selected server.**
2. Edit Widget exposes one setting named **Server**. Its choices are **All
   servers**, followed by the app's saved servers in their saved order. All
   servers is the default, including when an old widget has no configuration.
3. A selection belongs to that widget instance. A person can place an aggregate
   widget and individual server widgets beside each other without changing the
   app's selection or other widgets.
4. The aggregate choice keeps its current counts, status text, and layout.
   An individual choice shows only that server's block rate, Queries, Blocked,
   24h marker, availability dot, and update age, with the same formatting and
   refresh policy as today.
5. The individual widget uses the server's current display name in the existing
   header. Renaming a server updates its name on refresh without losing the
   selection. Long names stay within the small widget's bounds.

## Identity and display

Persist selection by server UUID, never by label, URL, or position in the list.
Use a nonblank server label for display; otherwise use the URL hostname, then
the saved URL if no hostname can be parsed. If labels are duplicated, show a
hostname or URL subtitle in the picker so people can distinguish the servers.

The selected server name remains visible when its statistics are unavailable.
Accessibility includes the server name, availability state, and statistics or
guidance, without claiming that a failed or expired check is healthy.

The header change, naming fallback, and picker subtitles are implementation
proposals that support identifying the selected server. The user requirement
is unchanged statistics for an individual server.

## Empty and failure states

- Shared storage not ready: keep **Open Holeberry to finish setup**. Setup takes
  precedence over a missing-server message.
- All servers selected, no saved servers: keep **Add a server in Holeberry**.
- A selected UUID no longer exists: show **Server removed** and **Edit widget to
  choose another server**. Do not show another server's numbers or silently
  switch to All servers. A new server at the same URL has a different identity.
- A saved server cannot be reached or authenticated: keep the existing
  statistics-unavailable behavior, scoped to that server. Other servers must
  not contribute counts or determine its availability.
- An old, absent configuration means All servers. An explicit stale selection
  remains a missing-server selection; entity resolution must preserve this
  distinction rather than replacing it with the default.

Widget clicks continue to open Holeberry settings. Selecting another server is
done through the system's Edit Widget interface.

## Implementation boundaries

Use WidgetKit AppIntentConfiguration, a WidgetConfigurationIntent, an AppEntity
query for saved server choices, and an AppIntentTimelineProvider. These support
the app's macOS 14 minimum. The builder may choose the simplest explicit
representation of the All servers choice, provided absent configuration and
removed-server behavior remain distinct and covered by tests.

Retain the persisted widget kind **AllServersWidget**, extension identity, and
supported systemSmall family. Do not register another widget kind. Retaining
the identity and default is required; actual upgrade behavior must also be
checked in the system widget host before being reported as verified.

Reuse ServerScope.all / ServerScope.server(UUID), QueryStatisticsSnapshot, the
existing provider's loading and timeline logic, and the existing SwiftUI view.
Do not add a parallel network stack or duplicate aggregation logic. Preserve
shared-storage readiness checks, connection-change validation, on-demand
execution, logout cleanup, credential privacy, and service decorators.

App Intents and WidgetKit adapters belong in the widget target. Any reusable
storage or business logic belongs in HoleberryCore, uses typed Defaults keys,
and follows the existing protocol and mock conventions. Listing choices reads
only server metadata and does not need a network request or Keychain prompt.

Preserve app-target previews and the widget test target when adding sources.
Change project.yml and regenerate with XcodeGen when needed; never hand-edit
the generated project. Do not change the refresh interval or expiry policy.

## Acceptance and validation

Automated tests should exercise observable behavior through existing snapshot,
entry, and injected persistence seams where possible. Cover aggregate defaults,
selecting each of two servers with different numbers, UUID-based selection
across rename and reorder, removed selection without fallback, picker metadata
and duplicate labels, setup precedence, individual failure, and stale data.
Avoid tests that merely mirror the App Intents declarations.

Run the core suite, widget tests, applicable strict SwiftLint and swift-format
checks, and a macOS app/extension build. Add previews for an individual server,
a long name, individual unavailability, and a removed server. Report any check
that could not run and its cause.

Manual host checks: edit the picker; place aggregate and individual widgets
together; rename and remove the selected server; confirm a previously installed
static widget still shows aggregate statistics after an upgrade. Distinguish
these manual checks from automated results; do not claim they passed unless run.

## Out of scope and delivery

No new metrics, widget sizes, blocking controls, providers, server limits,
refresh tuning, or changes to app settings selection. README translations only
need changes if the implementation changes README content.

After spec approval, the **DeepSeek V4.1 Flash** Paseo preset is the implementation
workhorse. The parent agent reviews the resulting diff against this spec and
repository standards, checks the validation evidence, and resolves findings
before reporting completion. No commit, push, PR, or posted review comment is
authorized by this task.

## Implementation evidence

DeepSeek V4.1 Flash implemented the feature. Parent review covered the full diff
and validation logs, with separate standards and spec reviews. Review fixes added
the required MainActor test-suite annotations and ensured removed-server preview
snapshots show guidance rather than fabricated sample statistics. Preview
resolution also distinguishes unavailable shared storage from a removed server.

- Core: 735 tests passed; integration-support target: 12 tests passed.
- Widgets: 42 tests passed, including preview regression coverage.
- macOS app and widget extension build passed with code signing disabled.
- Strict SwiftLint and swift-format passed; git diff --check was clean.
- SDK declarations and deployment settings confirm macOS 14 API compatibility;
  runtime tests ran on macOS 27.2.1, not macOS 14.

Evidence logs are `/tmp/holeberry-core-test.log`, `/tmp/holeberry-test.log`,
`/tmp/holeberry-build.log`, `/tmp/holeberry-swiftlint.log`, and
`/tmp/holeberry-swift-format.log`. The final widget test result bundle is
`/tmp/holeberry-dd/Logs/Test/Test-Holeberry-2026.11.22_12-11-38-+0000.xcresult`.

Pending manual verification requires a signed install: actual picker interaction,
placed widgets with independent selections, rename/removal display, and upgrade
from the previous static widget. These checks have not been reported as passed.
The Pi-hole container integration suite was not enabled for this work.

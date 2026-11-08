# Small all-servers widget

> Translation pending: this guide is English-only for now. The README
> translations have not been updated for the widget.

Holeberry includes one native, read-only WidgetKit widget for the macOS small
widget family. It shows aggregate Pi-hole statistics for all configured servers
(the existing two-server limit still applies). It never toggles blocking or
writes to Pi-hole.

## Setup

1. Update to a release that includes the widget, then launch Holeberry once.
   Startup migration runs automatically before the app-mode manager and copies
   the server configuration, temporary-unblock records, and credentials into the
   shared App Group and Keychain. There is no manual migration step.
2. Open the macOS widget gallery, choose Holeberry, and add the **All servers**
   widget to Notification Center or the desktop.
3. If Holeberry reports **Widget setup unavailable**, keep using the app. That
   message is failure-only: migration has not completed, so that launch stays on
   the original storage and retries at the next app launch. Servers and
   passwords do not need to be re-entered.
4. If shared storage worked before but cannot be reopened, Holeberry shows
   **Saved storage unavailable**, keeps the app running on a no-write empty
   state, and disables adding or changing servers until storage reopens. It does
   not fall back to stale legacy data.

## What the widget shows

- A health dot and the fixed **All servers** heading.
  - Green: every configured server returned a query summary.
  - Amber: some servers returned a query summary.
  - Red: no server returned a query summary.
  - Gray: no recent check, no servers configured, or the latest check is more
    than 60 minutes old.
- Health uses query-summary success only. Blocking state is excluded, so a
  server that is paused but reachable can still be healthy.
- A large one-decimal blocked percentage: `100 * sum(blocked) / sum(queries)`.
  Zero queries safely show `0.0%`.
- Blocked and total query counts from the same live query summaries used by the app.
- A compact **Updated HH:mm** footer for the latest successful live fetch.
- Every refresh fetches live query summaries; the widget never saves or reuses
  aggregate totals.
- A partial or failed refresh shows **Statistics unavailable**; the dot still
  reflects which servers responded. Earlier numbers are never displayed.

## Reads and scheduling

- The widget extension fetches independently. Holeberry does not need to be
  running for a fetch. It reads all configured servers directly; there is no
  host-only statistics path.
- The extension provider is parameterized by `ServerScope`; the current widget
  passes `.all`. No per-server widget UI or gallery entry is shipped.
- The widget carries the same intentional ATS arbitrary-loads policy as the app,
  so user-entered HTTP Pi-hole and VPN endpoints work. `NSAllowsLocalNetworking`
  is intentionally absent because it changes ATS precedence.
- The containing app carries `NSLocalNetworkUsageDescription`. The widget does
  not add a separate usage-description key.
- No new UDP prompt mechanism is added. Foreground server setup already requests
  local-network data; a real-LAN test should verify that prompt before relying
  on background widget reads.
- The extension requests another timeline after about 15 minutes. macOS decides
  when the extension actually runs; 15 minutes is a request, not a guarantee.
- Each fetch uses one all-server query-summary read through the existing
  on-demand manager, then logs out its own clients. Aggregate totals come only
  from that fetch.
- A normal timeline fetch never launches Holeberry. A deliberate widget click
  opens Holeberry Settings for diagnosis or setup; it never performs a Pi-hole
  write.
- Server or credential changes request a widget reload. macOS may defer that
  reload.

## Migration and persistence

- Shared storage uses App Group `group.me.pedrovieira.holeberry` and the stable
  shared Keychain service `me.pedrovieira.holeberry.shared`.
- Startup migration runs before the application-mode manager. It copies:
  - every server field, including UUID, label, icon, URL, and API version;
  - every configured server's complete temporary-unblock records, including
    record UUID, start time, duration, pending-removal state, and retry count;
  - each present credential, with exact readback verification.
- The completion marker is versioned and is written only after all copies
  verify. Legacy data is preserved. An interrupted migration retries from the
  current legacy state.
- A present but malformed legacy configuration or temporary-record array fails
  closed instead of being copied as empty. An intentionally empty completed
  configuration stays authoritative and never resurrects removed servers.
- The widget does not persist aggregate statistics between fetches. An older
  saved `widgetStatistics` value is unused.

## Release signing and CI profiles

The release workflow needs the existing Developer ID and notarization secrets
plus two new base64 secrets:

| Secret | Contents |
| --- | --- |
| `HOLEBERRY_APP_PROFILE` | Base64-encoded Developer ID provisioning profile for `me.pedrovieira.holeberry` |
| `HOLEBERRY_WIDGET_PROFILE` | Base64-encoded Developer ID provisioning profile for `me.pedrovieira.holeberry.widgets` |

To prepare them, create two **Developer ID Application** provisioning profiles
in the Apple Developer portal (one for each bundle identifier) with the App Group
and Keychain capabilities, download the `.provisionprofile` files, and set each
file's base64 value as the corresponding repository secret. The workflow decodes
each profile and reads its UUID; do not put a profile name or a different UUID
into the secrets.

Each profile must:

- be a valid, unexpired Developer ID Application profile for the exact target
  bundle identifier;
- authorize App Group `group.me.pedrovieira.holeberry`;
- authorize Keychain group `TEAMID.me.pedrovieira.holeberry.shared` (the profile
  may use an authorized wildcard such as `TEAMID.*`);
- contain no `get-task-allow` debug entitlement;
- for the widget profile, the signed bundle must also carry App Sandbox and
  outbound network client entitlements.

The workflow:

- requires both profile secrets, decodes them, and reads each UUID; missing
  secrets or malformed profiles fail before the build;
- runs a small inline preflight on each decoded profile: exact role application
  identifier, team, registered App Group authorization, shared Keychain group
  authorization (with valid wildcard allowances), and future expiration;
- installs them privately with restrictive permissions in
  `~/Library/MobileDevice/Provisioning Profiles`. An existing profile with the
  same UUID and bytes is reused without deletion; the same UUID with different
  bytes fails instead of being overwritten;
- passes separate per-target `PROVISIONING_PROFILE_SPECIFIER` UUIDs. The project
  settings set `REGISTER_APP_GROUPS=YES` for local/automatic signing; the manual
  Developer ID build uses the explicit profiles;
- after nested Sparkle re-signing, asserts both embedded profiles, actual signed
  entitlements from `codesign`, concrete App Group/Keychain markers in the built
  Info plists, no debug entitlement, widget Sandbox/network entitlements, and
  matching app/widget versions;
- relies on Xcode's signing checks, the existing Developer ID/team audit, the
  `codesign --verify --deep --strict` check before notarization, and Apple's
  notarization result for signature validation. There is no separate custom
  signing validator;
- removes only profiles recorded in its own install manifest, even on failure.

Versions have one source in `project.yml`: `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION`. Both targets use those values for
`CFBundleShortVersionString` and `CFBundleVersion`. The release tag must equal
the app marketing version; the embedded widget marketing and build versions must
equal the app's. `CURRENT_PROJECT_VERSION` remains independent of the tag so
Sparkle build-version ordering is preserved.

Profiles and certificates are never committed. Unsigned local builds remain
possible with `CODE_SIGNING_ALLOWED=NO`.

## Validation status

Verified locally on the current branch:

- Core tests: 611 tests in 71 suites plus 12 integration-support tests passed.
- Unsigned app/widget build succeeded. Both resolved built Info plists show
  marketing/build version `1.2.0`; unsigned shared markers have an empty team
  prefix, which is expected without signing.
- `actionlint` is clean. Inline profile preflight and post-sign Python blocks
  were syntax-checked.
- Positive post-sign audit against the final Developer ID export app and widget
  passed. That export predates the latest Bundle/widget-file organization, so
  this is metadata validation, not a new signed build of the current sources.
- Isolated negative fixtures for wrong application ID, missing App Group,
  expired profile, unexpanded keychain prefix, and debug entitlement failed as
  expected.
- Historical signed packaging evidence: the corrected sources archived and a
  Developer ID export produced the final app. A pre-simplification custom
  validator (since removed) passed on that export. This is evidence about the
  signed artifacts, not a test of the current manual CI workflow end-to-end.
- Apple-issued Developer ID profiles exist locally through Xcode export and
  authorize both production target IDs/groups. No profiles or certificates are
  committed.
- The earlier widget spike validated feasibility only; it was not a shipping
  runtime test.

Still required before shipping:

- A full manual Developer ID CI release run with the real app/widget profile
  secrets. The existing local export validated explicit profiles and the
  team-prefixed markers separately; the exact new workflow still needs real
  release validation, including notarization, appcast publication, and
  Sparkle/publish gates.
- A clean-user or VM test on a real LAN:
  - normal LaunchServices app launch, not a shell with inherited permission;
    local-network permission may be undetermined, allowed, or denied;
  - observe the foreground server-setup prompt before relying on widget reads;
  - app-quit cross-process App Group/Keychain reads;
  - real-user configuration/temporary-record/credential migration;
  - widget rendering and actual system scheduling of 15-minute refreshes.
- WidgetKit background execution classification is not claimed proven. VPN
  interfaces differ from LAN, although `.local` DNS and routing can still
  matter. macOS 27.2 privacy-reset support is not claimed verified.
- No claim is made that the app-quit shipping runtime, real-user migration, or
  notarization has already been exercised.

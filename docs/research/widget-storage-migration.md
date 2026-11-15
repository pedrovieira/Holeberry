# Widget storage migration: failure and recovery

Investigated 2026-11-15. Research and recommendations only; this document does not change migration policy.
Translation pending: this research note is English-only.

## Scope and current behavior

Holeberry moves one server array and at most two credentials from app-local defaults and the legacy Keychain
namespace into shared stores. This is a local copy; internet availability and Pi-hole reachability do not determine
whether that copy succeeds.

Currently, `SharedStorageMigration.migrate` catches import failures, attempts to empty the shared server list,
then records completion. Legacy data remains untouched but is not imported again after completion. If the reset
itself fails, startup selects unavailable storage. The widget waits for the shared completion marker.
See [migration](../../Packages/HoleberryCore/Sources/HoleberryCore/Persistence/SharedStorageMigration.swift),
[startup](../../Packages/HoleberryCore/Sources/HoleberryCore/Persistence/AppStorageStartup.swift), and
[widget setup gate](../../Sources/HoleberryWidgets/QueryStatisticsProvider.swift).

## What can fail, and how often?

| Failure | What it means | What recovery can do |
| --- | --- | --- |
| Wrong App Group, access group, provisioning, or target metadata | A configuration/build error can affect every install of that build. A defaults object opening is not an entitlement check. | Correct the signed build/configuration. Repeating the same copy cannot repair its entitlements. |
| Keychain locked, protected data unavailable, or access denied/cancelled | The credential can exist but be unreadable in the current context. | Retry after the required user action, such as unlock or authorizing access. Do not interpret every read failure as a missing credential. |
| Malformed legacy server data | The stored representation cannot decode completely under this app version. | Repair the decoder/data or let the user explicitly start over. Retrying unchanged bytes does not fix them. |
| Process interruption or a failed individual operation | Defaults and Keychain are separate stores, with no transaction spanning the copy. | Keep the source, make writes repeatable, and publish readiness last. |
| Genuine absence of a credential | Passwordless servers legitimately have no secret; an already-broken authenticated connection may also have none. | Keep the server configuration and use the existing reauthentication flow where required. |

Apple documents missing-entitlement failures and inspecting the **built app's** entitlements, rather than trusting
the source plist. Older macOS provisioning profiles may omit App Group authorization.
[Keychain entitlements](https://developer.apple.com/documentation/security/errsecmissingentitlement),
[macOS App Group provisioning](https://developer.apple.com/documentation/xcode/accessing-app-group-containers).

Apple's Security engineer describes locked Data Protection Keychain reads failing with
`errSecInteractionNotAllowed`, warns against deleting credentials after such a failure, and recommends
non-destructive cancellation or choosing an appropriate accessibility class. On macOS this guidance concerns
the Data Protection Keychain; legacy file-based items have their own access controls.
[SecItem pitfalls](https://developer.apple.com/forums/thread/724013),
[legacy access control](https://developer.apple.com/documentation/security/access-control-lists).

**Frequency is unknown.** Neither the examined sources nor Holeberry supplies a representative failure rate.
There is no basis for claiming a percentage or promising that all failures are rare. Configuration errors are
systematic; transient access failures depend on the user's execution context. Measure actual migration outcomes
before assigning rates.

## What shipped apps actually do

These are comparable source examples, not evidence of one universal industry policy or identical macOS behavior.

| App | Observed implementation | Relevance and limits |
| --- | --- | --- |
| WordPress → Jetpack | Exports defaults through a dictionary in shared storage, publishes the authentication token to a shared Keychain, then sets a readiness flag. Real Keychain read/write failures fail export; a genuinely missing token is distinguished. | Direct precedent for a small copy plus readiness marker. This is migration between two apps, not specifically the first introduction of a widget. [Source](https://github.com/wordpress-mobile/WordPress-iOS/blob/bb932cb5129e35906025886e2835c2b40b6f2fdd/WordPress/Classes/Jetpack/Utility/DataMigrator.swift#L60-L82). |
| WordPress/Jetpack widgets | Copies an explicit list of widget defaults using `object(forKey:)` and `set`. Credential migration avoids overwriting an existing destination token. Widget initialization fills shared configuration when its destination site ID is missing. | Supports targeted raw copies and preserving existing destination state. Some operations are best effort; that does not make ignored errors a requirement. [Widget migration](https://github.com/wordpress-mobile/WordPress-iOS/blob/bb932cb5129e35906025886e2835c2b40b6f2fdd/Modules/Sources/WordPressData/Swift/SharedDataIssueSolver.swift), [initialization](https://github.com/wordpress-mobile/WordPress-iOS/blob/bb932cb5129e35906025886e2835c2b40b6f2fdd/WordPress/Classes/Stores/StatsWidgetsStore.swift). |
| Bitwarden iOS | Runs numbered migrations, advances the version after a throwing migration returns, and logs an escaping failure without advancing that step. A separate migration updates Keychain access groups; it logs and continues individual item-update errors. | Precedent for version markers and differing policies per operation. It is not an all-or-nothing transaction or an exact private-defaults-to-widget migration. [Source](https://github.com/bitwarden/ios/blob/31b15f8ecb3caf0f9f4521dd63f4b55404c02617/BitwardenShared/Core/Platform/Services/MigrationService.swift#L344-L360). |

No verified exact Firefox or 1Password equivalent was established in this investigation. Their behavior should
not be inferred from these examples.

## Raw copying versus strict reads

Raw copying of the known server key is reasonable if its representation stays compatible. Copying every key
would also move app-only preferences that do not belong in shared storage. WordPress demonstrates that a raw
dictionary approach can be practical; it does not establish that every migration needs that entire dictionary.

`dictionaryRepresentation()` merges domains, including registered fallbacks; `persistentDomain(forName:)`
restricts the dictionary to one saved domain. Neither validates server records.
[Dictionary representation](https://developer.apple.com/documentation/foundation/userdefaults/dictionaryrepresentation()),
[persistent domain](https://developer.apple.com/documentation/foundation/userdefaults/persistentdomain(forname:)).

Defaults writes update in-process state immediately and persist asynchronously. `set` does not return a success
result. Readback can detect representation mistakes or an absent target value, but does **not** prove that a disk
flush completed. Apple says `synchronize()` is unnecessary and should not be used as a durability protocol.
[UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults).

## Two simple recovery policies

These are alternatives to discuss, not changes approved or implemented by this research.

1. **Preserve the working host until cutover.** Before the first successful shared copy, keep the app on legacy
   storage if a transient migration error occurs; leave the widget in setup. Retry on the next launch or an
   explicit Retry action. Once cutover succeeds, use shared storage exclusively, so old data never overwrites
   newer edits. This preserves service but is a deliberate reversal of this branch's removed legacy fallback.
   A local activation marker can distinguish pre-cutover from post-cutover failure.
2. **Preserve valid configurations, repair credentials separately.** Copy the server array and try each
   credential. A failed credential copy need not discard either server: keep successfully copied credentials,
   expose the affected connection for reauthentication, and retain the legacy source. This is the simpler
   non-transactional option for two re-creatable connections. However, reauthentication cannot repair a missing
   entitlement or an unwritable shared Keychain; report those as storage failures rather than endlessly asking
   for a password. Marking cutover complete under this policy deliberately ends automatic legacy import.

For either policy, one attempt per launch or explicit retry is enough; no busy loop or arbitrary retry count is
needed. A counter does not make a permanent build error recoverable. A user can choose **Start fresh** when
configuration is irreparable, but silently emptying all connections because one secret is temporarily inaccessible
is a separate product decision. Do not report a failed copy as successful migration merely to stop retries.

The smallest robust flow is: read the known data, copy it, publish readiness last, preserve the source, and make
the failure state actionable. Avoid deleting legacy data during this feature rollout. An interrupted pre-cutover
attempt may repeat safely; a completed cutover must never re-import stale legacy values.

## Pi-hole counter range

The examined FTL v5.25.2 and v6 summary implementations represent total and blocked counts as signed C `int`
(32-bit on the conventional supported Linux targets). The positive representation ceiling is **2,147,483,647**
per count. Two instances sum to **4,294,967,294**, far below 64-bit Swift `Int.max`:
**9,223,372,036,854,775,807**. This is a representation limit, not a promised throughput or daily traffic cap.
[v5 source](https://github.com/pi-hole/FTL/blob/v5.25.2/src/api/api.c#L75-L105),
[v6 source](https://github.com/pi-hole/FTL/blob/2a0fcb7421d84d065f4501eb226d2775d3767011/src/api/stats.c#L139-L164).

BigInt is unnecessary for those API values. Holeberry's models accept unrestricted `Int` inputs, so a small
checked-addition guard can still protect against malformed, synthetic, or future wider values without adding a
dependency or changing UI numeric types.

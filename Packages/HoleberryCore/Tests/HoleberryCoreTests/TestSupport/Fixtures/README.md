# Captured Pi-hole reply fixtures

Live captures, 2026-09-24, from `pihole/pihole` Docker images run locally
(colima VM, ports 18080/18081/18082; containers removed after capture).
Every `.json` file is a verbatim reply body — statuses and headers noted
below, not embedded in the files.

No fallbacks were used: every file is a live capture. The tests inline
these bodies (see `PiholeV5ServiceTests` and `PiholeV6ServiceTests`); this directory is captured
evidence, not read by the test target (`exclude` in `Package.swift`).

| Image tag | core | web | FTL | duplicate-add reply |
|---|---|---|---|---|
| `pihole/pihole:2026.09.0` | v6.4.3 | v6.6 | **v6.7.1** | 400 `database_error` |
| `pihole/pihole:2026.04.0` | v6.4.1 | v6.5 | **v6.6** | 201 + `processed.errors` |
| `pihole/pihole:2024.07.0` | v5.18.3 | v5.21 | v5.25.2 | 200 + message string |

## v6 — FTL ≥ 6.6.1 family (image `2026.09.0`, FTL v6.7.1)

- `v6-domains-allow-exact-miss.json` — `GET /api/domains/allow/exact/example.com`
  before any add → **200**, empty `domains` array.
- `v6-add-success-201.json` — first `POST /api/domains/allow/exact`
  (comment `via holeberryapp.com / probe`) → **201**; `processed.success`
  non-empty and the read-back entry carries `enabled: true` plus our comment.
- `v6-domains-allow-exact-hit.json` — the same GET after the add → **200**,
  one entry (comment and `enabled` echoed).
- `v6-add-duplicate-400.json` — the same POST again → **400**
  `database_error` with `hint: "The item is already present"`; the body has
  no list. Temporary unblocking disambiguates this reply with one
  single-domain GET, including when the hint does not match a known message.

## v6 — FTL ≤ 6.6 family (image `2026.04.0`, FTL v6.6)

- `v6-add-duplicate-201.json` — duplicate `POST /api/domains/allow/exact` →
  **201** with the pre-existing entry read back and
  `processed.errors = [{item, error: "UNIQUE constraint failed:
  domainlist.domain, domainlist.type"}]`, `processed.success = []`.
  `processed.success` confirms insertion; an existing row is classified
  through a single-domain lookup when insertion was not confirmed.

## v5 (image `2024.07.0`, web v5.21)

- `v5-list-white.json` — `GET /admin/api.php?list=white` (web-session auth;
  token auth returns the same body) → **200 JSON**, never HTML:
  `{"data":[{"id":1,"type":0,"domain":"example.com","enabled":1,…}]}`.
  `enabled` and `type` arrive as integers (1/0), not booleans.
- `v5-add-duplicate.json` — duplicate `…?list=white&add=example.com` →
  **200** `{"success":true,"message":"Not adding example.com as it is
  already on the list"}` — success status, message only, no structure
  (hence the v5 read-first flow).

## Legacy v5 sweep — the pre-5.5 window (2026-09-25)

Follow-up to the research doc's flagged gap: the v5.0–5.4 *web* tags
couldn't be verified from source (mid-refactor snapshot). Booted the
corresponding `pihole/pihole:v5.*` images (amd64 under emulation; their
EOL init scripts need archive.debian.org apt sources, v5.1 additionally a
stub `apt-get`) and probed both endpoints:

| Image tag | core | web | FTL | `?list=white` | duplicate add |
|---|---|---|---|---|---|
| `v5.0` | v5.0 | v5.0 | v5.0 | **500, empty body** — PHP fatal: `require(scripts/pi-hole/php/get.php)` missing (`api.php:124`) | plain text: `Success, added 0 of 1 domain (skipped 1 duplicates)` |
| `v5.1` | v5.1.1 | v5.1 | v5.1 | 200 `{"data":[]}` | 200 `{"success":true,"message":"Not adding example.com as it is already on the list"}` |
| `v5.2` | v5.2 | v5.2 | v5.3.1 | 200 `{"data":[]}` | same JSON pair |
| `v5.3.4` | v5.2.2 | v5.2.2 | v5.3.4 | 200 `{"data":[]}` | same JSON pair |
| `v5.4` | v5.2.3 | v5.3 | v5.4 | 200 `{"data":[]}` | same JSON pair |
| `v5.5` | v5.2.4 | v5.3.1 | v5.5 | 200 `{"data":[]}` | same JSON pair |

- Every probed revision from web **5.1** on returns the JSON bodies the
  service decodes (same `data`/`success` shapes as v5.21 above; entries
  carry `enabled: 1`, `comment: null`, `groups: [0]`).
- **web v5.0 is the single outlier** — and it is not HTML: the list
  endpoint is a hard 500 (its `api.php` requires the never-shipped
  `get.php`) and adds reply in plain text. The app fails closed there:
  the probe throws, so nothing is added or deleted, and expiry marks the
  record for retry rather than deleting blind.
- Web 5.4 itself isn't bundled by any image in this registry window
  (image tags track core/FTL); it sits inside the JSON-verified 5.1→5.21
  range.

Capture notes: `/api/info/version` returns 401 until `POST /api/auth`;
v5 needs a web-session cookie (`pw=…` posted to `/admin/index.php`).

## Browser domain-history transport fixtures (2026-10-22)

`PiholeV5DomainQueryHistoryTests` and `PiholeV6DomainQueryHistoryTests` inline
**synthetic, source-derived** payloads. They are not live captures and do not
alter the provenance of the `.json` captures above. Tests generate pagination
pages with JSONSerialization to vary cursor/count metadata without duplicating
large fixtures. No live-server compatibility has been claimed for this POC.

Primary sources inspected:

- [Web v5.21 api_FTL.php](https://github.com/pi-hole/web/blob/v5.21/api_FTL.php#L262):
  `getAllQueries` filter precedence; the 12-column array layout at lines 310–311;
  Unix timestamps arrive as strings through the PHP CSV path (numeric variants
  are accepted by the tests). V5 history requests now send only `from`/`until`
  with `getAllQueries`: PHP selects time before domain and client. Bounds use
  floor(start)/ceil(end) integer seconds; local filtering enforces the precise
  captured 15-minute interval, hostname and client.
- [FTL v5.25.1 api.c](https://github.com/pi-hole/FTL/blob/v5.25.1/src/api/api.c):
  a query row reports the known client hostname instead of its IP. Relevant
  exact-IP matches are used first, without a name lookup. Only when there are no
  IP matches and relevant named rows exist does `getClientNames` resolve names
  for the captured IPv4. The same history response is searched again for those
  names; unrelated names do not need resolving. Missing mappings, hidden names,
  and matching names shared with another IP (including IPv6) fail verification. No client-history fallback remains. The client list
  must be fully visible (`API_EXCLUDE_CLIENTS` empty); this endpoint cannot prove
  that hidden duplicate mappings do not exist. FTL also records the DNS root as
  `.`, so the history decoder preserves general DNS names before local filtering.
- [FTL v5.25.1 request.c](https://github.com/pi-hole/FTL/blob/v5.25.1/src/api/request.c#L85)
  and [datastructure.c](https://github.com/pi-hole/FTL/blob/v5.25.1/src/datastructure.c#L434):
  `getAllQueries` holds the shared-memory lock while formatting rows, and client
  IP/name strings come from the client's current record. Visible rows for a
  client therefore use its current name or IP consistently. Fixtures represent
  one format per client, rather than a synthetic transition from IP to name
  within the same response. Latest allowed/block ordering remains tested within
  each representation.
- [FTL queries API schema](https://github.com/pi-hole/FTL/blob/master/src/api/docs/content/specs/queries.yaml):
  v6 time/type/status/client/reply fields and optional pagination metadata.
- [FTL queries implementation](https://github.com/pi-hole/FTL/blob/master/src/api/queries.c):
  the first response cursor pins the snapshot; later requests reuse it with
  `start=50` / `start=100`. `cursor:null` is the privacy-hidden response.
- [FTL status/reply names](https://github.com/pi-hole/FTL/blob/master/src/datastructure.c):
  local rule blocks versus external/upstream blocks, busy/special/unfinished states,
  and reply classifications.

Observed mocked request cost: one v5 time-window read per candidate when relevant
rows contain matching IPs, plus one client-name lookup only when no IP rows match
and relevant named rows exist.
The two candidates still dispatch separate reads through the existing per-domain
API seam; the time-window response includes all clients and hostnames, so live
payload-size measurements remain pending. V6 sends
one read per candidate normally and at most three pages of 50 rows. A full page
without a stable cursor returns incomplete evidence rather than reading a page
that new arrivals could shift. Existing `getRecentBlocked` display decoding stays
separate from these strict decision fixtures.

V5 POC compatibility requirement: set `API_QUERY_LOG_SHOW=all` and keep domain/client history visible. `API_QUERY_LOG_SHOW` can hide
allowed or blocked rows before the API sends domain/client history. A completed
HTTP response cannot prove that this preference includes both categories; a
hidden newer allowed row can otherwise leave an older block looking current.
The v5 transport does not change Pi-hole configuration or claim to detect this
preference. Live verification must inspect it before relying on both statuses.

# Captured Pi-hole reply fixtures

Live captures, 2026-09-24, from `pihole/pihole` Docker images run locally
(colima VM, ports 18080/18081/18082; containers removed after capture).
Every `.json` file is a verbatim reply body — statuses and headers noted
below, not embedded in the files.

No fallbacks were used: every file is a live capture. The tests inline
these bodies (see `PiholeV5ServiceTests`, `PiholeV6ServiceTests`) and cite
this directory.

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
  no list. The app disambiguates with one single-domain GET — it never
  parses the hint text.

## v6 — FTL ≤ 6.6 family (image `2026.04.0`, FTL v6.6)

- `v6-add-duplicate-201.json` — duplicate `POST /api/domains/allow/exact` →
  **201** with the pre-existing entry read back and
  `processed.errors = [{item, error: "UNIQUE constraint failed:
  domainlist.domain, domainlist.type"}]`, `processed.success = []`.
  `processed` is the structural signal; the error string is informational.

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

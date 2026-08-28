# Security Policy

Holeberry stores credentials for your Pi-hole® instances (in the macOS Keychain), reads the URL of your current browser tab, and connects directly to the Pi-hole instances you configure. We take security issues seriously. If you believe you've found a security vulnerability, please report it privately — **do not open a public issue**.

## Supported Versions

Security fixes are only shipped in the latest release. Please update Holeberry from the [Releases](https://github.com/pedrovieira/Holeberry/releases) page.

| Version | Supported |
| ------- | --------- |
| Latest release (1.x) | ✅ Supported |
| Older releases | ❌ Unsupported |

## Reporting a Vulnerability

Please use GitHub's private advisory form:

👉 https://github.com/pedrovieira/Holeberry/security/advisories/new

Please include:

- What the issue is and why you consider it a security problem
- Reproduction steps, or a minimal proof of concept
- Affected version and macOS version
- Anything else that would help us fix it faster

What to expect:

- Acknowledgment of your report within **7 days**
- Updates on progress as we work toward a fix
- Coordinated disclosure once the fix ships, with credit if you'd like it

If we haven't responded within **30 days**, you're free to disclose the issue yourself.

## Scope

**In scope** — vulnerabilities in Holeberry's own code, e.g.:

- Misuse of Pi-hole credentials, tokens, or session handling
- Weaknesses in update verification (Sparkle/Ed25519) or code signing
- Anything that exposes credentials or browser data to other processes or parties

**Out of scope** — these aren't Holeberry bugs:

- Issues in Pi-hole itself or its web interface → report to [Pi-hole](https://github.com/pi-hole/pi-hole)
- Vulnerabilities in third-party dependencies (Sparkle, KeyboardShortcuts, SymbolPicker, …) → report to those projects
- Issues caused by modifying or repackaging the app yourself
- Crashes, feature requests, or behavior complaints → open a regular [issue](https://github.com/pedrovieira/Holeberry/issues)

There is no bug bounty program.

## Notes

- Pi-hole credentials live in the macOS Keychain; the app never writes them to disk in plaintext.
- Holeberry connects only to the Pi-hole instances you configure and to the GitHub-hosted update feed — it sends no telemetry.
- Updates are verified with Sparkle's embedded Ed25519 key; only install builds from the official [Releases](https://github.com/pedrovieira/Holeberry/releases) page. From 1.1.0 onward, the DMGs are notarized; earlier releases were not notarized (free Apple ID), so for those, verify the origin before bypassing Gatekeeper.

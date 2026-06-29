# Security Policy

RememBar is a small, on-device macOS app maintained by Evan C. Navarro. Because it reads sensitive
local data (files, browser history, 1Password metadata), security reports are taken seriously.

## Reporting a vulnerability

Please report privately — **do not open a public issue** for security problems:

- Open a [private security advisory](https://github.com/EvanCNavarro/remembar/security/advisories/new), or
- Email **evancnavarro@gmail.com**.

I'll acknowledge within a few days and aim to ship a fix promptly.

## What RememBar does with your data

- **Search is on-device.** File search (`mdfind`), browser-history reads (local SQLite), and
  1Password lookups (`op`) all run on your Mac. Query text and results are never transmitted.
- **No telemetry, no analytics, no AI.**
- **1Password access is read-only metadata** (titles, vaults, categories) — never passwords or
  secret fields.
- **The only network requests** are result icons: favicons from Google and video thumbnails from
  YouTube. See the README "Privacy & permissions" section.
- Sensitive file paths/names are redacted from the app's local diagnostic log.

## How releases are verified

- Each release is **built by this repo's GitHub Actions**, not a personal machine.
- Releases carry **build provenance** (`gh attestation verify`), a **VirusTotal** scan link, and a
  published **SHA-256**.
- Auto-updates are **EdDSA-signed**; Sparkle refuses any update without a valid signature.
- Code is scanned by **CodeQL** on every change.

## Supported versions

The latest released version receives security updates.

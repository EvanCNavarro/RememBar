# RememBar — TODO

Roadmap by milestone. Shipped history lives in `release-notes/` + the GitHub Releases page; the
resolved post-review cleanup analysis lives in `docs/CLEANUP-PLAN.md` and `.engine/state/`.

## Toward v0.5.0 — product polish (the focus before we pay to sign)
Improve the experience first, *then* invest in Developer ID. Buckets (each to be scoped when we start):

- [ ] **Onboarding** — a better first-run experience: explain the permission ask (Full Disk Access),
      what RememBar searches, and how to use it. Today it drops you at an empty search bar.
- [ ] **Update-flow animations** — smoother transitions between the update dialog states
      (checking → available → downloading → ready). The morph exists; make it feel polished.
- [ ] **Search** — the interaction and quality:
      - Live-as-you-type (results per keystroke; Enter opens the selected result). The query already
        persists in the field as of 0.3.2, so this is the next step toward the full launcher feel.
      - Ranking / refinement improvements.
- [ ] **More sources** beyond files / browser history / 1Password. The line: index searchable
      *metadata / names*, never secret *values* or file *contents*. Ranked by value-to-effort:
      - **Browser bookmarks** *(next — no new access/permission, fully testable)*. Firefox: same
        `places.sqlite` we already read (`moz_bookmarks`); Chrome/Safari: a sibling file in the
        app-data path we already reach. Natural extension of the history source.
      - **Applications** *(easy — `mdfind kMDItemKind == 'Application'`)*. Launcher table-stakes,
        no new permission.
      - **Contacts** and **Calendar** *(after onboarding)* — high "half-remember" value (names/emails,
        meeting titles) but each adds its own TCC permission prompt, so they ride the onboarding wave.
      - **Bitwarden** — same clean metadata CLI shape as 1Password (`bw list items`); deferred, no
        local install to test against yet.
      - *Deliberately out of scope:* file **contents** / full-text (crosses names-not-contents; Spotlight
        already does it) and Messages/Mail **bodies** (secret-adjacent content — metadata only, if ever).

## v0.5.0 — Developer ID signing + notarization (deferred by decision)
Not before v0.5.0. Two problems, one fix — kept here so the rationale isn't lost:
1. Removes the first-launch Gatekeeper "Apple could not verify…" warning.
2. **Preserves Full Disk Access across updates.** The app is ad-hoc signed, so its TCC designated
   requirement is the per-build `cdhash` (verified: `codesign -d -r-` → `designated => cdhash H"..."`).
   Every Sparkle update has a new cdhash → macOS treats it as a different app → the user must re-grant
   Full Disk Access after *every* update. A Developer ID cert makes the requirement stable (team +
   bundle ID) so grants persist. ($99/yr Apple Developer Program; the CI plumbing can be prepped ahead
   of enrolling.)
3. **Reliable 1Password results.** RememBar reads 1Password by spawning its `op` CLI. `op` authorizes
   the *calling app* via the desktop app's "Integrate with 1Password CLI" biometric prompt, which is
   bound to the caller's code signature. An ad-hoc-signed app has an unstable cdhash, so 1Password
   can't hold a durable trust for it — same root cause as the TCC re-grant. Until Developer ID, the
   1Password source will often show blocked even when `op` works in a Terminal. The v0.3.3 fix stopped
   sending those users to the wrong pane (Full Disk Access) and points them at the CLI setup docs
   instead, but *durable* password-manager results are gated here.

## Considered and deferred (with rationale)
- [ ] **Sensitive-path policy hardening** — gated on threat model; mdfind doesn't surface dot-dir
      secrets and leaf-name rules already cover indexed files. See `.engine/state/stoke-plan-remaining.md`.
- [~] **Remote-image `URLCache`** — SKIP: `AsyncImage` already HTTP-caches; a decoded-image cache is a
      disproportionate pipeline rewrite for a few thumbnails per search.

## Done recently (see release-notes/ for the full list)
- [x] Crash-on-launch fix (0.3.1) + a build guard so a missing resource can't ship again.
- [x] All swiftlint warnings resolved; four-subsystem code review; perf benchmarked (all negligible).
- [x] Persistent, editable search query (0.3.2).

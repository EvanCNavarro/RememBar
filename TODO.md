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
- [ ] **More sources** beyond files / browser history / 1Password.

## v0.5.0 — Developer ID signing + notarization (deferred by decision)
Not before v0.5.0. Two problems, one fix — kept here so the rationale isn't lost:
1. Removes the first-launch Gatekeeper "Apple could not verify…" warning.
2. **Preserves Full Disk Access across updates.** The app is ad-hoc signed, so its TCC designated
   requirement is the per-build `cdhash` (verified: `codesign -d -r-` → `designated => cdhash H"..."`).
   Every Sparkle update has a new cdhash → macOS treats it as a different app → the user must re-grant
   Full Disk Access after *every* update. A Developer ID cert makes the requirement stable (team +
   bundle ID) so grants persist. ($99/yr Apple Developer Program; the CI plumbing can be prepped ahead
   of enrolling.)

## Considered and deferred (with rationale)
- [ ] **Sensitive-path policy hardening** — gated on threat model; mdfind doesn't surface dot-dir
      secrets and leaf-name rules already cover indexed files. See `.engine/state/stoke-plan-remaining.md`.
- [~] **Remote-image `URLCache`** — SKIP: `AsyncImage` already HTTP-caches; a decoded-image cache is a
      disproportionate pipeline rewrite for a few thumbnails per search.

## Done recently (see release-notes/ for the full list)
- [x] Crash-on-launch fix (0.3.1) + a build guard so a missing resource can't ship again.
- [x] All swiftlint warnings resolved; four-subsystem code review; perf benchmarked (all negligible).
- [x] Persistent, editable search query (0.3.2).

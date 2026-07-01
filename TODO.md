# RememBar — TODO

Open work, roughly by priority. Shipped history lives in `release-notes/` + the GitHub Releases page;
the resolved post-review cleanup analysis lives in `docs/CLEANUP-PLAN.md` and `.engine/state/`.

## Product
- [ ] **Signed + notarized releases (Developer ID) — HIGHEST VALUE.** Two problems, one fix:
      1. Removes the first-launch Gatekeeper "Apple could not verify…" warning.
      2. **Preserves Full Disk Access across updates.** The app is currently ad-hoc signed, so its
         TCC designated requirement is the raw per-build `cdhash` (verified: `codesign -d -r-` →
         `designated => cdhash H"..."`). Every Sparkle update has a new cdhash → macOS treats it as a
         different app → the user must re-grant Full Disk Access after *every* update. A Developer ID
         cert makes the requirement stable (team + bundle ID), so grants persist. ($99/yr Apple
         Developer Program. A persistent self-signed cert would fix #2 only, not #1.)
- [ ] **Live-as-you-type search** — results update on every keystroke; Enter opens the selected
      result (drop the explicit submit button). The query already persists in the field as of 0.3.2,
      so this is the natural next step toward the full launcher feel.
- [ ] **More sources** beyond files / browser history / 1Password.

## Considered and deferred (with rationale)
- [ ] **Sensitive-path policy hardening** (suppress Quick Look previews for files under `.ssh`,
      `.aws`, `Secrets/`, …) — gated on threat model. Verified that mdfind does not surface dot-dir
      secrets, and every indexed secret is already caught by the leaf-name rules, so this is low-value
      today. See `.engine/state/stoke-plan-remaining.md`.
- [~] **Remote-image `URLCache`** — decided SKIP: `AsyncImage` already HTTP-caches favicons/thumbnails
      via `URLCache.shared`; a decoded-image cache would mean rewriting the working thumbnail pipeline
      for a handful of images per search. Not worth the risk.

## Done recently (see release-notes/ for the full list)
- [x] Crash-on-launch fix (0.3.1) + build guard so a missing resource can't ship again.
- [x] All swiftlint warnings resolved; four-subsystem code review; perf benchmarked (all negligible).
- [x] Persistent, editable search query (0.3.2).

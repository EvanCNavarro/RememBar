# RememBar — TODO

Open work, roughly by priority. Shipped history lives in `release-notes/` + the GitHub Releases page;
the resolved post-review cleanup analysis lives in `docs/CLEANUP-PLAN.md` and `.engine/state/`.

## Product
- [ ] **Signed + notarized releases** — removes the first-launch Gatekeeper warning (the main
      install-friction today).
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

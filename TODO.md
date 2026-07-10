# RememBar — TODO

Roadmap by milestone. Shipped history lives in `release-notes/` + the GitHub Releases page; the
resolved post-review cleanup analysis lives in `docs/CLEANUP-PLAN.md` and `.engine/state/`.

## Toward v0.5.0 — product polish (the focus before we pay to sign)
Improve the experience first, *then* invest in Developer ID. Buckets (each to be scoped when we start):

- [ ] **Onboarding** — a better first-run experience: explain the permission ask (Full Disk Access),
      what RememBar searches, and how to use it. Today it drops you at an empty search bar.
- [ ] **Update-flow animations** — smoother transitions between the update dialog states
      (checking → available → downloading → ready). The morph exists; make it feel polished.
- [ ] **Search quality** — live-as-you-type, keyboard nav, and the re-search feedback all shipped
      (see "Done"). What's left: **ranking / frecency** (weight by recency + how often you pick a
      result for a query), and a **product decision on click behavior** (see Nits below — clicking a
      result currently copies; opening needs the arrow or Enter).
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

## Nits & polish (from the 2026-07-10 audit — none blocking; pick any)
Small, self-contained refinements. Build is green, 211 tests pass, lint is 0 — these are craft, not bugs.
- [ ] **Product decision: clicking a result copies, it doesn't open.** The row's click action is
      `select()` (copies to pasteboard + highlights); opening needs the trailing ↗ arrow or Enter.
      Decide the model — row-click-opens (with a copy glyph), or keep click=copy — then make it
      consistent. `ResultsView.swift` (row Button → `select`), `MemorySearchStore.select/open`.
- [ ] **Delete vestigial `refinements`** on `MemorySearchStore` — only ever assigned `[]`, nothing
      appends; drop the `@Published` property + the `!refinements.isEmpty` term in `canClearSearch`.
      (The provider-level `refinements:` param is a wider sweep — leave unless doing it deliberately.)
- [ ] **A11y:** the selected-row "copied" double-check glyph has no `accessibilityLabel` (VoiceOver
      reads "checkmark, checkmark"); the open ↗ arrow hit target is 22×20, under the 24×24 the gear
      already honors. `ResultsView.swift`.
- [ ] **Unify the dim constant** — stale-results dim is `0.45` (`MemoryPanel.swift`) vs `0.46`
      (`ResultsView.swift`); almost certainly meant to be one value → hoist to a shared constant.
- [ ] **Stale doc comment** `Controls.swift:8` — `IconControlButton` is now only the settings gear +
      pagination (clear/submit moved to MacFaceKit `GhostIconButton`; the "?" popover is gone).
- [ ] **Missing early release notes** — `v0.1.0`/`v0.2.0` have tags but no `release-notes/*.md`
      (pre-convention history; low priority).

## Considered and deferred (with rationale)
- [ ] **Sensitive-path policy hardening** — gated on threat model; mdfind doesn't surface dot-dir
      secrets and leaf-name rules already cover indexed files. See `.engine/state/stoke-plan-remaining.md`.
- [~] **Remote-image `URLCache`** — SKIP: `AsyncImage` already HTTP-caches; a decoded-image cache is a
      disproportionate pipeline rewrite for a few thumbnails per search.

## Done recently (see release-notes/ for the full list)
- [x] Crash-on-launch fix (0.3.1) + a build guard so a missing resource can't ship again.
- [x] All swiftlint warnings resolved; four-subsystem code review; perf benchmarked (all negligible).
- [x] Persistent, editable search query (0.3.2).
- [x] 1Password remediation fix (0.3.3) — a blocked password manager reads as a calm hint pointing at
      the CLI setup, not an amber Full Disk Access warning that never applied.
- [x] **Term-families management UI + live reload.** In-app editor (chips + add-word, no JSON), reached
      from the About "…" menu. Shared `AliasCatalog` (lock-guarded, off-main-safe) is read per search,
      so edits apply live with no restart. Draft state keeps half-built families visible while the
      engine stays sanitized. STOKE-planned + skeptic-audited + TDD; verified in the real runtime.
- [x] **Live-as-you-type search (P1a).** Typing searches (debounced ~180 ms) through one dispatch
      pipeline; Enter searches immediately. Stale-while-revalidate (no blank/flicker), distinct
      no-results state, field stays editable during load. One re-entrancy invariant
      (`query != baseQuery`) fixes retry/clear/whitespace re-entry.
- [x] **Keyboard navigation.** ↑/↓ move a highlight through results (cross pages at the boundary,
      no wrap); Enter opens the highlighted/top result when results match, else searches; Esc clears.
      `.onKeyPress` on the focused field; store logic fully unit-tested.
- [x] **Re-search feedback.** Overriding a query now dims the stale rows the instant the field
      diverges (`resultsQuery`/`resultsAreStale`) + shows the bar spinner; no-results names the query.
- [x] **Tabbed Settings window (0.4.1).** Real `NSWindow` hosting a `SettingsRootView` tab bar
      (Term Families | About), reached from a gear in the search bar; About consolidated out of the
      old "?" popover. (Chose a self-owned window over a SwiftUI `Settings` scene — cleaner close hook.)
- [x] **MacFaceKit migration (unreleased, on `main` since v0.4.2).** Update-flow UI + icon buttons +
      tokens + `ReleaseNotesParser` extracted to the shared `github.com/400faces/MacFaceKit` package;
      `RememBarUserDriver` is now a thin adapter over the kit's `UpdateWindowController`. Four commits
      on `main` past v0.4.2 → **cut v0.4.3 when ready** (behavior-preserving refactor, worth a note).

# RememBar — Post-Review Cleanup & Optimization Plan

> **RESOLVED (2026-07-01):** Phases 1–4 done or measured-SKIP (see commits + `.engine/state/`). The
> last two open items — remote-image `URLCache` (3.2) and sensitive-path hardening (4.1/4.2) — were
> STOKE-audited (`.engine/state/stoke-plan-remaining.md`) and adversarially re-checked: **both SKIP.**
> URLCache is already handled by `URLCache.shared` (AsyncImage); the policy hardening is dead code —
> mdfind never surfaces dot-dir secrets, and every indexed secret is already caught leaf-side. Nothing
> left to build.


Follow-ups deferred from the 2026-07-01 four-subsystem review (after `0522f2c` cleared all
lint and `7675104` landed the thumbnail-presentation win). Ordered **foundational-first**: a
trustworthy test suite, then safe cleanups, then optimizations (each gated on a real measurement),
then optional policy hardening. Every item is behavior-preserving unless marked otherwise, ships as
its own commit, and is tests-first.

Legend — **Value** / **Risk** / **Rec**: `DO` (worth it), `GATE` (only if a benchmark/threat-model
justifies it), `SKIP-unless-asked` (marginal; don't spend the risk).

---

## Phase 1 — Test reliability (do first: it's the safety net for every later change)

| # | Item | Evidence | Rec |
|---|------|----------|-----|
| 1.1 | Harden the flaky subprocess-timing test — replace the fixed `eventually` budget with a longer/adaptive wait (or poll to a deadline) so a slow process spawn under load can't fail `#require(started)`. | `IntegrationTests.swift:505` (`onePasswordCLIListerTerminatesProcessWhenTaskIsCancelled`); passes 5/5 in isolation, flaked once under a 4×-loop. | DO |
| 1.2 | Audit sibling timing tests for the same pattern (the `terminated` check right below; any debounce/async-await-file tests) and give them the same deadline-based helper. | same file; `eventually {}` helper | DO |

**Test:** run the hardened test in a tight loop (≥20×) under `swift test` load; expect 0 flakes.
**Rollback:** revert the helper; the tests still pass in isolation.

---

## Phase 2 — Safe cleanups (low-risk, no behavior change; do before opts to cut noise)

| # | Item | Evidence | Value/Risk | Rec |
|---|------|----------|-----------|-----|
| 2.1 | Inline the three thin `slugified()` wrappers into one call each (or a single shared helper). | `SpotlightFileSearchProvider.sourceIDComponent`, `LocalHistorySearchProvider` `HistoryDiscoveryIssue.idComponent` + `HistorySource.idComponent` | low / low | DO |
| 2.2 | `ExternalAppTarget.onePassword()!` → `guard let … else { return nil }`. Static-constant today, but a force-unwrap in a result path. | `OnePasswordSearchProvider.swift:~242` (touches `ExternalAppTarget`, cross-file) | low / low | DO |
| 2.3 | `HistoryResultKind` `query!` → `if let query, !query.isEmpty`. Guarded today, brittle to edits. | `MemoryResult.swift:~336` | low / low | DO |
| 2.4 | AboutView website URL: hoist `URL(string:)!` to a `static let` with a `#if DEBUG assert`. | `AboutView.swift:83` | trivial / trivial | DO |
| 2.5 | `MdfindSpotlightSearch`: drop stdout lines that don't start with `/` before mapping to file URLs (keeps stray diagnostics out of `candidateCount`). | `MdfindSpotlightSearch.swift:~98–114` | low / low | DO |
| 2.6 | Tile DRY — extract a shared `LabeledTile(icon:text:)` behind `FileTile`/`SystemSettingsTile`. | `ResultThumbnail.swift:195–267` | cosmetic / low | SKIP-unless-asked (duplication is small; our own principle prefers it over abstraction) |

**Test:** add a unit test for each nil/empty branch introduced by 2.2/2.3; existing tests cover the rest.
**Rollback:** per-item revert; all independent.

---

## Phase 3 — MEASURED (2026-07-01): all CPU items SKIP, backed by numbers

Ran a micro-benchmark against the real code (25 realistic results). Per-search cost:
- `MemoryResult.kind` (URL parse): ~86µs to touch all 25 once → ~260µs/search. Caching saves ~170µs.
- `orderedResults` sort of 25: ~197µs per page-flip.
- Diagnostics `record()`: ~479µs/event → ~8ms/search over ~18 events (the state re-read is only a
  slice of that).

Against a search that is hundreds of ms (subprocess/SQLite-bound, 620ms debounce), the CPU items are
imperceptible — **SKIP, confirmed by measurement, not assumption.** The diagnostics ~8ms is the
largest but invisible and the state-read opt only shaves part of it → SKIP. Full suite verified 5/5
under 4x CPU load (no other flaky tests). **Only genuinely-open perf item:** remote-image `URLCache`
(3.2) — network/bandwidth behavior, not microbenchmarkable; marginal for a menu-bar app; still
deferred pending a real profiling scenario.

### (original analysis retained below)

## Phase 3 — Optimizations (MEASURE FIRST; the code is already well-optimized)

The review's honest finding: subprocess I/O is off-main, size probes are O(1), icons are cached.
Result sets are ≤25. So **benchmark before building** — if the win isn't real on a realistic profile,
skip it. Add a lightweight timing harness (or `os_signpost`) and capture a before/after number in the
commit; no number, no merge.

| # | Item | Evidence | Blast radius | Rec |
|---|------|----------|--------------|-----|
| 3.1 | Cache `MemoryResult.kind` as a stored `let` computed once at init (it parses the URL; hit by render + ranking + diagnostics). **Foundational** — enables 3.2 and simplifies hot paths. | `MemoryResult.swift:~93` computed | across all 4 initializers + `Equatable`/`Sendable` | GATE (do first in Phase 3, with a per-target-type regression test) |
| 3.2 | Remote-image caching: configure a `URLCache` (or an `NSCache<NSURL,NSImage>` in front of the loader) so favicons/YouTube thumbs don't re-fetch/re-decode on row-identity churn. | `RemoteMemoryThumbnail.swift:~138` (`AsyncImage`, no cache); app bootstrap `BrowserMemoryBarApp.swift` | cross-file (app config) | GATE (needs a test asserting a repeat load hits cache) |
| 3.3 | Cache `orderedResults` (invalidate on new search / sort-toggle) to stop the double `O(n log n)` sort on page-flips. | `MemorySearchStore.swift:317–342` | in-file, adds one stored var | GATE-on-benchmark (n≤25 → likely SKIP) |
| 3.4 | History row/token cache keyed by source path + mtime (short-lived) so refinements/retries don't re-copy the DB snapshot + re-tokenize 50k rows. | `HistorySQLite.readRows`, `HistoryRanker.score:~68` | moderate, adds cache | GATE (real win only on large histories; measure) |
| 3.5 | Diagnostics: stop re-reading cross-process state from disk on every event; cache the "another process owns state" determination, invalidate on write. | `RememBarDiagnostics.swift:~293 → ~378` (`writeState`→`readState` per event) | in-file, adds cache | GATE (I/O on breadcrumb path; measure vs 15–20 reads/search) |
| 3.6 | Menu-glyph: `static var` → cached `static let` (like `AppIconView.bundledIcon`) to stop re-reading the file + rebuilding `NSImage` on every render. Needs `@MainActor`/`nonisolated(unsafe)` for Swift 6. | `MemoryPanel.swift:~135` | in-file, sendability nuance | DO (small, real; fold the sendability handling in carefully) |

**Rollback:** each opt is a standalone commit reverting cleanly; 3.1 reverts last (others may build on it).

---

## Phase 4 — Security/policy hardening (optional; threat-model dependent)

| # | Item | Evidence | Rec |
|---|------|----------|-----|
| 4.1 | Add an **ancestor-directory** signal to `SensitivePathPolicy` (suppress previews for files under `Secrets/`, `.ssh`, `.gnupg`, `.aws`), not just leaf-name matching. | `SensitivePathPolicy.swift:40–53` (documented leaf-only false-allow) | GATE (tightens Quick Look preview suppression; decide if in threat model) |
| 4.2 | Extend `nameKeywords`/`sensitiveExactLeaves` (`authorized_keys`, `known_hosts`, `wallet-backup`, broader `.ssh`). | `SensitivePathPolicy.swift:20–37` | GATE |
| 4.3 | Add a test pinning redaction's **sentence-vs-path** behavior (a bare keyword sentence is wholly redacted = over-redaction, fails safe). Decide if that's acceptable (it is, for logs). | `SensitivePathPolicy.swift:64–101` | DO (test only; no logic change) |

---

## Recommended sequence & scope

1. **Phase 1** (test reliability) — do now; small, unblocks confidence.
2. **Phase 2** (safe cleanups, minus 2.6) — quick, low-risk batch, one commit or a few.
3. **Phase 3.6 + 3.1** — the two optimizations with real, non-marginal payoff (glyph cache is cheap;
   `kind` caching is foundational). Everything else in Phase 3 is **GATE-on-benchmark** — build the
   timing harness, measure, and only land what actually moves.
4. **Phase 4.3** now (a test); 4.1/4.2 only if the threat model calls for it.

**Not worth doing** unless asked: 2.6 (tile DRY), 3.3 (orderedResults at n≤25), and any Phase-3 perf
item that doesn't show a measured win.

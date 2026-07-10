# RememBar — Handoff

_Last updated: 2026-07-10. This is the single spot to pick the project back up. When you return, read
this top-to-bottom, then jump to **▶ Start here**._

## Current state (all green)

| Check | State |
|---|---|
| Build | ✅ `swift build` — clean (39s incl. MacFaceKit fetch) |
| Tests | ✅ `swift test` — **211 passing** |
| Lint | ✅ `swiftlint lint Sources/` — **0 warnings** |
| Git | ✅ `main` == `origin/main`, working tree **clean** (nothing dirty) |
| Latest release | **v0.4.2** (2026-07-06) |
| Unreleased on `main` | 6 commits past v0.4.2 (MacFaceKit update-flow migration + kit bump + this doc polish) — see below |

## What was broken ("things aren't working") — FIXED

Two stray **`GalleryView 2.swift`** and **`RememBarUserDriver 2.swift`** files (Finder/Xcode
duplicate-copy artifacts from July 5, *before* the MacFaceKit migration finished) were sitting in
`Sources/BrowserMemoryBar/` **untracked**. They caused `invalid redeclaration of GalleryView /
GalleryWindowController / RememBarUserDriver` → the build failed. They were stale (pre-migration) and
not in git. **Fix:** moved them out (backed up to the session scratchpad). Build recovered immediately.
_If this recurs:_ `git status` will show untracked `* 2.swift` files — delete them; the tracked
originals are the source of truth.

## ▶ Start here (next session, in order)

1. **Sanity-check health** — `swift build && swift test` (expect 211 pass). If red, check for stray
   `* 2.swift` duplicates first (see above).
2. **Decide: cut v0.4.3.** `main` has 6 unreleased commits past v0.4.2 — the MacFaceKit update-flow
   migration (behavior-preserving refactor) + a kit bump + doc polish. It's verified (adapter is a
   clean thin wrapper, tests green). To ship: add `release-notes/0.4.3.md`, then
   `git tag v0.4.3 && git push origin v0.4.3` (**tagging is gated — it publishes a public Release;
   confirm before pushing the tag**).
3. **Pick up product/polish work** from `TODO.md`. The highest-signal open item is the **click-behavior
   decision** (clicking a result copies, doesn't open — see Nits), then **ranking/frecency**. Bigger
   milestones: **onboarding**, **update-flow animations**, **more sources** (bookmarks first).

## Where the project is

- **Released & live:** v0.4.2. Full-featured local menu-bar search (files/history/1Password), custom
  Sparkle update UI, tabbed Settings window, live-as-you-type + keyboard navigation, term-families
  editor with live reload.
- **The big recent arc:** extracted a shared **MacFaceKit** package (`github.com/400faces/MacFaceKit`,
  public, pinned `.upToNextMinor(from: "0.3.2")`) — the update-flow UI, icon buttons, tokens, and
  `ReleaseNotesParser` now live there; `RememBarUserDriver` is a thin adapter over the kit's
  `UpdateWindowController`. Migration is **complete and clean** (no leftover local dupes).
- **Next milestone:** v0.5.0 = Developer ID signing + notarization (deferred by decision — it's what
  makes Full Disk Access + durable 1Password results survive updates; rationale in `TODO.md`).

## Architecture map (for whoever picks up)

- **Search:** `MemorySearchStore` (the `@MainActor` brain — one `dispatchSearch` pipeline, debounce,
  stale-while-revalidate, keyboard nav) → `CompositeMemorySearchProvider` (fans out to Spotlight/
  history/1Password providers via `withTaskGroup`, reads the live `AliasCatalog` per search).
- **Term families:** `AliasGroups` (immutable value) + `AliasCatalog` (lock-guarded live authority,
  **NOT `@MainActor`** — providers read it off-main) + `AliasEditorModel` (draft state) +
  `AliasEditorView`.
- **Settings:** `SettingsWindowController` (self-owned titled `NSWindow`, `.regular`↔`.accessory`
  activation dance) hosts `SettingsRootView` (custom tab bar → Term Families | About).
- **Updates:** `SparkleUpdater` (app-local, Sparkle vendored) → `RememBarUserDriver` (adapter) →
  MacFaceKit `UpdateWindowController`.
- **Design tokens / icon buttons:** MacFaceKit (`Tokens` is a module `typealias` to `MacFaceKit.Tokens`).

## Gotchas / non-obvious

- **Sparkle is vendored, gitignored.** A fresh clone must run `./scripts/fetch-sparkle.sh` before
  `swift build`. MacFaceKit resolves automatically (SPM).
- **Release = tag.** `git tag vX.Y.Z && git push origin vX.Y.Z` triggers CI, which builds, stamps the
  version from the tag, embeds `release-notes/X.Y.Z.md` inline in the appcast, and publishes. Verify
  the published zip (not a local build) — a local build defaults to the version in
  `build-remembar-app.sh`.
- **Runtime UI can't be screenshot-verified in this environment** — the tiling window manager
  (TermTile) occludes windows, and SwiftUI hosting views don't expose their tree to external
  accessibility. Offscreen `ImageRenderer` (the `PanelRenderTests`/`AliasEditorRenderTests` harness,
  gated on `REMEMBAR_RENDER_DIR`) covers layout; real interaction (keyboard nav, typing in the
  settings window) needs a hands-on `swift run RememBar`. Dev hooks: `REMEMBAR_GALLERY=1`,
  `REMEMBAR_OPEN_SETTINGS=1` (DEBUG-only) open surfaces directly on launch.

## Open work → `TODO.md`

`TODO.md` is current. Structure: **Toward v0.5.0** (onboarding · update animations · search ranking ·
more sources) · **Nits & polish** (the audit list — click behavior, vestigial `refinements`, a11y,
dim constant, a stale comment) · **v0.5.0 Developer ID** (with full rationale) · **Done recently**.

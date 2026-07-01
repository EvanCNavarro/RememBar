<div align="center">

# RememBar

**A minimalist menu-bar search for your system files, browser history, password managers, and more.**

Type a few words, get what you half-remember — the file, the page you visited, the login —
without leaving the keyboard. Search runs entirely on your Mac.

[Install](#install) · [Privacy](#privacy--permissions) · [Verify the download](#verify-this-download) · [Build from source](#build-from-source) · [Roadmap](#roadmap)

</div>

> [!NOTE]
> **Early days.** RememBar is a young project I built for myself and a few friends. It works and it's
> careful with your data, but it isn't notarized by Apple yet, so macOS will warn on first launch
> (see [Install](#install)). After that, **new versions install in-app** (via Sparkle, EdDSA-signed) —
> no re-downloading.

---

## What it is

RememBar lives in your menu bar. Click it (or use the hotkey), type, and it searches several places
on your Mac at once and ranks the best matches:

- **Files** — via Spotlight (`mdfind`), across your home folder.
- **Browser history** — Safari, every major Chromium-based browser (Chrome, Arc, Brave, Edge,
  Opera, Vivaldi, Chromium), and every Firefox-based browser (Firefox, Zen, Waterfox, LibreWolf).
- **Password managers** — item **titles, vaults, and categories** (never your passwords). Currently
  **1Password**, via its `op` CLI, if it's installed and you're signed in.

More sources will come over time — hence the *"and more."*

There is **no AI and no account.** It's a fast local index search, not a chatbot.

**Term families (aliases).** Create `~/Library/Application Support/RememBar/aliases.json` with groups
of interchangeable words — then searching any member also finds things named after the others (e.g.
search `evan` and surface `ECN_*` files):

```json
[["evan", "ecn", "navarro"], ["mom", "mother"]]
```

Edits apply on the next launch. Aliases work across files, history, and password managers.

## Install

1. Download `RememBar.zip` from the [latest release](https://github.com/EvanCNavarro/RememBar/releases/latest)
   and unzip it. Drag **RememBar.app** to `/Applications`.
2. **First launch (macOS Sequoia / 15):** double-clicking shows *"Apple could not verify…"* — this is
   expected for an app that isn't notarized yet. To open it:
   - Open **System Settings → Privacy & Security**, scroll to the **Security** section, and click
     **"Open Anyway"** next to the RememBar message, then confirm.
   - *(The old "right-click → Open" trick was removed in macOS 15; use Open Anyway above.)*
3. **Grant Full Disk Access** so it can read Safari history and search across your files:
   **System Settings → Privacy & Security → Full Disk Access → enable RememBar.** RememBar will also
   offer a one-click button to this screen when it detects access is missing.
4. *(Optional)* For password-manager results (currently **1Password**), install the
   [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) and sign in.

Requires **macOS 14 (Sonoma) or later.**

## Privacy & permissions

Your searches and their results stay on your machine. Specifically:

- **Search is local.** File search (`mdfind`), browser-history reads (local SQLite databases), and
  password-manager lookups (`op`) all run on your Mac. Your query text and results are **never sent
  anywhere**, and there is no analytics or telemetry.
- **Password managers:** only item **metadata** (title, vault, category) is read — never passwords or
  secret fields. Sensitive file paths and names are redacted from the app's local diagnostic log.
- **The only network requests** RememBar makes are to fetch **result icons**: site favicons from
  Google's icon service (`google.com/s2/favicons`) and video thumbnails from YouTube
  (`img.youtube.com`). These reveal a result's domain or video ID to those icon servers — the same
  convenience pattern many apps use — and nothing else.

**Permissions it asks for:** Full Disk Access (to read Safari history + search files system-wide).
That's it.

## Verify this download

Every release is **built by this repository's GitHub Actions** — not a personal machine — and each
release's notes carry everything you need to check the file before you run it:

- **Build provenance** — confirm the download came from this repo's CI, untampered:
  ```bash
  gh attestation verify RememBar.zip --repo EvanCNavarro/RememBar
  ```
- **VirusTotal** — a scan link (dozens of engines) is posted in the release notes.
- **SHA-256** — published in the release notes; compare with `shasum -a 256 RememBar.zip`.
- **Signed updates** — the Sparkle auto-update feed is EdDSA-signed, so an update with a missing or
  bad signature is refused.

**Dependabot** keeps the CI action versions current.

## Build from source

```bash
git clone https://github.com/EvanCNavarro/RememBar.git
cd RememBar
./scripts/fetch-sparkle.sh        # one-time: vendors the Sparkle auto-update framework
swift build                       # debug build
swift test                        # run the test suite
./scripts/build-remembar-app.sh   # produces RememBar.app (embeds + signs Sparkle)
```

Requires the Swift toolchain (Xcode 16+ / Swift 6) on macOS 14+.

## Roadmap

- [x] Sparkle auto-updates (no App Store needed)
- [x] Custom in-app update experience (RememBar's own UI, EdDSA-signed)
- [x] Term families / aliases
- [x] One-click uninstall
- [x] Editable, persistent search query (stays in the box like Spotlight)
- [ ] Signed + notarized releases
- [ ] More sources beyond files / history / password managers
- [ ] Live-as-you-type search (results per keystroke; Enter opens the result)

## Uninstall

Open the **?** panel and click **"Remove RememBar…"** — it moves the app and its data (preferences,
caches, the diagnostics log) to the Trash, then quits. Afterward, remove RememBar from
**System Settings → Privacy & Security → Full Disk Access** (macOS doesn't let an app revoke its own
permission).

Prefer to do it by hand? Quit RememBar, drag **RememBar.app** to the Trash, and delete
`~/Library/Application Support/RememBar`.

## License

[MIT](LICENSE) © 2026 Evan C. Navarro · [ecn.dev/apps/RememBar](https://ecn.dev/apps/RememBar)

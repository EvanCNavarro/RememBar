#!/usr/bin/env bash
#
# End-to-end update test — run BEFORE tagging a release.
#
# Proves the whole update pipeline produces a valid, signed, *detectable* Sparkle update from one
# version to the next: builds v(old) and v(new), confirms each embeds Sparkle and code-signs, then
# generates + cryptographically verifies the signed appcast and that v(new) is seen as newer.
#
# Red-first: exits non-zero (and prints FAIL) on ANY broken link in the chain.
#
# Note: signing reads the EdDSA private key from your login Keychain. The first run may show a
# Keychain prompt — click "Always Allow".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPARKLE_VERSION="2.9.3"
OLD_VER="${E2E_OLD_VERSION:-0.1.0}"
NEW_VER="${E2E_NEW_VERSION:-0.1.1}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

red() { printf '\033[31m%s\033[0m\n' "$1"; }
fail() { red "FAIL: $1" >&2; exit 1; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }

version_build() { printf '%s' "$1" | tr -d '.'; } # mirrors build-remembar-app.sh

echo "E2E update test: v$OLD_VER → v$NEW_VER"

# 1. Sparkle CLI tools (bin/) — full dist, not the SPM xcframework.
echo "→ fetching Sparkle $SPARKLE_VERSION tools…"
curl -fsSL --max-time 180 \
  "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
  -o "$WORK/sparkle.tar.xz" || fail "could not download Sparkle dist"
mkdir -p "$WORK/tools" && tar xf "$WORK/sparkle.tar.xz" -C "$WORK/tools"
GEN_APPCAST="$(find "$WORK/tools" -name generate_appcast -type f | head -1)"
SIGN_UPDATE="$(find "$WORK/tools" -name sign_update -type f | head -1)"
[ -x "$GEN_APPCAST" ] && [ -x "$SIGN_UPDATE" ] || fail "Sparkle tools (generate_appcast/sign_update) missing"

# 2. Build both versions (release, with the version override).
echo "→ building both versions (release)…"
for spec in "old:$OLD_VER" "new:$NEW_VER"; do
  dir="${spec%%:*}"; ver="${spec#*:}"
  REMEMBAR_VERSION="$ver" CONFIGURATION=release REMEMBAR_DIST_DIR="$WORK/$dir" \
    "$SCRIPT_DIR/build-remembar-app.sh" >/dev/null || fail "build of v$ver failed"
done

# 3. Each build: Sparkle embedded, codesign valid, exact version baked in.
for spec in "old:$OLD_VER" "new:$NEW_VER"; do
  dir="${spec%%:*}"; ver="${spec#*:}"; build="$(version_build "$ver")"
  app="$WORK/$dir/RememBar.app"
  [ -d "$app/Contents/Frameworks/Sparkle.framework" ] || fail "$dir: Sparkle.framework not embedded"
  codesign --verify --deep --strict "$app" 2>/dev/null || fail "$dir: codesign --verify failed"
  got_short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  got_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
  [ "$got_short" = "$ver" ] && [ "$got_build" = "$build" ] \
    || fail "$dir: version is $got_short ($got_build), expected $ver ($build)"
  pass "v$ver ($build): Sparkle embedded, codesign valid, version correct"
done

# 4. Package the new version + generate the signed appcast.
echo "→ signing + generating appcast…"
( cd "$WORK/new" && ditto -c -k --keepParent "RememBar.app" "RememBar.zip" ) || fail "could not zip v$NEW_VER"
"$GEN_APPCAST" --download-url-prefix "https://example.invalid/" "$WORK/new" >/dev/null 2>&1 \
  || fail "generate_appcast failed (Keychain key available + allowed?)"
APPCAST="$WORK/new/appcast.xml"
[ -f "$APPCAST" ] || fail "appcast.xml was not produced"

# 5. Appcast advertises the new version, signed.
NEW_BUILD="$(version_build "$NEW_VER")"
grep -q "<sparkle:shortVersionString>$NEW_VER</sparkle:shortVersionString>" "$APPCAST" || fail "appcast missing shortVersionString $NEW_VER"
grep -q "<sparkle:version>$NEW_BUILD</sparkle:version>" "$APPCAST" || fail "appcast missing version $NEW_BUILD"
SIG_CAST="$(grep -oE 'edSignature="[^"]+"' "$APPCAST" | head -1 | sed 's/^edSignature="//;s/"$//')"
[ -n "$SIG_CAST" ] || fail "appcast has no EdDSA signature"
pass "appcast advertises v$NEW_VER ($NEW_BUILD), EdDSA-signed"

# 6. Cryptographic check: the appcast signature must match a fresh sign of the exact zip.
#    (Ed25519 is deterministic, so a correct signature reproduces byte-for-byte.)
SIG_FRESH="$("$SIGN_UPDATE" "$WORK/new/RememBar.zip" 2>/dev/null | grep -oE 'edSignature="[^"]+"' | head -1 | sed 's/^edSignature="//;s/"$//')"
[ -n "$SIG_FRESH" ] || fail "sign_update produced no signature"
[ "$SIG_CAST" = "$SIG_FRESH" ] || fail "appcast signature does NOT match the zip — the download would be rejected"
pass "appcast signature verified against the package"

# 7. v(new) must outrank v(old) by Sparkle's comparison (CFBundleVersion).
OLD_BUILD="$(version_build "$OLD_VER")"
[ "$((10#$NEW_BUILD))" -gt "$((10#$OLD_BUILD))" ] \
  || fail "v$NEW_VER ($NEW_BUILD) is not newer than v$OLD_VER ($OLD_BUILD) — update would never be offered"
pass "v$NEW_VER ($NEW_BUILD) is detected as newer than v$OLD_VER ($OLD_BUILD)"

printf '\n\033[32mE2E UPDATE TEST PASSED\033[0m — the pipeline yields a valid, signed, newer update.\n'
printf 'Manual UI confirmation (one-time per release): install v%s, hit Check for Updates, confirm\n' "$OLD_VER"
printf 'the dialog → download → install → relaunch lands on v%s.\n' "$NEW_VER"

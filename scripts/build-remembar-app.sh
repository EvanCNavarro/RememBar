#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_NAME="RememBar"
EXECUTABLE_NAME="RememBar"
BUNDLE_ID="dev.ecn.apps.remembar"
# Sparkle appcast URL (Info.plist SUFeedURL). 404s until the first release publishes appcast.xml;
# easily overridden if the repo slug changes.
SU_FEED_URL="${REMEMBAR_FEED_URL:-https://github.com/EvanCNavarro/remembar/releases/latest/download/appcast.xml}"
# Sparkle EdDSA PUBLIC key — safe to commit. The matching private key lives in the login Keychain
# (svce https://sparkle-project.org) and signs each update via `sign_update`. Updates with a bad/
# missing signature are refused by Sparkle.
SU_PUBLIC_ED_KEY="${REMEMBAR_ED_PUBKEY:-mIAUkTNj+kRPNqkAX1Z1EaqFqyLaFQ37pwEIGduj4Zs=}"
SPARKLE_FRAMEWORK="$PROJECT_DIR/Vendor/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
DIST_DIR="${REMEMBAR_DIST_DIR:-$HOME/Applications/RememBar}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PROJECT_ICON_SOURCE="$PROJECT_DIR/Sources/BrowserMemoryBar/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
ICON_SOURCE="${REMEMBAR_ICON_SOURCE:-$PROJECT_ICON_SOURCE}"
ICONSET_DIR="$PROJECT_DIR/.build/RememBar.iconset"
ICNS_PATH="$RESOURCES_DIR/RememBar.icns"

fail() {
  printf 'build-remembar-app: %s\n' "$1" >&2
  exit 1
}

[ -f "$ICON_SOURCE" ] || fail "missing icon source at $ICON_SOURCE"

swift build --package-path "$PROJECT_DIR" --configuration "$CONFIGURATION"
BUILD_DIR="$(swift build --package-path "$PROJECT_DIR" --configuration "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP_DIR" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"

cp "$BUILD_DIR/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$PROJECT_DIR/Sources/BrowserMemoryBar/Resources/RememBarMenuGlyph.pdf" "$RESOURCES_DIR/RememBarMenuGlyph.pdf"
cp "$PROJECT_DIR/Sources/BrowserMemoryBar/Resources/RememBarMenuGlyph.png" "$RESOURCES_DIR/RememBarMenuGlyph.png"
cp "$PROJECT_DIR/Sources/BrowserMemoryBar/Resources/RememBarMenuGlyph@2x.png" "$RESOURCES_DIR/RememBarMenuGlyph@2x.png"
cp "$PROJECT_DIR/Sources/BrowserMemoryBar/Resources/RememBarMenuGlyph@3x.png" "$RESOURCES_DIR/RememBarMenuGlyph@3x.png"

sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>RememBar</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIconFile</key>
  <string>RememBar</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>RememBar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>SUFeedURL</key>
  <string>$SU_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SU_PUBLIC_ED_KEY</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Evan C. Navarro · https://ecn.dev</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

# --- Embed Sparkle.framework -------------------------------------------------------------------
# REQUIRED whenever the binary links Sparkle: a linked @rpath/Sparkle.framework with nothing in
# Contents/Frameworks dyld-crashes at launch. `ditto` preserves the framework's version symlinks.
[ -d "$SPARKLE_FRAMEWORK" ] || "$SCRIPT_DIR/fetch-sparkle.sh"
[ -d "$SPARKLE_FRAMEWORK" ] || fail "Sparkle.framework missing at $SPARKLE_FRAMEWORK (run scripts/fetch-sparkle.sh)"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
SPARKLE_DST="$FRAMEWORKS_DIR/Sparkle.framework"
SPARKLE_V="$SPARKLE_DST/Versions/B"
mkdir -p "$FRAMEWORKS_DIR"
ditto "$SPARKLE_FRAMEWORK" "$SPARKLE_DST"

xattr -cr "$APP_DIR"

# Code-sign inside-out: deepest nested code first, then the framework, then the app WITHOUT --deep.
# Order + the "no --deep" rule are from Sparkle's docs — signing the XPC services / helpers
# individually keeps each signature intact (--deep can corrupt the XPC signatures).
codesign --force --sign - "$SPARKLE_V/XPCServices/Downloader.xpc"
codesign --force --sign - "$SPARKLE_V/XPCServices/Installer.xpc"
codesign --force --sign - "$SPARKLE_V/Updater.app"
codesign --force --sign - "$SPARKLE_V/Autoupdate"
codesign --force --sign - "$SPARKLE_DST"
codesign --force --sign - "$APP_DIR" >/dev/null
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
codesign --verify --deep --strict "$APP_DIR" >/dev/null

echo "$APP_DIR"

#!/usr/bin/env bash
# Vendors Sparkle.xcframework into Vendor/ (gitignored). Sparkle is referenced as a local
# binaryTarget because SPM's remote binary-artifact downloader hangs in some sandboxes, while a
# plain download works. Run this once after cloning (the app build script also invokes it).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPARKLE_VERSION="2.9.3"
DEST="$PROJECT_DIR/Vendor/Sparkle.xcframework"
[ -d "$DEST" ] && { echo "Sparkle already vendored at $DEST"; exit 0; }
URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip"
WORK="$(mktemp -d)"
echo "Fetching Sparkle ${SPARKLE_VERSION}…"
curl -fsSL --max-time 180 "$URL" -o "$WORK/spm.zip"
unzip -q "$WORK/spm.zip" -d "$WORK/x"
mkdir -p "$PROJECT_DIR/Vendor"
cp -R "$(find "$WORK/x" -maxdepth 2 -name Sparkle.xcframework -type d | head -1)" "$DEST"
echo "Vendored Sparkle.xcframework -> $DEST"

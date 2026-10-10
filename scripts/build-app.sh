#!/bin/bash
# Builds "build/PDF Voucher Editor.app" from the Swift package (no Xcode GUI needed).
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
cd "$ROOT"

"$ROOT/scripts/build-mupdf.sh"

swift build -c "$CONFIG" --product PDFVoucherEditor
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PDFVoucherEditor"

APP="$ROOT/build/PDF Voucher Editor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PDFVoucherEditor"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Ad-hoc signature so Gatekeeper lets a locally built app run.
codesign --force --sign - "$APP" >/dev/null
echo "Built: $APP"

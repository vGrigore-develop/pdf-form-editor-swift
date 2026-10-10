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
cp "$ROOT/Resources/AppIcon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Liquid Glass icon: compiled from AppIcon.icon when Xcode 26+ actool is available.
# Without it the app keeps the AppIcon.icns above (CFBundleIconFile) and still builds.
ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/appicon-car.XXXXXX")"
if "$ROOT/scripts/make-liquid-icon.sh" "$ICON_WORK" >/dev/null; then
    cp "$ICON_WORK/Assets.car" "$APP/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
else
    echo "Note: Liquid Glass icon not compiled (needs Xcode 26+ actool); using AppIcon.icns only." >&2
fi
rm -rf "$ICON_WORK"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Ad-hoc signature so Gatekeeper lets a locally built app run.
codesign --force --sign - "$APP" >/dev/null
echo "Built: $APP"

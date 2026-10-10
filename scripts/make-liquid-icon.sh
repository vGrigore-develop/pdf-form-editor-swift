#!/bin/bash
# Compiles the Liquid Glass app icon (Resources/AppIcon/AppIcon.icon, an Icon Composer
# document) with actool into <out-dir>/Assets.car plus <out-dir>/partial-info.plist
# (CFBundleIconName). The car also holds flattened renditions for macOS versions before
# Liquid Glass. Needs Xcode 26 or later (actool that reads .icon); exits non-zero otherwise.
# Usage: scripts/make-liquid-icon.sh <out-dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: make-liquid-icon.sh <out-dir>}"
ICON="$ROOT/Resources/AppIcon/AppIcon.icon"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")"

xcrun --find actool >/dev/null 2>&1 || { echo "make-liquid-icon: actool not found (install Xcode 26+)" >&2; exit 1; }
mkdir -p "$OUT"
rm -f "$OUT/Assets.car" "$OUT/partial-info.plist"

# The loose AppIcon.icns actool may also write is not used: the committed one (all sizes,
# hand-tuned 16/32 px) stays the CFBundleIconFile fallback.
LOG="$(xcrun actool "$ICON" \
    --compile "$OUT" \
    --platform macosx \
    --minimum-deployment-target "$MIN_OS" \
    --app-icon AppIcon \
    --standalone-icon-behavior none \
    --output-partial-info-plist "$OUT/partial-info.plist" \
    --output-format human-readable-text \
    --errors --warnings --notices 2>&1)" || { echo "$LOG" >&2; exit 1; }

# actool reports problems in its output rather than always through the exit status.
if grep -q -E '(error|warning|notice):' <<<"$LOG"; then
    echo "$LOG" >&2
    if grep -q 'error:' <<<"$LOG"; then exit 1; fi
fi
[ -s "$OUT/Assets.car" ] || { echo "$LOG" >&2; echo "make-liquid-icon: no Assets.car produced" >&2; exit 1; }
echo "Wrote $OUT/Assets.car"

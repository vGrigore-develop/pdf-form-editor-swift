#!/bin/bash
# Renders Resources/AppIcon/AppIcon.svg (and AppIcon-small.svg for 16/32 px) into
# Resources/AppIcon/AppIcon.icns. Needs only macOS tools (swiftc, iconutil).
# Usage: scripts/make-icon.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Resources/AppIcon"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/appicon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"

swiftc -O "$ROOT/scripts/render-svg.swift" -o "$WORK/render-svg"

render() { # <svg> <pixels> <iconset name>
    "$WORK/render-svg" "$1" "$SET/$3" "$2"
}
FULL="$SRC/AppIcon.svg"
SMALL="$SRC/AppIcon-small.svg"

render "$SMALL" 16   icon_16x16.png
render "$SMALL" 32   icon_16x16@2x.png
render "$SMALL" 32   icon_32x32.png
render "$FULL"  64   icon_32x32@2x.png
render "$FULL"  128  icon_128x128.png
render "$FULL"  256  icon_128x128@2x.png
render "$FULL"  256  icon_256x256.png
render "$FULL"  512  icon_256x256@2x.png
render "$FULL"  512  icon_512x512.png
render "$FULL"  1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o "$SRC/AppIcon.icns"
echo "Wrote $SRC/AppIcon.icns"

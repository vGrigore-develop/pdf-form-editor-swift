#!/bin/bash
# Builds MuPDF from a pinned source release into static libraries under vendor/mupdf/.
# Usage: scripts/build-mupdf.sh            (idempotent; skips if already built)
# Output:
#   vendor/mupdf/include/      MuPDF public headers
#   vendor/mupdf/lib/libmupdf.a, libmupdf-third.a   (arm64, macOS 15+)
# The JavaScript engine is compiled out (FZ_ENABLE_JS=0): the spec says it is never enabled.
set -euo pipefail

VERSION="1.28.2"
SHA256="44075a84e329db55b9bef5f342a70fd26d69e48ad1d33cb89d9664581c641156"
URL="https://mupdf.com/downloads/archive/mupdf-${VERSION}-source.tar.gz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
DL="$VENDOR/download"
SRC="$VENDOR/mupdf-${VERSION}-source"
OUT="$VENDOR/mupdf"
ARCH="$(uname -m)"
MIN_MACOS="15.0"

if [[ -f "$OUT/lib/libmupdf.a" && -f "$OUT/VERSION" && "$(cat "$OUT/VERSION")" == "$VERSION" ]]; then
  echo "MuPDF $VERSION already built in $OUT"; exit 0
fi

mkdir -p "$DL"
TARBALL="$DL/mupdf-${VERSION}-source.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
  echo "Downloading $URL"
  curl -fL --retry 3 -o "$TARBALL" "$URL"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c -

if [[ ! -d "$SRC" ]]; then
  tar -xzf "$TARBALL" -C "$VENDOR"
fi

JOBS="$(sysctl -n hw.ncpu)"
XCFLAGS="-DFZ_ENABLE_JS=0 -DTOFU_CJK -DTOFU_NOTO -mmacosx-version-min=$MIN_MACOS -arch $ARCH"
echo "Building MuPDF $VERSION ($ARCH, $JOBS jobs)"
make -C "$SRC" -j"$JOBS" build=release HAVE_X11=no HAVE_GLUT=no HAVE_CURL=no \
  XCFLAGS="$XCFLAGS" XLDFLAGS="-mmacosx-version-min=$MIN_MACOS -arch $ARCH" libs

rm -rf "$OUT"
mkdir -p "$OUT/lib"
cp -R "$SRC/include" "$OUT/include"
cp "$SRC/build/release/libmupdf.a" "$SRC/build/release/libmupdf-third.a" "$OUT/lib/"
echo "$VERSION" > "$OUT/VERSION"
echo "Done: $OUT"

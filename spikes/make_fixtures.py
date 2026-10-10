"""Generate synthetic test fixtures (no real voucher template is available yet).

Outputs, in Tests/Fixtures/:
  synthetic_voucher.pdf  landscape 842 x 595 pt, full-bleed coloured background,
                         vector artwork, an embedded raster image, text areas.
                         No pure-white pixels anywhere, so "blank outside the
                         cut" can be tested as "pixel == white". /Contents is an
                         array of several streams (the common case for edited PDFs).
  unbalanced_qQ.pdf      one page whose single content stream has one extra `Q`
                         before more drawing (some of it outside the outline).
  unbalanced_qQ_2.pdf    the same with two extra `Q`: enough to pop both the
                         inner q and the clip q of a naive Wrap, so drawing
                         after them leaks outside the outline.

The files are rebuilt deterministically (no timestamps, no random IDs) so the
byte-prefix and byte-identity checks are reproducible.
"""

from __future__ import annotations

import numpy as np
import pymupdf

from common import FIXTURES

W, H = 842, 595


def _gradient_image(w: int = 240, h: int = 160) -> pymupdf.Pixmap:
    y, x = np.mgrid[0:h, 0:w]
    r = (80 + 150 * x / w).astype(np.uint8)
    g = (60 + 120 * y / h).astype(np.uint8)
    b = (180 - 100 * x / w).astype(np.uint8)
    rgb = np.dstack([r, g, b]).astype(np.uint8)
    return pymupdf.Pixmap(pymupdf.csRGB, w, h, rgb.tobytes(), False)


def make_voucher(path) -> None:
    doc = pymupdf.open()
    page = doc.new_page(width=W, height=H)

    # Each draw/commit appends a separate content stream -> /Contents array.
    # PyMuPDF rects are top-left origin; PDF output is the usual bottom-left.
    page.draw_rect(page.rect, color=None, fill=(0.93, 0.80, 0.55))  # full-bleed background
    shape = page.new_shape()
    shape.draw_circle((700, 150), 120)
    shape.finish(color=None, fill=(0.85, 0.35, 0.25))
    shape.draw_rect(pymupdf.Rect(0, 470, W, 595))
    shape.finish(color=None, fill=(0.20, 0.30, 0.45))
    for i in range(12):  # diagonal stripes crossing the future cut edge
        x = -100 + i * 80
        shape.draw_polyline([(x, 0), (x + 60, 0), (x + 260, 470), (x + 200, 470)])
        shape.finish(color=None, fill=(0.88, 0.70, 0.45), closePath=True)
    shape.commit()

    page.insert_image(pymupdf.Rect(110, 140, 350, 300), pixmap=_gradient_image())

    # Text areas (light cream, not white) where fields will go.
    for r in [(420, 180, 780, 220), (420, 240, 780, 280), (420, 300, 640, 340)]:
        page.draw_rect(pymupdf.Rect(*r), color=(0.45, 0.35, 0.25), fill=(0.98, 0.95, 0.88), width=0.8)
    page.insert_text((420, 120), "VOUCHER", fontname="helv", fontsize=40, color=(0.2, 0.15, 0.1))
    page.insert_text((420, 170), "Recipient", fontname="helv", fontsize=10, color=(0.3, 0.25, 0.2))
    page.insert_text((110, 330), "Photo", fontname="helv", fontsize=10, color=(0.3, 0.25, 0.2))
    page.insert_text((420, 520), "Valabil 12 luni", fontname="helv", fontsize=14, color=(0.95, 0.9, 0.8))

    doc.save(path, garbage=0, deflate=True, no_new_id=True)
    doc.close()


def make_unbalanced(path, extra_q: int = 1) -> None:
    doc = pymupdf.open()
    page = doc.new_page(width=W, height=H)
    content = b"\n".join(
        [
            b"%% unbalanced fixture: %d extra Q below" % extra_q,
            b"q 0.30 0.55 0.80 rg 0 0 842 595 re f Q",
            b"Q\n" * extra_q,  # <-- extra Q: pops whatever the caller pushed
            b"q 0.95 0.85 0.30 rg 100 100 300 200 re f Q",
            b"q 0.80 0.20 0.30 rg 0 0 842 60 re f Q",  # full-width band at the bottom
            b"q 0.20 0.60 0.30 rg 600 300 m 800 300 l 800 560 l h f Q",
        ]
    )
    # New pages have no /Contents yet: add one stream object holding our bytes.
    cxref = doc.get_new_xref()
    doc.update_object(cxref, "<<>>")
    doc.update_stream(cxref, content, compress=True)
    doc.xref_set_key(page.xref, "Contents", f"{cxref} 0 R")
    doc.save(path, garbage=0, deflate=True, no_new_id=True)
    doc.close()


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    make_voucher(FIXTURES / "synthetic_voucher.pdf")
    make_unbalanced(FIXTURES / "unbalanced_qQ.pdf", extra_q=1)
    make_unbalanced(FIXTURES / "unbalanced_qQ_2.pdf", extra_q=2)
    for name in ["synthetic_voucher.pdf", "unbalanced_qQ.pdf", "unbalanced_qQ_2.pdf"]:
        p = FIXTURES / name
        with pymupdf.open(p) as d:
            print(f"{name}: {p.stat().st_size} bytes, contents={d[0].get_contents()}, mediabox={d[0].mediabox}")


if __name__ == "__main__":
    main()

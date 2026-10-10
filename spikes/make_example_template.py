"""Generate the example voucher template: Tests/Fixtures/example_voucher_template.pdf.

A synthetic stand-in for a real print template, with no client content, no photo of a
person and no brand. Landscape 842 x 595 pt, two pages, UNCUT (no outline stored).

Page 1: a procedurally generated raster (an image XObject, white outside the stepped edge)
for the left part, a cream panel, a solid dark half-disc at the right end, and a 1 pt
die line along the intended shape (SPEC 5.6.3's reference shape: stepped left edge with
3 steps, semicircular right end). Page 2: the same shape in vector art only.

AcroForm (all base-14 Helvetica):
  product_image   image push button, crosses the stepped left edge (the field-crop case)
  qr_image        image push button, fully inside the shape
  product_name    text, direct /Rect
  greeting        text, /Rect is an indirect array of indirect numbers (Illustrator/InDesign
                  export style; TemplateReader's leaves() case)
  availability    text, a parent field with a single /Kids widget (Merge field and widget)
  tips            multiline text
  voucher_code    text on the dark half-disc
  timestamp       text on the dark half-disc

Deterministic (no timestamps, fixed ID), small, no metadata beyond a generic Producer.
Run from spikes/:  ../.venv/bin/python make_example_template.py
"""

from __future__ import annotations

import io
import math

import numpy as np
import pymupdf
from PIL import Image, ImageDraw

from common import FIXTURES

W, H = 842, 595

# The shape in PDF user space (y up): the outline the app should find. Left edge x 36 with
# two steps in from the corners, top y 525, bottom y 70, semicircle right end.
BOTTOM, TOP = 70.0, 525.0
CX, CY = 590.0, (BOTTOM + TOP) / 2
R = (TOP - BOTTOM) / 2
# Stepped left edge as (x, y) corners, bottom to top.
LEFT_EDGE = [(150, BOTTOM), (150, 126), (96, 126), (96, 182), (36, 182), (36, 418),
             (96, 418), (96, 474), (150, 474), (150, TOP)]

IMG_X0, IMG_X1 = 36.0, 330.0  # the raster covers the left part of the shape


def fy(y: float) -> float:
    """PDF user space y to PyMuPDF's top-left y."""
    return H - y


def shape_points(arc_steps: int = 90) -> list[tuple[float, float]]:
    """The shape as a polygon in PDF space, counterclockwise from the bottom-left."""
    pts = list(LEFT_EDGE)  # bottom-left up the stepped edge to the top-left
    pts.append((CX, TOP))
    for i in range(1, arc_steps):  # clockwise from the top over the right end to the bottom
        a = math.pi / 2 - math.pi * i / arc_steps
        pts.append((CX + R * math.cos(a), CY + R * math.sin(a)))
    pts.append((CX, BOTTOM))
    return pts


def draw_path(sh: pymupdf.Shape) -> None:
    """The outline as exact lines and arcs on a PyMuPDF Shape (top-left coordinates)."""
    p = [(x, fy(y)) for x, y in LEFT_EDGE]
    sh.draw_polyline(p)
    sh.draw_line((p[-1][0], p[-1][1]), (CX, fy(TOP)))
    # Half circle: draw as a Bezier-approximated sector from the top to the bottom.
    k = 0.5522847498 * R
    sh.draw_bezier((CX, fy(TOP)), (CX + k, fy(TOP)), (CX + R, fy(CY) - k), (CX + R, fy(CY)))
    sh.draw_bezier((CX + R, fy(CY)), (CX + R, fy(CY) + k), (CX + k, fy(BOTTOM)), (CX, fy(BOTTOM)))
    sh.draw_line((CX, fy(BOTTOM)), p[0])


def make_raster() -> bytes:
    """Procedural 'photo': sunset-like gradient, soft hills and discs; white outside the
    stepped edge. Two pixels per point; JPEG so the file stays small."""
    s = 2
    w, h = int((IMG_X1 - IMG_X0) * s), int((TOP - BOTTOM) * s)
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    t = y / h
    sky = np.dstack([40 + 200 * t, 70 + 110 * t, 150 - 60 * t])
    img = Image.fromarray(np.clip(sky, 0, 255).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(img)
    d.ellipse([w * 0.55, h * 0.18, w * 0.55 + 150, h * 0.18 + 150], fill=(250, 225, 140))
    for base, col, amp, ph in [(0.62, (70, 110, 90), 40, 0.0), (0.74, (40, 80, 70), 55, 1.7), (0.88, (25, 50, 55), 35, 3.1)]:
        pts = [(0, h)] + [(px, h * base + amp * math.sin(px / 90 + ph) + 20 * math.sin(px / 33 + ph)) for px in range(0, w + 8, 8)] + [(w, h)]
        d.polygon(pts, fill=col)
    # White outside the stepped edge (left of the steps), in image pixels.
    mask = Image.new("L", (w, h), 0)
    md = ImageDraw.Draw(mask)
    poly = [((px - IMG_X0) * s, (TOP - py) * s) for px, py in LEFT_EDGE]
    poly += [(w, 0), (w, h)]
    poly = [(a, b) for a, b in poly]
    md.polygon([(a, b) for a, b in poly], fill=255)
    out = Image.new("RGB", (w, h), (255, 255, 255))
    out.paste(img, (0, 0), mask)
    buf = io.BytesIO()
    out.save(buf, "JPEG", quality=80, optimize=True, subsampling=0)
    return buf.getvalue()


def page_one(doc: pymupdf.Document) -> pymupdf.Page:
    page = doc.new_page(width=W, height=H)
    # Cream panel between the raster and the half-disc.
    page.draw_rect(pymupdf.Rect(IMG_X1, fy(TOP), CX + 1, fy(BOTTOM)), color=None, fill=(0.96, 0.92, 0.82))
    # Raster, placed as an image XObject.
    page.insert_image(pymupdf.Rect(IMG_X0, fy(TOP), IMG_X1, fy(BOTTOM)), stream=make_raster())
    # Solid dark half-disc.
    sh = page.new_shape()
    k = 0.5522847498 * R
    sh.draw_line((CX, fy(TOP)), (CX, fy(TOP)))
    sh.draw_bezier((CX, fy(TOP)), (CX + k, fy(TOP)), (CX + R, fy(CY) - k), (CX + R, fy(CY)))
    sh.draw_bezier((CX + R, fy(CY)), (CX + R, fy(CY) + k), (CX + k, fy(BOTTOM)), (CX, fy(BOTTOM)))
    sh.draw_line((CX, fy(BOTTOM)), (CX, fy(TOP)))
    sh.finish(color=None, fill=(0.13, 0.17, 0.27), closePath=True)
    sh.commit()
    # Printed labels (base-14 only).
    page.insert_text((347, fy(512)), "VOUCHER", fontname="hebo", fontsize=11, color=(0.3, 0.25, 0.2))
    page.insert_text((347, fy(454)), "Greeting", fontname="helv", fontsize=8, color=(0.4, 0.35, 0.3))
    page.insert_text((347, fy(172)), "Availability", fontname="helv", fontsize=8, color=(0.4, 0.35, 0.3))
    page.insert_text((347, fy(332)), "Tips", fontname="helv", fontsize=8, color=(0.4, 0.35, 0.3))
    page.insert_text((612, fy(306)), "CODE", fontname="helv", fontsize=8, color=(0.8, 0.82, 0.9))
    # The die line: 1 pt, dark red, along the intended shape (drawn last, on top).
    dl = page.new_shape()
    draw_path(dl)
    dl.finish(color=(0.55, 0.05, 0.1), fill=None, width=1.0, closePath=True)
    dl.commit()
    return page


def page_two(doc: pymupdf.Document) -> None:
    page = doc.new_page(width=W, height=H)
    poly = [(x, fy(y)) for x, y in shape_points()]
    # Vector art only: diagonal bands, clipped to the shape by drawing them inside it.
    sh = page.new_shape()
    sh.draw_polyline(poly)
    sh.finish(color=None, fill=(0.93, 0.85, 0.62), closePath=True)
    sh.commit()
    sh = page.new_shape()
    for i in range(9):
        x = 60 + i * 80
        sh.draw_polyline([(x, fy(BOTTOM + 1)), (x + 36, fy(BOTTOM + 1)), (x + 36 + 120, fy(TOP - 1)), (x + 120, fy(TOP - 1))])
        sh.finish(color=None, fill=(0.80, 0.45, 0.30) if i % 2 else (0.35, 0.55, 0.60), closePath=True)
    sh.commit()
    # Keep the bands inside the shape: white mask outside it, then the half-disc end.
    mask = page.new_shape()
    mask.draw_rect(pymupdf.Rect(0, 0, W, H))
    mask.draw_polyline(poly)
    mask.finish(color=None, fill=(1, 1, 1), even_odd=True, closePath=True)
    mask.commit()
    sh = page.new_shape()
    k = 0.5522847498 * R
    sh.draw_bezier((CX, fy(TOP)), (CX + k, fy(TOP)), (CX + R, fy(CY) - k), (CX + R, fy(CY)))
    sh.draw_bezier((CX + R, fy(CY)), (CX + R, fy(CY) + k), (CX + k, fy(BOTTOM)), (CX, fy(BOTTOM)))
    sh.draw_line((CX, fy(BOTTOM)), (CX, fy(TOP)))
    sh.finish(color=None, fill=(0.16, 0.22, 0.30), closePath=True)
    sh.commit()
    page.insert_text((347, fy(300)), "Terms and conditions", fontname="hebo", fontsize=14, color=(0.1, 0.1, 0.1))
    dl = page.new_shape()
    draw_path(dl)
    dl.finish(color=(0.55, 0.05, 0.1), fill=None, width=1.0, closePath=True)
    dl.commit()


def add_widget(page, name, kind, rect, multiline=False):
    """rect is in PDF space (x0, y0, x1, y1)."""
    w = pymupdf.Widget()
    w.field_name = name
    w.rect = pymupdf.Rect(rect[0], fy(rect[3]), rect[2], fy(rect[1]))
    if kind == "text":
        w.field_type = pymupdf.PDF_WIDGET_TYPE_TEXT
        w.text_font = "Helv"
        w.text_fontsize = 0 if multiline else 12
        w.text_color = (0, 0, 0)
        w.border_color = (0.45, 0.35, 0.25)
        w.fill_color = (0.99, 0.97, 0.92)
        w.border_width = 0.8
        if multiline:
            w.field_flags = pymupdf.PDF_TX_FIELD_IS_MULTILINE
    else:
        w.field_type = pymupdf.PDF_WIDGET_TYPE_BUTTON
        w.field_flags = pymupdf.PDF_BTN_FIELD_IS_PUSHBUTTON
        w.button_caption = ""
        w.border_color = None
        w.fill_color = (1, 1, 1)
        w.border_width = 0
    return page.add_widget(w)


def make_placeholder(doc, widget) -> None:
    """Image slots draw only a thin dashed outline, so the artwork under them stays visible."""
    x = widget.xref
    r = [float(v) for v in key(doc, x, "Rect").strip("[]").split()]
    w, h = r[2] - r[0], r[3] - r[1]
    ap = int(key(doc, x, "AP/N").split()[0])
    doc.update_stream(ap, (f"q 0.45 0.45 0.45 RG 0.75 w [4 3] 0 d 0.4 0.4 {w - 0.8:g} {h - 0.8:g} re S Q").encode())
    doc.xref_set_key(x, "AP/D", "null")
    # An icon-only push button, as design tools export image slots (TemplateReader: /MK /TP 1 + /IF).
    doc.xref_set_key(x, "MK", "<< /TP 1 /IF << /SW /A /S /P /A [0.5 0.5] >> >>")


def strip_nulls(doc, xref) -> None:
    """xref_set_key(..., "null") leaves `/Key null` entries behind; drop them for real."""
    lines = doc.xref_object(xref).splitlines()
    kept = [ln for ln in lines if not ln.rstrip().endswith(" null") or not ln.strip().startswith("/")]
    if len(kept) != len(lines):
        doc.update_object(xref, "\n".join(kept))


def key(doc, xref, k):
    return doc.xref_get_key(xref, k)[1]


def main() -> None:
    doc = pymupdf.open()
    page_one(doc)
    page_two(doc)
    p1 = doc[0]

    make_placeholder(doc, add_widget(p1, "product_image", "image", (20, 96, 330, 510)))  # crosses the stepped left edge
    make_placeholder(doc, add_widget(p1, "qr_image", "image", (625, 360, 725, 460)))
    add_widget(p1, "product_name", "text", (345, 465, 575, 497))
    greeting = add_widget(p1, "greeting", "text", (345, 420, 575, 450))
    avail = add_widget(p1, "availability", "text", (345, 130, 575, 163))
    add_widget(p1, "tips", "text", (345, 190, 575, 325), multiline=True)
    add_widget(p1, "voucher_code", "text", (612, 268, 792, 298))
    add_widget(p1, "timestamp", "text", (612, 226, 792, 254))

    # Illustrator/InDesign style: /Rect is an indirect array of indirect numbers.
    gx = greeting.xref
    r = [float(v) for v in key(doc, gx, "Rect").strip("[]").split()]
    nums = []
    for v in r:
        n = doc.get_new_xref()
        doc.update_object(n, f"{v:g}")
        nums.append(n)
    arr = doc.get_new_xref()
    doc.update_object(arr, "[" + " ".join(f"{n} 0 R" for n in nums) + "]")
    doc.xref_set_key(gx, "Rect", f"{arr} 0 R")

    # Parent field with a single /Kids widget: the widget keeps only widget keys.
    ax = avail.xref
    parent = doc.get_new_xref()
    da = key(doc, ax, "DA")
    doc.update_object(parent, f"<< /FT /Tx /T (availability) /DA ({da}) /Kids [{ax} 0 R] >>")
    for k in ("T", "FT", "DA", "Ff"):
        doc.xref_set_key(ax, k, "null")
    doc.xref_set_key(ax, "Parent", f"{parent} 0 R")
    cat = doc.pdf_catalog()
    helv = int(key(doc, ax, "AP/N") and doc.xref_get_key(int(key(doc, ax, "AP/N").split()[0]), "Resources/Font/Helv")[1].split()[0])
    doc.xref_set_key(cat, "AcroForm/DA", "(/Helv 0 Tf 0 g)")
    doc.xref_set_key(cat, "AcroForm/DR", f"<< /Font << /Helv {helv} 0 R >> >>")
    fields = key(doc, cat, "AcroForm/Fields")
    assert f"{ax} 0 R" in fields
    doc.xref_set_key(cat, "AcroForm/Fields", fields.replace(f"{ax} 0 R", f"{parent} 0 R"))

    # /Annots as an indirect array, as design tools write it.
    annots = doc.get_new_xref()
    doc.update_object(annots, key(doc, p1.xref, "Annots"))
    doc.xref_set_key(p1.xref, "Annots", f"{annots} 0 R")
    doc.xref_set_key(cat, "Info", "null")  # a stray /Info the Catalog would otherwise carry
    for w in p1.widgets():  # /P on every widget, as exports write it
        doc.xref_set_key(w.xref, "P", f"{p1.xref} 0 R")
    for x in [cat, ax] + [w.xref for w in p1.widgets()]:
        strip_nulls(doc, x)
    doc.set_metadata({"producer": "Example template generator", "creator": "", "title": "",
                      "author": "", "subject": "", "keywords": "", "creationDate": "", "modDate": ""})
    doc.del_xml_metadata()
    strip_nulls(doc, int(doc.xref_get_key(-1, "Info")[1].split()[0]))
    path = FIXTURES / "example_voucher_template.pdf"
    doc.save(path, garbage=3, deflate=True, no_new_id=True)
    doc.close()
    with pymupdf.open(path) as d:
        print(f"{path.name}: {path.stat().st_size} bytes, {len(d)} pages, fields "
              f"{[w.field_name for w in d[0].widgets()]}")


if __name__ == "__main__":
    main()

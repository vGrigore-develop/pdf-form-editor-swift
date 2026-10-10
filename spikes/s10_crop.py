"""S10: crop form fields to the cut outline (SPEC 5.3), measured with real filling code.

The cut clips page content only. Widgets are annotations drawn on top, and whatever a
filler appends after the cut's end stream (flattened appearances, insert_image,
merged overlays) is outside the clip. This spike builds the candidate fixes on one
cut template and fills each with the S9 fillers, then measures the pixels painted
outside the outline.

Variants of the template (all start from the same Wrap-mode cut):
  base   the cut alone (the S9 template shape)
  A      every widget's /AP /N wrapped in a clip to the outline (form space)
  B      the clip left open: cutEnd without its "Q Q"
  C      a cover annotation (page minus outline, even-odd, white) last in /Annots
  AC     A and C together

Fillers per variant (from s9_fill.py): PyMuPDF (text via widget.update, images with
insert_image + delete the image widget; flattened with bake), pypdf (fields,
images merged as an overlay page; flatten=True), pdf-lib (setText, setImage,
form.flatten). Plus the unfilled template itself.

Renders: MuPDF (annots), PDFium (FPDF_ANNOT + FFLDraw) and PDFKit (the engine of
macOS Preview and of the app's Preview, via spikes/out/pdfkit_render built from
pdfkit_render.swift). Metric: pixels more than 1 px outside the outline that are
not white; and the share of each image slot (inside the outline) that shows the
filled image.

Run:  ../.venv/bin/python s10_crop.py                 # the example template, Tests/Fixtures/example_voucher_template.pdf
      ../.venv/bin/python s10_crop.py template.pdf    # build and compare the variants on a template
      S10_TEMPLATE_IS_SWIFT=1 ../.venv/bin/python s10_crop.py   # the Swift engine's out/swift/swift_crossing_cut.pdf
  Without a template the example one is used, with its sample text in every text field. With
  a template (or $S10_TEMPLATE), e.g. a copy of your own, the outline is read from its cut,
  or the example template's outline (EXAMPLE_OUTLINE below) is applied; pass a template with
  a cut for any other shape.
  S10_VALUES=values.json ({"field": "text", ...}) and S10_IMAGES=a,b name the text and
  image fields to fill; by default the S9 names are used if present, otherwise every text
  field gets a sample value and every push button is filled as an image.
  S10_VARIANTS=base,A,... restricts the variants; S10_COVER=Watermark|Stamp picks
  the cover subtype; S10_TEMPLATE_IS_SWIFT=1 skips building variants and only fills
  and measures the given template (for the Swift engine's own output).
  Hard checks run for AC and the Swift output: nothing outside the outline in any
  engine, except pdf-lib unflattened in MuPDF and PDFium (the known limit).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pymupdf

import common
import cut
import s9_fill as s9
from common import Report, new_object, new_stream
from outline import Outline, arc_to_beziers, fmt, raster_mask, to_pdf_path

OUT = common.OUT / "s10"
PDFKIT = common.OUT / "pdfkit_render"

# The example template's die line (11 lines, 1 arc), the shape the smart outline finds on
# page 1 of Tests/Fixtures/example_voucher_template.pdf (RealTemplateTests asserts it).
EXAMPLE_OUTLINE = Outline((150, 70), [
    ("L", 150, 126), ("L", 96, 126), ("L", 96, 182), ("L", 36, 182), ("L", 36, 418),
    ("L", 96, 418), ("L", 96, 474), ("L", 150, 474), ("L", 150, 525), ("L", 590, 525),
    ("A", 590, 70, 590, 297.5, True), ("L", 150, 70),
])
EXAMPLE_TEMPLATE = common.FIXTURES / "example_voucher_template.pdf"
SAMPLE_TEXT = "Sample text 2026"


# ---------------------------------------------------------------------------
# Path in another coordinate space
# ---------------------------------------------------------------------------
def path_ops(o: Outline, f) -> str:
    """The outline as m/l/c/h operators with every point mapped through f."""
    def p(pt):
        x, y = f(pt)
        return f"{fmt(x)} {fmt(y)}"
    ops = [f"{p(o.start)} m"]
    cur = o.start
    for s in o.segments:
        if s[0] == "L":
            ops.append(f"{p((s[1], s[2]))} l"); cur = (s[1], s[2])
        elif s[0] == "C":
            ops.append(f"{p(s[1:3])} {p(s[3:5])} {p(s[5:7])} c"); cur = (s[5], s[6])
        else:
            for b in arc_to_beziers(cur, (s[1], s[2]), (s[3], s[4]), s[5]):
                ops.append(f"{p(b[0:2])} {p(b[2:4])} {p(b[4:6])} c")
            cur = (s[1], s[2])
    ops.append("h")
    return "\n".join(ops)


def nums(doc, xref, key) -> list[float] | None:
    kind, val = doc.xref_get_key(xref, key)
    if kind == "null":
        return None
    if kind == "xref":
        val = doc.xref_object(int(val.split()[0]), compressed=True)
    return [float(v) for v in val.strip("[]").split()]


# ---------------------------------------------------------------------------
# Variants
# ---------------------------------------------------------------------------
def clip_appearances(doc, page, o: Outline) -> int:
    """Option A: wrap each widget's /AP /N in a form that clips to the outline.

    The wrapper's space is the original form's space after its /Matrix (so the
    wrapper has an identity /Matrix and the transformed bbox), and the outline is
    mapped from page space by the inverse of the annotation's bbox-to-/Rect map."""
    n = 0
    for w in page.widgets():
        kind, val = doc.xref_get_key(w.xref, "AP/N")
        if kind != "xref":
            continue
        ap = int(val.split()[0])
        bx0, by0, bx1, by1 = nums(doc, ap, "BBox")
        a, b, c, d, e, f = nums(doc, ap, "Matrix") or [1, 0, 0, 1, 0, 0]
        pts = [(a * x + c * y + e, b * x + d * y + f) for x, y in ((bx0, by0), (bx1, by0), (bx0, by1), (bx1, by1))]
        tx0, ty0 = min(p[0] for p in pts), min(p[1] for p in pts)
        tx1, ty1 = max(p[0] for p in pts), max(p[1] for p in pts)
        h = page.mediabox.height  # widget.rect is y-down; the page is unrotated here
        rx0, ry0, rx1, ry1 = w.rect.x0, h - w.rect.y1, w.rect.x1, h - w.rect.y0
        sx = (rx1 - rx0) / (tx1 - tx0) if tx1 > tx0 else 1
        sy = (ry1 - ry0) / (ty1 - ty0) if ty1 > ty0 else 1
        inv = lambda pt: ((pt[0] - rx0) / sx + tx0, (pt[1] - ry0) / sy + ty0)  # noqa: E731
        content = "% VoucherEditor field crop v1\nq\n" + path_ops(o, inv) + "\nW n\n/VEAP Do\nQ\n"
        wrapper = new_stream(doc, f"<< /Type /XObject /Subtype /Form /BBox [{fmt(tx0)} {fmt(ty0)} {fmt(tx1)} {fmt(ty1)}]"
                                  f" /Resources << /XObject << /VEAP {ap} 0 R >> >> >>", content.encode())
        doc.xref_set_key(w.xref, "AP/N", f"{wrapper} 0 R")
        n += 1
    return n


def open_clip(doc, page) -> None:
    """Option B: the cut's end stream keeps only its marker, so the clip stays open."""
    d = cut.read_cut_dict(doc, page.xref)
    end = int(d["EndRef"][1].split()[0])
    doc.update_stream(end, cut.MARKER + b"\n")


def add_cover(doc, page, o: Outline, subtype: str) -> int:
    """Option C: a non-interactive annotation, last in /Annots, that paints the page
    minus the outline (even-odd) white."""
    x0, y0, x1, y1 = nums(doc, page.xref, "MediaBox")
    content = (f"% VoucherEditor cover v1\n1 g\n{fmt(x0)} {fmt(y0)} {fmt(x1 - x0)} {fmt(y1 - y0)} re\n"
               + to_pdf_path(o) + "\nf*\n")
    box = f"[{fmt(x0)} {fmt(y0)} {fmt(x1)} {fmt(y1)}]"
    ap = new_stream(doc, f"<< /Type /XObject /Subtype /Form /BBox {box} /Resources << >> >>", content.encode())
    # Print 4 + ReadOnly 64 + Locked 128 + LockedContents 512
    annot = new_object(doc, f"<< /Type /Annot /Subtype /{subtype} /Rect {box} /F 708 /AP << /N {ap} 0 R >>"
                            f" /P {page.xref} 0 R /NM (VoucherEditor cover) >>")
    common.append_to_array_key(doc, page.xref, "Annots", [annot])
    return annot


def build_variants(template: Path, o: Outline, names: list[str], cover: str) -> dict[str, Path]:
    OUT.mkdir(parents=True, exist_ok=True)
    out = {}
    for v in names:
        dst = OUT / f"s10_{v}.pdf"
        doc = pymupdf.open(template)
        page = doc[0]
        if cut.read_cut_dict(doc, page.xref) is None:
            cut.apply_cut(doc, 0, o)
        if "A" in v:
            clip_appearances(doc, page, o)
        if "B" in v:
            open_clip(doc, page)
        if "C" in v:
            add_cover(doc, page, o, cover)
        doc.save(dst, garbage=0)
        doc.close()
        out[v] = dst
    return out


# ---------------------------------------------------------------------------
# Measuring
# ---------------------------------------------------------------------------
def render_pdfkit(path: Path) -> np.ndarray | None:
    if not PDFKIT.exists():
        return None
    png = path.with_suffix(".pdfkit.png")
    subprocess.run([str(PDFKIT), str(path), str(png), str(common.DPI)], check=True)
    from PIL import Image
    return np.asarray(Image.open(png).convert("RGB")).copy()


def measure(path: Path, o: Outline, slots: dict, masks: dict, size) -> dict:
    res = {}
    engines = [("MuPDF", lambda: common.render_mupdf(path, annots=True)),
               ("PDFium", lambda: common.render_pdfium(path, forms=True)),
               ("PDFKit", lambda: render_pdfkit(path))]
    for name, fn in engines:
        img = fn()
        if img is None:
            continue
        key = img.shape[:2]
        if key not in masks:
            m = raster_mask(o, size[0], size[1], common.DPI, key)
            masks[key] = (~common.dilate(m, 1), common.erode(m, 2))
        outside, inside = masks[key]
        leak = int((outside & ~(img >= 250).all(axis=2)).sum())
        ink = {}
        s = common.DPI / 72
        for n, (x1, y1, x2, y2) in slots.items():
            sl = (slice(int((size[1] - y2) * s) + 3, int((size[1] - y1) * s) - 3), slice(int(x1 * s) + 3, int(x2 * s) - 3))
            sub = img[sl].astype(int)
            green = (sub[:, :, 1] - np.maximum(sub[:, :, 0], sub[:, :, 2])) > 40
            ins = inside[sl]
            ink[n] = round(float(green[ins].mean()) if ins.any() else 0.0, 2)
        res[name] = {"leak": leak, "ink": ink}
        common.save_png(img, path.with_name(path.stem + f"_{name.lower()}.png"))
    return res


def main() -> None:
    given = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("S10_TEMPLATE")
    swift_mode = bool(os.environ.get("S10_TEMPLATE_IS_SWIFT"))
    # Without an argument: the example template in Tests/Fixtures, cut with EXAMPLE_OUTLINE.
    example = given is None
    # With S10_TEMPLATE_IS_SWIFT=1 and no path: the Swift engine's own cut and cropped output.
    template = Path(given or (common.OUT / "swift" / "swift_crossing_cut.pdf" if swift_mode else EXAMPLE_TEMPLATE)).resolve()
    example = example and not swift_mode
    r = Report(f"S10 crop fields to the outline: {template.name}")
    with pymupdf.open(template) as doc:
        o = cut.read_outline(doc, 0) or EXAMPLE_OUTLINE
        mb = nums(doc, doc[0].xref, "MediaBox")
        size = (mb[2] - mb[0], mb[3] - mb[1])
        widgets = [(w.field_name, w.field_type) for w in doc[0].widgets()]
    names = [n for n, _ in widgets]
    if os.environ.get("S10_IMAGES"):
        images = [n for n in os.environ["S10_IMAGES"].split(",") if n in names]
    else:
        images = [n for n in s9.IMAGES if n in names] or \
                 [n for n, t in widgets if t == pymupdf.PDF_WIDGET_TYPE_BUTTON]
    if os.environ.get("S10_VALUES"):
        values = {k: v for k, v in json.loads(Path(os.environ["S10_VALUES"]).read_text()).items() if k in names}
    elif example:
        values = {n: SAMPLE_TEXT for n, t in widgets if t == pymupdf.PDF_WIDGET_TYPE_TEXT}
    else:
        values = {k: v for k, v in s9.ASCII_VALUES.items() if k in names} or \
                 {n: SAMPLE_TEXT for n, t in widgets if t == pymupdf.PDF_WIDGET_TYPE_TEXT}
    s9.IMAGES[:] = images
    if swift_mode:
        variants = {"swift": template}
    else:
        wanted = os.environ.get("S10_VARIANTS", "base,A,B,C,AC").split(",")
        variants = build_variants(template, o, wanted, os.environ.get("S10_COVER", "Watermark"))
    img = OUT / "s10_sample.png"
    OUT.mkdir(parents=True, exist_ok=True)
    s9.make_image(img)
    masks: dict = {}
    table: dict = {}
    for v, path in variants.items():
        s9.TEMPLATE = path
        exp = s9.expected_fields()
        slots = {n: exp[n][1] for n in images}
        scratch = Report(f"  fill {v}")  # the S9 structural checks; not part of this verdict
        outs = {"unfilled": [path]}
        outs["PyMuPDF"] = s9.fill_pymupdf(values, img, OUT / f"s10_{v}_pymupdf", None, exp)
        # pypdf 6.20 cannot build an appearance for a field whose /Rect holds indirect numbers
        # (two text fields in the development template, an Illustrator/InDesign export): it
        # raises TypeError. That is independent of the crop, so pypdf fills the other fields.
        with pymupdf.open(path) as d:
            direct = {w.field_name for w in d[0].widgets() if d.xref_get_key(w.xref, "Rect")[0] == "array"}
        outs["pypdf"] = s9.fill_pypdf({k: x for k, x in values.items() if k in direct}, img,
                                      OUT / f"s10_{v}_pypdf", scratch, exp)
        outs["pdf-lib"] = s9.fill_pdflib(values, img, OUT / f"s10_{v}_pdflib", "-", None, exp, "-")[0]
        for lib, files in outs.items():
            for f in files:
                kind = "flat" if f.stem.endswith("_flat") else ("unflat" if lib != "unfilled" else "-")
                m = measure(f, o, slots, masks, size)
                table[(v, lib, kind)] = m
                print(f"  {v:6} {lib:8} {kind:6} " + "  ".join(
                    f"{e}: leak {d['leak']:6d} ink {json.dumps(d['ink'])}" for e, d in m.items()))
    (OUT / "s10_results.json").write_text(json.dumps({"|".join(k): v for k, v in table.items()}, indent=1))
    # The chosen design (A + C, what the Swift engine writes) must leave nothing outside the
    # outline, except the known limit: an appearance pdf-lib rebuilds without flattening, which
    # MuPDF and PDFium draw above every other annotation.
    for v in variants:
        if v not in ("AC", "swift"):
            continue
        for (vv, lib, kind), m in table.items():
            if vv != v:
                continue
            for e, d in m.items():
                if (lib, kind) == ("pdf-lib", "unflat") and e in ("MuPDF", "PDFium"):
                    continue
                r.check(d["leak"] == 0, f"{v} {lib} {kind}: {e} blank outside the outline", f"{d['leak']} px")
    # Per variant: what shows outside.
    for v in variants:
        rows = {k: m for k, m in table.items() if k[0] == v}
        leaks = {f"{k[1]}/{k[2]}/{e}": d["leak"] for k, m in rows.items() for e, d in m.items() if d["leak"]}
        r.note(f"{v}: {'no pixel outside the outline in any output' if not leaks else 'painted outside: ' + json.dumps(leaks)}")
    r.finish()


if __name__ == "__main__":
    main()

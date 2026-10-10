"""S9 (automatable part): fill a template saved by the app's write path (S1 fields
plus the S5 cut on page 1: spikes/out/s5f_fields_and_cut.pdf) with the common
filling libraries, unflattened and flattened, and check what code depends on.

Libraries:
  PyMuPDF   widget.field_value + widget.update(); images with page.insert_image at the
            widget rect; flatten with Document.bake().
  pypdf     default (non-strict) reader; PdfWriter.update_page_form_field_values
            (default auto_regenerate, i.e. it also sets /NeedAppearances); images by
            merging an overlay page that draws the image at the rect; flatten=True.
  pdf-lib   node/fill_pdflib.mjs (local npm install in spikes/node): getTextField().setText,
            getButton().setImage, updateFieldAppearances(font), form.flatten().

Checks (hard):
  - each library finds every expected field by name, exactly one widget, the
    expected rect (within 0.01 pt) on page 1, without errors;
  - ASCII text lands inside its field rect (text extraction of the rendered /
    flattened output: every word's bbox within the rect, 1 pt slack);
  - images: there is image ink inside each image slot (not the placeholder grey);
  - the clip is intact: in MuPDF and PDFium renders with annotations, every pixel
    more than 1 px outside the outline is pure white (all fields are inside the outline).

Basic S2 (Romanian diacritics "Țară Ștefan ăâî ĂÂÎ șț ȘȚ" in recipient_name):
  - pdf-lib with a code-supplied Noto Sans (bundled fixture): extraction must
    return the exact string (hard check);
  - pdf-lib with only the template font (/Helv), PyMuPDF widget.update() and
    pypdf's own appearance generation: recorded as notes (S2's job is to choose
    the template encoding; here the template font is base-14 Helvetica);
  - PyMuPDF with a code-supplied font via insert_textbox at the widget rect: hard check.

Run:  ../.venv/bin/python s9_fill.py
"""

from __future__ import annotations

import io
import json
import subprocess
from pathlib import Path

import numpy as np
import pymupdf

import common
from common import Report
from outline import raster_mask, reference_outline

import os
TEMPLATE = Path(os.environ["S9_TEMPLATE"]).resolve() if os.environ.get("S9_TEMPLATE") else common.OUT / "s5f_fields_and_cut.pdf"
NOTO = common.FIXTURES / "NotoSans-Regular.ttf"
NODE_DIR = Path(__file__).resolve().parent / "node"
DIACRITICS = "Țară Ștefan ăâî ĂÂÎ șț ȘȚ"
ASCII_VALUES = {"recipient_name": "Ana Popescu", "valid_until": "31.12.2026", "voucher_code": "VC-2026-01"}
IMAGES = ["photo", "logo"]


def expected_fields() -> dict[str, tuple[str, tuple[float, float, float, float]]]:
    """name -> (type, PDF rect) read from the raw template dictionaries."""
    out = {}
    with pymupdf.open(TEMPLATE) as doc:
        for w in doc[0].widgets():
            kind, val = doc.xref_get_key(w.xref, "Rect")
            try:
                rect = tuple(float(v) for v in val.strip("[]").split())
            except ValueError:  # an indirect /Rect (Illustrator/InDesign exports): use the resolved one
                h = doc[0].mediabox.height
                rect = (w.rect.x0, h - w.rect.y1, w.rect.x1, h - w.rect.y0)
            out[w.field_name] = ("text" if w.field_type == pymupdf.PDF_WIDGET_TYPE_TEXT else "button", rect)
    return out


def make_image(path: Path) -> None:
    h, w = 160, 240
    y, x = np.mgrid[0:h, 0:w]
    rgb = np.dstack([(20 + 60 * x / w), (120 + 100 * y / h), (40 + 0 * x)]).astype(np.uint8)  # green-ish, dark
    common.save_png(rgb, path)


# ---------------------------------------------------------------------------
# Fillers
# ---------------------------------------------------------------------------
def fill_pymupdf(values: dict, img: Path, prefix: Path, r: Report | None, exp,
                 remove_image_widgets: bool = True) -> list[Path]:
    outs = []
    for flatten in (False, True):
        doc = pymupdf.open(TEMPLATE)
        page = doc[0]
        widgets = list(page.widgets())
        names = [w.field_name for w in widgets]
        if not flatten and r is not None:
            ok = sorted(names) == sorted(exp) and len(names) == len(set(names))
            r.check(ok, "PyMuPDF: every field found by name, exactly one widget each", str(names))
            h = page.rect.height
            for w in widgets:
                x1, y1, x2, y2 = exp[w.field_name][1]
                want = (x1, h - y2, x2, h - y1)
                r.check(all(abs(a - b) < 0.01 for a, b in zip(w.rect, want)), f"PyMuPDF: {w.field_name} rect on page 1")
        for w in widgets:
            if w.field_name in values:
                w.field_value = values[w.field_name]
                w.update()
        for w in list(page.widgets()):
            if w.field_name in IMAGES:
                page.insert_image(w.rect, filename=str(img), keep_proportion=True)
                # The image is page content, below annotations: the placeholder appearance would
                # hide it, so the usual recipe removes the image widget once the image is drawn.
                if remove_image_widgets:
                    page.delete_widget(w)
        if flatten:
            doc.bake()
        out = prefix.with_name(prefix.name + ("_flat.pdf" if flatten else "_unflat.pdf"))
        doc.save(out)
        doc.close()
        outs.append(out)
    return outs


def _pypdf_name(a) -> str:
    """Fully qualified field name of a widget or field dictionary (a /Kids widget has no /T)."""
    parts = []
    while a is not None:
        if a.get("/T") is not None:
            parts.append(str(a.get("/T")))
        a = a.get("/Parent").get_object() if a.get("/Parent") is not None else None
    return ".".join(reversed(parts))


def fill_pypdf(values: dict, img: Path, prefix: Path, r: Report, exp) -> list[Path]:
    import logging
    import warnings

    import pypdf

    logs: list[str] = []

    class H(logging.Handler):
        def emit(self, rec):
            logs.append(rec.getMessage())

    logging.getLogger("pypdf").addHandler(H())
    outs = []
    for flatten in (False, True):
        with warnings.catch_warnings(record=True) as wlist:
            warnings.simplefilter("always")
            reader = pypdf.PdfReader(str(TEMPLATE))  # default, non-strict
            fields = reader.get_fields() or {}
            if not flatten:
                r.check(set(fields) == set(exp), "pypdf: get_fields finds every expected name", str(sorted(fields)))
                annots = [a.get_object() for a in reader.pages[0].get("/Annots", [])]
                per_name: dict[str, list] = {}
                for a in annots:
                    if a.get("/Subtype") == "/Widget":
                        per_name.setdefault(_pypdf_name(a), []).append(a)
                r.check(all(len(per_name.get(n, [])) == 1 for n in exp), "pypdf: exactly one widget per name in /Annots")
                for n, lst in per_name.items():
                    if n not in exp:
                        continue
                    rect = tuple(float(v.get_object()) for v in lst[0]["/Rect"])
                    r.check(all(abs(a - b) < 0.01 for a, b in zip(rect, exp[n][1])), f"pypdf: {n} rect")
            writer = pypdf.PdfWriter(clone_from=reader)
            writer.update_page_form_field_values(writer.pages[0], values, flatten=flatten)
            # Images: overlay page drawn with PyMuPDF at each slot rect, merged onto the page.
            ov = pymupdf.open()
            p = ov.new_page(width=float(reader.pages[0].mediabox.width), height=float(reader.pages[0].mediabox.height))
            h = p.rect.height
            for n in IMAGES:
                x1, y1, x2, y2 = exp[n][1]
                p.insert_image(pymupdf.Rect(x1, h - y2, x2, h - y1), filename=str(img), keep_proportion=True)
            overlay = pypdf.PdfReader(io.BytesIO(ov.tobytes()))
            writer.pages[0].merge_page(overlay.pages[0])
            if not flatten:
                # As with PyMuPDF: drop the image widgets so their placeholder does not cover the image.
                page_annots = writer.pages[0]["/Annots"]
                keep = [a for a in page_annots if _pypdf_name(a.get_object()) not in IMAGES]
                writer.pages[0][pypdf.generic.NameObject("/Annots")] = pypdf.generic.ArrayObject(keep)
                af = writer._root_object["/AcroForm"]
                af[pypdf.generic.NameObject("/Fields")] = pypdf.generic.ArrayObject(
                    [f for f in af["/Fields"] if _pypdf_name(f.get_object()) not in IMAGES])
            if flatten:
                # pypdf's flatten=True writes the appearances into the content; drop the widgets as flattening does.
                writer.remove_annotations(subtypes="/Widget")
            out = prefix.with_name(prefix.name + ("_flat.pdf" if flatten else "_unflat.pdf"))
            with open(out, "wb") as f:
                writer.write(f)
            outs.append(out)
        noise = [str(w.message) for w in wlist] + logs
        known = [m for m in noise if m.startswith("Object count") and "exceeds defined trailer size" in m]
        if known:
            r.note(f"pypdf known warning on PdfWriter(clone_from=...): {known[0]} (caused by the cut's /PieceInfo refs)")
        noise = [m for m in noise if m not in known]
        r.check(not noise, f"pypdf ({'flatten' if flatten else 'unflattened'}): no warnings or log messages",
                "; ".join(noise[:3]))
        logs.clear()
    return outs


def fill_pdflib(values: dict, img: Path, prefix: Path, font: str, r: Report | None, exp, label: str):
    vals = prefix.with_name(prefix.name + "_values.json")
    vals.write_text(json.dumps({"text": values, "image": IMAGES}))
    res = subprocess.run(["node", str(NODE_DIR / "fill_pdflib.mjs"), str(TEMPLATE), str(prefix), font, str(img), str(vals)],
                         capture_output=True, text=True, cwd=NODE_DIR)
    rep = json.loads(res.stdout or "{}")
    if r is not None:
        fields = rep.get("fields", {})
        r.check(set(fields) == set(exp), f"pdf-lib ({label}): every field found by name", str(sorted(fields)))
        for n, f in fields.items():
            ok = f["widgets"] == 1 and f["page"] == [0] and all(abs(a - b) < 0.01 for a, b in zip(f["rect"][0], exp[n][1]))
            r.check(ok, f"pdf-lib ({label}): {n} one widget, page 1, expected rect", str(f))
        r.check(not rep.get("errors") and res.returncode == 0, f"pdf-lib ({label}): no errors",
                "; ".join(rep.get("errors", []))[:300] + res.stderr[:200])
        r.check(not rep.get("warnings"), f"pdf-lib ({label}): no warnings", "; ".join(rep.get("warnings", []))[:300])
    return [Path(p) for p in rep.get("outputs", [])], rep


# ---------------------------------------------------------------------------
# Output checks
# ---------------------------------------------------------------------------
def text_in_rect(path: Path, name: str, rect, want: str) -> tuple[bool, str]:
    """Words drawn for a field (page content or widget appearance) lie inside the rect.

    Widget appearances are not part of page.get_text(), so the page is flattened
    in memory first (bake), then words are extracted."""
    doc = pymupdf.open(path)
    doc.bake()
    page = doc[0]
    h = page.rect.height
    x1, y1, x2, y2 = rect
    clip = pymupdf.Rect(x1 - 1, h - y2 - 1, x2 + 1, h - y1 + 1)
    words = [w for w in page.get_text("words") if pymupdf.Rect(w[:4]).intersects(clip)]
    text = " ".join(w[4] for w in words)
    inside = all(pymupdf.Rect(w[:4]) in clip for w in words)
    doc.close()
    return (text == want and inside), f"extracted={text!r} inside={inside}"


def image_ink(img: np.ndarray, rect, page_h: float) -> float:
    s = common.DPI / 72
    x1, y1, x2, y2 = rect
    sub = img[int((page_h - y2) * s) + 3:int((page_h - y1) * s) - 3, int(x1 * s) + 3:int(x2 * s) - 3].astype(int)
    # the sample image is green-dominant; placeholder is neutral grey
    green = (sub[:, :, 1] - np.maximum(sub[:, :, 0], sub[:, :, 2])) > 40
    return float(green.mean())


def check_output(path: Path, lib: str, values: dict, exp, r: Report, mask_cache: dict, check_text: set[str]) -> None:
    for n in check_text:
        ok, detail = text_in_rect(path, n, exp[n][1], values[n])
        r.check(ok, f"{lib} {path.stem}: {n} text inside its rect", detail)
    o = reference_outline()
    for engine, img in [("MuPDF", common.render_mupdf(path, annots=True)), ("PDFium", common.render_pdfium(path, forms=True))]:
        key = img.shape[:2]
        if key not in mask_cache:
            mask_cache[key] = raster_mask(o, 842, 595, common.DPI, key)
        outside = ~common.dilate(mask_cache[key], 1)
        leak = int((outside & ~(img == 255).all(axis=2)).sum())
        r.check(leak == 0, f"{lib} {path.stem}: {engine} blank outside the outline", f"{leak} px painted outside")
        for n in IMAGES:
            ink = image_ink(img, exp[n][1], 595)
            r.check(ink > 0.3, f"{lib} {path.stem}: {engine} image drawn in {n}", f"{ink:.2f} of slot")
        common.save_png(img, common.OUT / f"s9_{path.stem}_{engine.lower()}.png")


def main() -> None:
    r = Report("S9 programmatic fill: PyMuPDF, pypdf, pdf-lib on the S5f template (fields + cut)")
    if not TEMPLATE.exists():
        raise SystemExit("run s5_cut.py first (needs spikes/out/s5f_fields_and_cut.pdf)")
    exp = expected_fields()
    img = common.ensure_out() / "s9_sample.png"
    make_image(img)
    masks: dict = {}

    # 1. ASCII values: the structural and placement checks for all three libraries.
    outs = {
        "PyMuPDF": fill_pymupdf(ASCII_VALUES, img, common.OUT / "s9_pymupdf", r, exp),
        "pypdf": fill_pypdf(ASCII_VALUES, img, common.OUT / "s9_pypdf", r, exp),
        "pdf-lib": fill_pdflib(ASCII_VALUES, img, common.OUT / "s9_pdflib", "-", r, exp, "template font")[0],
    }
    for lib, files in outs.items():
        for f in files:
            check_output(f, lib, ASCII_VALUES, exp, r, masks, set(ASCII_VALUES))

    # 1b. Unflattened fill that keeps the image widgets: is the drawn image visible?
    keep = fill_pymupdf(ASCII_VALUES, img, common.OUT / "s9_pymupdf_keepwidgets", None, exp, remove_image_widgets=False)[0]
    shot = common.render_mupdf(keep, annots=True)
    r.note("PyMuPDF insert_image while keeping the image widget: image visible in slot = "
           f"{image_ink(shot, exp['photo'][1], 595):.2f} (0 = hidden by the opaque placeholder appearance)")

    # 2. Basic S2: diacritics.
    dvals = dict(ASCII_VALUES, recipient_name=DIACRITICS)
    files, rep = fill_pdflib(dvals, img, common.OUT / "s9_pdflib_noto", str(NOTO), r, exp, "code-supplied Noto Sans")
    for f in files:
        check_output(f, "pdf-lib+Noto", dvals, exp, r, masks, set(dvals))
    _, rep = fill_pdflib(dvals, img, common.OUT / "s9_pdflib_helv_dia", "-", None, exp, "template font")
    r.note(f"S2 pdf-lib, template font (/Helv) with diacritics: errors={rep.get('errors')}")

    doc = pymupdf.open(TEMPLATE)
    for w in doc[0].widgets():
        if w.field_name == "recipient_name":
            w.field_value = DIACRITICS
            w.update()
    p = common.OUT / "s9_pymupdf_dia_unflat.pdf"
    doc.save(p)
    doc.close()
    ok, detail = text_in_rect(p, "recipient_name", exp["recipient_name"][1], DIACRITICS)
    r.note(f"S2 PyMuPDF widget.update() with the template font: exact={ok} {detail}")

    doc = pymupdf.open(TEMPLATE)
    page = doc[0]
    w = next(w for w in page.widgets() if w.field_name == "recipient_name")
    rect = w.rect
    page.delete_widget(w)
    page.insert_font(fontname="noto", fontfile=str(NOTO))
    rc = page.insert_textbox(rect + (4, 8, -4, 0), DIACRITICS, fontname="noto", fontsize=14)
    p = common.OUT / "s9_pymupdf_noto_drawn.pdf"
    doc.save(p)
    doc.close()
    ok, detail = text_in_rect(p, "recipient_name", exp["recipient_name"][1], DIACRITICS)
    r.check(ok and rc >= 0, "S2 PyMuPDF with a code-supplied Noto Sans (insert_textbox at the widget rect): exact text", detail)

    import pypdf
    reader = pypdf.PdfReader(str(TEMPLATE))
    writer = pypdf.PdfWriter(clone_from=reader)
    try:
        writer.update_page_form_field_values(writer.pages[0], {"recipient_name": DIACRITICS}, flatten=True)
        p = common.OUT / "s9_pypdf_dia_flat.pdf"
        with open(p, "wb") as f:
            writer.write(f)
        ok, detail = text_in_rect(p, "recipient_name", exp["recipient_name"][1], DIACRITICS)
        r.note(f"S2 pypdf appearance generation with the template font (/Helv): exact={ok} {detail}")
    except Exception as e:  # noqa: BLE001
        r.note(f"S2 pypdf with diacritics raised {type(e).__name__}: {e}")

    r.note("Not verified: Preview, Chrome UI and Acrobat views of the filled outputs (spikes/out/s9_*.pdf).")
    r.finish()


if __name__ == "__main__":
    main()

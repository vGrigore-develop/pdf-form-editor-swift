"""S1 (MuPDF side): add 3 text fields and 2 image fields with the low-level object
API and an incremental save, then verify the result with independent readers.

Field dictionaries follow SPEC 6.1: merged field/widget, flat names, /P, /F 4,
listed in the page's /Annots and in /AcroForm /Fields, minimal /DA, the font in
/AcroForm /DR, and a stored /AP /N for every widget (no /NeedAppearances).

Font: S1 is about the writer, not encodings, so the base-14 Helvetica (/Helv) is
used in /DR. The Noto Sans embedding and encoding choice is S2.

Run:  ../.venv/bin/python s1_fields.py [input.pdf]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import pymupdf

import common
from common import Report, new_object, new_stream, pdf_string, ref

FONT_NAME = "Helv"  # plain ASCII resource name, as 6.1 requires


# ---------------------------------------------------------------------------
# Field definitions (rects in PDF user space, origin bottom-left)
# ---------------------------------------------------------------------------
TEXT_FIELDS = [
    dict(name="recipient_name", rect=(422, 377, 778, 413), size=14, color=(0.1, 0.1, 0.1), q=0, tooltip="Recipient name"),
    dict(name="valid_until", rect=(422, 317, 778, 353), size=12, color=(0.1, 0.1, 0.1), q=0, tooltip="Valid until"),
    dict(name="voucher_code", rect=(422, 257, 638, 293), size=12, color=(0.6, 0.1, 0.1), q=1, tooltip="Voucher code",
         maxlen=10),
]
IMAGE_FIELDS = [
    dict(name="photo", rect=(110, 295, 350, 455), tooltip="Photo", js=True,
         fit=dict(SW="A", S="P", A=(0.5, 0.5), FB=False)),
    dict(name="logo", rect=(150, 60, 300, 130), tooltip="Logo", js=False,
         fit=dict(SW="B", S="P", A=(0.0, 0.5), FB=True)),
]
IMPORT_ICON_JS = "event.target.buttonImportIcon();"


def fmt(v: float) -> str:
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return s if s not in ("", "-0") else "0"


def rgb(c) -> str:
    return " ".join(fmt(x) for x in c)


# ---------------------------------------------------------------------------
# Appearance streams (empty-field appearances: background and border only for
# text; background, border and a label for the image placeholder)
# ---------------------------------------------------------------------------
def text_ap(w: float, h: float, bg, border, bw: float = 1.0) -> bytes:
    return (
        f"q {rgb(bg)} rg 0 0 {fmt(w)} {fmt(h)} re f Q\n"
        f"q {rgb(border)} RG {fmt(bw)} w {fmt(bw / 2)} {fmt(bw / 2)} {fmt(w - bw)} {fmt(h - bw)} re S Q\n"
        f"/Tx BMC EMC\n"
    ).encode()


def image_placeholder_ap(w: float, h: float, label: str, bg, border) -> bytes:
    size = 9
    # Helvetica average width ~0.5 em is enough for centring a placeholder label.
    tw = len(label) * size * 0.5
    return (
        f"q {rgb(bg)} rg 0 0 {fmt(w)} {fmt(h)} re f Q\n"
        f"q {rgb(border)} RG 1 w [3 2] 0 d 0.5 0.5 {fmt(w - 1)} {fmt(h - 1)} re S Q\n"
        f"q BT /{FONT_NAME} {size} Tf 0.35 0.35 0.35 rg {fmt((w - tw) / 2)} {fmt(h / 2 - size / 3)} Td "
        f"{pdf_string(label)} Tj ET Q\n"
    ).encode()


def ap_stream(doc, w, h, data: bytes, font_xref: int) -> int:
    return new_stream(
        doc,
        f"<< /Type /XObject /Subtype /Form /BBox [0 0 {fmt(w)} {fmt(h)}] "
        f"/Resources << /Font << /{FONT_NAME} {ref(font_xref)} >> >> >>",
        data,
    )


# ---------------------------------------------------------------------------
# AcroForm plumbing (key-level)
# ---------------------------------------------------------------------------
def ensure_acroform(doc: pymupdf.Document) -> tuple[int, int]:
    """Return (acroform_xref, font_xref). Creates /AcroForm if missing; otherwise
    edits only /Fields, /DR /Font /Helv and (if missing) /DA."""
    cat = doc.pdf_catalog()
    kind, value = doc.xref_get_key(cat, "AcroForm")
    font_xref = new_object(doc, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    if kind == "null":
        af = new_object(
            doc,
            f"<< /Fields [] /DR << /Font << /{FONT_NAME} {ref(font_xref)} >> >> /DA (/{FONT_NAME} 12 Tf 0 0 0 rg) >>",
        )
        doc.xref_set_key(cat, "AcroForm", ref(af))
        return af, font_xref
    if kind != "xref":
        # A direct /AcroForm dict: promote it to an object so later edits stay key-level.
        af = new_object(doc, value)
        doc.xref_set_key(cat, "AcroForm", ref(af))
    else:
        af = int(value.split()[0])
    dr_x, dr_p = common.ensure_dict_key(doc, af, "DR")
    font_holder, font_prefix = common.ensure_dict_key(doc, dr_x, dr_p + "Font")
    if doc.xref_get_key(font_holder, font_prefix + FONT_NAME)[0] == "null":
        doc.xref_set_key(font_holder, font_prefix + FONT_NAME, ref(font_xref))
    if doc.xref_get_key(af, "DA")[0] == "null":
        doc.xref_set_key(af, "DA", f"(/{FONT_NAME} 12 Tf 0 0 0 rg)")
    return af, font_xref


def add_text_field(doc, page, f, font_xref) -> int:
    x1, y1, x2, y2 = f["rect"]
    w, h = x2 - x1, y2 - y1
    bg, border = (1, 1, 1), (0.45, 0.35, 0.25)
    ap = ap_stream(doc, w, h, text_ap(w, h, bg, border), font_xref)
    parts = [
        "/Type /Annot /Subtype /Widget /FT /Tx",
        f"/T {pdf_string(f['name'])} /TU {pdf_string(f['tooltip'])}",
        f"/Rect [{fmt(x1)} {fmt(y1)} {fmt(x2)} {fmt(y2)}] /P {ref(page.xref)} /F 4",
        f"/DA (/{FONT_NAME} {fmt(f['size'])} Tf {rgb(f['color'])} rg) /Q {f['q']}",
        f"/MK << /BC [{rgb(border)}] /BG [{rgb(bg)}] >> /BS << /W 1 /S /S >>",
        f"/AP << /N {ref(ap)} >>",
    ]
    if "maxlen" in f:
        parts.append(f"/MaxLen {f['maxlen']}")
    return new_object(doc, "<< " + " ".join(parts) + " >>")


def add_image_field(doc, page, f, font_xref) -> int:
    x1, y1, x2, y2 = f["rect"]
    w, h = x2 - x1, y2 - y1
    bg, border = (0.92, 0.92, 0.92), (0.5, 0.5, 0.5)
    ap = ap_stream(doc, w, h, image_placeholder_ap(w, h, "Click to add image", bg, border), font_xref)
    fit = f["fit"]
    if_dict = (
        f"<< /SW /{fit['SW']} /S /{fit['S']} /A [{fmt(fit['A'][0])} {fmt(fit['A'][1])}] "
        f"/FB {'true' if fit['FB'] else 'false'} >>"
    )
    parts = [
        "/Type /Annot /Subtype /Widget /FT /Btn /Ff 65536",
        f"/T {pdf_string(f['name'])} /TU {pdf_string(f['tooltip'])}",
        f"/Rect [{fmt(x1)} {fmt(y1)} {fmt(x2)} {fmt(y2)}] /P {ref(page.xref)} /F 4",
        f"/DA (/{FONT_NAME} 0 Tf 0 0 0 rg)",
        f"/MK << /TP 1 /IF {if_dict} /BG [{rgb(bg)}] /BC [{rgb(border)}] >>",
        f"/AP << /N {ref(ap)} >>",
    ]
    if f["js"]:
        # Mouse-up activation action, as Acrobat's "Add Image" writes it (to be
        # confirmed against a real Acrobat-made field in S4).
        parts.append(f"/A << /S /JavaScript /JS {pdf_string(IMPORT_ICON_JS)} >>")
    return new_object(doc, "<< " + " ".join(parts) + " >>")


def add_fields(path: Path) -> list[int]:
    doc = pymupdf.open(path)
    page = doc[0]
    af, font_xref = ensure_acroform(doc)
    xrefs = [add_text_field(doc, page, f, font_xref) for f in TEXT_FIELDS]
    xrefs += [add_image_field(doc, page, f, font_xref) for f in IMAGE_FIELDS]
    common.append_to_array_key(doc, page.xref, "Annots", xrefs)
    common.append_to_array_key(doc, af, "Fields", xrefs)
    common.save_incremental(doc)
    doc.close()
    return xrefs


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
def appended_objects(original: Path, updated: Path) -> list[int]:
    tail = updated.read_bytes()[original.stat().st_size:]
    return sorted({int(m.group(1)) for m in re.finditer(rb"(?m)^(\d+) 0 obj", tail)})


def verify(original: Path, out: Path, r: Report) -> None:
    r.check(common.is_prefix(original, out), "original bytes are an exact prefix of the output")
    ok, issues = common.qpdf_check(out)
    r.check(ok, "libqpdf syntax check clean (pikepdf check_pdf_syntax, stands in for qpdf --check)",
            "; ".join(issues[:5]))
    objs = appended_objects(original, out)
    r.note(f"objects in the incremental section: {objs}")

    expected = {f["name"] for f in TEXT_FIELDS + IMAGE_FIELDS}

    # --- MuPDF reader
    with pymupdf.open(out) as doc:
        r.check(not doc.is_repaired, "MuPDF opens without repair")
        cat = doc.pdf_catalog()
        af = int(doc.xref_get_key(cat, "AcroForm")[1].split()[0])
        r.check(doc.xref_get_key(af, "NeedAppearances")[0] == "null", "no /NeedAppearances written")
        widgets = list(doc[0].widgets())
        names = [w.field_name for w in widgets]
        r.check(sorted(names) == sorted(expected) and len(names) == len(set(names)),
                "MuPDF: exactly one widget per expected field name", str(names))
        for w in widgets:
            want_type = pymupdf.PDF_WIDGET_TYPE_TEXT if w.field_name in {f["name"] for f in TEXT_FIELDS} \
                else pymupdf.PDF_WIDGET_TYPE_BUTTON
            r.check(w.field_type == want_type, f"MuPDF: {w.field_name} type", w.field_type_string)
        for f in IMAGE_FIELDS:
            x = next(w.xref for w in widgets if w.field_name == f["name"])
            mk_tp = doc.xref_get_key(x, "MK/TP")[1]
            if_sw = doc.xref_get_key(x, "MK/IF/SW")[1]
            ff = doc.xref_get_key(x, "Ff")[1]
            js_kind, js = doc.xref_get_key(x, "A/JS")
            r.check(ff == "65536" and mk_tp == "1" and if_sw == f"/{f['fit']['SW']}",
                    f"{f['name']}: /Ff 65536, /MK /TP 1 and /MK /IF present", f"Ff={ff} TP={mk_tp} SW={if_sw}")
            if f["js"]:
                r.check(js_kind == "string" and js == IMPORT_ICON_JS, f"{f['name']}: buttonImportIcon JS action present", js)
            else:
                r.check(js_kind == "null", f"{f['name']}: no JS when the toggle is off")
        for f in TEXT_FIELDS + IMAGE_FIELDS:
            w = next(w for w in widgets if w.field_name == f["name"])
            x1, y1, x2, y2 = f["rect"]
            h = doc[0].rect.height
            want = pymupdf.Rect(x1, h - y2, x2, h - y1)  # MuPDF reports top-left coordinates
            r.check(all(abs(a - b) < 0.01 for a, b in zip(w.rect, want)),
                    f"MuPDF: {f['name']} rect", str(w.rect))

    # --- pypdf reader (independent pure-Python parser)
    import pypdf

    reader = pypdf.PdfReader(str(out), strict=True)
    fields = reader.get_fields() or {}
    r.check(set(fields) == expected, "pypdf: get_fields finds exactly the expected names", str(sorted(fields)))
    annots = [a.get_object() for a in reader.pages[0].get("/Annots", [])]
    r.check(sum(1 for a in annots if a.get("/Subtype") == "/Widget") == 5, "pypdf: 5 widgets in page /Annots")
    r.check(all(a.get("/P").get_object() == reader.pages[0].get_object() for a in annots), "pypdf: every widget /P is page 1")

    # --- PDFium (Chrome's engine): form field hit-testing and rendering
    import pypdfium2 as pdfium
    import pypdfium2.raw as raw

    pdf = pdfium.PdfDocument(str(out))
    pdf.init_forms()
    page = pdf[0]
    want_types = {**{f["name"]: raw.FPDF_FORMFIELD_TEXTFIELD for f in TEXT_FIELDS},
                  **{f["name"]: raw.FPDF_FORMFIELD_PUSHBUTTON for f in IMAGE_FIELDS}}
    for f in TEXT_FIELDS + IMAGE_FIELDS:
        x1, y1, x2, y2 = f["rect"]
        t = raw.FPDFPage_HasFormFieldAtPoint(pdf.formenv.raw, page.raw, (x1 + x2) / 2, (y1 + y2) / 2)
        r.check(t == want_types[f["name"]], f"PDFium: form field of the right type at {f['name']} centre", f"type={t}")
    pdf.close()

    # Renders with widgets, for eyeballing
    common.save_png(common.render_mupdf(out, annots=True), common.OUT / "s1_mupdf.png")
    common.save_png(common.render_pdfium(out, forms=True), common.OUT / "s1_pdfium.png")
    r.note("renders written to spikes/out/s1_mupdf.png and spikes/out/s1_pdfium.png")

    # The placeholder background must be visible in both engines at the photo centre.
    for engine, img in [("MuPDF", common.render_mupdf(out, annots=True)), ("PDFium", common.render_pdfium(out, forms=True))]:
        x1, y1, x2, y2 = IMAGE_FIELDS[0]["rect"]
        s = common.DPI / 72
        px = img[int((595 - (y1 + y2) / 2 + 20) * s), int((x1 + x2) / 2 * s)]
        r.check(all(abs(int(c) - 235) <= 3 for c in px), f"{engine}: image placeholder appearance drawn", str(px))


def main() -> None:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else common.FIXTURES / "synthetic_voucher.pdf"
    out = common.fresh_copy(src, common.ensure_out() / "s1_fields.pdf")
    r = Report("S1 MuPDF writer: 3 text + 2 image fields, incremental")
    add_fields(out)
    verify(src, out, r)
    r.note("Not verified here: editing in Preview, Chrome UI and Acrobat Reader; PDFKit control output.")
    r.finish()


if __name__ == "__main__":
    main()

"""Shared helpers for the M0 spikes.

Everything here is deliberately small and explicit so it can be ported to the
C shim (MuPDF object API) and Swift later. PyMuPDF's xref_* methods map almost
1:1 onto pdf_dict_put / pdf_new_indirect / pdf_update_stream in C.
"""

from __future__ import annotations

import datetime
import re
import os
import shutil
import sys
from pathlib import Path

import numpy as np
import pymupdf

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "Tests" / "Fixtures"
OUT = REPO / "spikes" / "out"

DPI = 150


# ---------------------------------------------------------------------------
# Small reporting helper: every spike prints PASS/FAIL lines and exits non-zero
# on any failure, so the scripts can later run as regression tests.
# ---------------------------------------------------------------------------
class Report:
    def __init__(self, name: str):
        self.name = name
        self.failures: list[str] = []
        self.notes: list[str] = []
        print(f"=== {name} ===")

    def check(self, ok: bool, label: str, detail: str = "") -> bool:
        tag = "PASS" if ok else "FAIL"
        print(f"  [{tag}] {label}" + (f"  ({detail})" if detail else ""))
        if not ok:
            self.failures.append(label)
        return ok

    def note(self, text: str) -> None:
        print(f"  [note] {text}")
        self.notes.append(text)

    def finish(self) -> None:
        if self.failures:
            print(f"--- {self.name}: {len(self.failures)} failure(s)")
            for f in self.failures:
                print(f"    - {f}")
            sys.exit(1)
        print(f"--- {self.name}: all checks passed")


# ---------------------------------------------------------------------------
# PDF object helpers (key-level edits only, never whole-dictionary rewrites)
# ---------------------------------------------------------------------------
def pdf_date() -> str:
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("D:%Y%m%d%H%M%SZ")


def pdf_string(text: str) -> str:
    """Literal string for ASCII text; UTF-16BE hex with BOM otherwise (7.6)."""
    try:
        text.encode("ascii")
    except UnicodeEncodeError:
        return "<FEFF" + text.encode("utf-16-be").hex().upper() + ">"
    esc = text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    return f"({esc})"


def new_object(doc: pymupdf.Document, source: str) -> int:
    xref = doc.get_new_xref()
    doc.update_object(xref, source)
    return xref


def new_stream(doc: pymupdf.Document, dict_source: str, data: bytes, compress: bool = True) -> int:
    xref = new_object(doc, dict_source)
    doc.update_stream(xref, data, new=True, compress=compress)
    return xref


def ref(xref: int) -> str:
    return f"{xref} 0 R"


def parse_ref_array(value: str) -> list[int]:
    """'[12 0 R 13 0 R]' -> [12, 13]."""
    return [int(m) for m in re.findall(r"(\d+)\s+\d+\s+R", value)]


def append_to_array_key(doc: pymupdf.Document, holder_xref: int, key: str, refs: list[int]) -> None:
    """Append indirect refs to an array-valued key.

    If the key holds an indirect ref to an array object, that array object is
    updated (so other holders keep seeing it); otherwise the key's direct array
    is replaced by the extended copy. Either way only one key/object changes.
    """
    kind, value = doc.xref_get_key(holder_xref, key)
    addition = " ".join(ref(x) for x in refs)
    if kind == "xref":
        arr_xref = int(value.split()[0])
        body = doc.xref_object(arr_xref, compressed=True).strip()
        assert body.startswith("[") and body.endswith("]"), body
        doc.update_object(arr_xref, body[:-1] + " " + addition + "]")
    elif kind == "array":
        doc.xref_set_key(holder_xref, key, value.strip()[:-1] + " " + addition + "]")
    else:
        doc.xref_set_key(holder_xref, key, f"[{addition}]")


def ensure_dict_key(doc: pymupdf.Document, holder_xref: int, key: str) -> tuple[int, str]:
    """Return (xref, path_prefix) addressing a sub-dictionary for key-level edits.

    If holder[key] is an indirect dict, edits go to that object directly;
    if it is a direct dict, edits use the 'key/sub' path on the holder;
    if it is missing, an empty direct dict is created.
    """
    kind, value = doc.xref_get_key(holder_xref, key)
    if kind == "xref":
        return int(value.split()[0]), ""
    if kind != "dict":
        doc.xref_set_key(holder_xref, key, "<<>>")
    return holder_xref, key + "/"


# ---------------------------------------------------------------------------
# File helpers
# ---------------------------------------------------------------------------
def fresh_copy(src: Path, dst: Path) -> Path:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    return dst


def save_incremental(doc: pymupdf.Document) -> None:
    doc.save(doc.name, incremental=True, encryption=pymupdf.PDF_ENCRYPT_KEEP)


def is_prefix(original: Path, updated: Path) -> bool:
    a = original.read_bytes()
    b = updated.read_bytes()
    return len(b) > len(a) and b[: len(a)] == a


def qpdf_check(path: Path) -> tuple[bool, list[str]]:
    """Structural check with libqpdf (via pikepdf); stands in for `qpdf --check`."""
    import pikepdf

    with pikepdf.open(path) as pdf:
        problems = list(pdf.check_pdf_syntax())
        warnings = list(pdf.get_warnings())
    issues = problems + warnings
    return (not issues), issues


# ---------------------------------------------------------------------------
# Rendering: MuPDF and PDFium, both to greyscale-free RGB uint8 arrays
# ---------------------------------------------------------------------------
def render_mupdf(path: Path, page_no: int = 0, dpi: int = DPI, annots: bool = False) -> np.ndarray:
    with pymupdf.open(path) as doc:
        pix = doc[page_no].get_pixmap(dpi=dpi, annots=annots, alpha=False, colorspace=pymupdf.csRGB)
        arr = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, pix.n)
        return arr[:, :, :3].copy()


def render_pdfium(path: Path, page_no: int = 0, dpi: int = DPI, forms: bool = False) -> np.ndarray:
    """Render with PDFium at an exact scale.

    pypdfium2's high-level render() picks an integer bitmap size and stretches the
    page to fill it, which skews the scale by up to ~0.1 % (0.8 px at the right
    edge of an 842 pt page at 150 DPI). Here the bitmap is sized like MuPDF's
    (rounded out) and the page is drawn with an exact scale matrix, so both
    engines share one pixel grid.
    """
    import ctypes
    import math

    import pypdfium2 as pdfium
    import pypdfium2.raw as raw

    pdf = pdfium.PdfDocument(str(path))
    try:
        if forms:
            pdf.init_forms()  # formenv stays None when the file has no AcroForm
        page = pdf[page_no]
        s = dpi / 72.0
        pw, ph = page.get_size()
        w, h = math.ceil(pw * s - 1e-6), math.ceil(ph * s - 1e-6)
        bmp = raw.FPDFBitmap_Create(w, h, 0)
        raw.FPDFBitmap_FillRect(bmp, 0, 0, w, h, 0xFFFFFFFF)
        matrix = raw.FS_MATRIX(s, 0, 0, s, 0, 0)
        clip = raw.FS_RECTF(0, 0, w, h)
        flags = raw.FPDF_ANNOT if forms else 0
        raw.FPDF_RenderPageBitmapWithMatrix(bmp, page.raw, ctypes.byref(matrix), ctypes.byref(clip), flags)
        if forms and pdf.formenv is not None:
            raw.FPDF_FFLDraw(pdf.formenv.raw, bmp, page.raw, 0, 0, w, h, 0, flags)
        stride = raw.FPDFBitmap_GetStride(bmp)
        buf = ctypes.cast(raw.FPDFBitmap_GetBuffer(bmp), ctypes.POINTER(ctypes.c_ubyte * (stride * h))).contents
        arr = np.frombuffer(buf, dtype=np.uint8).reshape(h, stride)[:, : w * 4].reshape(h, w, 4)
        out = arr[:, :, 2::-1].copy()  # BGRA -> RGB
        raw.FPDFBitmap_Destroy(bmp)
        return out
    finally:
        pdf.close()


def crop_common(a: np.ndarray, b: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    h = min(a.shape[0], b.shape[0])
    w = min(a.shape[1], b.shape[1])
    return a[:h, :w], b[:h, :w]


def save_png(arr: np.ndarray, path: Path) -> None:
    from PIL import Image

    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(arr).save(path)


# ---------------------------------------------------------------------------
# Binary mask morphology (no scipy dependency)
# ---------------------------------------------------------------------------
def dilate(mask: np.ndarray, r: int) -> np.ndarray:
    """Square (Chebyshev) dilation: "within r px" includes diagonal neighbours."""
    out = mask.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            out |= np.roll(np.roll(mask, dy, axis=0), dx, axis=1)
    return out


def erode(mask: np.ndarray, r: int) -> np.ndarray:
    return ~dilate(~mask, r)


def ensure_out() -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    return OUT


if __name__ == "__main__":
    print(REPO, FIXTURES, OUT, os.getcwd())

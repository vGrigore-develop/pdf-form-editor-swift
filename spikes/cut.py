"""Shape cut (SPEC 5.2-5.4): apply, re-edit, remove, read back.

Wrap mode:     page /Contents := [cutStart, <original streams>, cutEnd]
               cutStart = "q <path> W n q", cutEnd = "Q Q"
XObject mode:  used when the original content has unbalanced q/Q.
               page /Contents  := cutStart = "q <path> W n /VEOrig Do Q"
               page /Resources := << /XObject << /VEOrig <form> >> >>
               the form holds the original content (raw-copied when there is a
               single stream) and the original /Resources.

Every edit is key-level on the page dictionary (/Contents, /Resources,
/PieceInfo, /LastModified); original content stream objects are never touched.
All state lives in /PieceInfo /VoucherEditor /Private /Cut.
"""

from __future__ import annotations

import re

import pymupdf

import common
from common import new_object, new_stream, pdf_date, ref
from outline import Outline, fmt, segments_from_pdf_array, segments_to_pdf_array, to_pdf_path

MARKER = b"% VoucherEditor cut v1"
XOBJ_NAME = "VEOrig"
CUT_PATH = "PieceInfo/VoucherEditor/Private/Cut"


# ---------------------------------------------------------------------------
# q/Q balance check: a small content tokenizer (strings, comments, hex strings,
# dicts/arrays, inline images). In the C shim this becomes a pdf_processor that
# counts q/Q via MuPDF's own content lexer.
# ---------------------------------------------------------------------------
WS = b" \t\r\n\f\x00"
DELIM = b"()<>[]{}/%"


def q_balance(data: bytes) -> tuple[int, int]:
    """Return (minimum depth reached, final depth). Balanced means (0, 0)."""
    i, n = 0, len(data)
    depth = min_depth = 0
    while i < n:
        c = data[i:i + 1]
        if c in (b"",) or c[0] in WS:
            i += 1
        elif c == b"%":
            while i < n and data[i] not in b"\r\n":
                i += 1
        elif c == b"(":
            lvl, i = 1, i + 1
            while i < n and lvl:
                ch = data[i]
                if ch == 0x5C:  # backslash escape
                    i += 2
                    continue
                if ch == 0x28:
                    lvl += 1
                elif ch == 0x29:
                    lvl -= 1
                i += 1
        elif data.startswith(b"<<", i) or data.startswith(b">>", i):
            i += 2
        elif c == b"<":
            j = data.find(b">", i)
            i = n if j < 0 else j + 1
        elif c in (b"[", b"]", b"{", b"}"):
            i += 1
        elif c == b"/":
            i += 1
            while i < n and data[i] not in WS and data[i] not in DELIM:
                i += 1
        else:
            j = i
            while j < n and data[j] not in WS and data[j] not in DELIM:
                j += 1
            tok = data[i:j]
            i = max(j, i + 1)
            if tok == b"q":
                depth += 1
            elif tok == b"Q":
                depth -= 1
                min_depth = min(min_depth, depth)
            elif tok == b"ID":
                # inline image data: skip one whitespace byte, then find "EI" between whitespace
                i += 1
                m = re.compile(rb"[\s]EI(?=[\s]|$)").search(data, i)
                i = n if m is None else m.end()
    return min_depth, depth


def is_balanced(data: bytes) -> bool:
    return q_balance(data) == (0, 0)


# ---------------------------------------------------------------------------
# Page /Contents helpers
# ---------------------------------------------------------------------------
def contents_value(doc, page_xref) -> tuple[str, str]:
    """(kind, value) of page /Contents exactly as stored: 'xref' or 'array'."""
    return doc.xref_get_key(page_xref, "Contents")


def content_stream_xrefs(doc, page_xref) -> list[int]:
    kind, value = contents_value(doc, page_xref)
    if kind == "xref":
        x = int(value.split()[0])
        if doc.xref_is_stream(x):
            return [x]
        return common.parse_ref_array(doc.xref_object(x, compressed=True))  # indirect array
    if kind == "array":
        return common.parse_ref_array(value)
    return []


def concatenated_content(doc, xrefs: list[int]) -> bytes:
    return b"\n".join(doc.xref_stream(x) or b"" for x in xrefs)


def resolved_key(doc, page_xref, key: str) -> tuple[str, str]:
    """An inheritable page key (/Resources, /MediaBox) as stored, or inherited."""
    kind, value = doc.xref_get_key(page_xref, key)
    x = page_xref
    while kind == "null":
        pk, pv = doc.xref_get_key(x, "Parent")
        if pk != "xref":
            return "null", "null"
        x = int(pv.split()[0])
        kind, value = doc.xref_get_key(x, key)
    return kind, value


# ---------------------------------------------------------------------------
# PieceInfo
# ---------------------------------------------------------------------------
def write_cut_dict(doc, page_xref, entries: dict[str, str]) -> None:
    body = " ".join(f"/{k} {v}" for k, v in entries.items())
    date = f"({pdf_date()})"
    holder, prefix = common.ensure_dict_key(doc, page_xref, "PieceInfo")
    doc.xref_set_key(holder, prefix + "VoucherEditor",
                     f"<< /LastModified {date} /Private << /Cut << {body} >> >> >>")
    # ISO 32000: a page with /PieceInfo must carry /LastModified.
    doc.xref_set_key(page_xref, "LastModified", date)


def read_cut_dict(doc, page_xref) -> dict[str, tuple[str, str]] | None:
    holder, prefix = page_xref, ""
    kind, value = doc.xref_get_key(page_xref, "PieceInfo")
    if kind == "null":
        return None
    if kind == "xref":
        holder = int(value.split()[0])
    else:
        prefix = "PieceInfo/"
    base = prefix + "VoucherEditor/Private/Cut"
    if doc.xref_get_key(holder, base)[0] == "null":
        return None
    keys = ["Version", "Start", "Segments", "StartRef", "EndRef", "Mode", "OrigContents",
            "OrigResources", "XObjectRef", "Source"]
    out = {k: doc.xref_get_key(holder, f"{base}/{k}") for k in keys}
    out["_holder"] = (str(holder), prefix)
    return out


def read_outline(doc, page_no: int = 0) -> Outline | None:
    d = read_cut_dict(doc, doc[page_no].xref)
    if d is None:
        return None
    return segments_from_pdf_array(d["Start"][1], d["Segments"][1])


# ---------------------------------------------------------------------------
# Apply / edit / remove
# ---------------------------------------------------------------------------
def _start_stream_wrap(doc, o: Outline) -> int:
    data = MARKER + b"\nq\n" + to_pdf_path(o).encode() + b"\nW n\nq\n"
    return new_stream(doc, "<<>>", data)


def _start_stream_xobject(doc, o: Outline) -> int:
    data = MARKER + b"\nq\n" + to_pdf_path(o).encode() + f"\nW n\n/{XOBJ_NAME} Do\nQ\n".encode()
    return new_stream(doc, "<<>>", data)


def _common_entries(o: Outline, mode: str, source: str | None) -> dict[str, str]:
    e = {
        "Version": "1",
        "Start": f"[{fmt(o.start[0])} {fmt(o.start[1])}]",
        "Segments": segments_to_pdf_array(o),
        "Mode": f"/{mode}",
    }
    if source:
        e["Source"] = source
    return e


def apply_cut(doc: pymupdf.Document, page_no: int, o: Outline, force_mode: str | None = None,
              source: str | None = None) -> dict:
    page = doc[page_no]
    px = page.xref
    if read_cut_dict(doc, px) is not None:
        raise ValueError("page already has a cut; use edit_cut")
    ckind, cvalue = contents_value(doc, px)
    streams = content_stream_xrefs(doc, px)
    original = concatenated_content(doc, streams)
    balance = q_balance(original)
    mode = force_mode or ("Wrap" if balance == (0, 0) else "XObject")
    entries = _common_entries(o, mode, source)
    entries["OrigContents"] = cvalue  # the exact stored value: a ref or a direct array

    if mode == "Wrap":
        start = _start_stream_wrap(doc, o)
        end = new_stream(doc, "<<>>", MARKER + b"\nQ\nQ\n")
        doc.xref_set_key(px, "Contents", "[" + " ".join(ref(x) for x in [start, *streams, end]) + "]")
        entries.update(StartRef=ref(start), EndRef=ref(end))
    else:
        rkind, rvalue = doc.xref_get_key(px, "Resources")
        inherited_kind, inherited_value = resolved_key(doc, px, "Resources")
        bbox = resolved_key(doc, px, "MediaBox")[1]
        res = inherited_value if inherited_kind != "null" else "<<>>"
        form_dict = f"<< /Type /XObject /Subtype /Form /BBox {bbox} /Resources {res} >>"
        if len(streams) == 1:
            # Copy the encoded bytes as they are, with the same filter keys.
            raw = doc.xref_stream_raw(streams[0])
            form = new_object(doc, form_dict)
            doc.update_stream(form, raw, new=True, compress=False)
            for key in ("Filter", "DecodeParms"):
                k, v = doc.xref_get_key(streams[0], key)
                if k != "null":
                    doc.xref_set_key(form, key, v)
        else:
            form = new_stream(doc, form_dict, original)
        start = _start_stream_xobject(doc, o)
        doc.xref_set_key(px, "Contents", ref(start))
        doc.xref_set_key(px, "Resources", f"<< /XObject << /{XOBJ_NAME} {ref(form)} >> >>")
        entries.update(StartRef=ref(start), XObjectRef=ref(form),
                       OrigResources=rvalue if rkind != "null" else "null")
    write_cut_dict(doc, px, entries)
    return {"mode": mode, "balance": balance, "start": start}


def edit_cut(doc: pymupdf.Document, page_no: int, o: Outline) -> dict:
    """Replace cutStart with a new stream object and update the stored outline."""
    page = doc[page_no]
    px = page.xref
    d = read_cut_dict(doc, px)
    if d is None:
        raise ValueError("no cut on this page")
    mode = d["Mode"][1].lstrip("/")
    entries = _common_entries(o, mode, None)
    for k in ("OrigContents", "EndRef", "OrigResources", "XObjectRef", "Source"):
        if k in d and d[k][0] != "null":
            entries[k] = d[k][1]
    if mode == "Wrap":
        start = _start_stream_wrap(doc, o)
        refs = content_stream_xrefs(doc, px)
        old_start = int(d["StartRef"][1].split()[0])
        assert refs[0] == old_start, "cutStart is no longer first in /Contents"
        refs[0] = start
        doc.xref_set_key(px, "Contents", "[" + " ".join(ref(x) for x in refs) + "]")
    else:
        start = _start_stream_xobject(doc, o)
        doc.xref_set_key(px, "Contents", ref(start))
    entries["StartRef"] = ref(start)
    write_cut_dict(doc, px, entries)
    return {"mode": mode, "start": start}


def remove_cut(doc: pymupdf.Document, page_no: int) -> None:
    page = doc[page_no]
    px = page.xref
    d = read_cut_dict(doc, px)
    if d is None:
        raise ValueError("no cut on this page")
    doc.xref_set_key(px, "Contents", d["OrigContents"][1])
    if d["Mode"][1] == "/XObject":
        doc.xref_set_key(px, "Resources", d["OrigResources"][1] if d["OrigResources"][0] != "null" else "null")
    holder, prefix = d["_holder"]
    # PyMuPDF's xref_set_key(path, "null") on a nested path stores "/Cut null"
    # instead of deleting the key (equivalent per ISO 32000 7.3.7, but untidy).
    # /Private is the app's own dictionary and holds only /Cut so far, so it is
    # rewritten without it. The C shim should use pdf_dict_del instead.
    doc.xref_set_key(int(holder), prefix + "VoucherEditor/Private", "<<>>")
    doc.xref_set_key(px, "LastModified", f"({pdf_date()})")


# ---------------------------------------------------------------------------
# Recovery when PieceInfo is missing (5.4): find our marker streams
# ---------------------------------------------------------------------------
def find_marker_streams(doc, page_no: int = 0) -> list[int]:
    return [x for x in content_stream_xrefs(doc, doc[page_no].xref)
            if (doc.xref_stream(x) or b"").startswith(MARKER)]


def path_from_start_stream(data: bytes) -> Outline:
    """Rebuild an outline (lines and curves; arcs come back as curves, and can be
    re-detected with the primitive fitter) from a cutStart stream's clip path."""
    toks = data.split(b"\n", 1)[1].split()
    nums: list[float] = []
    start = None
    segs = []
    for t in toks:
        if t in (b"m", b"l", b"c"):
            if t == b"m":
                start = (nums[0], nums[1])
            elif t == b"l":
                segs.append(("L", nums[0], nums[1]))
            else:
                segs.append(("C", *nums[:6]))
            nums = []
        elif t == b"h":
            break
        else:
            try:
                nums.append(float(t))
            except ValueError:
                nums = []
    return Outline(start, segs)

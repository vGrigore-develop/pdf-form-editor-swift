"""S5 (automatable part): shape cut store / re-edit / reverse, rendered with MuPDF
and PDFium at 150 DPI.

Scenarios
  a  synthetic voucher, reference outline -> edited outline     (Wrap mode)
  b  synthetic voucher, outline with a curve segment            (Wrap mode)
  c  synthetic voucher, XObject mode forced (multi-stream copy) (XObject mode)
  d  unbalanced q/Q fixture, automatic mode                     (must pick XObject)
  d2 unbalanced fixture with two stray Q, automatic mode        (must pick XObject)
  e1 one stray Q, Wrap forced: still clips (the inner q absorbs one stray Q)
  e2 two stray Q, Wrap forced: leaks outside the outline (shows why the guard exists)

Checks per cut render, for each engine:
  outside (more than 1 px from the analytic outline) is pure white;
  painted pixels agree with the analytic outline within 1 px, and the two
  engines agree with each other within 1 px;
  interior pixels (2 px inside) are unchanged from the original render.
Reversal: renders pixel-identical to the original, original content stream
objects byte-identical, /Contents (and /Resources) values restored exactly.

Run:  ../.venv/bin/python s5_cut.py
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pymupdf

import common
import cut
from common import Report
from outline import (Outline, PAGE_H, PAGE_W, curve_outline, edited_outline, hausdorff, raster_mask,
                     reference_outline)

ENGINES = {"MuPDF": common.render_mupdf, "PDFium": common.render_pdfium}


def coverage(cut_img: np.ndarray, orig_img: np.ndarray) -> np.ndarray:
    """Per-pixel clip coverage estimated against the unclipped original render.

    A clipped pixel composites the original colour over white with coverage a:
    cut = 255 - a * (255 - orig). The channel furthest from white gives the most
    precise estimate. The fixtures have no white areas, so this is defined everywhere.
    """
    cut_img, orig_img = common.crop_common(cut_img, orig_img)
    dist = 255 - orig_img.astype(int)
    ch = dist.argmax(axis=2)[..., None]
    num = np.take_along_axis(255 - cut_img.astype(int), ch, axis=2)[..., 0]
    den = np.take_along_axis(dist, ch, axis=2)[..., 0]
    return np.clip(num / np.maximum(den, 1), 0, 1)


def check_cut_render(r: Report, label: str, path: Path, o: Outline, originals: dict) -> dict:
    """Pass criteria (S5 part 1, automatable half):
    - outside: every pixel more than 1 px (Chebyshev) from the analytic outline is pure white;
    - edge: the 50 % coverage edge lies within 1 px of the analytic outline, and the
      MuPDF and PDFium edges lie within 1 px of each other;
    - interior (2 px inside): flat areas are identical to the original render, and
      anti-aliased artwork edges differ by at most 8/255 (clip-group compositing)."""
    edges = {}
    for name, fn in ENGINES.items():
        img = fn(path)
        orig = originals[name]
        mask = raster_mask(o, PAGE_W, PAGE_H, common.DPI, img.shape[:2])
        outside = ~common.dilate(mask, 1)
        white = (img == 255).all(axis=2)
        leak = outside & ~white
        faint = int((255 - img.min(axis=2))[outside].max()) if leak.any() else 0
        r.check(not leak.any(), f"{label} {name}: blank outside the outline (beyond 1 px)",
                f"{int(leak.sum())} non-white px, darkest {255 - faint}")
        cov = coverage(img, orig)
        m = mask[: cov.shape[0], : cov.shape[1]]
        edge = cov >= 0.5
        over = int((edge & ~common.dilate(m, 1)).sum())
        under = int((common.erode(m, 1) & ~edge).sum())
        r.check(over == 0 and under == 0, f"{label} {name}: 50% edge within 1 px of the analytic outline",
                f"over={over} under={under}")
        edges[name] = edge
        a, b = common.crop_common(img, orig)
        inner = common.erode(m, 2)
        d = np.abs(a.astype(int) - b.astype(int)).max(axis=2)
        g = np.zeros(d.shape, int)  # local variation in the original: 0 on flat areas
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                g = np.maximum(g, np.abs(np.roll(np.roll(b.astype(int), dy, 0), dx, 1) - b).max(axis=2))
        flat_diff = int((d * (inner & (g == 0))).max())
        edge_diff = int((d * (inner & (g > 0))).max())
        r.check(flat_diff == 0 and edge_diff <= 8, f"{label} {name}: interior unchanged",
                f"flat areas max diff {flat_diff}, artwork AA edges max diff {edge_diff}, "
                f"{int(((d > 0) & inner).sum())} px differ")
        common.save_png(img, common.OUT / f"{path.stem}_{name.lower()}.png")
    em, ep = common.crop_common(edges["MuPDF"][..., None], edges["PDFium"][..., None])
    em, ep = em[..., 0], ep[..., 0]
    dm = int((em & ~common.dilate(ep, 1)).sum())
    dp = int((ep & ~common.dilate(em, 1)).sum())
    r.check(dm == 0 and dp == 0, f"{label}: MuPDF and PDFium edges agree within 1 px", f"{dm}/{dp} px")
    return edges


def stream_snapshot(doc, xrefs):
    return {x: (doc.xref_object(x, compressed=True), doc.xref_stream_raw(x)) for x in xrefs}


def run_scenario(r: Report, tag: str, fixture: Path, first: Outline, second: Outline,
                 force_mode: str | None, expect_mode: str) -> None:
    out = common.ensure_out()
    originals = {name: fn(fixture) for name, fn in ENGINES.items()}
    with pymupdf.open(fixture) as d0:
        px0 = d0[0].xref
        orig_contents = d0.xref_get_key(px0, "Contents")
        orig_resources = d0.xref_get_key(px0, "Resources")
        orig_streams = cut.content_stream_xrefs(d0, px0)
        snap0 = stream_snapshot(d0, orig_streams)

    # --- part 1: apply
    a = common.fresh_copy(fixture, out / f"s5{tag}_1_cut.pdf")
    doc = pymupdf.open(a)
    info = cut.apply_cut(doc, 0, first, force_mode=force_mode, source="<< /Kind /Drawn >>")
    common.save_incremental(doc)
    doc.close()
    r.check(info["mode"] == expect_mode, f"{tag}: mode {expect_mode} chosen", f"got {info['mode']}, q/Q balance {info['balance']}")
    r.check(common.is_prefix(fixture, a), f"{tag}: apply is an incremental append")
    ok, issues = common.qpdf_check(a)
    r.check(ok, f"{tag}: libqpdf check clean after apply", "; ".join(issues[:3]))
    check_cut_render(r, f"{tag} apply", a, first, originals)

    # --- recovery without PieceInfo (5.4): marker streams found, outline rebuilt
    with pymupdf.open(a) as d:
        d.xref_set_key(d[0].xref, "PieceInfo", "null")
        markers = cut.find_marker_streams(d)
        rebuilt = cut.path_from_start_stream(d.xref_stream(markers[0]))
        dist = hausdorff(rebuilt, first)
        want = 2 if info["mode"] == "Wrap" else 1
        # tolerance 0.1 pt: the rebuilt path has the arcs as Béziers (error <= 0.027 % of r)
        r.check(len(markers) == want and dist < 0.1, f"{tag}: cut recognised by marker without PieceInfo",
                f"{len(markers)} marker streams, rebuilt outline within {dist:.4f} pt")

    # --- part 2: re-edit
    b = common.fresh_copy(a, out / f"s5{tag}_2_edit.pdf")
    doc = pymupdf.open(b)
    back = cut.read_outline(doc)
    r.check(back is not None and hausdorff(back, first) < 1e-3, f"{tag}: outline reads back from PieceInfo")
    old = cut.read_cut_dict(doc, doc[0].xref)
    old_start = int(old["StartRef"][1].split()[0])
    cut.edit_cut(doc, 0, second)
    common.save_incremental(doc)
    doc.close()
    r.check(common.is_prefix(a, b), f"{tag}: edit is an incremental append")
    with pymupdf.open(b) as d:
        refs = cut.content_stream_xrefs(d, d[0].xref)
        r.check(old_start not in refs, f"{tag}: old cutStart no longer referenced", f"/Contents refs {refs}")
        if info["mode"] == "Wrap":
            r.check(refs[1:-1] == orig_streams, f"{tag}: original streams still wrapped in order")
    check_cut_render(r, f"{tag} edit", b, second, originals)

    # --- part 3: remove
    c = common.fresh_copy(b, out / f"s5{tag}_3_removed.pdf")
    doc = pymupdf.open(c)
    cut.remove_cut(doc, 0)
    common.save_incremental(doc)
    doc.close()
    r.check(common.is_prefix(b, c) and common.is_prefix(fixture, c), f"{tag}: remove is an incremental append")
    ok, issues = common.qpdf_check(c)
    r.check(ok, f"{tag}: libqpdf check clean after remove", "; ".join(issues[:3]))
    with pymupdf.open(c) as d:
        px = d[0].xref
        r.check(d.xref_get_key(px, "Contents") == orig_contents, f"{tag}: /Contents value restored exactly",
                str(d.xref_get_key(px, "Contents")))
        r.check(d.xref_get_key(px, "Resources") == orig_resources, f"{tag}: /Resources value restored exactly")
        r.check(stream_snapshot(d, orig_streams) == snap0, f"{tag}: original content stream objects byte-identical")
        r.check(cut.read_cut_dict(d, px) is None, f"{tag}: /Cut dropped")
    for name, fn in ENGINES.items():
        x, y = common.crop_common(fn(c), originals[name])
        n = int((x != y).any(axis=2).sum())
        r.check(n == 0, f"{tag}: {name} render pixel-identical to the original after removal", f"{n} px differ")


def tokenizer_tests(r: Report) -> None:
    cases = {
        b"q 1 0 0 1 0 0 cm Q": (0, 0),
        b"q (a string with Q and \\) q) Tj Q": (0, 0),
        b"q % comment Q Q Q\n Q": (0, 0),
        b"q BI /W 2 /H 1 /BPC 8 /CS /G ID \x51\x20\x51 EI Q": (0, 0),
        b"q <</MCID 0>> BDC Q EMC Q": (-1, -1),
        b"q q Q": (0, 1),
        b"q /Q gs Q": (0, 0),
    }
    for data, want in cases.items():
        got = cut.q_balance(data)
        r.check(got == want, f"q/Q tokenizer: {data[:40]!r}", f"got {got}, want {want}")


def main() -> None:
    r = Report("S5 shape cut: apply, re-edit, reverse")
    tokenizer_tests(r)
    voucher = common.FIXTURES / "synthetic_voucher.pdf"
    unbalanced = common.FIXTURES / "unbalanced_qQ.pdf"
    unbalanced2 = common.FIXTURES / "unbalanced_qQ_2.pdf"
    run_scenario(r, "a", voucher, reference_outline(), edited_outline(), None, "Wrap")
    run_scenario(r, "b", voucher, curve_outline(), reference_outline(), None, "Wrap")
    run_scenario(r, "c", voucher, reference_outline(), curve_outline(), "XObject", "XObject")
    run_scenario(r, "d", unbalanced, reference_outline(), edited_outline(), None, "XObject")

    run_scenario(r, "d2", unbalanced2, reference_outline(), edited_outline(), None, "XObject")

    # e: what a naive Wrap does with unbalanced content (why the guard exists)
    for tag, fixture, expect_leak in [("e1", unbalanced, False), ("e2", unbalanced2, True)]:
        e = common.fresh_copy(fixture, common.OUT / f"s5{tag}_naive_wrap.pdf")
        doc = pymupdf.open(e)
        cut.apply_cut(doc, 0, reference_outline(), force_mode="Wrap")
        common.save_incremental(doc)
        doc.close()
        img = common.render_mupdf(e)
        mask = raster_mask(reference_outline(), PAGE_W, PAGE_H, common.DPI, img.shape[:2])
        leak = int((~common.dilate(mask, 1) & ~(img == 255).all(axis=2)).sum())
        if expect_leak:
            r.check(leak > 0, f"{tag}: naive Wrap with 2 stray Q leaks outside the outline (guard needed)",
                    f"{leak} px painted outside")
        else:
            r.check(leak == 0, f"{tag}: naive Wrap with 1 stray Q still clips (the inner q absorbs it)",
                    f"{leak} px painted outside")
    # f: cut a template that already has fields (S1 output); fields must be untouched
    import pypdf

    import s1_fields

    f = common.fresh_copy(voucher, common.OUT / "s5f_fields_and_cut.pdf")
    s1_fields.add_fields(f)
    with_fields = common.fresh_copy(f, common.OUT / "s5f_fields_only.pdf")
    doc = pymupdf.open(f)
    annots_before = doc.xref_get_key(doc[0].xref, "Annots")
    cut.apply_cut(doc, 0, reference_outline())
    common.save_incremental(doc)
    doc.close()
    with pymupdf.open(f) as d:
        r.check(d.xref_get_key(d[0].xref, "Annots") == annots_before, "f: page /Annots untouched by the cut")
        r.check(len(list(d[0].widgets())) == 5, "f: MuPDF still finds 5 widgets after the cut")
    r.check(len(pypdf.PdfReader(str(f)).get_fields()) == 5, "f: pypdf still finds 5 fields after the cut")
    r.check(common.is_prefix(with_fields, f), "f: cut appended after the field save")
    common.save_png(common.render_pdfium(f, forms=True), common.OUT / "s5f_fields_and_cut_pdfium.png")

    r.note("renders in spikes/out/*.png; Preview, Chrome, Acrobat and Print-to-PDF not verified here")
    r.finish()


if __name__ == "__main__":
    main()

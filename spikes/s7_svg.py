"""S7 (first version): SVG path parsing, placement and primitive fitting.

Pass criteria checked (SPEC S7), with the files available here:
  - every point within 0.1 pt of the reference geometry after Fit to page;
  - y-flip and viewBox offsets correct (orientation of the steps and the arc);
  - circular arcs survive as arcs, the non-uniform case becomes curves;
  - after "Detect lines and arcs", the cubic-only export reduces to the
    expected line and arc count (11 lines + 1 arc for the synthetic shape);
  - path parsing agrees with an independent parser. nanosvg (the spec's oracle)
    is a C library; svgelements (pure Python, full transform support) stands in.

Run:  ../.venv/bin/python s7_svg.py
"""

from __future__ import annotations

import math

import numpy as np

import common
from common import Report
from fitting import fit_primitives
from outline import PAGE_H, PAGE_W, Outline, flatten, hausdorff, reference_outline
from svg_import import (_aspect_matrix, apply, import_svg, mul, parse_path, parse_transform, viewport)

SVG_DIR = common.FIXTURES / "svg"
TOL = 0.1  # pt


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def inverse(m):
    a, b, c, d, e, f = m
    det = a * d - b * c
    ia, ib, ic, id_ = d / det, -b / det, -c / det, a / det
    return (ia, ib, ic, id_, -(ia * e + ic * f), -(ib * e + id_ * f))


def _dist_points_to_polyline(p: np.ndarray, q: np.ndarray) -> np.ndarray:
    """Distance from each point in p to the polyline through q (vectorised)."""
    a, b = q[:-1], q[1:]
    ab = b - a
    L2 = np.maximum((ab ** 2).sum(1), 1e-18)
    best = np.full(len(p), np.inf)
    for i in range(0, len(p), 512):
        pp = p[i:i + 512, None, :]
        t = np.clip(((pp - a[None]) * ab[None]).sum(2) / L2[None], 0, 1)
        proj = a[None] + t[..., None] * ab[None]
        best[i:i + 512] = np.sqrt(((pp - proj) ** 2).sum(2)).min(1)
    return best


def point_set_hausdorff(p: np.ndarray, q: np.ndarray) -> float:
    """Hausdorff distance between two polylines given by dense samples."""
    return float(max(_dist_points_to_polyline(p, q).max(), _dist_points_to_polyline(q, p).max()))


def oracle_points(svg_path, element_id: str, place) -> np.ndarray:
    """Sample an element with svgelements and map its points into page space."""
    import xml.etree.ElementTree as ET

    from svgelements import SVG, Path, Shape

    root = ET.parse(svg_path).getroot()
    vb, w, h, par = viewport(root)
    vpm = _aspect_matrix(vb, w or vb[2], h or vb[3], par)  # what svgelements applies (user -> px)
    to_page = mul(place, inverse(vpm))
    svg = SVG.parse(str(svg_path), reify=True, ppi=96)
    for el in svg.elements():
        if isinstance(el, Shape) and el.id == element_id:
            path = Path(el)
            pts = []
            for seg in path.segments():
                if seg.__class__.__name__ in ("Move",):
                    continue
                n = max(8, int(seg.length() / 0.5) + 1)  # ~0.5 pt spacing; polyline distance below
                for t in np.linspace(0, 1, n):
                    p = seg.point(t)
                    pts.append(apply(to_page, (p.x, p.y)))
            return np.array(pts)
    raise KeyError(element_id)


def vertex_match(o: Outline, ref: Outline) -> float:
    """Max distance between corresponding end points, allowing a rotated start."""
    a = o.end_points()[:-1] if math.dist(o.end_points()[-1], o.start) < 1e-6 else o.end_points()
    b = ref.end_points()[:-1]
    if len(a) != len(b):
        return math.inf
    best = math.inf
    for s in range(len(a)):
        best = min(best, max(math.dist(a[(i + s) % len(a)], b[i]) for i in range(len(b))))
    return best


def scale_about(o: Outline, k: float, c) -> Outline:
    f = lambda x, y: (c[0] + k * (x - c[0]), c[1] + k * (y - c[1]))  # noqa: E731
    segs = []
    for sg in o.segments:
        if sg[0] == "L":
            segs.append(("L", *f(*sg[1:3])))
        elif sg[0] == "A":
            segs.append(("A", *f(*sg[1:3]), *f(*sg[3:5]), sg[5]))
        else:
            segs.append(("C", *f(*sg[1:3]), *f(*sg[3:5]), *f(*sg[5:7])))
    return Outline(f(*o.start), segs)


def arcs(o: Outline):
    return [s for s in o.segments if s[0] == "A"]


# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------
def test_parser_units(r: Report) -> None:
    sp = parse_path("m460,420a20,20 0 1020,0l.5.5-1e1,1E1z")[0]
    kinds = [s[0] for s in sp.segs]
    r.check(kinds == ["E", "L", "L", "L"] and sp.closed, "path parser: packed arc flags, '.5.5', exponents",
            str(kinds))
    e = sp.segs[0]
    r.check(e[5] is True and e[6] is False and e[1] == (480.0, 420.0), "path parser: arc flags read as 1, 0",
            str(e))
    sp = parse_path("M10 10 20 20 h5 v-5 Z M0 0 l1 1")
    r.check(len(sp) == 2 and sp[0].segs[0] == ("L", (20.0, 20.0)) and not sp[1].closed,
            "path parser: implicit lineto after M, open second subpath")
    m = parse_transform("translate(10) rotate(90 5 5) scale(2,3)")
    p = apply(m, (1, 1))
    # scale -> (2, 3); rotate 90 about (5, 5) -> (7, 2); translate -> (17, 2)
    r.check(math.dist(p, (17.0, 2.0)) < 1e-9, "transform list composes left to right", f"{p} vs (17, 2)")


def test_handwritten(r: Report) -> None:
    path = SVG_DIR / "handwritten.svg"
    ref = reference_outline()
    res = import_svg(str(path), PAGE_W, PAGE_H, "fit")
    o = res.outline
    c = o.counts()
    r.check(c == {"L": 11, "A": 1, "C": 0}, "handwritten: largest shape is the voucher, 11 lines + 1 arc", str(c))
    vm = vertex_match(o, ref)
    r.check(vm <= TOL, "handwritten: every vertex within 0.1 pt of the reference after Fit to page", f"{vm:.2e} pt")
    a = arcs(o)[0]
    ra = arcs(ref)[0]
    r.check(math.dist(a[3:5], ra[3:5]) <= TOL and a[5] == ra[5],
            "handwritten: arc centre and direction survive the flipped transform chain",
            f"centre {a[3]:.4f},{a[4]:.4f} cw={a[5]}")
    hd = hausdorff(o, ref)
    r.check(hd <= TOL, "handwritten: whole outline within 0.1 pt (Hausdorff)", f"{hd:.2e} pt")
    # orientation: notch on the left, arc on the right, top edge at the top
    xs = [p[0] for p in o.end_points()]
    ys = [p[1] for p in o.end_points()]
    r.check(abs(min(xs) - 40) < 1e-6 and abs(max(ys) - 545) < 1e-6 and a[3] > 500 and a[5] is False,
            "handwritten: y-flip and orientation correct (steps left, arc right, counter-clockwise)")
    r.check(any("open subpath" in n for n in res.notes), "handwritten: open polyline ignored with a note",
            "; ".join(res.notes))
    # oracle agreement on both closed shapes
    for el in ("voucher", "decoy"):
        ours = next(cand for name, cand in res.candidates if name == el)
        d = point_set_hausdorff(flatten(ours, 0.5), oracle_points(path, el, res.placement))
        r.check(d <= TOL, f"handwritten: <{el}> agrees with svgelements", f"{d:.3e} pt")
    # fitting must leave an exact outline unchanged
    fo = fit_primitives(o, TOL)
    r.check(fo.counts() == c and hausdorff(fo, ref) <= TOL, "handwritten: fitting is a no-op on exact input",
            str(fo.counts()))

    # Actual size: user units -> px via viewBox/viewport (meet, centred) -> 0.75 pt/px, centred on the page.
    res2 = import_svg(str(path), PAGE_W, PAGE_H, "actual")
    k = 0.75 * min((297 / 25.4 * 96) / 1684, (210 / 25.4 * 96) / 1190)
    # reference in root user space: X = 2x, Y = 2(595 - y); expected page point = centre + k * (P - vb centre), y flipped
    # In page terms that is a uniform scale by 2k about the page centre.
    exp = scale_about(ref, 2 * k, (PAGE_W / 2, PAGE_H / 2))
    hd2 = hausdorff(res2.outline, exp)
    r.check(hd2 <= TOL, "handwritten: Actual size (297 x 210 mm artboard) places the shape at 96 px/in, centred",
            f"{hd2:.2e} pt, scale {k:.6f} pt/unit")


def test_primitives(r: Report) -> None:
    path = SVG_DIR / "primitives.svg"
    res = import_svg(str(path), PAGE_W, PAGE_H, "fit")
    got = {name: o for name, o in res.candidates}
    expected = {
        "rrect": {"L": 4, "A": 4, "C": 0},
        "rrect_elliptic": {"L": 4, "A": 0, "C": 4},
        "circle": {"L": 0, "A": 2, "C": 0},
        "ellipse": {"L": 0, "A": 0, "C": 4},
        "poly": {"L": 3, "A": 0, "C": 0},
        "curvy": {"L": 2, "A": 0, "C": 4},
        "compact": {"L": 3, "A": 1, "C": 0},
        "squashed": {"L": 0, "A": 0, "C": 4},
        "rotrect": {"L": 4, "A": 4, "C": 0},
    }
    r.check("open" not in got, "primitives: open polyline is not a candidate")
    for name, want in expected.items():
        o = got.get(name)
        r.check(o is not None and o.counts() == want, f"primitives: <{name}> segment kinds", str(o.counts() if o else None))
        if o is not None:
            d = point_set_hausdorff(flatten(o, 0.5), oracle_points(path, name, res.placement))
            r.check(d <= TOL, f"primitives: <{name}> agrees with svgelements", f"{d:.3e} pt")
    # rect with radii: arc centres inset by r from the corners (page coords, y flipped)
    rr = got["rrect"]
    centres = sorted((round(s[3], 6), round(s[4], 6)) for s in arcs(rr))
    want = sorted([(120.0, 475.0), (280.0, 475.0), (120.0, 395.0), (280.0, 395.0)])
    r.check(centres == want,
            "primitives: rounded rect corner arcs centred on the inset corners", str(centres))
    # rotate() keeps arcs (similarity); scale(1.5,1) turns the circle into curves
    r.check(len(arcs(got["rotrect"])) == 4 and not arcs(got["squashed"]),
            "primitives: rotation keeps arcs, non-uniform scale gives curves")


def test_cubic_only(r: Report) -> None:
    path = SVG_DIR / "cubic_only.svg"
    ref = reference_outline()
    res = import_svg(str(path), PAGE_W, PAGE_H, "fit")
    raw = res.outline
    d = point_set_hausdorff(flatten(raw, 0.5), oracle_points(path, "voucher", res.placement))
    r.check(d <= TOL, "cubic-only: raw parse agrees with svgelements", f"{d:.3e} pt")
    fo = fit_primitives(raw, TOL)
    r.note(f"cubic-only: {raw.counts()} before fitting -> {fo.counts()} after")
    r.check(fo.counts() == {"L": 11, "A": 1, "C": 0}, "cubic-only: Detect lines and arcs gives 11 lines + 1 arc",
            str(fo.counts()))
    vm = vertex_match(fo, ref)
    r.check(vm <= TOL, "cubic-only: vertices within 0.1 pt of the reference", f"{vm:.3f} pt")
    hd = hausdorff(fo, ref)
    r.check(hd <= TOL, "cubic-only: fitted outline within 0.1 pt of the reference", f"{hd:.3f} pt")
    ortho = all(
        abs(a[0] - b[0]) < 1e-9 or abs(a[1] - b[1]) < 1e-9
        for s, a, b in zip(fo.segments, fo.end_points(), fo.end_points()[1:]) if s[0] == "L"
        and not (abs(a[1] - b[1]) > 1 and abs(a[0] - b[0]) > 1)
    )
    r.check(ortho, "cubic-only: steps exactly orthogonal after snapping (0.04 pt jitter removed)")
    if arcs(fo):
        a = arcs(fo)[0]
        r.check(math.dist(a[3:5], (564.5, 297.5)) <= TOL and a[5] is False,
                "cubic-only: detected arc has the reference centre and direction", f"{a[3]:.4f},{a[4]:.4f}")


def test_nonuniform(r: Report) -> None:
    path = SVG_DIR / "nonuniform.svg"
    res = import_svg(str(path), PAGE_W, PAGE_H, "fit")
    o = res.outline
    r.check(not arcs(o) and o.counts()["C"] > 0, "non-uniform: the arc imports as curves", str(o.counts()))
    d = point_set_hausdorff(flatten(o, 0.5), oracle_points(path, "voucher", res.placement))
    r.check(d <= TOL, "non-uniform: agrees with svgelements", f"{d:.3e} pt")
    fo = fit_primitives(o, TOL)
    r.check(not arcs(fo), "non-uniform: fitting does not turn the half ellipse into a circle", str(fo.counts()))
    r.check(hausdorff(fo, o) <= TOL, "non-uniform: fitting keeps the shape within 0.1 pt")


def main() -> None:
    r = Report("S7 SVG import: parsing, placement, primitive fitting")
    test_parser_units(r)
    test_handwritten(r)
    test_primitives(r)
    test_cubic_only(r)
    test_nonuniform(r)
    r.note("not covered: real Illustrator / Figma / Inkscape / Affinity exports (none available)")
    r.finish()


if __name__ == "__main__":
    main()

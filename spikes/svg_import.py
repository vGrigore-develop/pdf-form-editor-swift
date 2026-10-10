"""SVG outline import, first version (SPEC 5.6.1 and 5.5).

Parses path/rect/circle/ellipse/polygon/polyline and nested <g> with all
transform types, honours the root viewBox, width/height units and
preserveAspectRatio, keeps circular arcs as arcs when the accumulated transform
is a similarity, and places the result on the page (Fit to page or Actual size)
with the y-axis flipped.

The structure mirrors the planned Swift importer (XMLParser delegate + a path
parser + a geometry stage), so it ports almost line by line.

Internal segment forms, in whatever coordinate system they are expressed:
    ("L", (x, y))
    ("C", (x1, y1), (x2, y2), (x, y))
    ("E", (x, y), rx, ry, phi_deg, large, sweep)    SVG elliptical arc (endpoint form)
    ("A", (x, y), (cx, cy), positive)                circular arc; positive = increasing angle
"""

from __future__ import annotations

import math
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

from outline import Outline

Matrix = tuple[float, float, float, float, float, float]  # SVG (a b c d e f)
IDENTITY: Matrix = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


# ---------------------------------------------------------------------------
# Affine helpers
# ---------------------------------------------------------------------------
def mul(m: Matrix, n: Matrix) -> Matrix:
    """m * n: apply n first, then m."""
    a, b, c, d, e, f = m
    A, B, C, D, E, F = n
    return (a * A + c * B, b * A + d * B, a * C + c * D, b * C + d * D, a * E + c * F + e, b * E + d * F + f)


def apply(m: Matrix, p) -> tuple[float, float]:
    a, b, c, d, e, f = m
    return (a * p[0] + c * p[1] + e, b * p[0] + d * p[1] + f)


def det(m: Matrix) -> float:
    return m[0] * m[3] - m[1] * m[2]


def is_similarity(m: Matrix, eps: float = 1e-9) -> bool:
    a, b, c, d = m[:4]
    s = max(abs(a), abs(b), abs(c), abs(d), 1e-300)
    rot = abs(a - d) <= eps * s and abs(b + c) <= eps * s
    refl = abs(a + d) <= eps * s and abs(b - c) <= eps * s
    return rot or refl


# ---------------------------------------------------------------------------
# Attribute parsing
# ---------------------------------------------------------------------------
NUM_RE = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")
UNITS_PX = {"": 1.0, "px": 1.0, "pt": 96 / 72, "pc": 16.0, "mm": 96 / 25.4, "cm": 96 / 2.54, "in": 96.0}


def parse_length(s: str | None, default: float | None = None) -> float | None:
    if s is None:
        return default
    m = re.fullmatch(r"\s*([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)\s*(px|pt|pc|mm|cm|in)?\s*", s)
    if not m:
        if s.strip().endswith("%"):
            return default  # percentages need a viewport; treated as unspecified
        raise ValueError(f"unsupported length {s!r}")
    return float(m.group(1)) * UNITS_PX[m.group(2) or ""]


def parse_transform(s: str | None) -> Matrix:
    m = IDENTITY
    if not s:
        return m
    for name, args in re.findall(r"(matrix|translate|scale|rotate|skewX|skewY)\s*\(([^)]*)\)", s):
        v = [float(x) for x in NUM_RE.findall(args)]
        if name == "matrix":
            t = tuple(v[:6])
        elif name == "translate":
            t = (1, 0, 0, 1, v[0], v[1] if len(v) > 1 else 0)
        elif name == "scale":
            t = (v[0], 0, 0, v[1] if len(v) > 1 else v[0], 0, 0)
        elif name == "rotate":
            a = math.radians(v[0])
            r = (math.cos(a), math.sin(a), -math.sin(a), math.cos(a), 0, 0)
            if len(v) >= 3:
                cx, cy = v[1], v[2]
                t = mul(mul((1, 0, 0, 1, cx, cy), r), (1, 0, 0, 1, -cx, -cy))
            else:
                t = r
        elif name == "skewX":
            t = (1, 0, math.tan(math.radians(v[0])), 1, 0, 0)
        else:
            t = (1, math.tan(math.radians(v[0])), 0, 1, 0, 0)
        m = mul(m, t)
    return m


# ---------------------------------------------------------------------------
# Path data
# ---------------------------------------------------------------------------
@dataclass
class Subpath:
    start: tuple[float, float]
    segs: list[tuple] = field(default_factory=list)
    closed: bool = False


def parse_path(d: str) -> list[Subpath]:
    # Arc flags may be written without separators ("0 1120 0" = 0, 1, 1, 20, 0),
    # which a plain number tokenizer would read as "1120". Handle A/a by reading
    # flags character-wise from the raw string.
    subs: list[Subpath] = []
    cur = start = (0.0, 0.0)
    sp: Subpath | None = None
    last_c2 = last_q = None
    i, n = 0, len(d)
    cmd = None

    def skip_ws(j):
        while j < n and d[j] in " \t\r\n,":
            j += 1
        return j

    def num(j):
        j = skip_ws(j)
        m = NUM_RE.match(d, j)
        if not m:
            raise ValueError(f"number expected at {j}: {d[j:j + 20]!r}")
        return float(m.group(0)), m.end()

    def flag(j):
        j = skip_ws(j)
        if j >= n or d[j] not in "01":
            raise ValueError(f"arc flag expected at {j}")
        return d[j] == "1", j + 1

    def ensure_sp():
        nonlocal sp
        if sp is None:
            sp = Subpath(cur)
            subs.append(sp)
        return sp

    while True:
        i = skip_ws(i)
        if i >= n:
            break
        if d[i].isalpha():
            cmd = d[i]
            i += 1
            if cmd in "Zz":
                if sp is not None:
                    if math.dist(cur, sp.start) > 1e-9:
                        sp.segs.append(("L", sp.start))
                    sp.closed = True
                cur = start
                sp = None
                last_c2 = last_q = None
                continue
        elif cmd is None:
            raise ValueError("path data must start with a command")
        rel = cmd.islower()
        C = cmd.upper()
        ox, oy = cur if rel else (0.0, 0.0)
        if C == "M":
            x, i = num(i); y, i = num(i)
            cur = start = (ox + x, oy + y)
            sp = Subpath(cur)
            subs.append(sp)
            cmd = "l" if rel else "L"  # implicit lineto after the first pair
            last_c2 = last_q = None
            continue
        s = ensure_sp()
        if C == "L":
            x, i = num(i); y, i = num(i)
            p = (ox + x, oy + y)
            s.segs.append(("L", p)); last_c2 = last_q = None
        elif C == "H":
            x, i = num(i)
            p = (ox + x, cur[1])
            s.segs.append(("L", p)); last_c2 = last_q = None
        elif C == "V":
            y, i = num(i)
            p = (cur[0], (cur[1] if rel else 0.0) + y)
            s.segs.append(("L", p)); last_c2 = last_q = None
        elif C == "C":
            v = []
            for _ in range(6):
                t, i = num(i); v.append(t)
            c1, c2, p = (ox + v[0], oy + v[1]), (ox + v[2], oy + v[3]), (ox + v[4], oy + v[5])
            s.segs.append(("C", c1, c2, p)); last_c2, last_q = c2, None
        elif C == "S":
            v = []
            for _ in range(4):
                t, i = num(i); v.append(t)
            c1 = (2 * cur[0] - last_c2[0], 2 * cur[1] - last_c2[1]) if last_c2 else cur
            c2, p = (ox + v[0], oy + v[1]), (ox + v[2], oy + v[3])
            s.segs.append(("C", c1, c2, p)); last_c2, last_q = c2, None
        elif C == "Q":
            v = []
            for _ in range(4):
                t, i = num(i); v.append(t)
            q, p = (ox + v[0], oy + v[1]), (ox + v[2], oy + v[3])
            s.segs.append(_quad_to_cubic(cur, q, p)); last_q, last_c2 = q, None
        elif C == "T":
            x, i = num(i); y, i = num(i)
            q = (2 * cur[0] - last_q[0], 2 * cur[1] - last_q[1]) if last_q else cur
            p = (ox + x, oy + y)
            s.segs.append(_quad_to_cubic(cur, q, p)); last_q, last_c2 = q, None
        elif C == "A":
            rx, i = num(i); ry, i = num(i); phi, i = num(i)
            large, i = flag(i); sweep, i = flag(i)
            x, i = num(i); y, i = num(i)
            p = (ox + x, oy + y)
            if math.dist(p, cur) < 1e-12:
                pass  # zero-length arc is omitted (SVG F.6.2)
            elif rx == 0 or ry == 0:
                s.segs.append(("L", p))
            else:
                s.segs.append(("E", p, abs(rx), abs(ry), phi, large, sweep))
            last_c2 = last_q = None
        else:
            raise ValueError(f"unsupported command {cmd!r}")
        cur = p
    return subs


def _quad_to_cubic(p0, q, p):
    c1 = (p0[0] + 2 / 3 * (q[0] - p0[0]), p0[1] + 2 / 3 * (q[1] - p0[1]))
    c2 = (p[0] + 2 / 3 * (q[0] - p[0]), p[1] + 2 / 3 * (q[1] - p[1]))
    return ("C", c1, c2, p)


# ---------------------------------------------------------------------------
# Basic shapes as path data (SVG 1.1 / 2 equivalent paths)
# ---------------------------------------------------------------------------
def shape_to_d(el: ET.Element, tag: str) -> str | None:
    g = lambda k, dflt=0.0: parse_length(el.get(k), dflt)  # noqa: E731
    if tag == "path":
        return el.get("d", "")
    if tag == "rect":
        x, y, w, h = g("x"), g("y"), g("width"), g("height")
        rx, ry = parse_length(el.get("rx")), parse_length(el.get("ry"))
        if rx is None and ry is None:
            rx = ry = 0.0
        elif rx is None:
            rx = ry
        elif ry is None:
            ry = rx
        rx, ry = min(rx, w / 2), min(ry, h / 2)
        if rx <= 0 or ry <= 0:
            return f"M{x} {y} H{x + w} V{y + h} H{x} Z"
        return (f"M{x + rx} {y} H{x + w - rx} A{rx} {ry} 0 0 1 {x + w} {y + ry} V{y + h - ry} "
                f"A{rx} {ry} 0 0 1 {x + w - rx} {y + h} H{x + rx} A{rx} {ry} 0 0 1 {x} {y + h - ry} "
                f"V{y + ry} A{rx} {ry} 0 0 1 {x + rx} {y} Z")
    if tag in ("circle", "ellipse"):
        cx, cy = g("cx"), g("cy")
        rx = g("r") if tag == "circle" else g("rx")
        ry = g("r") if tag == "circle" else g("ry")
        return f"M{cx + rx} {cy} A{rx} {ry} 0 0 1 {cx - rx} {cy} A{rx} {ry} 0 0 1 {cx + rx} {cy} Z"
    if tag in ("polygon", "polyline"):
        v = [float(t) for t in NUM_RE.findall(el.get("points", ""))]
        pts = list(zip(v[0::2], v[1::2]))
        if not pts:
            return None
        d = f"M{pts[0][0]} {pts[0][1]} " + " ".join(f"L{x} {y}" for x, y in pts[1:])
        return d + (" Z" if tag == "polygon" else "")
    return None


# ---------------------------------------------------------------------------
# Geometry stage: transform segments, keeping circular arcs where possible
# ---------------------------------------------------------------------------
def _arc_center(p0, seg):
    """SVG F.6.5 endpoint -> centre parameterisation."""
    _, p1, rx, ry, phi_deg, large, sweep = seg
    phi = math.radians(phi_deg)
    cphi, sphi = math.cos(phi), math.sin(phi)
    dx2, dy2 = (p0[0] - p1[0]) / 2, (p0[1] - p1[1]) / 2
    x1p = cphi * dx2 + sphi * dy2
    y1p = -sphi * dx2 + cphi * dy2
    lam = x1p**2 / rx**2 + y1p**2 / ry**2
    if lam > 1:
        rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num = rx**2 * ry**2 - rx**2 * y1p**2 - ry**2 * x1p**2
    den = rx**2 * y1p**2 + ry**2 * x1p**2
    coef = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large == sweep:
        coef = -coef
    cxp, cyp = coef * rx * y1p / ry, -coef * ry * x1p / rx
    cx = cphi * cxp - sphi * cyp + (p0[0] + p1[0]) / 2
    cy = sphi * cxp + cphi * cyp + (p0[1] + p1[1]) / 2

    def ang(ux, uy, vx, vy):
        return math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)

    t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi
    return (cx, cy), rx, ry, phi, t1, dt


def _ellipse_to_cubics(c, rx, ry, phi, t1, dt, p_end):
    n = max(1, math.ceil(abs(dt) / (math.pi / 2) - 1e-9))
    d = dt / n
    k = 4 / 3 * math.tan(d / 4)
    cphi, sphi = math.cos(phi), math.sin(phi)

    def pt(t):
        x, y = rx * math.cos(t), ry * math.sin(t)
        return (c[0] + cphi * x - sphi * y, c[1] + sphi * x + cphi * y)

    def dpt(t):
        x, y = -rx * math.sin(t), ry * math.cos(t)
        return (cphi * x - sphi * y, sphi * x + cphi * y)

    out = []
    for i in range(n):
        a, b = t1 + i * d, t1 + (i + 1) * d
        pa, pb, da, db = pt(a), pt(b), dpt(a), dpt(b)
        end = p_end if i == n - 1 else pb
        out.append(("C", (pa[0] + k * da[0], pa[1] + k * da[1]), (pb[0] - k * db[0], pb[1] - k * db[1]), end))
    return out


def transform_subpath(sp: Subpath, m: Matrix) -> Subpath:
    out = Subpath(apply(m, sp.start), closed=sp.closed)
    sim = is_similarity(m)
    flip = det(m) < 0
    cur = sp.start
    for seg in sp.segs:
        if seg[0] == "L":
            out.segs.append(("L", apply(m, seg[1])))
        elif seg[0] == "C":
            out.segs.append(("C", apply(m, seg[1]), apply(m, seg[2]), apply(m, seg[3])))
        else:  # "E"
            c, rx, ry, phi, t1, dt = _arc_center(cur, seg)
            if sim and abs(rx - ry) <= 1e-9 * max(rx, ry):
                out.segs.append(("A", apply(m, seg[1]), apply(m, c), (dt > 0) != flip))
            else:
                for cseg in _ellipse_to_cubics(c, rx, ry, phi, t1, dt, seg[1]):
                    out.segs.append(("C", apply(m, cseg[1]), apply(m, cseg[2]), apply(m, cseg[3])))
        cur = seg[1] if seg[0] != "C" else seg[3]
    return out


def to_outline(sp: Subpath) -> Outline:
    """Final page-space subpath -> Outline (arc direction expressed for y-up space)."""
    segs = []
    for s in sp.segs:
        if s[0] == "L":
            segs.append(("L", *s[1]))
        elif s[0] == "C":
            segs.append(("C", *s[1], *s[2], *s[3]))
        else:
            segs.append(("A", *s[1], *s[2], not s[3]))  # positive angle in y-up = counter-clockwise
    return Outline(sp.start, segs)


# ---------------------------------------------------------------------------
# Document walk and placement
# ---------------------------------------------------------------------------
@dataclass
class ImportResult:
    outline: Outline | None
    candidates: list[tuple[str, Outline]]  # (element id or tag, outline) for every closed subpath
    notes: list[str]
    placement: Matrix


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _walk(el: ET.Element, ctm: Matrix, out: list, notes: list) -> None:
    tag = _local(el.tag)
    m = mul(ctm, parse_transform(el.get("transform")))
    if tag in ("svg", "g"):
        for child in el:
            _walk(child, m if tag == "g" else ctm, out, notes)
        return
    if tag in ("use", "symbol", "clipPath", "mask", "text", "style", "defs"):
        if tag not in ("defs",):
            notes.append(f"<{tag}> not supported, ignored")
        return
    if el.get("style") and re.search(r"transform|\bd\s*:", el.get("style", "")):
        notes.append(f"style attribute on <{tag}> may change geometry; ignored")
    d = shape_to_d(el, tag)
    if d is None:
        return
    if el.get("stroke-width") or "stroke" in (el.get("style") or ""):
        notes.append(f"stroke on <{tag}> ignored: the outline is the geometry's centre line")
    for sp in parse_path(d):
        out.append((el.get("id") or tag, sp, m))


def viewport(root: ET.Element) -> tuple[tuple[float, float, float, float], float | None, float | None, str]:
    vb = root.get("viewBox")
    w, h = parse_length(root.get("width")), parse_length(root.get("height"))
    if vb:
        x, y, vw, vh = (float(t) for t in NUM_RE.findall(vb))
    else:
        x, y, vw, vh = 0.0, 0.0, w or 0.0, h or 0.0
    return (x, y, vw, vh), w, h, root.get("preserveAspectRatio", "xMidYMid meet")


def _aspect_matrix(vb, vpw, vph, par: str) -> Matrix:
    """viewBox -> viewport (SVG 'preserveAspectRatio' rules)."""
    x, y, vw, vh = vb
    sx, sy = vpw / vw, vph / vh
    parts = par.split()
    align = parts[0] if parts else "xMidYMid"
    slice_ = len(parts) > 1 and parts[1] == "slice"
    if align == "none":
        return (sx, 0, 0, sy, -x * sx, -y * sy)
    s = max(sx, sy) if slice_ else min(sx, sy)
    tx, ty = -x * s, -y * s
    if "xMid" in align:
        tx += (vpw - vw * s) / 2
    elif "xMax" in align:
        tx += vpw - vw * s
    if "YMid" in align:
        ty += (vph - vh * s) / 2
    elif "YMax" in align:
        ty += vph - vh * s
    return (s, 0, 0, s, tx, ty)


def placement_matrix(root: ET.Element, page_w: float, page_h: float, mode: str) -> tuple[Matrix, list[str]]:
    """Root user space -> PDF page space (y up)."""
    notes = []
    vb, w, h, par = viewport(root)
    flip = (1, 0, 0, -1, 0, page_h)
    if mode == "fit":
        # Fit to page: viewBox onto the MediaBox. A uniform scale keeps circular
        # arcs exact; when the aspect ratios differ (allowed up to 1 %), the shape
        # is centred ("meet") rather than stretched.
        ratio = (vb[2] / vb[3]) / (page_w / page_h)
        if abs(ratio - 1) > 0.01:
            notes.append(f"aspect ratio differs from the page by {abs(ratio - 1) * 100:.2f} %: "
                         "Actual size would be the default")
        m = _aspect_matrix(vb, page_w, page_h, "xMidYMid meet")
        return mul(flip, m), notes
    # Actual size: user units -> viewport px (96/in) -> pt, centred on the page
    vpw, vph = (w or vb[2]), (h or vb[3])
    m = _aspect_matrix(vb, vpw, vph, par)
    to_pt = (0.75, 0, 0, 0.75, 0, 0)
    centre = (1, 0, 0, 1, (page_w - vpw * 0.75) / 2, (page_h - vph * 0.75) / 2)
    return mul(flip, mul(centre, mul(to_pt, m))), notes


def import_svg(path_or_text: str, page_w: float, page_h: float, mode: str = "fit") -> ImportResult:
    text = path_or_text if path_or_text.lstrip().startswith("<") else open(path_or_text, encoding="utf-8").read()
    root = ET.fromstring(text)
    place, notes = placement_matrix(root, page_w, page_h, mode)
    found: list = []
    _walk(root, IDENTITY, found, notes)
    candidates = []
    from outline import area

    for name, sp, m in found:
        closed = sp.closed or (sp.segs and math.dist(sp.start, _end(sp.segs[-1])) < 1e-9)
        if not closed:
            notes.append(f"open subpath in <{name}> ignored")
            continue
        if not sp.segs:
            continue
        o = to_outline(transform_subpath(sp, mul(place, m)))
        candidates.append((name, o))
    best = max(candidates, key=lambda c: abs(area(c[1])))[1] if candidates else None
    if len(candidates) > 1:
        notes.append(f"{len(candidates)} closed shapes; the largest was chosen")
    return ImportResult(best, candidates, notes, place)


def _end(seg):
    return seg[1] if seg[0] in ("L", "E", "A") else seg[3]

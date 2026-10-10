"""Outline geometry (SPEC 5.1): one closed path of line, arc and curve segments
in PDF user space (points, y up).

Representation, kept deliberately plain so it ports to a Swift enum:
    Outline(start=(x, y), segments=[...]) where each segment is a tuple
    ("L", x, y)
    ("A", x, y, cx, cy, cw)        cw: True = clockwise (in y-up user space)
    ("C", x1, y1, x2, y2, x, y)
The path is implicitly closed back to `start`.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field

import numpy as np


@dataclass
class Outline:
    start: tuple[float, float]
    segments: list[tuple] = field(default_factory=list)

    def end_points(self) -> list[tuple[float, float]]:
        pts = [self.start]
        for s in self.segments:
            pts.append((s[1], s[2]) if s[0] in ("L", "A") else (s[5], s[6]))
        return pts

    def counts(self) -> dict[str, int]:
        out = {"L": 0, "A": 0, "C": 0}
        for s in self.segments:
            out[s[0]] += 1
        return out


# ---------------------------------------------------------------------------
# Arcs
# ---------------------------------------------------------------------------
def arc_sweep(p0, p1, c, cw: bool) -> tuple[float, float, float]:
    """Return (radius, start_angle, signed_sweep) for an arc from p0 to p1 around c."""
    a0 = math.atan2(p0[1] - c[1], p0[0] - c[0])
    a1 = math.atan2(p1[1] - c[1], p1[0] - c[0])
    r = math.hypot(p0[0] - c[0], p0[1] - c[1])
    if cw:
        sweep = -((a0 - a1) % (2 * math.pi))
    else:
        sweep = (a1 - a0) % (2 * math.pi)
    if abs(sweep) < 1e-12:  # a closed full circle is not a valid single segment
        sweep = -2 * math.pi if cw else 2 * math.pi
    return r, a0, sweep


def arc_to_beziers(p0, p1, c, cw: bool) -> list[tuple[float, ...]]:
    """Split an arc into cubic Béziers of at most 90 degrees each (SPEC 5.1)."""
    r, a0, sweep = arc_sweep(p0, p1, c, cw)
    n = max(1, math.ceil(abs(sweep) / (math.pi / 2) - 1e-9))
    d = sweep / n
    k = 4.0 / 3.0 * math.tan(d / 4.0)
    out = []
    for i in range(n):
        s, e = a0 + i * d, a0 + (i + 1) * d
        x1 = c[0] + r * (math.cos(s) - k * math.sin(s))
        y1 = c[1] + r * (math.sin(s) + k * math.cos(s))
        x2 = c[0] + r * (math.cos(e) + k * math.sin(e))
        y2 = c[1] + r * (math.sin(e) - k * math.cos(e))
        if i == n - 1:
            x, y = p1
        else:
            x, y = c[0] + r * math.cos(e), c[1] + r * math.sin(e)
        out.append((x1, y1, x2, y2, x, y))
    return out


# ---------------------------------------------------------------------------
# PDF path operators
# ---------------------------------------------------------------------------
def fmt(v: float) -> str:
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return "0" if s in ("", "-0") else s


def to_pdf_path(o: Outline) -> str:
    ops = [f"{fmt(o.start[0])} {fmt(o.start[1])} m"]
    cur = o.start
    for s in o.segments:
        if s[0] == "L":
            ops.append(f"{fmt(s[1])} {fmt(s[2])} l")
            cur = (s[1], s[2])
        elif s[0] == "C":
            ops.append(" ".join(fmt(v) for v in s[1:]) + " c")
            cur = (s[5], s[6])
        elif s[0] == "A":
            for b in arc_to_beziers(cur, (s[1], s[2]), (s[3], s[4]), s[5]):
                ops.append(" ".join(fmt(v) for v in b) + " c")
            cur = (s[1], s[2])
    ops.append("h")
    return "\n".join(ops)


def segments_to_pdf_array(o: Outline) -> str:
    """SPEC 5.4 /Segments syntax."""
    items = []
    for s in o.segments:
        if s[0] == "L":
            items.append(f"[/L {fmt(s[1])} {fmt(s[2])}]")
        elif s[0] == "A":
            items.append(f"[/A {fmt(s[1])} {fmt(s[2])} {fmt(s[3])} {fmt(s[4])} /{'CW' if s[5] else 'CCW'}]")
        else:
            items.append("[/C " + " ".join(fmt(v) for v in s[1:]) + "]")
    return "[" + " ".join(items) + "]"


def segments_from_pdf_array(start: str, segments: str) -> Outline:
    """Parse /Start and /Segments values as returned by MuPDF (compact syntax)."""
    sx, sy = (float(v) for v in re.findall(r"-?[\d.]+", start))
    segs = []
    for item in re.findall(r"\[\s*/(L|A|C)([^\[\]]*)\]", segments):
        kind, body = item
        nums = [float(v) for v in re.findall(r"-?\d*\.?\d+", body)]
        if kind == "L":
            segs.append(("L", nums[0], nums[1]))
        elif kind == "C":
            segs.append(("C", *nums[:6]))
        else:
            segs.append(("A", *nums[:4], "/CW" in body and "/CCW" not in body))
    return Outline((sx, sy), segs)


# ---------------------------------------------------------------------------
# Flattening and rasterising (independent of the Bézier approximation used in
# the PDF, so it can be used as a reference: arcs are sampled on the true circle)
# ---------------------------------------------------------------------------
def flatten(o: Outline, step: float = 0.25) -> np.ndarray:
    pts = [o.start]
    cur = o.start
    for s in o.segments:
        if s[0] == "L":
            p1 = (s[1], s[2])
            n = max(1, int(math.hypot(p1[0] - cur[0], p1[1] - cur[1]) / step))
            for i in range(1, n + 1):
                t = i / n
                pts.append((cur[0] + (p1[0] - cur[0]) * t, cur[1] + (p1[1] - cur[1]) * t))
            cur = p1
        elif s[0] == "A":
            p1, c = (s[1], s[2]), (s[3], s[4])
            r, a0, sweep = arc_sweep(cur, p1, c, s[5])
            n = max(2, int(abs(sweep) * r / step))
            for i in range(1, n + 1):
                a = a0 + sweep * i / n
                pts.append((c[0] + r * math.cos(a), c[1] + r * math.sin(a)))
            cur = p1
        else:
            x1, y1, x2, y2, x, y = s[1:]
            poly_len = (math.hypot(x1 - cur[0], y1 - cur[1]) + math.hypot(x2 - x1, y2 - y1)
                        + math.hypot(x - x2, y - y2))
            n = max(8, int(poly_len / step))
            for i in range(1, n + 1):
                t = i / n
                mt = 1 - t
                pts.append((
                    mt**3 * cur[0] + 3 * mt * mt * t * x1 + 3 * mt * t * t * x2 + t**3 * x,
                    mt**3 * cur[1] + 3 * mt * mt * t * y1 + 3 * mt * t * t * y2 + t**3 * y,
                ))
            cur = (x, y)
    return np.array(pts)


def raster_mask(o: Outline, page_w: float, page_h: float, dpi: int, shape: tuple[int, int]) -> np.ndarray:
    """Boolean mask of pixel centres inside the outline (even-odd), image rows top-down."""
    s = dpi / 72.0
    h, w = shape
    px = (np.arange(w) + 0.5) / s
    py = page_h - (np.arange(h) + 0.5) / s
    X, Y = np.meshgrid(px, py)
    poly = flatten(o, step=0.05)
    inside = np.zeros(shape, dtype=bool)
    x1, y1 = poly[:-1, 0], poly[:-1, 1]
    x2, y2 = poly[1:, 0], poly[1:, 1]
    # close
    x1 = np.append(x1, poly[-1, 0]); y1 = np.append(y1, poly[-1, 1])
    x2 = np.append(x2, poly[0, 0]); y2 = np.append(y2, poly[0, 1])
    for a, b, c, d in zip(x1, y1, x2, y2):
        if b == d:
            continue
        lo, hi = min(b, d), max(b, d)
        rows = np.where((py >= lo) & (py < hi))[0]
        if rows.size == 0:
            continue
        yy = Y[rows]
        xint = a + (yy - b) * (c - a) / (d - b)
        inside[rows] ^= X[rows] < xint
    return inside


def area(o: Outline) -> float:
    p = flatten(o, step=1.0)
    return 0.5 * float(np.sum(p[:-1, 0] * p[1:, 1] - p[1:, 0] * p[:-1, 1]) + (p[-1, 0] * p[0, 1] - p[0, 0] * p[-1, 1]))


def hausdorff(a: Outline, b: Outline, step: float = 0.1) -> float:
    pa, pb = flatten(a, step), flatten(b, step)

    def directed(p, q):
        best = np.full(len(p), np.inf)
        for i in range(0, len(q), 2048):
            chunk = q[i:i + 2048]
            d = np.hypot(p[:, None, 0] - chunk[None, :, 0], p[:, None, 1] - chunk[None, :, 1])
            best = np.minimum(best, d.min(axis=1))
        return best.max()

    return max(directed(pa, pb), directed(pb, pa))


# ---------------------------------------------------------------------------
# Reference shapes on an 842 x 595 page
# ---------------------------------------------------------------------------
PAGE_W, PAGE_H = 842.0, 595.0
R_CX, R_CY, R_R = 564.5, 297.5, 247.5


def reference_outline() -> Outline:
    """Stepped left edge (a symmetric notch: 4 jogs) and a semicircular right end.
    11 lines + 1 arc."""
    return Outline(
        (564.5, 545),
        [
            ("L", 40, 545), ("L", 40, 460), ("L", 60, 460), ("L", 60, 380), ("L", 80, 380),
            ("L", 80, 215), ("L", 60, 215), ("L", 60, 135), ("L", 40, 135), ("L", 40, 50),
            ("L", 564.5, 50),
            ("A", 564.5, 545, R_CX, R_CY, False),  # bottom -> right -> top: counter-clockwise
        ],
    )


def edited_outline() -> Outline:
    """The re-edit case: deeper steps and a smaller right end."""
    return Outline(
        (520, 525),
        [
            ("L", 30, 525), ("L", 30, 430), ("L", 70, 430), ("L", 70, 165), ("L", 30, 165),
            ("L", 30, 70), ("L", 520, 70),
            ("A", 520, 525, 520, 297.5, False),
        ],
    )


def curve_outline() -> Outline:
    """Reference shape with the bottom edge replaced by a cubic wave."""
    o = reference_outline()
    segs = list(o.segments)
    i = segs.index(("L", 564.5, 50))
    segs[i] = ("C", 200, 10, 400, 110, 564.5, 50)
    return Outline(o.start, segs)

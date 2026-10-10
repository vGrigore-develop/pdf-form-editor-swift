"""Primitive fitting and simplification, first version (SPEC 5.6.3).

Steps, all within `tol` (pt):
  0. curves whose control points lie on the chord become lines;
  1. runs of nearly collinear lines merge into one line;
  2. lines within 0.5 degrees of horizontal/vertical snap to exact orthogonals;
  3. runs of curves that fit one circle (least squares, max deviation < tol,
     constrained through the run's end points) become one arc;
  4. (not yet) merging adjacent curves into one cubic;
  5. end points snap to shared x / y values;
  6. arc centres are re-projected onto the bisector of their (possibly moved)
     end points, so every arc stays exactly consistent.

Internal form: a cyclic vertex list V and, per edge i (V[i] -> V[i+1]):
  ("L",) | ("C", c1, c2) | ("A", centre, cw)
"""

from __future__ import annotations

import math

import numpy as np

from outline import Outline

ORTHO_DEG = 0.5


def _to_cyclic(o: Outline):
    V = [o.start]
    E = []
    cur = o.start
    for s in o.segments:
        if s[0] == "L":
            p = (s[1], s[2]); E.append(("L",))
        elif s[0] == "C":
            p = (s[5], s[6]); E.append(("C", (s[1], s[2]), (s[3], s[4])))
        else:
            p = (s[1], s[2]); E.append(("A", (s[3], s[4]), s[5]))
        V.append(p)
        cur = p
    if math.dist(V[-1], V[0]) < 1e-9:
        V.pop()
    else:
        E.append(("L",))  # implicit closing line made explicit
    return V, E


def _from_cyclic(V, E) -> Outline:
    segs = []
    n = len(V)
    for i, e in enumerate(E):
        p = V[(i + 1) % n]
        if e[0] == "L":
            segs.append(("L", *p))
        elif e[0] == "C":
            segs.append(("C", *e[1], *e[2], *p))
        else:
            segs.append(("A", *p, *e[1], e[2]))
    return Outline(V[0], segs)


def _dist_to_segment(p, a, b) -> float:
    ax, ay = a; bx, by = b; px, py = p
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    if L2 == 0:
        return math.dist(p, a)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L2))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def _bezier(p0, c1, c2, p1, ts):
    ts = np.asarray(ts)[:, None]
    mt = 1 - ts
    P = np.array([p0, c1, c2, p1], dtype=float)
    return mt**3 * P[0] + 3 * mt**2 * ts * P[1] + 3 * mt * ts**2 * P[2] + ts**3 * P[3]


# --- step 0 -------------------------------------------------------------------
def curves_to_lines(V, E, tol):
    n = len(V)
    for i, e in enumerate(E):
        if e[0] == "C":
            a, b = V[i], V[(i + 1) % n]
            pts = _bezier(a, e[1], e[2], b, np.linspace(0, 1, 17))
            if all(_dist_to_segment(p, a, b) <= tol for p in pts):
                E[i] = ("L",)
    return V, E


# --- step 1 -------------------------------------------------------------------
def merge_lines(V, E, tol):
    n = len(V)

    def corner(i):  # vertex i cannot be removed by merging its two neighbouring lines
        a, m, b = V[(i - 1) % n], V[i], V[(i + 1) % n]
        if E[(i - 1) % n][0] != "L" or E[i][0] != "L":
            return True
        return _dist_to_segment(m, a, b) > tol

    # Start at a corner so a run never wraps around the start point.
    s = next((i for i in range(n) if corner(i)), None)
    if s is None:
        return V, E
    pos = [(s + k) % n for k in range(n)] + [s]  # pos[n] closes the loop
    newV, newE = [], []
    k = 0
    while k < n:
        i = pos[k]
        newV.append(V[i])
        if E[i][0] != "L":
            newE.append(E[i])
            k += 1
            continue
        j = k + 1  # current run is pos[k] .. pos[j]
        while j < n and E[pos[j]][0] == "L":
            a, b = V[i], V[pos[j + 1]]
            if all(_dist_to_segment(V[pos[t]], a, b) <= tol for t in range(k + 1, j + 1)):
                j += 1
            else:
                break
        newE.append(("L",))
        k = j
    return newV, newE


# --- step 2 -------------------------------------------------------------------
def snap_orthogonal(V, E):
    n = len(V)
    V = [list(p) for p in V]
    for i, e in enumerate(E):
        if e[0] != "L":
            continue
        a, b = V[i], V[(i + 1) % n]
        ang = math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])) % 180
        if min(ang, 180 - ang) <= ORTHO_DEG:
            y = (a[1] + b[1]) / 2; a[1] = b[1] = y
        elif abs(ang - 90) <= ORTHO_DEG:
            x = (a[0] + b[0]) / 2; a[0] = b[0] = x
    return [tuple(p) for p in V], E


# --- step 3 -------------------------------------------------------------------
def _fit_arc(p0, p1, pts, tol):
    """Circle through p0 and p1 that best fits pts; returns (centre, cw, maxdev) or None."""
    if math.dist(p0, p1) < 1e-6:
        return None
    pts = np.asarray(pts)
    # Kasa algebraic fit for a starting centre
    A = np.c_[pts[:, 0], pts[:, 1], np.ones(len(pts))]
    rhs = -(pts[:, 0] ** 2 + pts[:, 1] ** 2)
    (D, Ec, _F), *_ = np.linalg.lstsq(A, rhs, rcond=None)
    c0 = np.array([-D / 2, -Ec / 2])
    # Constrain the centre to the perpendicular bisector of p0-p1, then 1-D refine
    m = (np.array(p0) + np.array(p1)) / 2
    d = np.array(p1) - np.array(p0)
    nrm = np.array([-d[1], d[0]]) / np.linalg.norm(d)
    t0 = float(np.dot(c0 - m, nrm))

    def cost(t):
        c = m + t * nrm
        r = np.linalg.norm(np.array(p0) - c)
        return float(np.max(np.abs(np.linalg.norm(pts - c, axis=1) - r)))

    lo, hi = t0 - 0.05 * abs(t0) - 1, t0 + 0.05 * abs(t0) + 1
    for _ in range(80):  # golden-section search on the max deviation
        a = hi - (hi - lo) * 0.618
        b = lo + (hi - lo) * 0.618
        if cost(a) < cost(b):
            hi = b
        else:
            lo = a
    t = (lo + hi) / 2
    c = m + t * nrm
    dev = cost(t)
    r = float(np.linalg.norm(np.array(p0) - c))
    if dev > tol or r > 1e4:
        return None
    ang = np.unwrap(np.arctan2(pts[:, 1] - c[1], pts[:, 0] - c[0]))
    steps = np.diff(ang)
    if not (np.all(steps > 0) or np.all(steps < 0)):
        return None
    sweep = ang[-1] - ang[0]
    if abs(sweep) >= 2 * math.pi - 1e-6:
        return None
    return (float(c[0]), float(c[1])), bool(sweep < 0), dev


def curves_to_arcs(V, E, tol):
    n = len(V)
    i = 0
    newV, newE = [], []
    # rotate so we don't start inside a run of curves
    s = next((k for k in range(n) if E[k - 1][0] != "C"), 0)
    V = V[s:] + V[:s]
    E = E[s:] + E[:s]
    while i < n:
        if E[i][0] != "C":
            newV.append(V[i]); newE.append(E[i]); i += 1
            continue
        best = None
        j = i
        while j < n and E[j][0] == "C":
            pts = [V[i]]
            for k in range(i, j + 1):
                e = E[k]
                pts.extend(_bezier(V[k], e[1], e[2], V[(k + 1) % n], np.linspace(0, 1, 17))[1:].tolist())
            fit = _fit_arc(V[i], V[(j + 1) % n], pts, tol)
            if fit is None:
                break
            best = (j, fit)
            j += 1
        if best is None:
            newV.append(V[i]); newE.append(E[i]); i += 1
        else:
            j, (c, cw, _dev) = best
            newV.append(V[i]); newE.append(("A", c, cw)); i = j + 1
    return newV, newE


# --- step 5 and 6 ---------------------------------------------------------------
def snap_shared(V, tol):
    V = [list(p) for p in V]
    for axis in (0, 1):
        order = sorted(range(len(V)), key=lambda k: V[k][axis])
        cluster = [order[0]]
        for k in order[1:] + [None]:
            if k is not None and V[k][axis] - V[cluster[0]][axis] <= tol:
                cluster.append(k)
                continue
            if len(cluster) > 1:
                mean = sum(V[c][axis] for c in cluster) / len(cluster)
                for c in cluster:
                    V[c][axis] = mean
            cluster = [k] if k is not None else []
    return [tuple(p) for p in V]


def fix_arcs(V, E):
    n = len(V)
    for i, e in enumerate(E):
        if e[0] == "A":
            p0, p1 = np.array(V[i]), np.array(V[(i + 1) % n])
            m = (p0 + p1) / 2
            d = p1 - p0
            nrm = np.array([-d[1], d[0]]) / np.linalg.norm(d)
            c = m + np.dot(np.array(e[1]) - m, nrm) * nrm
            E[i] = ("A", (float(c[0]), float(c[1])), e[2])
    return E


def fit_primitives(o: Outline, tol: float) -> Outline:
    V, E = _to_cyclic(o)
    V, E = curves_to_lines(V, E, tol)
    V, E = merge_lines(V, E, tol)
    V, E = snap_orthogonal(V, E)
    V, E = curves_to_arcs(V, E, tol)
    V = snap_shared(V, tol)
    E = fix_arcs(V, E)
    return _from_cyclic(V, E)

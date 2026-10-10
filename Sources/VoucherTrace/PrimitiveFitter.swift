import Foundation
import VoucherModel
import VoucherGeometry

/// Fits lines and circular arcs to a dense closed polyline (a traced edge), within a
/// tolerance in points (SPEC 5.6.3). The result is an ordinary `Outline`.
///
/// 1. Resample to at most `tolerance` spacing and start at the sharpest corner.
/// 2. Greedy segmentation: from the current point, the longest run that one line fits
///    (total least squares, max deviation <= tol) and the longest run one circle fits
///    (algebraic fit refined geometrically, max deviation <= tol, monotonic sweep); the
///    arc wins only when it covers clearly more (so straight runs stay lines).
/// 3. Primitives shorter than about 2 tol are dropped (a live-wire path cuts corners by a
///    pixel or two), and each primitive is refitted on its interior points.
/// 4. Vertices are the intersections of neighbouring primitives (line/line, line/circle,
///    tangent point, circle/circle) near the break, so corners are sharp even when the
///    trace rounded them.
/// 5. The `spikes/fitting.py` passes: merge collinear lines, snap lines within 0.5 degrees
///    (or within the tolerance) of horizontal/vertical to exact orthogonals, merge arcs
///    on one circle, snap end points to shared x/y within the tolerance, and put every
///    arc centre back on its chord's bisector so each arc stays exactly consistent.
public enum PrimitiveFitter {
    public static let orthoDegrees = 0.5
    public static let maxRadius = 1e4

    // MARK: Internal representation

    enum Geo {
        case line(p: PDFPoint, d: PDFPoint)               // point on line, unit direction
        case arc(c: PDFPoint, r: Double, cw: Bool)
    }

    struct Prim {
        var isArc: Bool
        var lo: Int
        var hi: Int
    }

    /// Cyclic edge kinds after vertex construction (V[i] -> V[i+1]).
    enum Edge: Equatable {
        case line
        case arc(c: PDFPoint, cw: Bool)
    }

    // MARK: Entry point

    /// Lines and arcs fitted to the closed polyline `input` (the last point connects back
    /// to the first). Nil when the input is degenerate.
    /// `cornerCheck`, when given, confirms a sharp corner before a short line across it is
    /// replaced by the corner point (the trace's raster knows whether the artwork has an
    /// edge there, or a real small bevel).
    public static func fitClosed(_ input: [PDFPoint], tolerance tol: Double, cornerCheck: ((PDFPoint) -> Bool)? = nil) -> Outline? {
        let tol = max(0.01, tol)
        var pts = dedupe(input)
        guard pts.count >= 3 else { return nil }
        pts = resample(pts, maxSpacing: max(0.1, min(1.0, tol)))
        // Corners first: the trace rounds them, so the polyline is cut there, a little of it
        // either side is left out, and the smooth runs in between are fitted on their own.
        // Measured over 4 pt either side, longer than the 1-2 pt a trace rounds a corner by.
        let reach = max(4.0, 8 * tol)
        let corners = detectCorners(pts, reach: reach)
        let start = corners.first ?? sharpestCorner(pts, reach: reach)
        let R = Array(pts[start...] + pts[..<start]) + [pts[start]]
        let n = pts.count
        var prims: [Prim] = []
        var cornerAt: [Int: Int] = [:] // prim index starting right after a corner -> R index of that corner
        if corners.isEmpty {
            prims = dropTiny(segment(R, 0, R.count - 1, tol: tol), R, minLen: max(1.5, 3 * tol))
        } else {
            let cs = corners.map { ($0 - start + n) % n }.sorted() + [n]
            let trim = max(2.5, 4 * tol) // a live wire cuts a corner by up to about 4 px (2 pt at 150 dpi)
            for k in 0..<(cs.count - 1) {
                var lo = cs[k], hi = cs[k + 1]
                while lo < hi - 2, R[lo].distance(to: R[cs[k]]) < trim { lo += 1 }
                while hi > lo + 2, R[hi].distance(to: R[cs[k + 1]]) < trim { hi -= 1 }
                cornerAt[prims.count] = cs[k]
                prims += dropTiny(segment(R, lo, hi, tol: tol), R, minLen: max(1.5, 3 * tol))
            }
        }
        guard prims.count >= 2 else { return nil }
        var geos = prims.map { geometry($0, R, tol: tol) }
        let dmax = max(2.5, 5 * tol)
        var V = vertices(geos, prims, R, corners: cornerAt, dmax: dmax, tol: tol)
        // Second pass: refit each line on the points between its own two vertices only (a
        // line that ran on into a tangent arc, or around a rounded corner, is pulled back
        // out of it), then recompute the vertices.
        for k in prims.indices {
            guard case .line = geos[k] else { continue }
            let a = V[k], b = V[(k + 1) % V.count]
            let ab = b - a, len2 = ab.x * ab.x + ab.y * ab.y
            guard len2 > 1e-12 else { continue }
            let sel = (prims[k].lo...prims[k].hi).filter { i in
                let t = ((R[i].x - a.x) * ab.x + (R[i].y - a.y) * ab.y) / len2
                return t > 0.02 && t < 0.98 && Geometry.distance(from: R[i], toSegment: a, b) <= tol
            }
            guard sel.count >= 3 else { continue }
            let sub = sel.map { R[$0] }
            let f = fitLine(sub, 0, sub.count - 1)
            var d = f.d
            if ab.x * d.x + ab.y * d.y < 0 { d = PDFPoint(-d.x, -d.y) }
            geos[k] = .line(p: f.p, d: d)
        }
        V = vertices(geos, prims, R, corners: cornerAt, dmax: dmax, tol: tol)
        var poly = Poly(V: V, E: geos.map {
            switch $0 {
            case .line: return .line
            case .arc(let c, _, let cw): return .arc(c: c, cw: cw)
            }
        }, S: prims.map { Array($0.lo...$0.hi) }, R: R, trim: max(1.5, 3 * tol))
        poly.removeShortEdges(minLen: 1e-6)
        poly.demoteSmallArcs(tol: tol)
        poly.sharpenCorners(maxLen: max(5.0, 10 * tol), isCorner: cornerCheck)
        poly.mergeLines(tol: tol)
        poly.mergeArcs(tol: tol)
        poly.V = snapOrthogonal(poly.V, poly.E, tol: tol)
        poly.V = snapShared(poly.V, tol: tol)
        poly.removeShortEdges(minLen: 1e-6)
        poly.mergeLines(tol: tol)
        poly.fitArcsThroughEnds()
        let E = poly.E
        V = poly.V
        guard V.count >= 2 else { return nil }
        var segs: [Segment] = []
        for i in V.indices {
            let to = V[(i + 1) % V.count]
            switch E[i] {
            case .line: segs.append(.line(to: to))
            case .arc(let c, let cw): segs.append(.arc(to: to, center: c, clockwise: cw))
            }
        }
        return Outline(start: V[0], segments: segs)
    }

    // MARK: Preparation

    static func dedupe(_ pts: [PDFPoint]) -> [PDFPoint] {
        var out: [PDFPoint] = []
        for p in pts where out.last.map({ $0.distance(to: p) > 1e-6 }) ?? true { out.append(p) }
        while out.count > 1, out.last!.distance(to: out[0]) <= 1e-6 { out.removeLast() }
        return out
    }

    static func resample(_ pts: [PDFPoint], maxSpacing s: Double) -> [PDFPoint] {
        var out: [PDFPoint] = []
        for i in pts.indices {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            out.append(a)
            let d = a.distance(to: b)
            if d > s {
                let n = Int((d / s).rounded(.up))
                for k in 1..<n {
                    let t = Double(k) / Double(n)
                    out.append(PDFPoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
                }
            }
        }
        return out
    }

    /// Index with the largest turning angle measured over `reach` points of arc length.
    static func sharpestCorner(_ pts: [PDFPoint], reach: Double) -> Int {
        let n = pts.count
        var total = 0.0
        for i in 0..<n { total += pts[i].distance(to: pts[(i + 1) % n]) }
        let k = max(1, min(n / 4, Int((reach / max(1e-9, total / Double(n))).rounded(.up))))
        var best = 0, bestAngle = -1.0
        for i in 0..<n {
            let a = pts[(i - k + n) % n], m = pts[i], b = pts[(i + k) % n]
            let u = m - a, v = b - m
            let lu = hypot(u.x, u.y), lv = hypot(v.x, v.y)
            guard lu > 1e-9, lv > 1e-9 else { continue }
            let cosang = max(-1, min(1, (u.x * v.x + u.y * v.y) / (lu * lv)))
            let ang = acos(cosang)
            if ang > bestAngle + 1e-9 { bestAngle = ang; best = i }
        }
        return best
    }

    // MARK: Fits

    struct LineFit { var p: PDFPoint; var d: PDFPoint; var maxDev: Double }

    static func fitLine(_ R: [PDFPoint], _ lo: Int, _ hi: Int) -> LineFit {
        let n = Double(hi - lo + 1)
        var mx = 0.0, my = 0.0
        for i in lo...hi { mx += R[i].x; my += R[i].y }
        mx /= n; my /= n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in lo...hi {
            let dx = R[i].x - mx, dy = R[i].y - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        var d = PDFPoint(cos(theta), sin(theta))
        if sxx + syy < 1e-18 {
            let c = R[hi] - R[lo], l = hypot(c.x, c.y)
            d = l > 1e-12 ? PDFPoint(c.x / l, c.y / l) : PDFPoint(1, 0)
        }
        var dev = 0.0
        for i in lo...hi { dev = max(dev, abs((R[i].x - mx) * -d.y + (R[i].y - my) * d.x)) }
        return LineFit(p: PDFPoint(mx, my), d: d, maxDev: dev)
    }

    struct CircleFit {
        var c: PDFPoint; var r: Double; var cw: Bool; var maxDev: Double; var sweep: Double

        /// Worth being an arc: visibly curved (no line fits it within the tolerance) and
        /// longer than a rounded-off corner of a trace.
        func worthIt(tol: Double) -> Bool {
            let sagitta = r * (1 - cos(min(abs(sweep), .pi) / 2))
            return sagitta > tol && r >= max(2.0, 4 * tol) && r * abs(sweep) >= max(5.0, 10 * tol)
        }
    }

    /// Circle through R[lo...hi]: algebraic (Kasa) fit, refined with a few Gauss-Newton
    /// steps on the geometric distance. Nil when the points are not an arc we accept.
    static func fitCircle(_ R: [PDFPoint], _ lo: Int, _ hi: Int, tol: Double) -> CircleFit? {
        let n = hi - lo + 1
        guard n >= 5 else { return nil }
        var mx = 0.0, my = 0.0
        for i in lo...hi { mx += R[i].x; my += R[i].y }
        mx /= Double(n); my /= Double(n)
        // Kasa: minimise sum (u^2 + v^2 + D u + E v + F)^2 in centred coordinates.
        var suu = 0.0, svv = 0.0, suv = 0.0, su = 0.0, sv = 0.0
        var suz = 0.0, svz = 0.0, sz = 0.0
        for i in lo...hi {
            let u = R[i].x - mx, v = R[i].y - my, z = u * u + v * v
            suu += u * u; svv += v * v; suv += u * v; su += u; sv += v
            suz += u * z; svz += v * z; sz += z
        }
        let A = [[suu, suv, su], [suv, svv, sv], [su, sv, Double(n)]]
        guard let sol = solve3(A, [-suz, -svz, -sz]) else { return nil }
        var cx = -sol[0] / 2, cy = -sol[1] / 2
        var r = (cx * cx + cy * cy - sol[2]).squareRoot()
        guard r.isFinite, r > 0 else { return nil }
        // Geometric refinement.
        for _ in 0..<4 {
            var JtJ = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
            var Jtr = [0.0, 0.0, 0.0]
            for i in lo...hi {
                let u = R[i].x - mx - cx, v = R[i].y - my - cy
                let d = max(1e-12, (u * u + v * v).squareRoot())
                let res = d - r
                let j = [-u / d, -v / d, -1.0]
                for a in 0..<3 {
                    Jtr[a] += j[a] * res
                    for b in 0..<3 { JtJ[a][b] += j[a] * j[b] }
                }
            }
            guard let step = solve3(JtJ, Jtr.map { -$0 }) else { break }
            cx += step[0]; cy += step[1]; r += step[2]
            if abs(step[0]) + abs(step[1]) + abs(step[2]) < 1e-9 { break }
        }
        guard r.isFinite, r <= maxRadius, r >= max(1.0, 3 * tol) else { return nil }
        let c = PDFPoint(cx + mx, cy + my)
        var dev = 0.0
        var prev = atan2(R[lo].y - c.y, R[lo].x - c.x)
        var acc = 0.0
        var angles: [Double] = [0]
        angles.reserveCapacity(n)
        for i in lo...hi {
            dev = max(dev, abs(R[i].distance(to: c) - r))
            if dev > tol { return nil }
            if i > lo {
                let a = atan2(R[i].y - c.y, R[i].x - c.x)
                var d = a - prev
                if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
                acc += d
                angles.append(acc)
                prev = a
            }
        }
        let sweep = acc
        guard abs(sweep) <= 2 * .pi - 0.2, abs(sweep) > 1e-6 else { return nil }
        // Monotonic within noise: never back up by more than the noise allows.
        let s = sweep > 0 ? 1.0 : -1.0
        let allowance = 2 * tol / r + 0.02
        var best = -Double.infinity
        for a in angles {
            let v = a * s
            if v < best - allowance { return nil }
            best = max(best, v)
        }
        return CircleFit(c: c, r: r, cw: sweep < 0, maxDev: dev, sweep: sweep)
    }

    static func solve3(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        var M = A
        var y = b
        for col in 0..<3 {
            var piv = col
            for r in (col + 1)..<3 where abs(M[r][col]) > abs(M[piv][col]) { piv = r }
            guard abs(M[piv][col]) > 1e-14 else { return nil }
            if piv != col { M.swapAt(piv, col); y.swapAt(piv, col) }
            for r in (col + 1)..<3 {
                let f = M[r][col] / M[col][col]
                for k in col..<3 { M[r][k] -= f * M[col][k] }
                y[r] -= f * y[col]
            }
        }
        var x = [0.0, 0.0, 0.0]
        for r in stride(from: 2, through: 0, by: -1) {
            var s = y[r]
            for k in (r + 1)..<3 { s -= M[r][k] * x[k] }
            x[r] = s / M[r][r]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    // MARK: Segmentation

    /// Largest `j` in `minEnd...maxEnd` with `fits(j)`, by galloping then bisection
    /// (assumes a fit that fails stays failing, which holds closely for these fits).
    static func furthest(minEnd: Int, maxEnd: Int, _ fits: (Int) -> Bool) -> Int? {
        guard minEnd <= maxEnd, fits(minEnd) else { return nil }
        var good = minEnd, step = 2
        var bad: Int?
        while good < maxEnd {
            let j = min(good + step, maxEnd)
            if fits(j) { good = j; step *= 2 } else { bad = j; break }
        }
        if var hiBad = bad {
            while hiBad - good > 1 {
                let mid = (good + hiBad) / 2
                if fits(mid) { good = mid } else { hiBad = mid }
            }
        }
        return good
    }

    static func segment(_ R: [PDFPoint], _ first: Int, _ last: Int, tol: Double) -> [Prim] {
        var prims: [Prim] = []
        var i = first
        while i < last {
            let lineEnd = furthest(minEnd: i + 1, maxEnd: last) { j in fitLine(R, i, j).maxDev <= tol } ?? (i + 1)
            var arcEnd: Int?
            if last - i >= 4 {
                arcEnd = furthest(minEnd: i + 4, maxEnd: last) { j in fitCircle(R, i, j, tol: tol) != nil }
            }
            if let a = arcEnd, a > lineEnd, Double(a - i) > 1.2 * Double(lineEnd - i),
               fitCircle(R, i, a, tol: tol)?.worthIt(tol: tol) == true {
                prims.append(Prim(isArc: true, lo: i, hi: a))
                i = a
            } else {
                prims.append(Prim(isArc: false, lo: i, hi: lineEnd))
                i = lineEnd
            }
        }
        return prims
    }

    /// Merge primitives whose chord is shorter than `minLen` into their neighbours (the
    /// break moves to the middle of the dropped run). The first and last are kept, since
    /// the polyline starts and ends at the sharpest corner.
    static func dropTiny(_ input: [Prim], _ R: [PDFPoint], minLen: Double) -> [Prim] {
        var prims = input
        var changed = true
        while changed && prims.count > 2 {
            changed = false
            for k in 1..<(prims.count - 1) {
                let p = prims[k]
                if R[p.lo].distance(to: R[p.hi]) < minLen {
                    let mid = (p.lo + p.hi) / 2
                    prims[k - 1].hi = mid
                    prims[k + 1].lo = mid
                    prims.remove(at: k)
                    changed = true
                    break
                }
            }
        }
        // Re-classify neighbours that grew: an arc that no longer fits becomes a line.
        return prims
    }

    /// Geometry of a primitive, fitted on its interior (ends trimmed by about 2 tol,
    /// where the trace may already bend into the next primitive).
    static func geometry(_ p: Prim, _ R: [PDFPoint], tol: Double) -> Geo {
        var lo = p.lo, hi = p.hi
        let trim = 2 * tol
        while lo < hi - 6, R[lo].distance(to: R[p.lo]) < trim { lo += 1 }
        while hi > lo + 6, R[hi].distance(to: R[p.hi]) < trim { hi -= 1 }
        if p.isArc {
            if let f = fitCircle(R, lo, hi, tol: tol * 1.5) ?? fitCircle(R, p.lo, p.hi, tol: tol * 3) {
                return .arc(c: f.c, r: f.r, cw: f.cw)
            }
        }
        let f = fitLine(R, lo, hi)
        // Orient the direction along the run.
        var d = f.d
        let run = R[p.hi] - R[p.lo]
        if run.x * d.x + run.y * d.y < 0 { d = PDFPoint(-d.x, -d.y) }
        return .line(p: f.p, d: d)
    }

    // MARK: Vertices

    static func project(_ q: PDFPoint, _ g: Geo) -> PDFPoint {
        switch g {
        case .line(let p, let d):
            let t = (q.x - p.x) * d.x + (q.y - p.y) * d.y
            return PDFPoint(p.x + t * d.x, p.y + t * d.y)
        case .arc(let c, let r, _):
            let v = q - c, l = hypot(v.x, v.y)
            guard l > 1e-12 else { return PDFPoint(c.x + r, c.y) }
            return PDFPoint(c.x + v.x / l * r, c.y + v.y / l * r)
        }
    }

    static func lineCircle(_ p: PDFPoint, _ d: PDFPoint, _ c: PDFPoint, _ r: Double, tol: Double) -> [PDFPoint] {
        // Foot of the centre on the line, then +- along the line.
        let t0 = (c.x - p.x) * d.x + (c.y - p.y) * d.y
        let foot = PDFPoint(p.x + t0 * d.x, p.y + t0 * d.y)
        let h = foot.distance(to: c)
        var out: [PDFPoint] = []
        if h <= r {
            let s = (r * r - h * h).squareRoot()
            out.append(PDFPoint(foot.x + s * d.x, foot.y + s * d.y))
            out.append(PDFPoint(foot.x - s * d.x, foot.y - s * d.y))
        }
        // Tangent (or nearly tangent) junction: the foot point itself.
        if abs(h - r) <= 2 * tol { out.append(foot) }
        return out
    }

    static func circleCircle(_ c1: PDFPoint, _ r1: Double, _ c2: PDFPoint, _ r2: Double) -> [PDFPoint] {
        let d = c1.distance(to: c2)
        guard d > 1e-9, d <= r1 + r2, d >= abs(r1 - r2) else { return [] }
        let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let h = max(0, r1 * r1 - a * a).squareRoot()
        let ex = (c2.x - c1.x) / d, ey = (c2.y - c1.y) / d
        let m = PDFPoint(c1.x + a * ex, c1.y + a * ey)
        return [PDFPoint(m.x - h * ey, m.y + h * ex), PDFPoint(m.x + h * ey, m.y - h * ex)]
    }

    /// The vertex before each primitive: at a detected corner the neighbours' intersection
    /// near the trace's corner point (allowing for the rounding), elsewhere the smooth join.
    static func vertices(_ geos: [Geo], _ prims: [Prim], _ R: [PDFPoint], corners: [Int: Int], dmax: Double, tol: Double) -> [PDFPoint] {
        prims.indices.map { k in
            let prev = geos[(k - 1 + geos.count) % geos.count]
            if let c = corners[k] { return junction(prev, geos[k], near: R[c], dmax: dmax + 2 * tol, tol: tol, corner: true) }
            return junction(prev, geos[k], near: R[prims[k].lo], dmax: dmax, tol: tol)
        }
    }

    /// Corners of the closed polyline: points where the direction turns by 40 degrees or more
    /// over `reach` of arc length either side, one per corner (the sharpest of each cluster).
    static func detectCorners(_ pts: [PDFPoint], reach: Double) -> [Int] {
        let n = pts.count
        guard n >= 8 else { return [] }
        var total = 0.0
        for i in 0..<n { total += pts[i].distance(to: pts[(i + 1) % n]) }
        let k = max(1, min(n / 6, Int((reach / max(1e-9, total / Double(n))).rounded(.up))))
        var turn = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = pts[(i - k + n) % n], m = pts[i], b = pts[(i + k) % n]
            let u = m - a, v = b - m
            let lu = hypot(u.x, u.y), lv = hypot(v.x, v.y)
            guard lu > 1e-9, lv > 1e-9 else { continue }
            turn[i] = acos(max(-1, min(1, (u.x * v.x + u.y * v.y) / (lu * lv))))
        }
        let minTurn = 40 * Double.pi / 180
        var out: [Int] = []
        for i in 0..<n where turn[i] >= minTurn {
            // Strict maximum within k either side, so a plateau yields its first point only.
            var isMax = true
            for d in 1...k {
                let l = turn[(i - d + n) % n], r = turn[(i + d) % n]
                if l >= turn[i] || r > turn[i] { isMax = false; break }
            }
            if isMax { out.append(i) }
        }
        return out
    }

    static func tangent(_ g: Geo, at x: PDFPoint) -> PDFPoint {
        switch g {
        case .line(_, let d): return d
        case .arc(let c, _, _):
            let v = x - c, l = max(1e-12, hypot(v.x, v.y))
            return PDFPoint(-v.y / l, v.x / l)
        }
    }

    /// |sin| of the angle between the two primitives' directions at `x`.
    static func crossingSine(_ a: Geo, _ b: Geo, at x: PDFPoint) -> Double {
        let ta = tangent(a, at: x), tb = tangent(b, at: x)
        return abs(ta.x * tb.y - ta.y * tb.x)
    }

    static func junction(_ a: Geo, _ b: Geo, near q: PDFPoint, dmax: Double, tol: Double, corner: Bool = false) -> PDFPoint {
        var candidates: [PDFPoint] = []
        switch (a, b) {
        case (.line(let p1, let d1), .line(let p2, let d2)):
            // Intersect only at a real corner; on a smooth curve made of lines, near-parallel
            // neighbours would meet far from the trace.
            let cross = d1.x * d2.y - d1.y * d2.x
            if abs(cross) > sin((corner ? 10 : 30) * Double.pi / 180) {
                let t = ((p2.x - p1.x) * d2.y - (p2.y - p1.y) * d2.x) / cross
                candidates.append(PDFPoint(p1.x + t * d1.x, p1.y + t * d1.y))
            }
        case (.line(let p, let d), .arc(let c, let r, _)), (.arc(let c, let r, _), .line(let p, let d)):
            candidates = lineCircle(p, d, c, r, tol: tol)
            // A line meeting an arc tangentially fits the first sqrt(2 r tol) of the arc as
            // well, so the break can be that far from the true tangent point.
            let t0 = (c.x - p.x) * d.x + (c.y - p.y) * d.y
            let foot = PDFPoint(p.x + t0 * d.x, p.y + t0 * d.y)
            if abs(foot.distance(to: c) - r) <= tol, foot.distance(to: q) <= dmax + 1.5 * (2 * r * tol).squareRoot() {
                return foot
            }
        case (.arc(let c1, let r1, _), .arc(let c2, let r2, _)):
            candidates = circleCircle(c1, r1, c2, r2)
        }
        // A real corner (the primitives meet at 30 degrees or more) may be up to dmax from
        // the trace, which rounds corners; a shallow crossing must stay on the trace.
        if let best = candidates.min(by: { $0.distance(to: q) < $1.distance(to: q) }),
           best.distance(to: q) <= (corner || crossingSine(a, b, at: best) >= 0.5 ? dmax : 1.5 * tol) {
            return best
        }
        let pa = project(q, a), pb = project(q, b)
        return PDFPoint((pa.x + pb.x) / 2, (pa.y + pb.y) / 2)
    }

    // MARK: Post passes (spikes/fitting.py)

    /// Vertices, edge kinds and, per edge, the indices of the trace points it stands for,
    /// so merges are checked against the trace itself and not just against vertices.
    struct Poly {
        var V: [PDFPoint]
        var E: [Edge]
        var S: [[Int]]
        let R: [PDFPoint]
        /// Trace points this close to a run's outer vertices are not checked (the trace
        /// rounds corners there).
        let trim: Double

        /// Remove vertex i together with edge i: edge i-1 then ends where edge i ended.
        mutating func removeVertex(_ i: Int) {
            let prev = (i - 1 + V.count) % V.count
            S[prev].append(contentsOf: S[i])
            V.remove(at: i); E.remove(at: i); S.remove(at: i)
        }

        /// Arcs too small to be worth it (a rounded-off corner of the trace) become lines,
        /// which `sharpenCorners` can then turn back into the corner.
        mutating func demoteSmallArcs(tol: Double) {
            for i in E.indices {
                guard case .arc(let c, let cw) = E[i] else { continue }
                let a = V[i], b = V[(i + 1) % V.count]
                let (r, _, sweep) = Geometry.arcSweep(from: a, to: b, center: c, clockwise: cw)
                let sagitta = r * (1 - cos(min(abs(sweep), .pi) / 2))
                if r < max(2.0, 4 * tol) || r * abs(sweep) < max(5.0, 10 * tol) || sagitta <= tol / 2 { E[i] = .line }
            }
        }

        /// Give every arc the circle through its two end points that best fits its trace
        /// points (least squares, centre on the chord's bisector; `spikes/fitting.py` _fit_arc), so
        /// each arc is exactly consistent and still follows the trace after its ends moved.
        mutating func fitArcsThroughEnds() {
            for i in E.indices {
                guard case .arc(let c0, let cw) = E[i] else { continue }
                let a = V[i], b = V[(i + 1) % V.count]
                let m = PDFPoint((a.x + b.x) / 2, (a.y + b.y) / 2)
                let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
                guard len > 1e-9 else { continue }
                let nx = -dy / len, ny = dx / len
                let t0 = (c0.x - m.x) * nx + (c0.y - m.y) * ny
                let pts = points(from: i, count: 1)
                func centre(_ t: Double) -> PDFPoint { PDFPoint(m.x + t * nx, m.y + t * ny) }
                func cost(_ t: Double) -> Double {
                    let c = centre(t), r = a.distance(to: c)
                    return pts.reduce(0) { let e = $1.distance(to: c) - r; return $0 + e * e }
                }
                var t = t0
                if !pts.isEmpty {
                    let r0 = a.distance(to: c0)
                    var lo = t0 - max(2, 0.1 * r0), hi = t0 + max(2, 0.1 * r0)
                    for _ in 0..<60 {
                        let x1 = hi - (hi - lo) * 0.618, x2 = lo + (hi - lo) * 0.618
                        if cost(x1) < cost(x2) { hi = x2 } else { lo = x1 }
                    }
                    t = (lo + hi) / 2
                }
                E[i] = .arc(c: centre(t), cw: cw)
            }
        }

        /// Make vertex i the first one (same cyclic polygon).
        mutating func rotate(to i: Int) {
            guard i > 0 else { return }
            V = Array(V[i...] + V[..<i]); E = Array(E[i...] + E[..<i]); S = Array(S[i...] + S[..<i])
        }

        mutating func removeShortEdges(minLen: Double) {
            var i = 0
            while i < V.count && V.count > 2 {
                if V[i].distance(to: V[(i + 1) % V.count]) < minLen { removeVertex(i) } else { i += 1 }
            }
        }

        /// Trace points of edges first..<first+count (cyclic), in order, minus those near
        /// the run's outer vertices and those past them (a primitive's trace can run on a
        /// little beyond the vertex its neighbour's geometry put at the junction).
        func points(from first: Int, count: Int) -> [PDFPoint] {
            let n = V.count
            let a = V[first], b = V[(first + count) % n]
            var marks: [Int?] = [] // trace point index, or -(e + 1) for vertex e between edges
            for k in 0..<count {
                let e = (first + k) % n
                if k > 0 { marks.append(-(e + 1)) }
                for i in S[e] { marks.append(i) }
            }
            // Cut before the trace point nearest to a (in the first edge) and after the one
            // nearest to b (in the last edge).
            let firstCount = S[first].count, lastEdge = (first + count - 1) % n, lastCount = S[lastEdge].count
            var startAt = 0, endAt = marks.count - 1
            if firstCount > 0, let j = (0..<firstCount).min(by: { R[S[first][$0]].distance(to: a) < R[S[first][$1]].distance(to: a) }) { startAt = j }
            if lastCount > 0, let j = (0..<lastCount).min(by: { R[S[lastEdge][$0]].distance(to: b) < R[S[lastEdge][$1]].distance(to: b) }) {
                endAt = marks.count - lastCount + j
            }
            var out: [PDFPoint] = []
            guard startAt <= endAt else { return out }
            for m in marks[startAt...endAt] {
                guard let m else { continue }
                if m < 0 { out.append(V[-m - 1]); continue }
                if R[m].distance(to: a) >= trim && R[m].distance(to: b) >= trim { out.append(R[m]) }
            }
            return out
        }

        /// Merge neighbouring lines when one line through the outer vertices stays within
        /// the tolerance of every trace point they cover.
        mutating func mergeLines(tol: Double) {
            var changed = true
            while changed && V.count > 3 {
                changed = false
                for i in 0..<V.count {
                    let n = V.count, prev = (i - 1 + n) % n
                    guard E[prev] == .line, E[i] == .line else { continue }
                    let a = V[prev], b = V[(i + 1) % n]
                    let ab = b - a, len2 = ab.x * ab.x + ab.y * ab.y
                    guard len2 > 1e-12, Geometry.distance(from: V[i], toSegment: a, b) <= tol / 2 else { continue }
                    // Points past either end belong to the neighbours (a line that ran on into a
                    // tangent arc); only the part alongside the chord counts. Isolated outliers
                    // up to 1.5 tol (a kink at an anchor or a gap) are allowed if the fit is tight.
                    let devs = points(from: prev, count: 2).compactMap { q -> Double? in
                        let t = ((q.x - a.x) * ab.x + (q.y - a.y) * ab.y) / len2
                        return t < 0 || t > 1 ? nil : Geometry.distance(from: q, toSegment: a, b)
                    }
                    let maxDev = devs.max() ?? 0
                    let rms = devs.isEmpty ? 0 : (devs.reduce(0) { $0 + $1 * $1 } / Double(devs.count)).squareRoot()
                    guard maxDev <= tol || (maxDev <= 1.5 * tol && rms <= 0.35 * tol) else { continue }
                    removeVertex(i)
                    changed = true
                    break
                }
            }
        }

        /// Merge runs of [arc, arc] and [arc, short line, arc] that one circle fits within
        /// the tolerance (a trace split at an anchor, a gap or a kink).
        mutating func mergeArcs(tol: Double) {
            var changed = true
            while changed && V.count > 2 {
                changed = false
                let n = V.count
                outer: for i in 0..<n {
                    guard case .arc(_, let cw) = E[i] else { continue }
                    for span in [2, 3] where span < n {
                        let last = (i + span - 1) % n
                        guard case .arc(_, let cw2) = E[last], cw2 == cw else { continue }
                        if span == 3 {
                            let mid = (i + 1) % n
                            guard E[mid] == .line, V[mid].distance(to: V[(mid + 1) % n]) <= max(12, 24 * tol) else { continue }
                        }
                        let pts = [V[i]] + points(from: i, count: span) + [V[(last + 1) % n]]
                        // Within the tolerance, allowing isolated outliers up to 1.5 tol (a kink
                        // where the trace bridged a gap) as long as the fit is tight overall.
                        guard let f = PrimitiveFitter.fitCircle(pts, 0, pts.count - 1, tol: 1.5 * tol), f.cw == cw else { continue }
                        let rms = (pts.reduce(0) { let e = $1.distance(to: f.c) - f.r; return $0 + e * e } / Double(pts.count)).squareRoot()
                        guard f.maxDev <= tol || rms <= 0.35 * tol else { continue }
                        E[i] = .arc(c: f.c, cw: cw)
                        rotate(to: i) // the merged edge is now edge 0, so removals never wrap
                        for _ in 1..<span { removeVertex(1) }
                        changed = true
                        break outer
                    }
                }
            }
        }

        /// A trace rounds sharp corners off by a pixel or two, which can leave a short line
        /// across the corner. Replace it with the corner where its neighbours meet, when they
        /// meet at a real angle (30 degrees or more) close by and `isCorner` agrees.
        mutating func sharpenCorners(maxLen: Double, isCorner: ((PDFPoint) -> Bool)?) {
            var changed = true
            while changed && V.count > 3 {
                changed = false
                let n = V.count
                for k in 0..<n {
                    let prev = (k - 1 + n) % n, next = (k + 1) % n
                    guard E[k] == .line, E[prev] == .line, E[next] == .line else { continue }
                    let a = V[prev], p = V[k], q = V[next], b = V[(k + 2) % n]
                    guard p.distance(to: q) < maxLen else { continue }
                    let d1 = p - a, d2 = b - q
                    let l1 = hypot(d1.x, d1.y), l2 = hypot(d2.x, d2.y)
                    guard l1 > 1e-9, l2 > 1e-9 else { continue }
                    let cross = d1.x * d2.y - d1.y * d2.x
                    guard abs(cross) / (l1 * l2) >= sin(30 * Double.pi / 180) else { continue }
                    let t = ((q.x - a.x) * d2.y - (q.y - a.y) * d2.x) / cross
                    let x = PDFPoint(a.x + t * d1.x, a.y + t * d1.y)
                    let m = PDFPoint((p.x + q.x) / 2, (p.y + q.y) / 2)
                    guard x.distance(to: m) <= maxLen, isCorner?(x) ?? true else { continue }
                    // The corner replaces q; vertex k goes with its edge k.
                    V[next] = x
                    removeVertex(k)
                    changed = true
                    break
                }
            }
        }
    }


    static func snapOrthogonal(_ V: [PDFPoint], _ E: [Edge], tol: Double) -> [PDFPoint] {
        var V = V
        let n = V.count
        for i in 0..<n where E[i] == .line {
            let j = (i + 1) % n
            let a = V[i], b = V[j]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            guard len > 1e-9 else { continue }
            var ang = atan2(dy, dx) * 180 / .pi
            ang = ang.truncatingRemainder(dividingBy: 180)
            if ang < 0 { ang += 180 }
            let offH = min(ang, 180 - ang), offV = abs(ang - 90)
            if offH <= orthoDegrees || (offH < 10 && abs(dy) <= tol) {
                let y = (a.y + b.y) / 2
                V[i].y = y; V[j].y = y
            } else if offV <= orthoDegrees || (offV < 10 && abs(dx) <= tol) {
                let x = (a.x + b.x) / 2
                V[i].x = x; V[j].x = x
            }
        }
        return V
    }

    static func snapShared(_ V: [PDFPoint], tol: Double) -> [PDFPoint] {
        var V = V
        guard V.count > 1 else { return V }
        for axis in 0..<2 {
            func val(_ k: Int) -> Double { axis == 0 ? V[k].x : V[k].y }
            let order = V.indices.sorted { val($0) < val($1) }
            var cluster = [order[0]]
            func flush() {
                guard cluster.count > 1 else { return }
                let mean = cluster.map(val).reduce(0, +) / Double(cluster.count)
                for c in cluster { if axis == 0 { V[c].x = mean } else { V[c].y = mean } }
            }
            for k in order.dropFirst() {
                if val(k) - val(cluster[0]) <= tol { cluster.append(k) } else { flush(); cluster = [k] }
            }
            flush()
        }
        return V
    }

    static func fixArcs(_ V: [PDFPoint], _ E: [Edge]) -> [Edge] {
        var E = E
        for i in E.indices {
            guard case .arc(let c, let cw) = E[i] else { continue }
            let a = V[i], b = V[(i + 1) % V.count]
            E[i] = .arc(c: Geometry.recenterArc(from: a, to: b, oldCenter: c), cw: cw)
        }
        return E
    }
}

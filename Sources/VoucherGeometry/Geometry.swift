import Foundation
import VoucherModel

/// Outline geometry (SPEC 5.1, 7.3): arc -> Bézier, flattening, validation,
/// point/rect containment, bounding box. Ported from spikes/outline.py.
public enum Geometry {
    public struct Cubic: Equatable, Sendable {
        public var c1: PDFPoint
        public var c2: PDFPoint
        public var to: PDFPoint
    }

    /// (radius, start angle, signed sweep) of an arc from p0 to p1 around c.
    public static func arcSweep(from p0: PDFPoint, to p1: PDFPoint, center c: PDFPoint, clockwise: Bool) -> (r: Double, a0: Double, sweep: Double) {
        let a0 = atan2(p0.y - c.y, p0.x - c.x)
        let a1 = atan2(p1.y - c.y, p1.x - c.x)
        let r = hypot(p0.x - c.x, p0.y - c.y)
        func mod2pi(_ v: Double) -> Double { let t = v.truncatingRemainder(dividingBy: 2 * .pi); return t < 0 ? t + 2 * .pi : t }
        var sweep = clockwise ? -mod2pi(a0 - a1) : mod2pi(a1 - a0)
        if abs(sweep) < 1e-12 { sweep = clockwise ? -2 * .pi : 2 * .pi }
        return (r, a0, sweep)
    }

    /// Split an arc into cubic Béziers of at most `maxDegrees` each (90 for clip paths, SPEC 5.1).
    public static func arcToBeziers(from p0: PDFPoint, to p1: PDFPoint, center c: PDFPoint, clockwise: Bool, maxDegrees: Double = 90) -> [Cubic] {
        let (r, a0, sweep) = arcSweep(from: p0, to: p1, center: c, clockwise: clockwise)
        let maxRad = maxDegrees * .pi / 180
        let n = max(1, Int(ceil(abs(sweep) / maxRad - 1e-9)))
        let d = sweep / Double(n)
        let k = 4.0 / 3.0 * tan(d / 4.0)
        var out: [Cubic] = []
        for i in 0..<n {
            let s = a0 + Double(i) * d, e = a0 + Double(i + 1) * d
            let c1 = PDFPoint(c.x + r * (cos(s) - k * sin(s)), c.y + r * (sin(s) + k * cos(s)))
            let c2 = PDFPoint(c.x + r * (cos(e) + k * sin(e)), c.y + r * (sin(e) - k * cos(e)))
            let to = i == n - 1 ? p1 : PDFPoint(c.x + r * cos(e), c.y + r * sin(e))
            out.append(Cubic(c1: c1, c2: c2, to: to))
        }
        return out
    }

    /// Polyline approximation; arcs are sampled on the true circle (step in pt).
    public static func flatten(_ o: Outline, step: Double = 1.0) -> [PDFPoint] {
        var pts = [o.start]
        var cur = o.start
        for s in o.segments {
            switch s {
            case .line(let p):
                pts.append(p)
                cur = p
            case .arc(let p, let c, let cw):
                let (r, a0, sweep) = arcSweep(from: cur, to: p, center: c, clockwise: cw)
                let n = max(2, Int(ceil(abs(sweep) * r / step)))
                for i in 1..<n {
                    let a = a0 + sweep * Double(i) / Double(n)
                    pts.append(PDFPoint(c.x + r * cos(a), c.y + r * sin(a)))
                }
                pts.append(p)
                cur = p
            case .curve(let c1, let c2, let p):
                let len = cur.distance(to: c1) + c1.distance(to: c2) + c2.distance(to: p)
                let n = max(2, Int(ceil(len / step)))
                for i in 1...n {
                    let t = Double(i) / Double(n), mt = 1 - t
                    let x = mt * mt * mt * cur.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * p.x
                    let y = mt * mt * mt * cur.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * p.y
                    pts.append(PDFPoint(x, y))
                }
                cur = p
            }
        }
        if let last = pts.last, last.distance(to: o.start) < 1e-9, pts.count > 1 { pts.removeLast() }
        return pts
    }

    public static func boundingBox(_ o: Outline) -> PDFRect {
        let pts = flatten(o, step: 0.5)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return PDFRect(x1: xs.min() ?? 0, y1: ys.min() ?? 0, x2: xs.max() ?? 0, y2: ys.max() ?? 0)
    }

    /// Signed area (positive = counter-clockwise in y-up space).
    public static func signedArea(_ o: Outline) -> Double {
        let p = flatten(o, step: 0.5)
        guard p.count > 2 else { return 0 }
        var a = 0.0
        for i in p.indices {
            let q = p[(i + 1) % p.count]
            a += p[i].x * q.y - q.x * p[i].y
        }
        return a / 2
    }

    // MARK: Validation

    public enum Problem: Equatable, Sendable {
        case tooFewSegments
        case notClosed(gap: Double)
        case arcRadiusMismatch(segment: Int, delta: Double)
        case selfIntersection(segmentA: Int, segmentB: Int)

        public var message: String {
            switch self {
            case .tooFewSegments: return "An outline needs at least 3 segments (or 2 with an arc)."
            case .notClosed(let g): return "The outline is not closed (gap \(PDFNumber.format(g)) pt)."
            case .arcRadiusMismatch(let i, let d): return "Arc \(i + 1): the end point is \(PDFNumber.format(d)) pt off the circle."
            case .selfIntersection(let a, let b): return "The outline crosses itself (segments \(a + 1) and \(b + 1))."
            }
        }
    }

    /// Closed, simple (no self-intersection), arcs consistent (SPEC 5.1: the app enforces this).
    public static func validate(_ o: Outline, tolerance: Double = 0.01) -> [Problem] {
        var out: [Problem] = []
        let hasArc = o.segments.contains { if case .arc = $0 { return true } else { return false } }
        if o.segments.count < (hasArc ? 2 : 3) { return [.tooFewSegments] }
        if let last = o.segments.last {
            let gap = last.end.distance(to: o.start)
            if gap > tolerance { out.append(.notClosed(gap: gap)) }
        }
        var cur = o.start
        for (i, s) in o.segments.enumerated() {
            if case .arc(let p, let c, _) = s {
                let d = abs(cur.distance(to: c) - p.distance(to: c))
                if d > max(tolerance, 1e-6 * cur.distance(to: c)) { out.append(.arcRadiusMismatch(segment: i, delta: d)) }
            }
            cur = s.end
        }
        if let x = firstSelfIntersection(o) { out.append(.selfIntersection(segmentA: x.0, segmentB: x.1)) }
        return out
    }

    /// Segment indices of the first crossing, using a per-segment flattening.
    public static func firstSelfIntersection(_ o: Outline) -> (Int, Int)? {
        // Flatten each segment separately, remembering which segment each edge belongs to.
        var edges: [(PDFPoint, PDFPoint, Int)] = []
        var cur = o.start
        for (i, s) in o.segments.enumerated() {
            let sub = flatten(Outline(start: cur, segments: [s]), step: 2.0)
            var pts = sub
            if pts.last.map({ $0.distance(to: s.end) > 1e-9 }) ?? true { pts.append(s.end) }
            for j in 1..<pts.count { edges.append((pts[j - 1], pts[j], i)) }
            cur = s.end
        }
        let n = edges.count
        guard n > 3 else { return nil }
        for a in 0..<(n - 2) {
            for b in (a + 2)..<n {
                if a == 0 && b == n - 1 { continue } // closing neighbours
                if edges[a].2 == edges[b].2 { continue } // same segment: arcs/curves are simple by construction
                if segmentsIntersect(edges[a].0, edges[a].1, edges[b].0, edges[b].1) {
                    // Touching at a shared vertex of adjacent segments is fine.
                    let adjacent = abs(edges[a].2 - edges[b].2) == 1 || (edges[a].2 == 0 && edges[b].2 == o.segments.count - 1)
                    if adjacent && sharesEndpoint(edges[a], edges[b]) { continue }
                    return (edges[a].2, edges[b].2)
                }
            }
        }
        return nil
    }

    private static func sharesEndpoint(_ a: (PDFPoint, PDFPoint, Int), _ b: (PDFPoint, PDFPoint, Int)) -> Bool {
        let e = 1e-6
        return a.0.distance(to: b.0) < e || a.0.distance(to: b.1) < e || a.1.distance(to: b.0) < e || a.1.distance(to: b.1) < e
    }

    static func segmentsIntersect(_ p1: PDFPoint, _ p2: PDFPoint, _ p3: PDFPoint, _ p4: PDFPoint) -> Bool {
        func orient(_ a: PDFPoint, _ b: PDFPoint, _ c: PDFPoint) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        let d1 = orient(p3, p4, p1), d2 = orient(p3, p4, p2), d3 = orient(p1, p2, p3), d4 = orient(p1, p2, p4)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return true }
        func onSeg(_ a: PDFPoint, _ b: PDFPoint, _ c: PDFPoint) -> Bool {
            min(a.x, b.x) - 1e-9 <= c.x && c.x <= max(a.x, b.x) + 1e-9 && min(a.y, b.y) - 1e-9 <= c.y && c.y <= max(a.y, b.y) + 1e-9
        }
        let eps = 1e-9
        if abs(d1) < eps && onSeg(p3, p4, p1) { return true }
        if abs(d2) < eps && onSeg(p3, p4, p2) { return true }
        if abs(d3) < eps && onSeg(p1, p2, p3) { return true }
        if abs(d4) < eps && onSeg(p1, p2, p4) { return true }
        return false
    }

    // MARK: Containment

    /// Even-odd point-in-polygon on the flattened outline.
    public static func contains(_ o: Outline, _ p: PDFPoint, polygon: [PDFPoint]? = nil) -> Bool {
        let poly = polygon ?? flatten(o, step: 0.5)
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Whether a rect is fully inside, partly inside, or outside the outline.
    public static func containment(of r: PDFRect, in o: Outline, tolerance: Double = 0.05) -> OutlineContainment {
        let poly = flatten(o, step: 0.5)
        let inner = PDFRect(x: r.x + tolerance, y: r.y + tolerance, width: max(0, r.width - 2 * tolerance), height: max(0, r.height - 2 * tolerance))
        // Sample the rect boundary.
        var samples: [PDFPoint] = []
        let nx = max(2, Int(inner.width / 4)), ny = max(2, Int(inner.height / 4))
        for i in 0...nx {
            let x = inner.minX + inner.width * Double(i) / Double(nx)
            samples.append(PDFPoint(x, inner.minY)); samples.append(PDFPoint(x, inner.maxY))
        }
        for j in 0...ny {
            let y = inner.minY + inner.height * Double(j) / Double(ny)
            samples.append(PDFPoint(inner.minX, y)); samples.append(PDFPoint(inner.maxX, y))
        }
        let ins = samples.map { contains(o, $0, polygon: poly) }
        // An outline vertex strictly inside the rect means the outline crosses into it.
        let poke = poly.contains { $0.x > inner.minX && $0.x < inner.maxX && $0.y > inner.minY && $0.y < inner.maxY }
        if ins.allSatisfy({ $0 }) { return poke ? .partial : .inside }
        if !ins.contains(true) { return poke ? .partial : .outside }
        return .partial
    }

    /// Distance from `p` to the segment a-b.
    public static func distance(from p: PDFPoint, toSegment a: PDFPoint, _ b: PDFPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return p.distance(to: PDFPoint(a.x + t * dx, a.y + t * dy))
    }

    /// Index of the segment nearest to `p` and the distance to it.
    public static func nearestSegment(_ o: Outline, to p: PDFPoint) -> (index: Int, distance: Double)? {
        var best: (Int, Double)?
        var cur = o.start
        for (i, s) in o.segments.enumerated() {
            let pts = flatten(Outline(start: cur, segments: [s]), step: 1.0) + [s.end]
            for j in 1..<pts.count {
                let d = distance(from: p, toSegment: pts[j - 1], pts[j])
                if best == nil || d < best!.1 { best = (i, d) }
            }
            cur = s.end
        }
        return best.map { (index: $0.0, distance: $0.1) }
    }

    /// Split segment `index` at its midpoint (lines and curves; arcs at the mid-angle).
    public static func insertPoint(in o: Outline, segment index: Int) -> Outline {
        guard o.segments.indices.contains(index) else { return o }
        var out = o
        let from = index == 0 ? o.start : o.segments[index - 1].end
        switch o.segments[index] {
        case .line(let p):
            let m = PDFPoint((from.x + p.x) / 2, (from.y + p.y) / 2)
            out.segments.replaceSubrange(index...index, with: [.line(to: m), .line(to: p)])
        case .arc(let p, let c, let cw):
            let (r, a0, sweep) = arcSweep(from: from, to: p, center: c, clockwise: cw)
            let m = PDFPoint(c.x + r * cos(a0 + sweep / 2), c.y + r * sin(a0 + sweep / 2))
            out.segments.replaceSubrange(index...index, with: [.arc(to: m, center: c, clockwise: cw), .arc(to: p, center: c, clockwise: cw)])
        case .curve(let c1, let c2, let p):
            // de Casteljau at t = 0.5
            func mid(_ a: PDFPoint, _ b: PDFPoint) -> PDFPoint { PDFPoint((a.x + b.x) / 2, (a.y + b.y) / 2) }
            let ab = mid(from, c1), bc = mid(c1, c2), cd = mid(c2, p)
            let abc = mid(ab, bc), bcd = mid(bc, cd), m = mid(abc, bcd)
            out.segments.replaceSubrange(index...index, with: [.curve(c1: ab, c2: abc, to: m), .curve(c1: bcd, c2: cd, to: p)])
        }
        return out
    }

    /// Remove vertex `index` (>= 1) by merging its two segments into a line.
    public static func removePoint(in o: Outline, vertex index: Int) -> Outline {
        guard index >= 1, o.segments.count > 3, o.segments.indices.contains(index) else { return o }
        var out = o
        let next = o.segments[index].end
        out.segments.replaceSubrange((index - 1)...index, with: [.line(to: next)])
        return out
    }

    /// For an arc whose end point moved: keep it valid by moving the centre along
    /// the perpendicular bisector of the chord, preserving the bulge side (SPEC 4).
    public static func recenterArc(from p0: PDFPoint, to p1: PDFPoint, oldCenter c: PDFPoint) -> PDFPoint {
        let m = PDFPoint((p0.x + p1.x) / 2, (p0.y + p1.y) / 2)
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let len = hypot(dx, dy)
        guard len > 1e-9 else { return c }
        let nx = -dy / len, ny = dx / len
        let t = (c.x - m.x) * nx + (c.y - m.y) * ny
        return PDFPoint(m.x + t * nx, m.y + t * ny)
    }
}

import Foundation
import VoucherModel
import VoucherGeometry

/// One piece of a smart outline between two anchors: the traced edge (magnetic) or a
/// plain straight segment (Shift, Cmd/Option, or no artwork raster).
public struct TracedSegment: Equatable, Sendable {
    public var points: [PDFPoint]
    public var magnetic: Bool
    public init(points: [PDFPoint], magnetic: Bool) { self.points = points; self.magnetic = magnetic }
}

/// Turns traced segments (or a detected region boundary) into a valid `Outline`.
public enum OutlineTracer {
    /// Cyclic polyline from consecutive segments (each starts where the previous ended,
    /// the last ends at the first's start), with back-tracking at the joins removed and
    /// small loops erased. `movable` marks points that came from a magnetic trace.
    public static func closedPolyline(_ input: [TracedSegment], junctionTrim: Double = 0) -> (points: [PDFPoint], movable: [Bool]) {
        var segs = input.filter { $0.points.count >= 2 }
        guard !segs.isEmpty else { return ([], []) }
        // A path that doubles back over the previous one at a join (the anchor snapped a
        // pixel past a corner) leaves a zero-width spike: trim it.
        if segs.count >= 2 {
            for k in segs.indices {
                let a = (k - 1 + segs.count) % segs.count
                while segs[a].points.count > 2, segs[k].points.count > 2,
                      segs[a].points[segs[a].points.count - 2].distance(to: segs[k].points[1]) < 1e-9 {
                    segs[a].points.removeLast()
                    segs[k].points.removeFirst()
                }
            }
        }
        // Where two traced segments meet, the anchor is a snapped pixel that can sit a pixel off
        // the true corner or line; drop the trace within `junctionTrim` of it on both sides
        // so it leaves no kink (the fitter rebuilds sharp corners from the neighbouring lines).
        if junctionTrim > 0 && segs.count >= 2 {
            for k in segs.indices {
                let a = (k - 1 + segs.count) % segs.count
                guard segs[a].magnetic, segs[k].magnetic, let j = segs[k].points.first else { continue }
                while segs[a].points.count > 3, segs[a].points[segs[a].points.count - 2].distance(to: j) < junctionTrim {
                    segs[a].points.remove(at: segs[a].points.count - 2)
                }
                while segs[k].points.count > 3, segs[k].points[1].distance(to: j) < junctionTrim { segs[k].points.remove(at: 1) }
                // The anchor itself goes too: both sides now end at their last kept points.
                if segs[a].points.count > 2 && segs[k].points.count > 2 {
                    segs[a].points.removeLast()
                    segs[k].points[0] = segs[a].points[segs[a].points.count - 1]
                }
            }
        }
        var pts: [PDFPoint] = []
        var mov: [Bool] = []
        for s in segs {
            for (i, p) in s.points.enumerated() {
                if i == 0 && !pts.isEmpty { continue } // shared with the previous segment's end
                pts.append(p)
                mov.append(s.magnetic)
            }
        }
        if pts.count > 1, pts.last!.distance(to: pts[0]) < 1e-9 { pts.removeLast(); mov.removeLast() }
        return eraseLoops(pts, mov)
    }

    /// Remove loops formed when the path revisits a point it already passed through (the
    /// part between the two visits, when it is the smaller part).
    static func eraseLoops(_ pts: [PDFPoint], _ mov: [Bool]) -> (points: [PDFPoint], movable: [Bool]) {
        struct Key: Hashable { var x: Int64; var y: Int64 }
        func key(_ p: PDFPoint) -> Key { Key(x: Int64((p.x * 1000).rounded()), y: Int64((p.y * 1000).rounded())) }
        var out: [PDFPoint] = []
        var om: [Bool] = []
        var seen: [Key: Int] = [:]
        for (i, p) in pts.enumerated() {
            let k = key(p)
            if let at = seen[k], (out.count - at) * 2 < pts.count {
                for q in out[(at + 1)...] { seen[key(q)] = nil }
                out.removeSubrange((at + 1)...)
                om.removeSubrange((at + 1)...)
                om[at] = om[at] && mov[i]
                continue
            }
            seen[k] = out.count
            out.append(p)
            om.append(mov[i])
        }
        return (out, om)
    }

    /// Fit lines and arcs to the closed polyline and check the result (closed, simple,
    /// arcs consistent). If the fit crosses itself it is retried with half the tolerance;
    /// if that fails too, the failure explains where.
    public static func outline(polyline pts: [PDFPoint], tolerance: Double, context: TraceContext? = nil) -> Result<Outline, TraceFailure> {
        guard pts.count >= 3 else { return .failure(TraceFailure("The traced outline is too short.")) }
        var lastProblems: [Geometry.Problem] = []
        for tol in [tolerance, tolerance / 2] {
            guard let o = PrimitiveFitter.fitClosed(pts, tolerance: tol, cornerCheck: context.map { c in { c.isNearEdge($0) } }) else { continue }
            let problems = Geometry.validate(o)
            if problems.isEmpty { return .success(o) }
            lastProblems = problems
        }
        if let p = lastProblems.first {
            if case .selfIntersection = p {
                return .failure(TraceFailure("The traced outline crosses itself. Press Delete to remove the last anchor and place anchors closer together, or hold Shift for straight segments."))
            }
            return .failure(TraceFailure("The traced outline is not valid: \(p.message)"))
        }
        return .failure(TraceFailure("The traced outline is too small or degenerate."))
    }

    /// Segments -> refined polyline -> fitted, validated outline.
    public static func outline(segments: [TracedSegment], context: TraceContext?, tolerance: Double) -> Result<Outline, TraceFailure> {
        let trim = context.map { 1.5 / $0.pixelsPerPoint } ?? 0
        var (pts, mov) = closedPolyline(segments, junctionTrim: trim)
        let area = abs(zip(pts, pts.dropFirst() + pts.prefix(1)).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
        guard pts.count >= 3, area >= 1 else {
            return .failure(TraceFailure("The trace runs back along itself and encloses nothing. Add an anchor on the other side of the shape, or hold Shift for a straight segment."))
        }
        if let ctx = context, mov.contains(true) { pts = ctx.refine(pts, movable: mov) }
        return outline(polyline: pts, tolerance: tolerance, context: context)
    }
}

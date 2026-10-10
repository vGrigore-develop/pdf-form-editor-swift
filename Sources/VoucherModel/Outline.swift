import Foundation

/// One segment of a cut outline (SPEC 5.1). Each segment starts where the previous one ended.
public enum Segment: Codable, Hashable, Sendable {
    case line(to: PDFPoint)
    /// Circular arc around `center`; `clockwise` in y-up user space.
    case arc(to: PDFPoint, center: PDFPoint, clockwise: Bool)
    case curve(c1: PDFPoint, c2: PDFPoint, to: PDFPoint)

    public var end: PDFPoint {
        switch self {
        case .line(let p), .arc(let p, _, _), .curve(_, _, let p): return p
        }
    }

    public var kindName: String {
        switch self {
        case .line: return "line"
        case .arc: return "arc"
        case .curve: return "curve"
        }
    }

    public func withEnd(_ p: PDFPoint) -> Segment {
        switch self {
        case .line: return .line(to: p)
        case .arc(_, let c, let cw): return .arc(to: p, center: c, clockwise: cw)
        case .curve(let c1, let c2, _): return .curve(c1: c1, c2: c2, to: p)
        }
    }
}

/// A closed path: `start`, then segments; implicitly closed back to `start`
/// (the last segment normally ends at `start`).
public struct Outline: Codable, Hashable, Sendable {
    public var start: PDFPoint
    public var segments: [Segment]

    public init(start: PDFPoint, segments: [Segment]) {
        self.start = start
        self.segments = segments
    }

    /// Vertices: start plus every segment end.
    public var points: [PDFPoint] { [start] + segments.map(\.end) }

    /// A rectangle outline, counter-clockwise from the bottom-left corner.
    public static func rectangle(_ r: PDFRect) -> Outline {
        Outline(start: PDFPoint(r.minX, r.minY), segments: [
            .line(to: PDFPoint(r.maxX, r.minY)),
            .line(to: PDFPoint(r.maxX, r.maxY)),
            .line(to: PDFPoint(r.minX, r.maxY)),
            .line(to: PDFPoint(r.minX, r.minY)),
        ])
    }

    /// Move vertex `index` (0 = start) to `p`. Moving the start also moves the
    /// closing segment's end, so the path stays closed.
    public mutating func moveVertex(_ index: Int, to p: PDFPoint) {
        if index == 0 {
            let closes = segments.last.map { $0.end.distance(to: start) < 1e-6 } ?? false
            start = p
            if closes, let last = segments.indices.last { segments[last] = segments[last].withEnd(p) }
        } else if segments.indices.contains(index - 1) {
            let wasClosing = index - 1 == segments.count - 1 && segments[index - 1].end.distance(to: start) < 1e-6
            segments[index - 1] = segments[index - 1].withEnd(p)
            if wasClosing { start = p }
        }
    }

    public func translated(dx: Double, dy: Double) -> Outline {
        func t(_ p: PDFPoint) -> PDFPoint { PDFPoint(p.x + dx, p.y + dy) }
        return Outline(start: t(start), segments: segments.map {
            switch $0 {
            case .line(let p): return .line(to: t(p))
            case .arc(let p, let c, let cw): return .arc(to: t(p), center: t(c), clockwise: cw)
            case .curve(let a, let b, let p): return .curve(c1: t(a), c2: t(b), to: t(p))
            }
        })
    }

    public var counts: (lines: Int, arcs: Int, curves: Int) {
        var l = 0, a = 0, c = 0
        for s in segments {
            switch s {
            case .line: l += 1
            case .arc: a += 1
            case .curve: c += 1
            }
        }
        return (l, a, c)
    }
}

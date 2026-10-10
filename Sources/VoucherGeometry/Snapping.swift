import Foundation
import VoucherModel

/// Dynamic snapping for moving and resizing fields (SPEC 4, "Snapping (v1)").
/// Pure functions in page space: the canvas converts the screen threshold to points
/// (`pixels / scale`) and draws the returned guides.
public enum Snapping {
    public enum Axis: Sendable { case x, y }

    public enum Source: Sendable { case field, page, outline }

    /// A line other items can align to. `value` is the x (for x targets) or y (for y
    /// targets); `lo...hi` is its extent along the other axis, used to size guides.
    public struct Target: Equatable, Sendable {
        public var value: Double
        public var lo: Double
        public var hi: Double
        public var source: Source
        public init(value: Double, lo: Double, hi: Double, source: Source) {
            self.value = value; self.lo = lo; self.hi = hi; self.source = source
        }
    }

    public struct Targets: Equatable, Sendable {
        public var xs: [Target] = []
        public var ys: [Target] = []
        public init(xs: [Target] = [], ys: [Target] = []) { self.xs = xs; self.ys = ys }

        /// Edges and centres of other fields, the page edges and centre, and the
        /// outline's bounding edges when a cut exists.
        public static func build(page: PDFRect, fields: [PDFRect], outlineBounds: PDFRect?) -> Targets {
            var t = Targets()
            func add(_ r: PDFRect, mids: Bool, _ s: Source) {
                for x in mids ? [r.minX, r.midX, r.maxX] : [r.minX, r.maxX] {
                    t.xs.append(Target(value: x, lo: r.minY, hi: r.maxY, source: s))
                }
                for y in mids ? [r.minY, r.midY, r.maxY] : [r.minY, r.maxY] {
                    t.ys.append(Target(value: y, lo: r.minX, hi: r.maxX, source: s))
                }
            }
            for f in fields { add(f, mids: true, .field) }
            add(page, mids: true, .page)
            if let o = outlineBounds { add(o, mids: false, .outline) }
            return t
        }
    }

    /// A guide line: a vertical line at x = `position` (axis .x) or a horizontal line at
    /// y = `position` (axis .y), from `from` to `to` along the other axis.
    public struct Guide: Equatable, Sendable {
        public var axis: Axis
        public var position: Double
        public var from: Double
        public var to: Double
    }

    /// What one axis snapped to: the target value and the union of the targets' extents there.
    public struct Match: Equatable, Sendable {
        public var value: Double
        public var lo: Double
        public var hi: Double
    }

    public struct Result: Equatable, Sendable {
        /// Add to the proposed rect (move) or point (resize).
        public var dx: Double
        public var dy: Double
        /// Set only when the axis snapped to a field/page/outline target (not the grid).
        public var xMatch: Match?
        public var yMatch: Match?
        /// Guides for the proposed rect after applying (dx, dy).
        public var guides: [Guide]

        /// Guides for the rect that was finally used: only for edges or centres that still
        /// sit on the matched value (clamping may have moved it), spanning both items.
        public func guides(for rect: PDFRect, tolerance: Double = 0.01) -> [Guide] {
            Snapping.guides(rect: rect, xMatch: xMatch, yMatch: yMatch, tolerance: tolerance)
        }
    }

    // MARK: Core

    private struct AxisSnap {
        var delta: Double
        var match: Match?
    }

    /// Nearest target within `threshold` of any candidate wins (field alignment before the
    /// grid); without one, the nearest grid line of `gridCandidates` (always, when `grid` is set).
    private static func snapAxis(candidates: [Double], gridCandidates: [Double], targets: [Target],
                                 threshold: Double, grid: Double?) -> AxisSnap {
        var best: (delta: Double, value: Double)?
        for c in candidates {
            for t in targets {
                let d = t.value - c
                if abs(d) <= threshold, best == nil || abs(d) < abs(best!.delta) - 1e-9 { best = (d, t.value) }
            }
        }
        if let best {
            let same = targets.filter { abs($0.value - best.value) < 1e-6 }
            return AxisSnap(delta: best.delta, match: Match(value: best.value,
                                                            lo: same.map(\.lo).min() ?? 0, hi: same.map(\.hi).max() ?? 0))
        }
        if let g = grid, g > 0 {
            var gd: Double?
            for c in gridCandidates {
                let d = (c / g).rounded() * g - c
                if gd == nil || abs(d) < abs(gd!) - 1e-9 { gd = d }
            }
            if let gd { return AxisSnap(delta: gd, match: nil) }
        }
        return AxisSnap(delta: 0, match: nil)
    }

    private static func guides(rect: PDFRect, xMatch: Match?, yMatch: Match?, tolerance: Double) -> [Guide] {
        var out: [Guide] = []
        if let m = xMatch, [rect.minX, rect.midX, rect.maxX].contains(where: { abs($0 - m.value) <= tolerance }) {
            out.append(Guide(axis: .x, position: m.value, from: min(m.lo, rect.minY), to: max(m.hi, rect.maxY)))
        }
        if let m = yMatch, [rect.minY, rect.midY, rect.maxY].contains(where: { abs($0 - m.value) <= tolerance }) {
            out.append(Guide(axis: .y, position: m.value, from: min(m.lo, rect.minX), to: max(m.hi, rect.maxX)))
        }
        return out
    }

    // MARK: Move

    /// Snap a moving rect: the nearest of its left/centre/right to an x target and its
    /// bottom/centre/top to a y target; otherwise the left/right (bottom/top) edge to the grid.
    public static func snapMove(rect: PDFRect, targets: Targets, threshold: Double, grid: Double?) -> Result {
        let sx = snapAxis(candidates: [rect.minX, rect.midX, rect.maxX], gridCandidates: [rect.minX, rect.maxX],
                          targets: targets.xs, threshold: threshold, grid: grid)
        let sy = snapAxis(candidates: [rect.minY, rect.midY, rect.maxY], gridCandidates: [rect.minY, rect.maxY],
                          targets: targets.ys, threshold: threshold, grid: grid)
        let moved = rect.offsetBy(dx: sx.delta, dy: sy.delta)
        return Result(dx: sx.delta, dy: sy.delta, xMatch: sx.match, yMatch: sy.match,
                      guides: guides(rect: moved, xMatch: sx.match, yMatch: sy.match, tolerance: 0.01))
    }

    // MARK: Resize

    /// Snap the edge(s) being dragged. `handle` is a `RectHandle` number; `point` is where the
    /// handle is being dragged to; `rect` is the rect before the drag. The result's dx/dy move
    /// `point`; guides refer to the plain resize (`RectHandle.resize` without modifiers).
    public static func snapResize(rect: PDFRect, handle: Int, point: PDFPoint, targets: Targets,
                                  threshold: Double, grid: Double?) -> Result {
        let movesX = [0, 2, 3, 4, 6, 7].contains(handle)
        let movesY = [0, 1, 2, 4, 5, 6].contains(handle)
        let sx = movesX ? snapAxis(candidates: [point.x], gridCandidates: [point.x], targets: targets.xs,
                                   threshold: threshold, grid: grid) : AxisSnap(delta: 0, match: nil)
        let sy = movesY ? snapAxis(candidates: [point.y], gridCandidates: [point.y], targets: targets.ys,
                                   threshold: threshold, grid: grid) : AxisSnap(delta: 0, match: nil)
        let snapped = PDFPoint(point.x + sx.delta, point.y + sy.delta)
        let resized = RectHandle.resize(rect, handle: handle, to: snapped)
        return Result(dx: sx.delta, dy: sy.delta, xMatch: sx.match, yMatch: sy.match,
                      guides: guides(rect: resized, xMatch: sx.match, yMatch: sy.match, tolerance: 0.01))
    }

    /// Grid steps worth drawing: the grid size, or a multiple of it so lines stay at least
    /// `minPixels` apart on screen.
    public static func visibleGridStep(grid: Double, scale: Double, minPixels: Double = 6) -> Double {
        guard grid > 0, scale > 0 else { return grid }
        return grid * max(1, (minPixels / (grid * scale)).rounded(.up))
    }
}

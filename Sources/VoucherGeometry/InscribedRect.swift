import Foundation
import VoucherModel

extension Geometry {
    /// The largest-area axis-aligned rectangle inside both `r` and the outline ("Fit to
    /// Outline" for a field that crosses the cut). nil when no part of `r` is inside.
    ///
    /// Candidate edges are the rect's edges, the x and y of every outline vertex inside
    /// `r`, and samples along arcs and curves (at most `maxCandidates` per axis). A cell of
    /// that grid counts as inside when its centre and its four corners (nudged 2 % towards
    /// the centre, so corners on the outline itself test reliably) are inside; the
    /// maximal rectangle of inside cells is then found row by row (largest rectangle in a
    /// histogram, with real cell widths). The result is checked with `containment` and
    /// shrunk inward by `step` until it passes, so it is always fully inside.
    public static func largestRect(inside o: Outline, within r: PDFRect, step: Double = 0.5,
                                   maxCandidates: Int = 120) -> PDFRect? {
        guard r.width > 0, r.height > 0 else { return nil }
        // 1 pt chords are within 0.001 pt of an arc of radius 100 pt or more.
        let poly = flatten(o, step: 1)
        func snap(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        // Exact vertices always; sampled arc/curve points thinned to the budget.
        var exactX: Set<Double> = [snap(r.minX), snap(r.maxX)], exactY: Set<Double> = [snap(r.minY), snap(r.maxY)]
        // A vertex outside the rect still bounds it (a vertical edge from (80, 215) to (80, 380)
        // limits a rect spanning y 250-350), so every vertex counts along its own axis.
        for p in o.points {
            if p.x > r.minX && p.x < r.maxX { exactX.insert(snap(p.x)) }
            if p.y > r.minY && p.y < r.maxY { exactY.insert(snap(p.y)) }
        }
        func thin(_ v: [Double]) -> [Double] {
            let s = Array(Set(v.map(snap))).sorted()
            guard s.count > maxCandidates else { return s }
            return (0..<maxCandidates).map { s[$0 * s.count / maxCandidates] }
        }
        let gx = Array(exactX.union(thin(poly.map(\.x).filter { $0 > r.minX && $0 < r.maxX }))).sorted()
        let gy = Array(exactY.union(thin(poly.map(\.y).filter { $0 > r.minY && $0 < r.maxY }))).sorted()
        let nx = gx.count - 1, ny = gy.count - 1
        guard nx > 0, ny > 0 else { return nil }

        // Even-odd inside test along one horizontal line: the sorted x crossings.
        func crossings(_ y: Double) -> [Double] {
            var xs: [Double] = []
            var j = poly.count - 1
            for i in poly.indices {
                let a = poly[i], b = poly[j]
                if (a.y > y) != (b.y > y) { xs.append(a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)) }
                j = i
            }
            return xs.sorted()
        }
        func inside(_ x: Double, _ xs: [Double]) -> Bool {
            var lo = 0, hi = xs.count // number of crossings left of x
            while lo < hi { let m = (lo + hi) / 2; if xs[m] < x { lo = m + 1 } else { hi = m } }
            return lo % 2 == 1
        }

        var heights = [Double](repeating: 0, count: nx)
        var best: (area: Double, rect: PDFRect)?
        for j in 0..<ny {
            let ch = gy[j + 1] - gy[j]
            let lowY = gy[j] + ch * 0.02, midY = gy[j] + ch / 2, highY = gy[j + 1] - ch * 0.02
            let low = crossings(lowY), mid = crossings(midY), high = crossings(highY)
            for i in 0..<nx {
                let cw = gx[i + 1] - gx[i]
                let lx = gx[i] + cw * 0.02, mx = gx[i] + cw / 2, hx = gx[i + 1] - cw * 0.02
                let ok = inside(mx, mid) && inside(lx, low) && inside(hx, low) && inside(lx, high) && inside(hx, high)
                heights[i] = ok ? heights[i] + ch : 0
            }
            // Largest rectangle under the histogram; bar i spans gx[i]...gx[i+1].
            var stack: [Int] = []
            for i in 0...nx {
                let h = i < nx ? heights[i] : -1
                while let top = stack.last, heights[top] >= h {
                    stack.removeLast()
                    let left = stack.last.map { $0 + 1 } ?? 0
                    let width = gx[i] - gx[left]
                    let area = width * heights[top]
                    if heights[top] > 0, area > (best?.area ?? 0) {
                        best = (area, PDFRect(x: gx[left], y: gy[j + 1] - heights[top], width: width, height: heights[top]))
                    }
                }
                if i < nx { stack.append(i) }
            }
        }
        guard var rect = best?.rect else { return nil }
        for _ in 0..<20 where containment(of: rect, in: o) != .inside {
            rect = PDFRect(x: rect.x + step, y: rect.y + step, width: rect.width - 2 * step, height: rect.height - 2 * step)
            if rect.width <= 0 || rect.height <= 0 { return nil }
        }
        return containment(of: rect, in: o) == .inside ? rect : nil
    }
}

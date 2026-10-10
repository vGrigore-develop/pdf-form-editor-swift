import Foundation
import VoucherModel
import VoucherGeometry

/// Everything the smart outline tool needs for one page: the raster, its edge map and
/// the cost image for the current sensitivity. All inputs and outputs are in the
/// page's user space (points, y up); pixels are an internal detail.
public final class TraceContext {
    public let raster: PageRaster
    public let edges: EdgeMap
    public private(set) var sensitivity: Double
    public private(set) var cost: [UInt8]

    public init(raster: PageRaster, sensitivity: Double = TraceDefaults.sensitivity) {
        self.raster = raster
        edges = EdgeMap(raster: raster)
        self.sensitivity = sensitivity
        cost = edges.costMap(sensitivity: sensitivity)
    }

    /// Recompute the cost image (live wires made before keep the old one).
    public func setSensitivity(_ s: Double) {
        guard s != sensitivity else { return }
        sensitivity = s
        cost = edges.costMap(sensitivity: s)
    }

    public var pixelsPerPoint: Double { raster.scale }

    /// The anchor for a click at `p`: the strongest corner, else the strongest edge pixel,
    /// within `radiusPx` raster pixels; the click itself when there is no edge nearby.
    public func snapAnchor(_ p: PDFPoint, radiusPx: Double) -> PDFPoint {
        guard raster.contains(p) else { return p }
        let (x, y) = raster.pixel(of: p)
        let ix = Int(x.rounded()), iy = Int(y.rounded())
        let idx = edges.snap(x: ix, y: iy, radius: Int(radiusPx.rounded()), sensitivity: sensitivity)
        if idx == iy * raster.width + ix, edges.strength[idx] < edges.edgeThreshold(sensitivity: sensitivity) { return p }
        return raster.pointOfPixel(idx)
    }

    /// Whether `p` lies on (or right next to) an edge, for the hover feedback.
    public func isOnEdge(_ p: PDFPoint) -> Bool {
        guard raster.contains(p) else { return false }
        return edges.strength[raster.pixelIndex(of: p)] >= edges.edgeThreshold(sensitivity: sensitivity)
    }

    /// Whether there is an edge within about a pixel of `p` (used to confirm that a corner
    /// the fitter wants to sharpen is really in the artwork).
    public func isNearEdge(_ p: PDFPoint) -> Bool {
        guard raster.contains(p) else { return false }
        let (x, y) = raster.pixel(of: p)
        let t = edges.edgeThreshold(sensitivity: sensitivity)
        for dy in [-1.0, 0, 1] { for dx in [-1.0, 0, 1] where edges.sample(x + dx, y + dy) >= t { return true } }
        return false
    }

    public func wire(from p: PDFPoint) -> LiveWire {
        LiveWire(cost: cost, width: raster.width, height: raster.height, seed: raster.pixelIndex(of: p))
    }

    /// The minimum-cost path from the wire's anchor `from` to `to`, as page points (pixel
    /// centres in between, the exact end points at both ends). Nil if unreachable within
    /// the settle budget or outside the raster.
    public func trace(_ wire: LiveWire, from: PDFPoint, to: PDFPoint, maxSettle: Int = .max) -> [PDFPoint]? {
        guard raster.contains(to) else { return nil }
        guard let idx = wire.path(to: raster.pixelIndex(of: to), maxSettle: maxSettle) else { return nil }
        var pts = idx.map { raster.pointOfPixel($0) }
        pts[0] = from
        if pts.count == 1 { pts.append(to) } else { pts[pts.count - 1] = to }
        return pts
    }

    /// The traced segment from the wire's anchor to `to`, or a straight segment when the
    /// path mostly crosses empty page (no artwork edge to follow there, and a live-wire path
    /// through a flat area is a staircase, not a line).
    public func segment(_ wire: LiveWire, from: PDFPoint, to: PDFPoint, maxSettle: Int = .max) -> TracedSegment? {
        guard let pts = trace(wire, from: from, to: to, maxSettle: maxSettle) else { return nil }
        let t = edges.edgeThreshold(sensitivity: sensitivity)
        let onEdge = pts.reduce(0) { $0 + (edges.strength[raster.pixelIndex(of: $1)] >= t ? 1 : 0) }
        if pts.count > 2 && Double(onEdge) >= 0.5 * Double(pts.count) { return TracedSegment(points: pts, magnetic: true) }
        return TracedSegment(points: [from, to], magnetic: false)
    }

    /// Move magnetic points onto the edge ridge with sub-pixel accuracy (closed path).
    public func refine(_ pts: [PDFPoint], movable: [Bool]) -> [PDFPoint] {
        let px = pts.map { raster.pixel(of: $0) }
        let out = edges.refine(px, movable: movable, minStrength: edges.edgeThreshold(sensitivity: sensitivity))
        return out.map { raster.point(x: $0.x, y: $0.y) }
    }

    // MARK: Auto-detect shape

    /// The closed boundary of the region of similar colour around `p` (flood fill with
    /// `threshold` as the RGB distance, 0...441). Clicking the plain background around a
    /// shape (the fill reaches the page border) selects the largest shape it surrounds.
    public func detectRegion(at p: PDFPoint, threshold: Double) -> Result<[PDFPoint], TraceFailure> {
        guard raster.contains(p) else { return .failure(TraceFailure("Click on the page to detect a shape.")) }
        let w = raster.width, h = raster.height, n = w * h
        let seed = raster.pixelIndex(of: p)
        let fill = RegionTracer.floodFill(raster, seed: seed, threshold: threshold)
        var mask: [Bool]
        if fill.touchesBorder {
            // Background click: the shape is the largest region the background surrounds.
            var inverse = [Bool](repeating: false, count: n)
            for i in 0..<n { inverse[i] = !fill.mask[i] }
            guard let comp = RegionTracer.largestComponent(inverse, w, h) else {
                return .failure(TraceFailure("No shape found: the colour around the click fills the whole page. Lower the threshold."))
            }
            mask = comp
        } else {
            mask = fill.mask
        }
        let area = mask.reduce(0) { $0 + ($1 ? 1 : 0) }
        if area < 200 { return .failure(TraceFailure("The detected region is too small (\(area) px). Raise the threshold or click inside a larger area.")) }
        if Double(area) > 0.985 * Double(n) { return .failure(TraceFailure("The detected region covers the whole page. Lower the threshold.")) }
        let boundary = RegionTracer.outerBoundary(mask, w, h)
        guard boundary.count >= 8 else { return .failure(TraceFailure("Could not trace the region's boundary.")) }
        let refined = edges.refine(boundary, movable: Array(repeating: true, count: boundary.count),
                                   minStrength: edges.edgeThreshold(sensitivity: sensitivity))
        return .success(refined.map { raster.point(x: $0.x, y: $0.y) })
    }
}

public enum TraceDefaults {
    public static let sensitivity = 0.5
    public static let tolerance = 0.5
    /// Anchor snap radius in screen points.
    public static let snapRadius = 8.0
    /// Auto-detect colour threshold (RGB distance).
    public static let regionThreshold = 40.0
    public static let dpi = 150.0
}

public struct TraceFailure: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import VoucherModel
import VoucherGeometry
import VoucherTrace

/// Synthetic rasters for the trace tests: an outline drawn with CoreGraphics into a
/// page-sized bitmap, exactly as `PageRaster.render` lays pixels out.
enum Synth {
    /// The S5 reference shape (GeometryTests.reference): stepped left edge, semicircular right end.
    static let reference = Outline(start: PDFPoint(564.5, 545), segments: [
        .line(to: PDFPoint(40, 545)), .line(to: PDFPoint(40, 460)), .line(to: PDFPoint(60, 460)),
        .line(to: PDFPoint(60, 380)), .line(to: PDFPoint(80, 380)), .line(to: PDFPoint(80, 215)),
        .line(to: PDFPoint(60, 215)), .line(to: PDFPoint(60, 135)), .line(to: PDFPoint(40, 135)),
        .line(to: PDFPoint(40, 50)), .line(to: PDFPoint(564.5, 50)),
        .arc(to: PDFPoint(564.5, 545), center: PDFPoint(564.5, 297.5), clockwise: false),
    ])

    static let page = PDFRect(x: 0, y: 0, width: 842, height: 595)

    enum Style { case filled, stroked(width: Double) }

    struct Options {
        var style: Style = .filled
        var dpi = 150.0
        var noise = 0.0                 // +- amplitude in 0...255
        var gaps: [PDFRect] = []        // painted white after drawing (breaks in the edge)
        var background: (Double, Double, Double) = (1, 1, 1)
        var ink: (Double, Double, Double) = (0, 0, 0)
    }

    static func raster(_ o: Outline, _ opt: Options = Options(), page: PDFRect = page) -> PageRaster {
        let scale = opt.dpi / 72
        let w = Int((page.width * scale).rounded(.up)), h = Int((page.height * scale).rounded(.up))
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: opt.background.0, green: opt.background.1, blue: opt.background.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -page.minX, y: -page.minY)
            let path = CGMutablePath()
            for (i, p) in Geometry.flatten(o, step: 0.1).enumerated() {
                if i == 0 { path.move(to: CGPoint(x: p.x, y: p.y)) } else { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            }
            path.closeSubpath()
            let ink = CGColor(red: opt.ink.0, green: opt.ink.1, blue: opt.ink.2, alpha: 1)
            switch opt.style {
            case .filled:
                ctx.setFillColor(ink)
                ctx.addPath(path); ctx.fillPath()
            case .stroked(let lw):
                ctx.setStrokeColor(ink)
                ctx.setLineWidth(lw)
                ctx.addPath(path); ctx.strokePath()
            }
            ctx.setFillColor(CGColor(red: opt.background.0, green: opt.background.1, blue: opt.background.2, alpha: 1))
            for g in opt.gaps { ctx.fill(CGRect(x: g.x, y: g.y, width: g.width, height: g.height)) }
        }
        if opt.noise > 0 {
            var rng = SeededRNG(seed: 42)
            for i in 0..<(w * h) {
                let n = (Double(rng.next() % 10_000) / 10_000 * 2 - 1) * opt.noise
                for c in 0..<3 {
                    let v = Double(bytes[4 * i + c]) + n
                    bytes[4 * i + c] = UInt8(max(0, min(255, v.rounded())))
                }
            }
        }
        return PageRaster(width: w, height: h, scale: scale, origin: PDFPoint(page.minX, page.minY), rgba: bytes)
    }

    /// Max distance from the points of `a` (flattened finely) to the polyline of `b`.
    static func deviation(_ a: Outline, from b: Outline) -> Double {
        let pa = Geometry.flatten(a, step: 0.5)
        let pb = Geometry.flatten(b, step: 0.25)
        var worst = 0.0
        for p in pa {
            var best = Double.infinity
            for i in pb.indices {
                best = min(best, Geometry.distance(from: p, toSegment: pb[i], pb[(i + 1) % pb.count]))
            }
            worst = max(worst, best)
        }
        return worst
    }

    static func hausdorff(_ a: Outline, _ b: Outline) -> Double { max(deviation(a, from: b), deviation(b, from: a)) }

    /// Simulate the smart outline tool: snap each click, trace from the previous anchor,
    /// close back to the first anchor, then fit. Returns the anchors and the result.
    static func traceByClicks(_ ctx: TraceContext, clicks: [PDFPoint], snapRadiusPx: Double = 6, tolerance: Double = 0.5)
        -> (anchors: [PDFPoint], result: Result<Outline, TraceFailure>) {
        var anchors: [PDFPoint] = []
        var segs: [TracedSegment] = []
        var wire: LiveWire?
        for c in clicks + [clicks[0]] {
            let a = anchors.count == clicks.count ? anchors[0] : ctx.snapAnchor(c, radiusPx: snapRadiusPx)
            if let w = wire, let last = anchors.last {
                segs.append(ctx.segment(w, from: last, to: a) ?? TracedSegment(points: [last, a], magnetic: false))
            }
            if anchors.count < clicks.count { anchors.append(a) }
            wire = ctx.wire(from: a)
        }
        return (anchors, OutlineTracer.outline(segments: segs, context: ctx, tolerance: tolerance))
    }

    /// PNG of the raster with outlines drawn over it (for eyeballing failures).
    static func writePNG(_ r: PageRaster, overlays: [(Outline, CGColor)] = [], polylines: [([PDFPoint], CGColor)] = [], to url: URL) {
        var bytes = r.rgba
        bytes.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: r.width, height: r.height, bitsPerComponent: 8, bytesPerRow: r.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.scaleBy(x: r.scale, y: r.scale)
            ctx.translateBy(x: -r.origin.x, y: -r.origin.y)
            ctx.setLineWidth(0.6)
            for (pts, color) in polylines + overlays.map({ (Geometry.flatten($0.0, step: 0.5) + [$0.0.start], $0.1) }) {
                ctx.setStrokeColor(color)
                for (i, p) in pts.enumerated() {
                    if i == 0 { ctx.move(to: CGPoint(x: p.x, y: p.y)) } else { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
                }
                ctx.strokePath()
            }
            for (o, color) in overlays {
                ctx.setFillColor(color)
                for p in o.points { ctx.fillEllipse(in: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)) }
            }
            let img = ctx.makeImage()!
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}

struct SeededRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
}

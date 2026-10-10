import XCTest
import CoreGraphics
import VoucherModel
import VoucherGeometry
import VoucherTrace

/// The smart outline on a real two-page voucher template. Opt-in: runs only when
/// $VE_TEMPLATE_PDF points at a copy of one (never the original); no real template is
/// included in the repo. On the template used during development, page 1's artwork is one
/// big JPEG with the die line drawn into the image as a ~1 pt dark stroke, and page 2 is
/// vector art.
final class RealTemplateTests: XCTestCase {
    static let path = ProcessInfo.processInfo.environment["VE_TEMPLATE_PDF"]

    func load(page: Int) throws -> (PageRaster, TraceContext) {
        guard let path = Self.path else { throw XCTSkip("set VE_TEMPLATE_PDF to a copy of your own template to run this test") }
        guard let data = FileManager.default.contents(atPath: path) else { throw XCTSkip("no template copy at \(path)") }
        let cg = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!)?.page(at: page + 1))
        let mb = cg.getBoxRect(.mediaBox)
        let box = PDFRect(x: Double(mb.minX), y: Double(mb.minY), width: Double(mb.width), height: Double(mb.height))
        let t0 = Date()
        let r = try XCTUnwrap(PageRaster.render(pdfData: data, pageIndex: page, box: box, dpi: TraceDefaults.dpi))
        let t1 = Date()
        let ctx = TraceContext(raster: r)
        print(String(format: "REAL page %d: %dx%d px, render %.0f ms, edge map %.0f ms, F floor %.3f norm %.3f",
                     page + 1, r.width, r.height, t1.timeIntervalSince(t0) * 1000, Date().timeIntervalSince(t1) * 1000,
                     ctx.edges.floor, ctx.edges.norm))
        return (r, ctx)
    }

    func describe(_ name: String, _ o: Outline) {
        let c = o.counts
        print("REAL \(name): \(c.lines) lines, \(c.arcs) arcs, \(c.curves) curves, valid \(Geometry.validate(o).isEmpty)")
        var cur = o.start
        for s in o.segments {
            var extra = ""
            if case .arc(_, let ctr, let cw) = s { extra = String(format: " centre (%.2f, %.2f) r %.2f %@", ctr.x, ctr.y, cur.distance(to: ctr), cw ? "CW" : "CCW") }
            print(String(format: "REAL   %@ (%.2f, %.2f) -> (%.2f, %.2f)%@", s.kindName, cur.x, cur.y, s.end.x, s.end.y, extra))
            cur = s.end
        }
    }

    func dump(_ name: String, _ r: PageRaster, _ o: Outline) {
        guard let dir = ProcessInfo.processInfo.environment["VE_TRACE_OUT"] else { return }
        Synth.writePNG(r, overlays: [(o, CGColor(red: 0, green: 0.85, blue: 1, alpha: 1))], to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    /// Auto-detect by clicking the white page margin, then trace by clicking near the
    /// detected corners (offset like a hand would) and compare the two.
    func run(page: Int, backgroundClick: PDFPoint) throws {
        let (r, ctx) = try load(page: page)
        let t0 = Date()
        let detected = try OutlineTracer.outline(polyline: try ctx.detectRegion(at: backgroundClick, threshold: TraceDefaults.regionThreshold).get(),
                                                 tolerance: TraceDefaults.tolerance, context: ctx).get()
        print(String(format: "REAL page %d auto-detect: %.0f ms", page + 1, Date().timeIntervalSince(t0) * 1000))
        describe("page \(page + 1) auto-detect", detected)
        dump("real-p\(page + 1)-detect", r, detected)
        XCTAssertEqual(Geometry.validate(detected), [])

        // Clicks: every detected vertex, nudged 1.5 pt, plus the middle of each arc.
        var clicks: [PDFPoint] = []
        var cur = detected.start
        for (i, s) in detected.segments.enumerated() {
            clicks.append(PDFPoint(cur.x + (i % 2 == 0 ? 1.5 : -1.2), cur.y + (i % 3 == 0 ? 1.1 : -1.4)))
            if case .arc(let to, let c, let cw) = s {
                let (rr, a0, sweep) = Geometry.arcSweep(from: cur, to: to, center: c, clockwise: cw)
                clicks.append(PDFPoint(c.x + rr * cos(a0 + sweep / 2) + 1, c.y + rr * sin(a0 + sweep / 2)))
            }
            cur = s.end
        }
        let t1 = Date()
        let traced = try Synth.traceByClicks(ctx, clicks: clicks, snapRadiusPx: 8 * ctx.pixelsPerPoint / 1.0 * 0.5).result.get()
        print(String(format: "REAL page %d magnetic trace (%d clicks): %.0f ms", page + 1, clicks.count, Date().timeIntervalSince(t1) * 1000))
        describe("page \(page + 1) magnetic", traced)
        dump("real-p\(page + 1)-magnetic", r, traced)
        XCTAssertEqual(Geometry.validate(traced), [])
        let dev = Synth.hausdorff(traced, detected)
        print(String(format: "REAL page %d: magnetic vs auto-detect max distance %.2f pt", page + 1, dev))
        XCTAssertLessThan(dev, 1.5)
    }

    func testPage1PhotoArtwork() throws { try run(page: 0, backgroundClick: PDFPoint(12, 580)) }

    func testPage2VectorArtwork() throws { try run(page: 1, backgroundClick: PDFPoint(12, 580)) }
}

import XCTest
import CoreGraphics
import VoucherModel
import VoucherGeometry
import VoucherTrace

final class TraceTests: XCTestCase {
    static let outDir: URL? = ProcessInfo.processInfo.environment["VE_TRACE_OUT"].map { URL(fileURLWithPath: $0) }

    func dump(_ name: String, _ r: PageRaster, _ result: Outline?, polyline: [PDFPoint] = []) {
        guard let dir = Self.outDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var overlays: [(Outline, CGColor)] = []
        if let o = result { overlays.append((o, CGColor(red: 1, green: 0, blue: 0.5, alpha: 1))) }
        Synth.writePNG(r, overlays: overlays, polylines: polyline.isEmpty ? [] : [(polyline, CGColor(red: 0, green: 0.7, blue: 0.9, alpha: 1))],
                       to: dir.appendingPathComponent("\(name).png"))
    }

    /// Clicks near each reference vertex (off by about a pixel or two, so snapping matters)
    /// plus one on the arc's rightmost point.
    static var referenceClicks: [PDFPoint] {
        var clicks = Synth.reference.points.dropLast().enumerated().map { i, p in
            PDFPoint(p.x + (i % 2 == 0 ? 1.2 : -0.9), p.y + (i % 3 == 0 ? -1.1 : 0.8))
        }
        clicks.append(PDFPoint(810.8, 298.4)) // on the semicircle (rightmost point 812, 297.5)
        return clicks
    }

    func assertReferenceShape(_ o: Outline, maxDeviation: Double = 0.5, file: StaticString = #filePath, line: UInt = #line) {
        let c = o.counts
        XCTAssertEqual(c.lines, 11, "lines", file: file, line: line)
        XCTAssertEqual(c.arcs, 1, "arcs", file: file, line: line)
        XCTAssertEqual(c.curves, 0, file: file, line: line)
        XCTAssertEqual(Geometry.validate(o), [], file: file, line: line)
        let dev = Synth.hausdorff(o, Synth.reference)
        XCTAssertLessThanOrEqual(dev, maxDeviation, "max deviation from the drawn shape", file: file, line: line)
        // Every reference vertex has a traced vertex within the tolerance.
        for p in Synth.reference.points {
            let d = o.points.map { $0.distance(to: p) }.min() ?? .infinity
            XCTAssertLessThanOrEqual(d, maxDeviation, "vertex \(p)", file: file, line: line)
        }
        // Steps are exactly orthogonal.
        var cur = o.start
        for s in o.segments {
            if case .line(let p) = s {
                XCTAssertTrue(p.x == cur.x || p.y == cur.y, "line \(cur) -> \(p) is exactly horizontal or vertical", file: file, line: line)
            }
            cur = s.end
        }
    }

    // MARK: Fitting alone

    func testFitterOnJitteredReferencePolyline() throws {
        var rng = SeededRNG(seed: 7)
        let pts = Geometry.flatten(Synth.reference, step: 0.5).map { p -> PDFPoint in
            let jx = (Double(rng.next() % 1000) / 1000 - 0.5) * 0.3, jy = (Double(rng.next() % 1000) / 1000 - 0.5) * 0.3
            return PDFPoint(p.x + jx, p.y + jy)
        }
        let o = try XCTUnwrap(PrimitiveFitter.fitClosed(pts, tolerance: 0.5))
        assertReferenceShape(o)
        if case .arc(_, let c, _) = o.segments.first(where: { if case .arc = $0 { return true } else { return false } })! {
            XCTAssertEqual(c.x, 564.5, accuracy: 0.3)
            XCTAssertEqual(c.y, 297.5, accuracy: 0.3)
            XCTAssertGreaterThan(Geometry.boundingBox(o).maxX, 811.5, "the arc bulges to the right")
        }
    }

    func testFitterKeepsFreeformAsShortPrimitivesWithinTolerance() throws {
        // A wobbly blob: no lines or one circle fit it, but the result stays within tolerance.
        let pts = (0..<720).map { i -> PDFPoint in
            let t = Double(i) / 720 * 2 * .pi
            let r = 120 + 18 * sin(3 * t) + 7 * cos(5 * t)
            return PDFPoint(400 + r * cos(t), 300 + r * sin(t))
        }
        let o = try XCTUnwrap(PrimitiveFitter.fitClosed(pts, tolerance: 0.5))
        XCTAssertEqual(Geometry.validate(o), [])
        let poly = Outline(start: pts[0], segments: pts.dropFirst().map { .line(to: $0) } + [.line(to: pts[0])])
        XCTAssertLessThanOrEqual(Synth.hausdorff(o, poly), 0.75)
        XCTAssertLessThan(o.segments.count, 120, "far fewer pieces than the 720 input points")
    }

    func testSelfIntersectingTraceIsRejectedWithMessage() {
        // A figure eight.
        let pts = (0..<400).map { i -> PDFPoint in
            let t = Double(i) / 400 * 2 * .pi
            return PDFPoint(400 + 200 * sin(t), 300 + 100 * sin(2 * t))
        }
        switch OutlineTracer.outline(polyline: pts, tolerance: 0.5) {
        case .success(let o): XCTFail("accepted a self-intersecting trace: \(o.segments.count) segments")
        case .failure(let f): XCTAssertTrue(f.message.contains("crosses itself"), f.message)
        }
    }

    func testJoinSpikesAndLoopsAreRemoved() {
        // Segment 2 doubles back over the end of segment 1 before turning.
        let a = TracedSegment(points: [PDFPoint(0, 0), PDFPoint(1, 0), PDFPoint(2, 0), PDFPoint(3, 0)], magnetic: true)
        let b = TracedSegment(points: [PDFPoint(3, 0), PDFPoint(2, 0), PDFPoint(2, 1), PDFPoint(2, 2), PDFPoint(0, 2)], magnetic: true)
        let c = TracedSegment(points: [PDFPoint(0, 2), PDFPoint(0, 1), PDFPoint(0, 0)], magnetic: true)
        let (pts, mov) = OutlineTracer.closedPolyline([a, b, c])
        XCTAssertEqual(pts, [PDFPoint(0, 0), PDFPoint(1, 0), PDFPoint(2, 0), PDFPoint(2, 1), PDFPoint(2, 2), PDFPoint(0, 2), PDFPoint(0, 1)])
        XCTAssertEqual(mov.count, pts.count)
    }

    // MARK: Magnetic tracing on synthetic rasters

    func testFilledReferenceShapeTracesToElevenLinesAndOneArc() throws {
        let r = Synth.raster(Synth.reference)
        let ctx = TraceContext(raster: r)
        let (anchors, result) = Synth.traceByClicks(ctx, clicks: Self.referenceClicks)
        // Clicks snapped onto the corners.
        for (a, p) in zip(anchors, Synth.reference.points.dropLast()) { XCTAssertLessThanOrEqual(a.distance(to: p), 1.6, "anchor \(a) snapped near \(p)") }
        let o = try result.get()
        dump("filled", r, o)
        assertReferenceShape(o)
    }

    func testStrokedReferenceShapeFollowsTheLineCentre() throws {
        let r = Synth.raster(Synth.reference, .init(style: .stroked(width: 1)))
        let ctx = TraceContext(raster: r)
        let o = try Synth.traceByClicks(ctx, clicks: Self.referenceClicks).result.get()
        dump("stroked", r, o)
        assertReferenceShape(o)
    }

    func testNoisyGreyShapeOnTintedBackground() throws {
        var opt = Synth.Options()
        opt.noise = 30
        opt.background = (0.86, 0.9, 0.95)
        opt.ink = (0.35, 0.3, 0.3)
        let r = Synth.raster(Synth.reference, opt)
        let ctx = TraceContext(raster: r)
        let o = try Synth.traceByClicks(ctx, clicks: Self.referenceClicks).result.get()
        dump("noisy", r, o)
        assertReferenceShape(o)
    }

    func testGapsInTheEdgeAreBridged() throws {
        var opt = Synth.Options(style: .stroked(width: 1))
        // 6 pt breaks in the bottom edge, in a step, and in the arc.
        opt.gaps = [PDFRect(x: 300, y: 45, width: 6, height: 10), PDFRect(x: 55, y: 300, width: 10, height: 6),
                    PDFRect(x: 790, y: 380, width: 12, height: 6)]
        let r = Synth.raster(Synth.reference, opt)
        let ctx = TraceContext(raster: r)
        let o = try Synth.traceByClicks(ctx, clicks: Self.referenceClicks).result.get()
        dump("gaps", r, o)
        assertReferenceShape(o)
    }

    func testCoarseAnchorsOnlyAtSomeCornersStillFollowTheEdge() throws {
        // Only 5 clicks: the live wire has to find the steps on its own between them.
        let r = Synth.raster(Synth.reference)
        let ctx = TraceContext(raster: r)
        let clicks = [PDFPoint(300, 545.8), PDFPoint(41, 500), PDFPoint(41, 90), PDFPoint(300, 50.5), PDFPoint(811, 297)]
        let o = try Synth.traceByClicks(ctx, clicks: clicks, snapRadiusPx: 6).result.get()
        dump("coarse", r, o)
        assertReferenceShape(o)
    }

    func testStraightSegmentsMixWithTracedOnes() throws {
        // Shift-clicks: straight segments for the left part, traced for the arc.
        let r = Synth.raster(Synth.reference)
        let ctx = TraceContext(raster: r)
        let ref = Synth.reference.points
        var segs: [TracedSegment] = []
        for i in 0..<11 { segs.append(TracedSegment(points: [ref[i], ref[i + 1]], magnetic: false)) }
        let w = ctx.wire(from: ref[11])
        let traced = try XCTUnwrap(ctx.trace(w, from: ref[11], to: ref[0]))
        segs.append(TracedSegment(points: traced, magnetic: true))
        let o = try OutlineTracer.outline(segments: segs, context: ctx, tolerance: 0.5).get()
        assertReferenceShape(o)
    }

    func testToleranceChangesTheResult() throws {
        // The semicircle drawn as a 24-gon: at 0.5 pt it is one arc; at 0.05 pt the facets show.
        var segs: [Segment] = [.line(to: PDFPoint(100, 100)), .line(to: PDFPoint(400, 100))]
        for k in 1...24 {
            let a = -Double.pi / 2 + Double.pi * Double(k) / 24
            segs.append(.line(to: PDFPoint(400 + 150 * cos(a), 250 + 150 * sin(a))))
        }
        let shape = Outline(start: PDFPoint(100, 400), segments: segs)
        let pts = Geometry.flatten(shape, step: 0.5)
        let coarse = try XCTUnwrap(PrimitiveFitter.fitClosed(pts, tolerance: 1.0))
        let fine = try XCTUnwrap(PrimitiveFitter.fitClosed(pts, tolerance: 0.05))
        XCTAssertEqual(coarse.counts.arcs, 1)
        XCTAssertGreaterThan(fine.segments.count, coarse.segments.count)
    }

    // MARK: Auto-detect shape

    func testAutoDetectFromBackgroundClick() throws {
        let r = Synth.raster(Synth.reference, .init(style: .stroked(width: 1)))
        let ctx = TraceContext(raster: r)
        let poly = try ctx.detectRegion(at: PDFPoint(10, 10), threshold: TraceDefaults.regionThreshold).get()
        let o = try OutlineTracer.outline(polyline: poly, tolerance: 0.5).get()
        dump("detect-bg", r, o)
        assertReferenceShape(o)
    }

    func testAutoDetectFromInsideClick() throws {
        let r = Synth.raster(Synth.reference)
        let ctx = TraceContext(raster: r)
        let poly = try ctx.detectRegion(at: PDFPoint(400, 300), threshold: TraceDefaults.regionThreshold).get()
        let o = try OutlineTracer.outline(polyline: poly, tolerance: 0.5).get()
        dump("detect-in", r, o)
        assertReferenceShape(o)
    }

    func testAutoDetectReportsTooSmallAndWholePage() {
        let r = Synth.raster(Synth.reference)
        let ctx = TraceContext(raster: r)
        if case .success = ctx.detectRegion(at: PDFPoint(400, 300), threshold: 500) { XCTFail("threshold above max distance fills the page") }
        if case .success = ctx.detectRegion(at: PDFPoint(-50, 10), threshold: 40) { XCTFail("outside the page") }
    }

    // MARK: Rendering and coordinates (S6: /Rotate and CropBox origin)

    /// A one-page PDF with /Rotate 90, a MediaBox and CropBox not at the origin, and a black
    /// square at user-space x 300...340, y 200...240.
    static func rotatedPDF() -> Data {
        let content = "0 0 0 rg 300 200 40 40 re f"
        var objs: [String] = []
        objs.append("<< /Type /Catalog /Pages 2 0 R >>")
        objs.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objs.append("<< /Type /Page /Parent 2 0 R /MediaBox [100 50 700 450] /CropBox [120 60 680 440] /Rotate 90 /Contents 4 0 R /Resources << >> >>")
        objs.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, o) in objs.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objs.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objs.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    func testRenderIsInUserSpaceIgnoringRotateWithCropBoxOrigin() throws {
        let box = PDFRect(x: 100, y: 50, width: 600, height: 400) // MediaBox (what the model uses)
        let r = try XCTUnwrap(PageRaster.render(pdfData: Self.rotatedPDF(), pageIndex: 0, box: box, dpi: 150))
        XCTAssertEqual(r.width, 1250); XCTAssertEqual(r.height, 834)
        func gray(_ p: PDFPoint) -> UInt8 { r.rgba[4 * r.pixelIndex(of: p)] }
        XCTAssertLessThan(gray(PDFPoint(320, 220)), 20, "the square is where user space says")
        XCTAssertGreaterThan(gray(PDFPoint(290, 220)), 235)
        XCTAssertGreaterThan(gray(PDFPoint(320, 250)), 235)
        // Region detection gives the square back in user space.
        let ctx = TraceContext(raster: r)
        let o = try OutlineTracer.outline(polyline: try ctx.detectRegion(at: PDFPoint(320, 220), threshold: 40).get(), tolerance: 0.5).get()
        let bb = Geometry.boundingBox(o)
        XCTAssertEqual(bb.minX, 300, accuracy: 0.5); XCTAssertEqual(bb.maxX, 340, accuracy: 0.5)
        XCTAssertEqual(bb.minY, 200, accuracy: 0.5); XCTAssertEqual(bb.maxY, 240, accuracy: 0.5)
        XCTAssertEqual(o.segments.count, 4)
    }

    func testPixelPointRoundTrip() {
        let r = Synth.raster(Synth.reference)
        for p in [PDFPoint(0.3, 0.2), PDFPoint(421.7, 297.1), PDFPoint(841.9, 594.9)] {
            let (x, y) = r.pixel(of: p)
            let q = r.point(x: x, y: y)
            XCTAssertEqual(q.x, p.x, accuracy: 1e-9); XCTAssertEqual(q.y, p.y, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(r.pointOfPixel(r.pixelIndex(of: p)).distance(to: p), 0.5 / r.scale * 1.5)
        }
    }

    // MARK: Performance (numbers printed; bounds are loose because tests run unoptimised)

    func testInteractivePerformanceOnAFullPage() throws {
        let r = Synth.raster(Synth.reference, .init(style: .stroked(width: 1), noise: 12))
        let t0 = Date()
        let ctx = TraceContext(raster: r)
        let tBuild = Date().timeIntervalSince(t0)
        // Anchor at the bottom-left corner; the cursor glides along the bottom edge and up the arc.
        let a = ctx.snapAnchor(PDFPoint(40, 50), radiusPx: 6)
        let t1 = Date()
        let wire = ctx.wire(from: a)
        let tWire = Date().timeIntervalSince(t1)
        var times: [Double] = []
        var cursor: [PDFPoint] = stride(from: 45.0, through: 560, by: 2.4).map { PDFPoint($0, 50) }
        for k in 0..<120 {
            let ang = -Double.pi / 2 + Double.pi * Double(k) / 120
            cursor.append(PDFPoint(564.5 + 247.5 * cos(ang), 297.5 + 247.5 * sin(ang)))
        }
        for c in cursor {
            let s = Date()
            _ = ctx.trace(wire, from: a, to: c)
            times.append(Date().timeIntervalSince(s))
        }
        let sorted = times.sorted()
        let msg = String(format: "page %dx%d px: edge map %.0f ms, new anchor %.1f ms, per update median %.2f ms, p95 %.2f ms, max %.1f ms, total %.0f ms over %d updates; settled %d px",
                         r.width, r.height, tBuild * 1000, tWire * 1000, sorted[sorted.count / 2] * 1000,
                         sorted[sorted.count * 95 / 100] * 1000, sorted.last! * 1000, times.reduce(0, +) * 1000, times.count, wire.settledCount)
        // Worst case: a fresh anchor and the cursor jumping to the far corner of the page,
        // which settles nearly every pixel.
        let far = ctx.wire(from: a)
        let t2 = Date()
        _ = ctx.trace(far, from: a, to: PDFPoint(840, 593))
        let tFar = Date().timeIntervalSince(t2)
        // Closing and fitting a whole outline.
        let t3 = Date()
        _ = Synth.traceByClicks(ctx, clicks: TraceTests.referenceClicks)
        let tFlow = Date().timeIntervalSince(t3)
        print("TRACE PERF: \(msg); " + String(format: "far-corner jump %.0f ms; 13 clicks + close + fit %.0f ms", tFar * 1000, tFlow * 1000))
        XCTAssertLessThan(sorted[sorted.count / 2], 0.25, msg)
    }
}

final class TraceRobustnessTests: XCTestCase {
    /// The reference shape over a grid of conditions at the app's 150 dpi: fill or 1 pt
    /// line, tolerance 0.5 or 1 pt, and three different sets of hand-placed clicks (+-1.5 pt).
    /// (At 200 dpi a 1 pt line is about 3 px wide and the trace can follow either side of it,
    /// up to 0.55 pt off; see the known limits in DECISIONS.md.)
    func testReferenceShapeAcrossConditions() throws {
        var failures: [String] = []
        for style in [Synth.Style.filled, .stroked(width: 1)] {
            for dpi in [150.0] {
                let r = Synth.raster(Synth.reference, .init(style: style, dpi: dpi))
                let ctx = TraceContext(raster: r)
                for tol in [0.5, 1.0] {
                    for seed in [1, 2] as [UInt64] {
                        var rng = SeededRNG(seed: seed)
                        func j() -> Double { Double(rng.next() % 1000) / 1000 * 3 - 1.5 } // +-1.5 pt
                        let clicks = TraceTests.referenceClicks.map { PDFPoint($0.x + j(), $0.y + j()) }
                        let name = "\(style) dpi \(Int(dpi)) tol \(tol) seed \(seed)"
                        switch Synth.traceByClicks(ctx, clicks: clicks, snapRadiusPx: 8 * dpi / 72, tolerance: tol).result {
                        case .failure(let f): failures.append("\(name): \(f.message)")
                        case .success(let o):
                            let c = o.counts, dev = Synth.hausdorff(o, Synth.reference)
                            if c.lines != 11 || c.arcs != 1 || dev > tol { failures.append("\(name): \(c.lines)L \(c.arcs)A dev \(String(format: "%.2f", dev))") }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(failures, [])
    }
}

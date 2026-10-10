import XCTest
import AppKit
import PDFKit
import CoreGraphics
@testable import VoucherEditorApp
import VoucherModel
import VoucherGeometry
import VoucherTrace

/// The smart outline driven through the real overlay with synthesized mouse and key
/// events (off-screen window, PDFView at 100 %), on a PDF whose artwork is the SPEC's
/// reference shape (stepped left edge, semicircular right end) drawn as a 1 pt line.
@MainActor
final class SmartOutlineTests: XCTestCase {
    var window: NSWindow!
    var pdfView: PDFView!
    var overlay: OverlayView!
    var model: DocumentModel!
    var undo: UndoManager!

    nonisolated static let reference = Outline(start: PDFPoint(564.5, 545), segments: [
        .line(to: PDFPoint(40, 545)), .line(to: PDFPoint(40, 460)), .line(to: PDFPoint(60, 460)),
        .line(to: PDFPoint(60, 380)), .line(to: PDFPoint(80, 380)), .line(to: PDFPoint(80, 215)),
        .line(to: PDFPoint(60, 215)), .line(to: PDFPoint(60, 135)), .line(to: PDFPoint(40, 135)),
        .line(to: PDFPoint(40, 50)), .line(to: PDFPoint(564.5, 50)),
        .arc(to: PDFPoint(564.5, 545), center: PDFPoint(564.5, 297.5), clockwise: false),
    ])

    /// A one-page PDF (842 x 595) with `outline` stroked in black, plus some grey text-like
    /// clutter inside so the trace has something to ignore.
    static func artworkPDF(_ outline: Outline = reference, lineWidth: CGFloat = 1) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 842, height: 595)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0.6, green: 0.6, blue: 0.65, alpha: 1))
        for k in 0..<6 { ctx.fill(CGRect(x: 160 + Double(k) * 60, y: 280, width: 40, height: 12)) }
        let path = CGMutablePath()
        for (i, p) in Geometry.flatten(outline, step: 0.25).enumerated() {
            if i == 0 { path.move(to: CGPoint(x: p.x, y: p.y)) } else { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
        }
        path.closeSubpath()
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(lineWidth)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    func open(_ data: Data) throws {
        undo = UndoManager()
        undo.groupsByEvent = false
        model = try DocumentModel(data: data, undoManager: undo)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760))
        pdfView.displayMode = .singlePage
        pdfView.autoScales = false
        window.contentView = pdfView
        pdfView.document = PDFDocument(data: data)
        pdfView.scaleFactor = 1
        pdfView.layoutDocumentView()
        overlay = OverlayView(frame: pdfView.bounds)
        overlay.pdfView = pdfView
        overlay.model = model
        pdfView.addSubview(overlay)
        model.pdfView = pdfView
    }

    override func setUp() async throws {
        for k in TracePrefs.allKeys { UserDefaults.standard.removeObject(forKey: k) } // defaults: smart on, click anchors
        try open(Self.artworkPDF())
    }

    override func tearDown() async throws {
        for k in TracePrefs.allKeys { UserDefaults.standard.removeObject(forKey: k) }
    }

    // MARK: Event helpers

    func viewPoint(_ x: Double, _ y: Double) -> NSPoint {
        let page = pdfView.document!.page(at: 0)!
        return overlay.convert(pdfView.convert(NSPoint(x: x, y: y), from: page), from: pdfView)
    }

    func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double, mods: NSEvent.ModifierFlags = []) -> NSEvent {
        let w = overlay.convert(viewPoint(x, y), to: nil)
        return NSEvent.mouseEvent(with: type, location: w, modifierFlags: mods, timestamp: 0, windowNumber: window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func click(_ x: Double, _ y: Double, mods: NSEvent.ModifierFlags = []) {
        overlay.mouseDown(with: mouse(.leftMouseDown, x, y, mods: mods)); overlay.mouseUp(with: mouse(.leftMouseUp, x, y, mods: mods))
    }

    func move(_ x: Double, _ y: Double, mods: NSEvent.ModifierFlags = []) { overlay.mouseMoved(with: mouse(.mouseMoved, x, y, mods: mods)) }

    func key(_ code: UInt16, _ chars: String = "") {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        overlay.keyDown(with: e)
    }

    func snapshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["VE_SNAPSHOT_TEST_DIR"] else { return }
        overlay.needsDisplay = true
        guard let rep = pdfView.bitmapImageRepForCachingDisplay(in: pdfView.bounds) else { return }
        pdfView.cacheDisplay(in: pdfView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    /// Clicks a hand would make: near each corner (1-2 pt off) and once on the semicircle.
    let clicks: [(Double, Double)] = [(565.6, 543.9), (41.2, 546.1), (38.9, 461.0), (61.4, 458.8), (58.8, 381.2), (81.3, 378.9),
                                      (78.7, 216.2), (61.2, 213.8), (58.9, 136.1), (41.3, 133.9), (38.8, 51.2), (563.4, 48.9), (811.2, 296.4)]

    func assertReference(_ o: Outline, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(o.counts.lines, 11, file: file, line: line)
        XCTAssertEqual(o.counts.arcs, 1, file: file, line: line)
        XCTAssertEqual(Geometry.validate(o), [], file: file, line: line)
        for p in Self.reference.points {
            XCTAssertLessThanOrEqual(o.points.map { $0.distance(to: p) }.min()!, 0.5, "vertex near \(p)", file: file, line: line)
        }
        var cur = o.start
        for s in o.segments {
            if case .line(let p) = s { XCTAssertTrue(p.x == cur.x || p.y == cur.y, "orthogonal \(cur) -> \(p)", file: file, line: line) }
            cur = s.end
        }
    }

    // MARK: Tests

    func testClickingAnchorsTracesTheArtworkIntoLinesAndOneArcInOneUndoStep() throws {
        model.tool = .outline
        for (x, y) in clicks { click(x, y) }
        XCTAssertEqual(overlay.pendingSegments.count, clicks.count - 1)
        XCTAssertTrue(overlay.pendingSegments.allSatisfy(\.magnetic))
        move(565.6, 545.6) // hovering the first anchor previews the closing trace
        XCTAssertNotNil(overlay.hoverTrace)
        snapshot("smart-1-before-close")
        click(565.6, 544.4) // close on the first anchor
        let o = try XCTUnwrap(model.template.outlines[0], "\(overlay.placementHint ?? "") anchors \(overlay.pendingOutline)")
        assertReference(o)
        XCTAssertFalse(overlay.isInProgress)
        snapshot("smart-2-closed")
        // One undo step for the whole outline.
        XCTAssertEqual(undo.undoActionName, "Trace Outline")
        undo.undo()
        XCTAssertNil(model.template.outlines[0])
        undo.redo()
        XCTAssertEqual(model.template.outlines[0], o)
    }

    func testLivePreviewFollowsTheEdgeInsteadOfTheStraightLine() throws {
        model.tool = .outline
        click(41, 51) // bottom-left corner
        // Cursor near the far end of the bottom edge, 1.5 pt above it.
        move(500, 51.5)
        let trace = try XCTUnwrap(overlay.hoverTrace)
        XCTAssertGreaterThan(trace.count, 100)
        XCTAssertTrue(trace.allSatisfy { abs($0.y - 50) <= 1.0 }, "the preview runs along the bottom edge")
        // Around the semicircle: the preview hugs the arc, not the chord.
        move(812, 297)
        let arc = try XCTUnwrap(overlay.hoverTrace)
        let onArc = arc.filter { $0.x > 566 }
        XCTAssertGreaterThan(onArc.count, 100)
        XCTAssertTrue(onArc.allSatisfy { abs($0.distance(to: PDFPoint(564.5, 297.5)) - 247.5) <= 1.0 })
        snapshot("smart-0-live-preview")
    }

    func testShiftCmdAndOptionPlaceStraightSegments() {
        model.tool = .outline
        click(41, 51)
        click(300, 200, mods: .shift)   // straight, angle-constrained
        click(320, 260, mods: .command) // straight, no snapping
        click(330, 300, mods: .option)
        XCTAssertEqual(overlay.pendingSegments.map(\.magnetic), [false, false, false])
        XCTAssertEqual(overlay.pendingSegments[0].points.count, 2)
        click(560, 51) // plain click: snaps onto the bottom edge and traces
        XCTAssertEqual(overlay.pendingSegments.last?.magnetic, true)
    }

    func testDeleteEscapeAndRightClickStillWork() {
        model.tool = .outline
        click(41, 51); click(563, 49); click(811, 296)
        XCTAssertEqual(overlay.pendingSegments.count, 2)
        key(51) // Delete removes the last anchor and its traced segment
        XCTAssertEqual(overlay.pendingSegments.count, 1)
        XCTAssertTrue(overlay.isInProgress)
        key(53) // Escape cancels
        XCTAssertFalse(overlay.isInProgress)
        XCTAssertNil(overlay.hoverTrace)
        click(41, 51); click(563, 49)
        overlay.rightMouseDown(with: mouse(.rightMouseDown, 300, 300))
        XCTAssertFalse(overlay.isInProgress)
        XCTAssertTrue(overlay.pendingSegments.isEmpty)
        XCTAssertNil(model.template.outlines[0])
    }

    func testReturnClosesAlongTheArtwork() throws {
        model.tool = .outline
        for (x, y) in clicks { click(x, y) }
        key(36) // Return: the closing segment is traced too
        assertReference(try XCTUnwrap(model.template.outlines[0]))
    }

    func testThreeAnchorsAndTheArtworkMakeAnOutline() throws {
        // Two clicks at the arc's ends: closing would run straight back along the same arc
        // (the cheapest path), which is refused with a hint; a third anchor on the left
        // side sends the closing trace round the steps.
        model.tool = .outline
        click(563.4, 48.9); click(565.6, 545.9)
        key(36)
        XCTAssertNil(model.template.outlines[0])
        XCTAssertEqual(overlay.placementHint?.contains("anchor"), true, overlay.placementHint ?? "")
        click(80.8, 300) // on the innermost step
        key(36)
        let o = try XCTUnwrap(model.template.outlines[0], overlay.placementHint ?? "")
        XCTAssertEqual(Geometry.validate(o), [])
        assertReference(o)
    }

    func testCrossingTraceIsRefusedWithMessageAndAnchorsKept() throws {
        model.tool = .outline
        click(40, 545)
        click(564.5, 50, mods: .command)  // straight diagonal
        click(40, 50, mods: .command)     // straight along the bottom
        click(564.5, 545, mods: .command) // straight diagonal, crossing the first
        key(36)                           // close along the top edge (traced)
        XCTAssertNil(model.template.outlines[0])
        XCTAssertTrue(overlay.isInProgress, "anchors stay so the last one can be removed")
        XCTAssertEqual(overlay.placementHint?.contains("crosses itself"), true, overlay.placementHint ?? "")
        key(51)
        XCTAssertNotEqual(overlay.placementHint?.contains("crosses itself"), true)
        key(53)
        XCTAssertFalse(overlay.isInProgress)
    }

    func testAutoDetectShapeInOneClick() throws {
        UserDefaults.standard.set(TracePrefs.Mode.detect.rawValue, forKey: TracePrefs.modeKey)
        model.tool = .outline
        click(10, 10) // the page margin around the shape
        let o = try XCTUnwrap(model.template.outlines[0])
        assertReference(o)
        XCTAssertEqual(undo.undoActionName, "Detect Outline")
        snapshot("smart-3-detected")
        undo.undo()
        XCTAssertNil(model.template.outlines[0])
        // Clicking inside one of the small grey boxes outlines that box.
        click(170, 286)
        let box = try XCTUnwrap(model.template.outlines[0])
        XCTAssertEqual(box.segments.count, 4)
        XCTAssertEqual(Geometry.boundingBox(box).minX, 160, accuracy: 0.5)
        undo.undo()
        // A threshold that takes in the whole page reports why nothing happened.
        UserDefaults.standard.set(500.0, forKey: TracePrefs.thresholdKey)
        click(400, 120)
        XCTAssertNil(model.template.outlines[0])
        XCTAssertNotNil(overlay.placementHint)
        key(53)
        XCTAssertNil(overlay.placementHint)
    }

    func testSmartOffIsThePlainClickTool() throws {
        UserDefaults.standard.set(false, forKey: TracePrefs.smartKey)
        model.tool = .outline
        click(41.2, 51.2); click(563.4, 48.9); click(811.2, 296.4)
        XCTAssertTrue(overlay.pendingSegments.allSatisfy { !$0.magnetic })
        click(41.2, 51.2)
        let o = try XCTUnwrap(model.template.outlines[0])
        XCTAssertEqual(o.points.prefix(3), [PDFPoint(41, 51), PDFPoint(563, 49), PDFPoint(811, 296)])
        XCTAssertEqual(undo.undoActionName, "Draw Outline")
    }

    func testTraceIgnoresAnExistingCutInTheSavedBytes() throws {
        // Save a small rectangular cut first; the trace must still see the artwork outside it.
        model.editor.setOutline(Outline.rectangle(PDFRect(x: 300, y: 250, width: 100, height: 60)), page: 0, actionName: "Cut")
        _ = try model.saveData(incremental: true)
        model.editor.setOutline(nil, page: 0, actionName: "Remove Cut")
        UserDefaults.standard.set(TracePrefs.Mode.detect.rawValue, forKey: TracePrefs.modeKey)
        model.tool = .outline
        click(10, 10)
        assertReference(try XCTUnwrap(model.template.outlines[0]))
    }

    func testRotatedPageWithOffsetCropBox() throws {
        // /Rotate 90, MediaBox and CropBox away from the origin, a black square at user-space
        // x 300...340, y 200...240 (S6). Detect by clicking it through the rotated view.
        try open(Self.rotatedPDF())
        UserDefaults.standard.set(TracePrefs.Mode.detect.rawValue, forKey: TracePrefs.modeKey)
        model.tool = .outline
        click(320, 220)
        let o = try XCTUnwrap(model.template.outlines[0])
        let bb = Geometry.boundingBox(o)
        XCTAssertEqual(bb.minX, 300, accuracy: 0.5); XCTAssertEqual(bb.maxX, 340, accuracy: 0.5)
        XCTAssertEqual(bb.minY, 200, accuracy: 0.5); XCTAssertEqual(bb.maxY, 240, accuracy: 0.5)
        XCTAssertEqual(o.segments.count, 4)
        snapshot("smart-4-rotated")
    }

    static func rotatedPDF() -> Data {
        let content = "0 0 0 rg 300 200 40 40 re f"
        let objs = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [100 50 700 450] /CropBox [120 60 680 440] /Rotate 90 /Contents 4 0 R /Resources << >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        ]
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

    /// Detect on page 1 of the example template (Tests/Fixtures/example_voucher_template.pdf)
    /// and snapshot. $VE_TEMPLATE_PDF points the test at a copy of your own template instead
    /// (never the original); the shape assertions are then skipped, the clicks are as on the example.
    func testExampleTemplateSnapshot() throws {
        let custom = ProcessInfo.processInfo.environment["VE_TEMPLATE_PDF"]
        let path = custom ?? AppTests.fixtures.appendingPathComponent("example_voucher_template.pdf").path
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path), "no template at \(path)")
        try open(data)
        pdfView.scaleFactor = 1.1
        pdfView.layoutDocumentView()
        UserDefaults.standard.set(TracePrefs.Mode.detect.rawValue, forKey: TracePrefs.modeKey)
        model.tool = .outline
        click(12, 580)
        let o = try XCTUnwrap(model.template.outlines[0])
        XCTAssertEqual(Geometry.validate(o), [])
        if custom == nil {
            XCTAssertEqual(o.counts.lines, 11)
            XCTAssertEqual(o.counts.arcs, 1)
            XCTAssertEqual(o.counts.curves, 0)
        }
        print("EXAMPLE canvas detect: \(o.counts)")
        snapshot("smart-5-example-detect")
        undo.undo()
        XCTAssertNil(model.template.outlines[0])
        UserDefaults.standard.set(TracePrefs.Mode.points.rawValue, forKey: TracePrefs.modeKey)
        click(151, 525); click(589, 525)
        move(815, 330)
        XCTAssertNotNil(overlay.hoverTrace)
        snapshot("smart-6-example-live")
    }
}

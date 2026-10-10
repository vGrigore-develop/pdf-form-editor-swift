import XCTest
import AppKit
import PDFKit
@testable import VoucherEditorApp
import VoucherModel
import VoucherGeometry
import MuPDFEngine
import UniformTypeIdentifiers

/// Drives the real canvas overlay with synthesized mouse and key events in an
/// off-screen window, and checks the document-level save pipeline (baseline/ids
/// across saves, undo after save). This is the closest to clicking in the app
/// that runs headless.
@MainActor
final class AppTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    var window: NSWindow!
    var pdfView: PDFView!
    var overlay: OverlayView!
    var model: DocumentModel!
    var undo: UndoManager!

    override func setUp() async throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("synthetic_voucher.pdf"))
        UserDefaults.standard.set(false, forKey: TracePrefs.smartKey) // plain click-to-place outline; SmartOutlineTests covers smart
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

    override func tearDown() async throws {
        for k in [SnapPrefs.enabledKey, SnapPrefs.gridKey, SnapPrefs.showGridKey] + TracePrefs.allKeys { UserDefaults.standard.removeObject(forKey: k) }
    }

    // MARK: Event helpers

    func viewPoint(_ x: Double, _ y: Double) -> NSPoint {
        let page = pdfView.document!.page(at: 0)!
        return overlay.convert(pdfView.convert(NSPoint(x: x, y: y), from: page), from: pdfView)
    }

    func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double, mods: NSEvent.ModifierFlags = []) -> NSEvent {
        let v = viewPoint(x, y)
        let w = overlay.convert(v, to: nil)
        return NSEvent.mouseEvent(with: type, location: w, modifierFlags: mods, timestamp: 0, windowNumber: window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func drag(from a: (Double, Double), to b: (Double, Double), mods: NSEvent.ModifierFlags = []) {
        overlay.mouseDown(with: mouse(.leftMouseDown, a.0, a.1, mods: mods))
        for i in 1...5 {
            let t = Double(i) / 5
            overlay.mouseDragged(with: mouse(.leftMouseDragged, a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, mods: mods))
        }
        overlay.mouseUp(with: mouse(.leftMouseUp, b.0, b.1, mods: mods))
    }

    func key(_ code: UInt16, _ chars: String = "", mods: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: window.windowNumber,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        overlay.keyDown(with: e)
    }

    // MARK: Tests

    func testCoordinateRoundTrip() {
        // A page point converted to the view and back lands within 0.5 pt (SPEC 7.5 at 100 %).
        let v = viewPoint(422, 377)
        let page = pdfView.document!.page(at: 0)!
        let back = pdfView.convert(overlay.convert(v, to: pdfView), to: page)
        XCTAssertEqual(back.x, 422, accuracy: 0.5)
        XCTAssertEqual(back.y, 377, accuracy: 0.5)
    }

    func testDrawTextFieldMoveResizeNudgeDeleteUndo() throws {
        // Draw
        model.tool = .text
        drag(from: (500, 100), to: (640, 130))
        XCTAssertEqual(model.template.fields.count, 1)
        var f = try XCTUnwrap(model.template.fields.first)
        XCTAssertEqual(f.kind, .text)
        XCTAssertEqual(f.name, "text_1")
        XCTAssertEqual(f.rect.x, 500, accuracy: 1)
        XCTAssertEqual(f.rect.y, 100, accuracy: 1)
        XCTAssertEqual(f.rect.width, 140, accuracy: 1)
        XCTAssertEqual(f.rect.height, 30, accuracy: 1)
        XCTAssertEqual(model.tool, .select, "tool reverts to Select")
        XCTAssertEqual(model.editor.selection, f.id)

        // Move by dragging the body: one undo step for the whole drag.
        drag(from: (520, 110), to: (560, 150))
        f = model.template.fields[0]
        XCTAssertEqual(f.rect.x, 540, accuracy: 1)
        XCTAssertEqual(f.rect.y, 140, accuracy: 1)

        // Resize with the top-right handle (handle 4).
        let tr = RectHandle.point(f.rect, 4)
        drag(from: (tr.x, tr.y), to: (tr.x + 60, tr.y + 10))
        f = model.template.fields[0]
        XCTAssertEqual(f.rect.width, 200, accuracy: 1)
        XCTAssertEqual(f.rect.height, 40, accuracy: 1)
        XCTAssertEqual(f.rect.x, 540, accuracy: 1, "opposite corner anchored")

        // Nudge: right arrow 1 pt, Shift-up 10 pt.
        key(124)
        key(126, mods: .shift)
        f = model.template.fields[0]
        XCTAssertEqual(f.rect.x, 541, accuracy: 0.01)
        XCTAssertEqual(f.rect.y, 150, accuracy: 0.01)

        // Undo the nudges, the resize and the move, step by step.
        undo.undo() // nudges coalesce
        XCTAssertEqual(model.template.fields[0].rect.x, 540, accuracy: 0.01)
        undo.undo() // resize
        XCTAssertEqual(model.template.fields[0].rect.width, 140, accuracy: 1)
        undo.undo() // move
        XCTAssertEqual(model.template.fields[0].rect.x, 500, accuracy: 1)
        undo.redo()
        XCTAssertEqual(model.template.fields[0].rect.x, 540, accuracy: 1)

        // Delete key removes the selected field; undo brings it back.
        key(51)
        XCTAssertTrue(model.template.fields.isEmpty)
        undo.undo()
        XCTAssertEqual(model.template.fields.count, 1)
    }

    func testClickCreatesDefaultImageFieldAndOptionDragDuplicates() throws {
        model.tool = .image
        overlay.mouseDown(with: mouse(.leftMouseDown, 200, 400))
        overlay.mouseUp(with: mouse(.leftMouseUp, 200, 400))
        let f = try XCTUnwrap(model.template.fields.first)
        XCTAssertEqual(f.kind, .image)
        XCTAssertEqual(f.rect.width, 120)
        XCTAssertEqual(f.rect.height, 90)
        XCTAssertTrue(f.image.importAction)
        // Option-drag duplicates in place and moves the copy.
        drag(from: (230, 360), to: (330, 360), mods: .option)
        XCTAssertEqual(model.template.fields.count, 2)
        XCTAssertEqual(Set(model.template.fields.map(\.name)), ["image_1", "image_1_2"])
        let dup = model.template.fields[1]
        XCTAssertEqual(dup.rect.x - f.rect.x, 100, accuracy: 1)
    }

    /// Two text fields: A (the target) and B (to be moved or resized), returns their ids.
    func makeTwoFields() throws -> (UUID, UUID) {
        UserDefaults.standard.set(true, forKey: SnapPrefs.enabledKey)
        UserDefaults.standard.set(1.0, forKey: SnapPrefs.gridKey)
        model.tool = .text
        drag(from: (300, 400), to: (400, 430))   // A: x 300...400, y 400...430
        let a = try XCTUnwrap(model.editor.selection)
        model.tool = .text
        drag(from: (100, 100), to: (180, 130))   // B: x 100...180, y 100...130
        let b = try XCTUnwrap(model.editor.selection)
        XCTAssertNotEqual(a, b)
        return (a, b)
    }

    func testMoveSnapsToOtherFieldEdgeWithGuideAndOneUndoStep() throws {
        let (a, b) = try makeTwoFields()
        let undoDepthBefore = model.template
        // Grab B at its centre-left (120,115) and drag so its left edge lands 3 pt short of A's left edge (300).
        overlay.mouseDown(with: mouse(.leftMouseDown, 120, 115))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 200, 200))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 317, 211.4))   // left edge -> 297, bottom -> 196.4
        var f = try XCTUnwrap(model.template.field(b))
        XCTAssertEqual(f.rect.minX, 300, accuracy: 0.001, "left edge snapped to A's left edge")
        XCTAssertEqual(f.rect.minY, 196, accuracy: 0.001, "y falls back to the 1 pt grid")
        let g = try XCTUnwrap(overlay.guides)
        XCTAssertEqual(g.lines.count, 1)
        XCTAssertEqual(g.lines[0].axis, .x)
        XCTAssertEqual(g.lines[0].position, 300, accuracy: 0.001)
        XCTAssertEqual(g.lines[0].from, 196, accuracy: 0.001)
        XCTAssertEqual(g.lines[0].to, 430, accuracy: 0.001, "spans from the moving field to A")
        if let dir = ProcessInfo.processInfo.environment["VE_SNAPSHOT_DIR"] {
            // Optional visual check: the guide line mid-drag, with the grid overlay on.
            UserDefaults.standard.set(true, forKey: SnapPrefs.showGridKey)
            UserDefaults.standard.set(10.0, forKey: SnapPrefs.gridKey)
            overlay.needsDisplay = true
            if let rep = pdfView.bitmapImageRepForCachingDisplay(in: pdfView.bounds) {
                pdfView.cacheDisplay(in: pdfView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("snap-guide.png"))
            }
            UserDefaults.standard.set(1.0, forKey: SnapPrefs.gridKey)
        }
        overlay.mouseUp(with: mouse(.leftMouseUp, 317, 211.4))
        XCTAssertNil(overlay.guides, "guides clear on mouse-up")
        f = try XCTUnwrap(model.template.field(b))
        XCTAssertEqual(f.rect.minX, 300, accuracy: 0.001)
        XCTAssertNotEqual(a, b)
        undo.undo()   // the whole drag is one step
        XCTAssertEqual(model.template.field(b)?.rect, undoDepthBefore.field(b)?.rect)
    }

    func testMoveSnapsMiddleToMiddleAndCmdDisablesSnapping() throws {
        let (_, b) = try makeTwoFields()
        // A's centre y = 415; B is 30 tall so its centre is 15 above its bottom. Drop B's centre ~2 pt off.
        overlay.mouseDown(with: mouse(.leftMouseDown, 120, 115))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 220, 302)) // B.y = 287...317 -> centre 302 (no target near)
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 220, 417.0)) // B.y = 402 -> centre 417, A centre 415
        XCTAssertEqual(model.template.field(b)?.rect.midY ?? 0, 415, accuracy: 0.001, "centre snapped to A's centre")
        XCTAssertEqual(overlay.guides?.lines.contains { $0.axis == .y }, true, "a horizontal guide is shown")
        overlay.mouseUp(with: mouse(.leftMouseUp, 220, 417))

        // With Cmd held there is no snapping and no guide.
        overlay.mouseDown(with: mouse(.leftMouseDown, 220, 415, mods: .command))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 220, 417, mods: .command))
        XCTAssertNil(overlay.guides)
        XCTAssertEqual(model.template.field(b)?.rect.midY ?? 0, 417, accuracy: 0.001)
        overlay.mouseUp(with: mouse(.leftMouseUp, 220, 417, mods: .command))
    }

    func testSnapToggleOffAndGridSize() throws {
        let (_, b) = try makeTwoFields()
        UserDefaults.standard.set(false, forKey: SnapPrefs.enabledKey)
        overlay.mouseDown(with: mouse(.leftMouseDown, 120, 115))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 137, 115)) // B.x = 117 ... not near anything; stays plain
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 317, 115)) // left edge 297, would snap to 300 if enabled
        XCTAssertEqual(model.template.field(b)?.rect.minX ?? 0, 297, accuracy: 0.001)
        XCTAssertNil(overlay.guides)
        overlay.mouseUp(with: mouse(.leftMouseUp, 317, 115))

        UserDefaults.standard.set(true, forKey: SnapPrefs.enabledKey)
        UserDefaults.standard.set(10.0, forKey: SnapPrefs.gridKey)
        overlay.mouseDown(with: mouse(.leftMouseDown, 320, 115))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 223, 118)) // left edge 200, bottom 103 -> grid 10 gives 100
        let r = try XCTUnwrap(model.template.field(b)?.rect)
        XCTAssertEqual(r.minX.truncatingRemainder(dividingBy: 10), 0, accuracy: 0.001)
        XCTAssertEqual(r.minY.truncatingRemainder(dividingBy: 10), 0, accuracy: 0.001)
        overlay.mouseUp(with: mouse(.leftMouseUp, 223, 118))
    }

    func testResizeSnapsDraggedEdgeToOtherField() throws {
        let (_, b) = try makeTwoFields()
        let tr = RectHandle.point(model.template.field(b)!.rect, 4) // (180,130)
        overlay.mouseDown(with: mouse(.leftMouseDown, tr.x, tr.y))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 250, 200))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 297.4, 398.2)) // x -> A.minX 300, y -> A.minY 400
        let r = try XCTUnwrap(model.template.field(b)?.rect)
        XCTAssertEqual(r.maxX, 300, accuracy: 0.001)
        XCTAssertEqual(r.maxY, 400, accuracy: 0.001)
        XCTAssertEqual(r.minX, 100, accuracy: 0.001, "opposite corner stays")
        XCTAssertEqual(overlay.guides?.lines.count, 2)
        overlay.mouseUp(with: mouse(.leftMouseUp, 297.4, 398.2))
        XCTAssertNil(overlay.guides)
        undo.undo()
        XCTAssertEqual(model.template.field(b)?.rect.width ?? 0, 80, accuracy: 0.001, "one undo step for the resize")
    }

    func testMoveSnapsToPageCentreAndEdgeAtOtherZoom() throws {
        let (_, b) = try makeTwoFields()
        pdfView.scaleFactor = 2   // threshold is 3 pt now
        pdfView.layoutDocumentView()
        let box = model.pageBounds(0)
        let cx = box.midX
        overlay.mouseDown(with: mouse(.leftMouseDown, 140, 115))   // B centre x = 140
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 200, 115))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, cx - 2, 115))
        XCTAssertEqual(model.template.field(b)?.rect.midX ?? 0, cx, accuracy: 0.001, "2 pt away snaps at 200 %")
        overlay.mouseDragged(with: mouse(.leftMouseDragged, cx - 5, 115))
        XCTAssertEqual(model.template.field(b)?.rect.midX ?? 0, cx - 5, accuracy: 0.001, "5 pt away is outside 6 px at 200 %")
        overlay.mouseUp(with: mouse(.leftMouseUp, cx - 5, 115))
    }

    func testArrowNudgeIgnoresSnapping() throws {
        let (_, b) = try makeTwoFields()
        model.editor.selection = b
        model.editor.updateField(b, "Place") { $0.rect = PDFRect(x: 298.5, y: 100, width: 80, height: 30) }
        key(124) // right 1 pt: would be 299.5, 0.5 from A's edge; the nudge must not snap
        XCTAssertEqual(model.template.field(b)?.rect.minX ?? 0, 299.5, accuracy: 0.001)
    }

    func testToolKeys() {
        key(0, "t"); XCTAssertEqual(model.tool, .text)
        key(0, "i"); XCTAssertEqual(model.tool, .image)
        key(0, "o"); XCTAssertEqual(model.tool, .outline)
        key(0, "v"); XCTAssertEqual(model.tool, .select)
    }

    func testDrawOutlineByClicksAndKeepInside() throws {
        model.tool = .outline
        for (x, y) in [(50.0, 50.0), (790, 50), (790, 545), (50, 545)] {
            overlay.mouseDown(with: mouse(.leftMouseDown, x, y)); overlay.mouseUp(with: mouse(.leftMouseUp, x, y))
        }
        // Clicking the first point closes the path.
        overlay.mouseDown(with: mouse(.leftMouseDown, 50, 50)); overlay.mouseUp(with: mouse(.leftMouseUp, 50, 50))
        let o = try XCTUnwrap(model.template.outlines[0])
        XCTAssertEqual(o.segments.count, 4)
        XCTAssertEqual(Geometry.validate(o), [])

        // Drag a vertex; snapping keeps it on the grid.
        overlay.mouseDown(with: mouse(.leftMouseDown, 790, 545))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 800.4, 555.2))
        overlay.mouseUp(with: mouse(.leftMouseUp, 800.4, 555.2))
        XCTAssertEqual(model.template.outlines[0]?.points[2], PDFPoint(800, 555))

        // A field inside the outline cannot be dragged out of it (keep inside, default on).
        model.tool = .text
        drag(from: (100, 100), to: (200, 130))
        let id = try XCTUnwrap(model.editor.selection)
        drag(from: (150, 115), to: (60, 115)) // would cross the left edge at x = 50
        XCTAssertGreaterThanOrEqual(model.template.field(id)!.rect.minX, 50, "stops at the last position inside the outline")
        XCTAssertEqual(Geometry.containment(of: model.template.field(id)!.rect, in: model.template.outlines[0]!), .inside)
    }

    // MARK: Cancelling in-progress gestures

    func click(_ x: Double, _ y: Double, mods: NSEvent.ModifierFlags = []) {
        overlay.mouseDown(with: mouse(.leftMouseDown, x, y, mods: mods)); overlay.mouseUp(with: mouse(.leftMouseUp, x, y, mods: mods))
    }

    func placeThreePoints() {
        model.tool = .outline
        click(50, 50); click(790, 50); click(790, 545)
    }

    func testEscapeCancelsPendingOutline() {
        placeThreePoints()
        XCTAssertNotNil(overlay.placementHint)
        XCTAssertTrue(overlay.isInProgress)
        overlay.mouseMoved(with: mouse(.mouseMoved, 400, 300))
        key(53)
        XCTAssertFalse(overlay.isInProgress)
        XCTAssertNil(overlay.placementHint)
        XCTAssertEqual(model.tool, .outline, "Outline tool stays armed")
        XCTAssertNil(model.template.outlines[0])
        // The next click starts a fresh outline, and Return with fewer than 3 points draws nothing.
        click(100, 100)
        XCTAssertTrue(overlay.isInProgress)
        key(36)
        XCTAssertNil(model.template.outlines[0])
    }

    func testRightClickAndCtrlClickCancelPendingOutline() {
        placeThreePoints()
        overlay.rightMouseDown(with: mouse(.rightMouseDown, 300, 300))
        XCTAssertFalse(overlay.isInProgress)
        placeThreePoints()
        overlay.mouseDown(with: mouse(.leftMouseDown, 300, 300, mods: .control))
        overlay.mouseUp(with: mouse(.leftMouseUp, 300, 300, mods: .control))
        XCTAssertFalse(overlay.isInProgress)
        XCTAssertNil(model.template.outlines[0])
    }

    func testDeleteRemovesOnlyLastPendingPointThenOutlineCloses() throws {
        model.tool = .outline
        click(50, 50); click(790, 50); click(790, 545); click(50, 545)
        key(51)
        XCTAssertTrue(overlay.isInProgress)
        XCTAssertEqual(overlay.placementHint?.contains("first point"), true)
        click(50, 545) // re-place the removed fourth point
        click(50, 50)  // close
        let o = try XCTUnwrap(model.template.outlines[0])
        XCTAssertEqual(o.segments.count, 4, "the removed point was really removed and re-added")
    }

    func testDeleteAllPendingPointsLeavesNothing() {
        model.tool = .outline
        click(50, 50); click(790, 50)
        key(51); key(51)
        XCTAssertFalse(overlay.isInProgress)
        key(51) // nothing pending, nothing selected: harmless
    }

    func testUndoActionRemovesLastPendingPoint() {
        placeThreePoints()
        overlay.undo(nil)
        XCTAssertTrue(overlay.isInProgress)
        overlay.undo(nil); overlay.undo(nil)
        XCTAssertFalse(overlay.isInProgress)
    }

    func testEscapeCancelsFieldDrawDrag() {
        model.tool = .text
        overlay.mouseDown(with: mouse(.leftMouseDown, 100, 100))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 200, 130))
        XCTAssertTrue(overlay.isInProgress)
        key(53)
        XCTAssertFalse(overlay.isInProgress)
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 250, 150))
        overlay.mouseUp(with: mouse(.leftMouseUp, 250, 150))
        XCTAssertEqual(model.template.fields.count, 0 + initialFieldCount, "no field created by the cancelled drag")
        XCTAssertEqual(model.tool, .text)
    }

    var initialFieldCount: Int { try! DocumentModel(data: Data(contentsOf: Self.fixtures.appendingPathComponent("synthetic_voucher.pdf")), undoManager: nil).template.fields.count }

    func testEscapeCancelsMoveAndResizeWithoutUndoStep() throws {
        model.tool = .text
        drag(from: (100, 100), to: (200, 130))
        let id = try XCTUnwrap(model.editor.selection)
        let original = try XCTUnwrap(model.template.field(id)).rect
        model.tool = .select
        undo.removeAllActions()

        overlay.mouseDown(with: mouse(.leftMouseDown, 150, 115))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 250, 215))
        XCTAssertNotEqual(model.template.field(id)?.rect, original)
        key(53)
        XCTAssertEqual(model.template.field(id)?.rect, original)
        XCTAssertNil(overlay.guides)
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 300, 300))
        overlay.mouseUp(with: mouse(.leftMouseUp, 300, 300))
        XCTAssertEqual(model.template.field(id)?.rect, original)
        XCTAssertFalse(undo.canUndo, "a cancelled move records no undo step")

        // Resize by the bottom-right handle.
        overlay.mouseDown(with: mouse(.leftMouseDown, original.maxX, original.minY))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, original.maxX + 60, original.minY - 40))
        XCTAssertNotEqual(model.template.field(id)?.rect, original)
        key(53)
        XCTAssertEqual(model.template.field(id)?.rect, original)
        overlay.mouseUp(with: mouse(.leftMouseUp, original.maxX + 60, original.minY - 40))
        XCTAssertFalse(undo.canUndo)
    }

    func testEscapeWithNothingInProgressOnlyDeselects() throws {
        model.tool = .text
        drag(from: (100, 100), to: (200, 130))
        XCTAssertNotNil(model.editor.selection)
        let before = model.template
        key(53)
        XCTAssertNil(model.editor.selection)
        XCTAssertEqual(model.template, before)
        key(53) // again: no crash, no effect
    }

    func testToolSwitchPreviewAndRemovalCancelPendingOutline() {
        placeThreePoints()
        model.tool = .select
        XCTAssertFalse(overlay.isInProgress)

        placeThreePoints()
        model.isPreview = true
        XCTAssertFalse(overlay.isInProgress)
        model.isPreview = false

        placeThreePoints()
        overlay.isHidden = true
        XCTAssertFalse(overlay.isInProgress)
        overlay.isHidden = false

        placeThreePoints()
        overlay.removeFromSuperview() // document closed
        XCTAssertFalse(overlay.isInProgress)
        overlay.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                               context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!)
    }

    func testToolSwitchDuringFieldDrawDoesNotCreateField() {
        model.tool = .text
        overlay.mouseDown(with: mouse(.leftMouseDown, 100, 100))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, 200, 130))
        let n = model.template.fields.count
        model.tool = .select
        overlay.mouseUp(with: mouse(.leftMouseUp, 200, 130))
        XCTAssertEqual(model.template.fields.count, n)
    }

    func testSaveUndoSaveThroughDocumentModel() throws {
        model.tool = .text
        drag(from: (500, 100), to: (640, 130))
        model.editor.updateField(model.template.fields[0].id, "Rename") { $0.name = "recipient_name" }
        let first = try model.saveData(incremental: true)
        XCTAssertEqual(try MuPDFEngine(data: first).readTemplate().template.fields.map(\.name), ["recipient_name"])
        XCTAssertFalse(model.hasUnsavedModelChanges)

        // Saving does not clear undo: undo the rename, save again -> renamed back in the file.
        undo.undo()
        XCTAssertEqual(model.template.fields[0].name, "text_1")
        let issues = model.runChecks()
        XCTAssertTrue(issues.contains { $0.message.contains("Renamed \"recipient_name\" to \"text_1\"") })
        let second = try model.saveData(incremental: true)
        XCTAssertEqual(second.prefix(first.count), first)
        XCTAssertEqual(try MuPDFEngine(data: second).readTemplate().template.fields.map(\.name), ["text_1"])

        // Undo the creation too: the next save deletes it from the file.
        undo.undo()
        XCTAssertTrue(model.template.fields.isEmpty)
        let third = try model.saveData(incremental: true)
        XCTAssertTrue(try MuPDFEngine(data: third).readTemplate().template.fields.isEmpty)
    }

    func testPreviewBuildsWithoutCommitting() throws {
        model.tool = .text
        drag(from: (500, 100), to: (640, 130))
        model.isPreview = true
        let preview = try XCTUnwrap(model.previewData)
        XCTAssertTrue(try MuPDFEngine(data: preview).readTemplate().template.fields.first?.text.defaultValue == "text_1",
                      "preview shows sample text (the field name when no sample is set)")
        XCTAssertTrue(model.hasUnsavedModelChanges, "preview does not save")
        XCTAssertEqual(model.engine.currentData, model.displayData)
    }

    // MARK: Border, background and sample (regression: "invisible on my voucher")

    /// The colour of a page point in the overlay's own drawing (Edit mode canvas).
    func overlayColor(_ x: Double, _ y: Double) throws -> NSColor {
        overlay.layoutSubtreeIfNeeded()
        // Render into an sRGB bitmap so the colours compare without colour management shifts.
        let cached = try XCTUnwrap(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        let rep = try XCTUnwrap(cached.retagging(with: .sRGB))
        overlay.cacheDisplay(in: overlay.bounds, to: rep)
        if let d = ProcessInfo.processInfo.environment["VE_SNAPSHOT_TEST_DIR"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: d).appendingPathComponent("overlay-box.png"))
        }
        let v = viewPoint(x, y)
        let k = CGFloat(rep.pixelsWide) / overlay.bounds.width
        let py = overlay.isFlipped ? v.y : overlay.bounds.height - v.y
        return try XCTUnwrap(rep.colorAt(x: Int(v.x * k), y: Int(py * k))?.usingColorSpace(.sRGB))
    }

    /// The colour PDFKit draws at a page point (annotations visible), on white.
    static func pdfKitColor(_ data: Data, _ x: Double, _ y: Double) throws -> NSColor {
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let b = page.bounds(for: .mediaBox)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let ctx = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        ctx.cgContext.setFillColor(NSColor.white.cgColor)
        ctx.cgContext.fill(CGRect(x: 0, y: 0, width: b.width, height: b.height))
        page.draw(with: .mediaBox, to: ctx.cgContext)
        ctx.flushGraphics()
        return try XCTUnwrap(rep.colorAt(x: Int(x - b.minX), y: Int(b.height - (y - b.minY)))?.usingColorSpace(.sRGB))
    }

    func assertColor(_ c: NSColor, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let ok = abs(c.redComponent - r) < 0.2 && abs(c.greenComponent - g) < 0.2 && abs(c.blueComponent - b) < 0.2
        XCTAssertTrue(ok, "\(what): got \(c.redComponent), \(c.greenComponent), \(c.blueComponent)", file: file, line: line)
    }

    func boxedFields() -> (UUID, UUID) {
        var t = FieldDef(kind: .text, name: "name", page: 0, rect: PDFRect(x: 500, y: 100, width: 200, height: 40))
        t.text.backgroundColor = VoucherModel.RGBColor(1, 1, 0)
        t.text.borderColor = VoucherModel.RGBColor(1, 0, 0)
        t.text.borderWidth = 6
        var i = FieldDef(kind: .image, name: "photo", page: 0, rect: PDFRect(x: 100, y: 300, width: 200, height: 150))
        i.image.backgroundColor = VoucherModel.RGBColor(0, 1, 0)
        i.image.borderColor = VoucherModel.RGBColor(0, 0, 1)
        i.image.borderWidth = 6
        i.image.label = ""
        model.editor.addField(t, select: false)
        model.editor.addField(i, select: false)
        return (t.id, i.id)
    }

    func testOverlayDrawsFieldBorderAndBackground() throws {
        _ = boxedFields()
        // Before the fix the overlay drew every field as a pale blue/green tint with a thin
        // kind-coloured outline, ignoring the field's own colours.
        assertColor(try overlayColor(600, 120), 1, 1, 0, "text background")
        assertColor(try overlayColor(501.5, 120), 1, 0, 0, "text border (6 pt)")
        assertColor(try overlayColor(200, 375), 0, 1, 0, "image background")
        assertColor(try overlayColor(110, 302.5), 0, 0, 1, "image border (dashed, first dash along the bottom edge)")
    }

    func testSavedEmptyFieldBoxIsVisibleInPDFKit() throws {
        _ = boxedFields()
        let saved = try model.saveData(incremental: true)
        // PDFKit skipped the empty text field's appearance (no /Resources): it stayed white.
        assertColor(try Self.pdfKitColor(saved, 600, 120), 1, 1, 0, "text background in PDFKit")
        assertColor(try Self.pdfKitColor(saved, 501.5, 120), 1, 0, 0, "text border in PDFKit")
        assertColor(try Self.pdfKitColor(saved, 200, 375), 0, 1, 0, "image background in PDFKit")
    }

    func testPreviewShowsSampleTextAndRebuildsOnEdit() throws {
        let (textID, _) = boxedFields()
        model.editor.updateField(textID, "Sample Value") { $0.text.sampleValue = "Ana Maria" }
        model.isPreview = true
        var preview = try XCTUnwrap(model.previewData)
        XCTAssertEqual(try MuPDFEngine(data: preview).readTemplate().template.fields.first { $0.name == "name" }?.text.defaultValue, "Ana Maria")
        assertColor(try Self.pdfKitColor(preview, 690, 120), 1, 1, 0, "background in Preview")

        // An inspector edit while Preview shows rebuilds it (it used to stay stale until
        // Preview was left and re-entered).
        model.editor.updateField(textID, "Background") { $0.text.backgroundColor = VoucherModel.RGBColor(0, 1, 1) }
        let rebuilt = expectation(description: "preview rebuilt")
        DispatchQueue.main.async { rebuilt.fulfill() }
        wait(for: [rebuilt], timeout: 2)
        preview = try XCTUnwrap(model.previewData)
        assertColor(try Self.pdfKitColor(preview, 690, 120), 0, 1, 1, "new background in rebuilt Preview")

        // The sample never reaches the saved file.
        model.isPreview = false
        let saved = try model.saveData(incremental: true)
        XCTAssertEqual(try MuPDFEngine(data: saved).readTemplate().template.fields.first { $0.name == "name" }?.text.defaultValue, "")
    }

    /// Crop fields to outline (S10): the canvas draws a crossing field only inside the shape,
    /// crossing is information rather than a warning, Preview shows the crop, Fit to Outline
    /// shrinks the field inside, and turning cropping off brings the old behaviour back.
    func testCroppedFieldOnCanvasPreviewAndChecks() throws {
        let stepped = Outline(start: PDFPoint(564.5, 545), segments: [
            .line(to: PDFPoint(40, 545)), .line(to: PDFPoint(40, 460)), .line(to: PDFPoint(60, 460)),
            .line(to: PDFPoint(60, 380)), .line(to: PDFPoint(80, 380)), .line(to: PDFPoint(80, 215)),
            .line(to: PDFPoint(60, 215)), .line(to: PDFPoint(60, 135)), .line(to: PDFPoint(40, 135)),
            .line(to: PDFPoint(40, 50)), .line(to: PDFPoint(564.5, 50)),
            .arc(to: PDFPoint(564.5, 545), center: PDFPoint(564.5, 297.5), clockwise: false),
        ])
        model.editor.setOutline(stepped, page: 0, actionName: "Outline")
        var f = FieldDef(kind: .image, name: "photo", page: 0, rect: PDFRect(x: 20, y: 250, width: 180, height: 100))
        f.image.backgroundColor = VoucherModel.RGBColor(0, 1, 0)
        f.image.label = ""
        model.editor.addField(f, select: false)
        XCTAssertTrue(model.template.cropFieldsToOutline)
        XCTAssertTrue(model.isCropped(f))
        XCTAssertFalse(model.fieldWarnings(f).contains { $0.hasPrefix("Partly") })
        let checks = model.runChecks()
        XCTAssertTrue(checks.contains { $0.severity == .info && $0.fieldID == f.id }, "\(checks)")
        XCTAssertFalse(checks.contains { $0.severity == .warning && $0.fieldID == f.id })

        assertColor(try overlayColor(150, 300), 0, 1, 0, "inside the outline: the field's background")
        XCTAssertLessThan(try overlayColor(50, 300).greenComponent, 0.5, "outside: not drawn")

        model.isPreview = true
        let preview = try XCTUnwrap(model.previewData)
        assertColor(try Self.pdfKitColor(preview, 150, 300), 0, 1, 0, "Preview inside")
        assertColor(try Self.pdfKitColor(preview, 50, 300), 1, 1, 1, "Preview outside: blank")
        model.isPreview = false

        let fitted = try XCTUnwrap(model.fittedRect(f))
        XCTAssertEqual(fitted.minX, 80, accuracy: 0.6)
        XCTAssertEqual(Geometry.containment(of: fitted, in: stepped), .inside)

        model.editor.perform("Don't Crop Fields") { $0.cropFieldsToOutline = false }
        XCTAssertTrue(model.fieldWarnings(f).contains { $0.hasPrefix("Partly") })
        assertColor(try overlayColor(50, 300), 0, 1, 0, "uncropped: drawn outside too")
        undo.undo()
        XCTAssertTrue(model.template.cropFieldsToOutline, "the setting is one undo step")
    }

    func testPreviewShowsSampleImage() throws {
        let (_, imageID) = boxedFields()
        let png = try BoxSampleImage.write(40, 30)
        defer { try? FileManager.default.removeItem(at: png) }
        model.editor.updateField(imageID, "Sample Image") { $0.image.sampleImagePath = png.path }
        model.isPreview = true
        let preview = try XCTUnwrap(model.previewData)
        // Proportional, always, centred: 40x30 into the 188x138 box inside the 6 pt border.
        assertColor(try Self.pdfKitColor(preview, 200, 375), 1, 0, 1, "sample image in Preview")
        model.isPreview = false
        let saved = try model.saveData(incremental: true)
        assertColor(try Self.pdfKitColor(saved, 200, 375), 0, 1, 0, "saved file shows the placeholder, not the sample")
    }
}

/// NSDocument's real save path: read from a file, edit, save to disk, check the bytes.
@MainActor
final class DocumentSaveTests: XCTestCase {
    func testNSDocumentSaveWritesIncrementalUpdate() throws {
        let src = AppTests.fixtures.appendingPathComponent("synthetic_voucher.pdf")
        let original = try Data(contentsOf: src)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("voucher.pdf")
        try original.write(to: url)

        let doc = try VoucherDocument(contentsOf: url, ofType: VoucherDocument.pdfType)
        let model = try XCTUnwrap(doc.model)
        var f = model.newField(kind: .text, rect: PDFRect(x: 422, y: 377, width: 356, height: 36), page: 0)
        f.name = "recipient_name"
        model.editor.addField(f)

        let done = expectation(description: "saved")
        doc.save(to: url, ofType: VoucherDocument.pdfType, for: .saveOperation) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let saved = try Data(contentsOf: url)
        XCTAssertGreaterThan(saved.count, original.count)
        XCTAssertEqual(saved.prefix(original.count), original, "the file on disk keeps the original bytes as a prefix")
        XCTAssertEqual(try MuPDFEngine(data: saved).readTemplate().template.fields.map(\.name), ["recipient_name"])
        XCTAssertNil(doc.autosavingFileType)
    }
}

/// The open path: PDF detection, and a PDF URL becoming a VoucherDocument with a window.
@MainActor
final class OpenPathTests: XCTestCase {
    func testIsPDF() {
        let f = AppTests.fixtures
        XCTAssertTrue(OpenPDF.isPDF(f.appendingPathComponent("synthetic_voucher.pdf")))
        XCTAssertFalse(OpenPDF.isPDF(f.appendingPathComponent("NotoSans-Regular.ttf")))
        XCTAssertFalse(OpenPDF.isPDF(URL(string: "https://example.com/a.pdf")!))
    }

    func testDocumentTypeIsPDF() {
        XCTAssertEqual(VoucherDocument.readableTypes, [UTType.pdf.identifier])
        let c = VoucherDocumentController()
        XCTAssertEqual(c.documentClassNames, ["VoucherDocument"])
        XCTAssertEqual(c.displayName(forType: UTType.pdf.identifier), "PDF Document")
    }

    func testOpeningFixtureCreatesDocumentWithWindow() async throws {
        let url = AppTests.fixtures.appendingPathComponent("synthetic_voucher.pdf")
        // The controller's own open path (panel, Open Recent, drops) ends in this: read, then windows.
        let doc = try VoucherDocument(contentsOf: url, ofType: UTType.pdf.identifier)
        doc.makeWindowControllers()
        XCTAssertEqual(doc.windowControllers.count, 1)
        XCTAssertNotNil(doc.model)
        doc.close()
    }
}

/// A solid magenta PNG for the sample-image tests.
enum BoxSampleImage {
    static func write(_ w: Int, _ h: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ve-sample-\(UUID().uuidString).png")
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }
}

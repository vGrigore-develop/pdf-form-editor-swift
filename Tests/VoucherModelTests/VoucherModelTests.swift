import XCTest
@testable import VoucherModel

final class NamingTests: XCTestCase {
    func testProblems() {
        XCTAssertEqual(Naming.problems(for: ""), [.empty])
        XCTAssertEqual(Naming.problems(for: "recipient_name"), [])
        XCTAssertEqual(Naming.problems(for: "a.b"), [.containsDot, .notSnakeCase])
        XCTAssertTrue(Naming.problems(for: "a.b", isNew: false).allSatisfy { !$0.isError })
        XCTAssertTrue(Naming.problems(for: "Has Space").contains(.containsSpace))
        XCTAssertTrue(Naming.problems(for: "nume_ș").contains(.nonASCII))
        XCTAssertEqual(Naming.problems(for: "CamelCase"), [.notSnakeCase])
        XCTAssertEqual(Naming.problems(for: "1abc"), [.notSnakeCase])
    }

    func testUniqueAndDuplicateNames() {
        XCTAssertEqual(Naming.uniqueName(base: "text", existing: []), "text_1")
        XCTAssertEqual(Naming.uniqueName(base: "text", existing: ["text_1", "text_2"]), "text_3")
        XCTAssertEqual(Naming.duplicateName(of: "code", existing: ["code"]), "code_2")
        XCTAssertEqual(Naming.duplicateName(of: "code_2", existing: ["code", "code_2"]), "code_3")
        XCTAssertEqual(Naming.duplicateName(of: "photo_1", existing: ["photo_1"]), "photo_1_2")
    }
}

final class FieldDefTests: XCTestCase {
    func testFlagsAndDA() {
        var f = FieldDef(kind: .text, name: "a", page: 0, rect: PDFRect(x: 0, y: 0, width: 10, height: 10))
        f.required = true
        f.text.multiline = true
        XCTAssertEqual(f.flags, FieldFlags.required | FieldFlags.multiline)
        f.text.color = RGBColor(1, 0.5, 0)
        f.text.fontSize = 11.5
        XCTAssertEqual(f.defaultAppearance, "/Helv 11.5 Tf 1 0.5 0 rg")

        // Unmanaged bits as read survive (e.g. password, bit 14).
        f.origin = FieldOrigin(objectNumber: 5, fullName: "a", rawFlags: FieldFlags.password | FieldFlags.comb)
        f.text.comb = false
        XCTAssertEqual(f.flags & FieldFlags.password, FieldFlags.password)
        XCTAssertEqual(f.flags & FieldFlags.comb, 0)

        var img = FieldDef(kind: .image, name: "p", page: 0, rect: PDFRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(img.flags, FieldFlags.pushButton)
        img.readOnly = true
        XCTAssertEqual(img.flags, FieldFlags.pushButton | FieldFlags.readOnly)
        XCTAssertEqual(img.defaultAppearance, "/Helv 0 Tf 0 0 0 rg")
    }

    func testQualifiedName() {
        var f = FieldDef(kind: .text, name: "leaf", page: 0, rect: PDFRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(f.qualifiedName, "leaf")
        f.origin = FieldOrigin(objectNumber: 1, fullName: "a.b.leaf", isHierarchical: true)
        f.name = "renamed"
        XCTAssertEqual(f.qualifiedName, "a.b.renamed")
    }

    func testRectNormalisationAndClamp() {
        let r = PDFRect(x1: 10, y1: 50, x2: 5, y2: 20)
        XCTAssertEqual(r, PDFRect(x: 5, y: 20, width: 5, height: 30))
        let page = PDFRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(PDFRect(x: 95, y: -5, width: 10, height: 10).clamped(into: page), PDFRect(x: 90, y: 0, width: 10, height: 10))
        XCTAssertEqual(PDFNumber.format(1.23456), "1.2346")
        XCTAssertEqual(PDFNumber.format(-0.00001), "0")
        XCTAssertEqual(PDFNumber.format(12), "12")
    }

    func testDAParse() {
        XCTAssertEqual(DAFormat.parse("/Helv 12 Tf 0 0 1 rg"), .init(fontName: "Helv", size: 12, color: RGBColor(0, 0, 1)))
        XCTAssertEqual(DAFormat.parse("0 g /HeBo 9 Tf")?.fontName, "HeBo")
        XCTAssertEqual(DAFormat.parse("0.5 g /F1 0 Tf")?.color, RGBColor(gray: 0.5))
        XCTAssertNil(DAFormat.parse("0 g"))
        XCTAssertTrue(DAFormat.isValidFontName("NotoSans"))
        XCTAssertFalse(DAFormat.isValidFontName("Noto Sans"))
    }
}

final class OutlineModelTests: XCTestCase {
    func testMoveStartKeepsClosed() {
        var o = Outline.rectangle(PDFRect(x: 0, y: 0, width: 10, height: 10))
        o.moveVertex(0, to: PDFPoint(1, 1))
        XCTAssertEqual(o.start, PDFPoint(1, 1))
        XCTAssertEqual(o.segments.last?.end, PDFPoint(1, 1))
        o.moveVertex(2, to: PDFPoint(12, 12))
        XCTAssertEqual(o.segments[1].end, PDFPoint(12, 12))
    }
}

@MainActor
final class TemplateEditorTests: XCTestCase {
    func makeEditor() -> (TemplateEditor, UndoManager) {
        let um = UndoManager()
        um.groupsByEvent = false
        let t = Template(pages: [PageInfo(mediaBox: PDFRect(x: 0, y: 0, width: 842, height: 595))])
        return (TemplateEditor(template: t, undoManager: um), um)
    }

    /// One user action. The editor opens its own undo group when none is open.
    func step(_ um: UndoManager, _ body: () -> Void) { body() }

    func testAddUndoRedo() {
        let (ed, um) = makeEditor()
        let f = FieldDef(kind: .text, name: "a", page: 0, rect: PDFRect(x: 10, y: 10, width: 50, height: 20))
        step(um) { ed.addField(f) }
        XCTAssertEqual(ed.template.fields.count, 1)
        XCTAssertEqual(ed.selection, f.id)
        um.undo()
        XCTAssertEqual(ed.template.fields.count, 0)
        XCTAssertNil(ed.selection, "selection of a removed field is cleared")
        um.redo()
        XCTAssertEqual(ed.template.fields.count, 1)
    }

    func testGestureCoalescesIntoOneStep() {
        let (ed, um) = makeEditor()
        let f = FieldDef(kind: .text, name: "a", page: 0, rect: PDFRect(x: 10, y: 10, width: 50, height: 20))
        step(um) { ed.addField(f) }
        step(um) {
            ed.beginGesture()
            for i in 1...20 {
                ed.updateDuringGesture { $0.fields[0].rect.x = 10 + Double(i) }
            }
            ed.endGesture("Move")
        }
        XCTAssertEqual(ed.template.fields[0].rect.x, 30)
        um.undo()
        XCTAssertEqual(ed.template.fields[0].rect.x, 10, "a whole drag undoes in one step")
        um.undo()
        XCTAssertTrue(ed.template.fields.isEmpty)
    }

    func testTypingCoalesces() {
        let (ed, um) = makeEditor()
        let f = FieldDef(kind: .text, name: "a", page: 0, rect: PDFRect(x: 10, y: 10, width: 50, height: 20))
        step(um) { ed.addField(f) }
        for n in ["ab", "abc", "abcd"] {
            step(um) { ed.updateField(f.id, "Rename", coalesceKey: "name") { $0.name = n } }
        }
        XCTAssertEqual(ed.template.fields[0].name, "abcd")
        um.undo()
        XCTAssertEqual(ed.template.fields[0].name, "a")
        // A different command breaks coalescing.
        step(um) { ed.updateField(f.id, "Rename", coalesceKey: "name") { $0.name = "x" } }
        step(um) { ed.updateField(f.id, "Size", coalesceKey: "size") { $0.text.fontSize = 20 } }
        step(um) { ed.updateField(f.id, "Rename", coalesceKey: "name") { $0.name = "y" } }
        um.undo()
        XCTAssertEqual(ed.template.fields[0].name, "x")
    }

    func testDeleteAndDuplicate() {
        let (ed, um) = makeEditor()
        let f = FieldDef(kind: .image, name: "photo", page: 0, rect: PDFRect(x: 835, y: 10, width: 5, height: 20))
        step(um) { ed.addField(f) }
        var dupID: UUID?
        step(um) { dupID = ed.duplicateField(f.id) }
        let dup = ed.template.field(dupID!)!
        XCTAssertEqual(dup.name, "photo_2")
        XCTAssertNil(dup.origin)
        XCTAssertLessThanOrEqual(dup.rect.maxX, 842, "duplicate is clamped into the page")
        step(um) { ed.deleteField(f.id) }
        XCTAssertEqual(ed.template.fields.map(\.name), ["photo_2"])
        um.undo()
        XCTAssertEqual(ed.template.fields.count, 2)
    }

    func testReadOnlyFieldsCannotBeDeleted() {
        let (ed, um) = makeEditor()
        var f = FieldDef(kind: .other, name: "sig", page: 0, rect: PDFRect(x: 0, y: 0, width: 5, height: 5))
        f.origin = FieldOrigin(objectNumber: 3, fullName: "sig", editable: false)
        step(um) { ed.addField(f) }
        ed.deleteField(f.id)
        XCTAssertEqual(ed.template.fields.count, 1)
    }
}

final class SaveChecksTests: XCTestCase {
    let page = PageInfo(mediaBox: PDFRect(x: 0, y: 0, width: 842, height: 595))

    func field(_ name: String, _ rect: PDFRect = PDFRect(x: 10, y: 10, width: 100, height: 20), page: Int = 0) -> FieldDef {
        FieldDef(kind: .text, name: name, page: page, rect: rect)
    }

    func errors(_ t: Template, _ names: [UUID: String] = [:]) -> [String] {
        SaveChecks.run(template: t, baselineNames: names).filter { $0.severity == .error }.map(\.message)
    }

    func warnings(_ t: Template, _ names: [UUID: String] = [:]) -> [String] {
        SaveChecks.run(template: t, baselineNames: names).filter { $0.severity == .warning }.map(\.message)
    }

    func testCleanTemplateHasNoIssues() {
        let t = Template(pages: [page], fields: [field("a"), field("b", PDFRect(x: 10, y: 100, width: 100, height: 20))])
        XCTAssertEqual(SaveChecks.run(template: t), [])
    }

    func testErrors() {
        var t = Template(pages: [page, page])
        t.fields = [field(""), field("dup", PDFRect(x: 10, y: 100, width: 10, height: 10)), field("dup", PDFRect(x: 10, y: 200, width: 10, height: 10)),
                    field("zero", PDFRect(x: 300, y: 300, width: 0, height: 10)), field("outside", PDFRect(x: 830, y: 300, width: 50, height: 10)),
                    field("new.dotted", PDFRect(x: 400, y: 400, width: 10, height: 10))]
        var comb = field("comb", PDFRect(x: 500, y: 500, width: 10, height: 10))
        comb.text.comb = true
        comb.text.multiline = true
        t.fields.append(comb)
        var multi = field("multi", PDFRect(x: 600, y: 500, width: 10, height: 10))
        multi.origin = FieldOrigin(objectNumber: 9, fullName: "multi", widgetCount: 2, editable: false, inPageAnnots: false, hasPageRef: false, inAcroFormFields: false)
        t.fields.append(multi)
        let e = errors(t)
        XCTAssertTrue(e.contains { $0.contains("empty name") })
        XCTAssertTrue(e.contains { $0.contains("Duplicate field name \"dup\"") })
        XCTAssertTrue(e.contains { $0.contains("zero or negative") })
        XCTAssertTrue(e.contains { $0.contains("\"outside\": /Rect is outside the page") })
        XCTAssertTrue(e.contains { $0.contains("dots") })
        XCTAssertTrue(e.contains { $0.contains("comb requires a max length") })
        XCTAssertTrue(e.contains { $0.contains("comb cannot be combined") })
        XCTAssertTrue(e.contains { $0.contains("2 widgets") })
        XCTAssertTrue(e.contains { $0.contains("not in its page's /Annots") })
        XCTAssertTrue(e.contains { $0.contains("no /P") })
        XCTAssertTrue(e.contains { $0.contains("missing from /AcroForm /Fields") })
    }

    func testWarnings() {
        var t = Template(pages: [page, PageInfo(mediaBox: PDFRect(x: 0, y: 0, width: 842, height: 595), rotation: 90)])
        var auto = field("auto")
        auto.text.fontSize = 0
        var withValue = field("value", PDFRect(x: 10, y: 100, width: 100, height: 20))
        withValue.text.defaultValue = "x"
        let p2 = field("on_page_two", page: 1)
        let caseA = field("Code", PDFRect(x: 10, y: 200, width: 10, height: 10))
        let caseB = field("code", PDFRect(x: 10, y: 300, width: 10, height: 10))
        let overlapA = field("ov_a", PDFRect(x: 400, y: 400, width: 50, height: 50))
        let overlapB = field("ov_b", PDFRect(x: 420, y: 420, width: 50, height: 50))
        t.fields = [auto, withValue, p2, caseA, caseB, overlapA, overlapB]
        let w = warnings(t, [auto.id: "old_auto"])
        XCTAssertTrue(w.contains { $0.contains("auto font size") })
        XCTAssertTrue(w.contains { $0.contains("has a value") })
        XCTAssertTrue(w.contains { $0.contains("on page 2") })
        XCTAssertTrue(w.contains { $0.contains("rotated page") })
        XCTAssertTrue(w.contains { $0.contains("differ only in case") })
        XCTAssertTrue(w.contains { $0.contains("overlap") })
        XCTAssertTrue(w.contains { $0.contains("Renamed \"old_auto\" to \"auto\"") })
        XCTAssertTrue(errors(t).isEmpty, "\(errors(t))")
    }

    func testOutlineContainmentWarning() {
        var t = Template(pages: [page], fields: [field("a")])
        t.outlines[0] = Outline.rectangle(PDFRect(x: 50, y: 0, width: 100, height: 100))
        t.cropFieldsToOutline = false
        let w = SaveChecks.run(template: t, containment: { _, _ in .partial })
        XCTAssertTrue(w.contains { $0.severity == .warning && $0.message.contains("partly outside the outline") })
        XCTAssertFalse(t.isCropped(t.fields[0]) { _, _ in .partial })
    }

    /// Cropped to the outline (S10): crossing is information, not a warning; fully outside
    /// stays a warning (the field would be invisible). Info never opens the save sheet.
    func testCroppedFieldCrossingIsInformation() {
        var t = Template(pages: [page], fields: [field("a")])
        t.outlines[0] = Outline.rectangle(PDFRect(x: 50, y: 0, width: 100, height: 100))
        XCTAssertTrue(t.cropFieldsToOutline, "on by default")
        let partial = SaveChecks.run(template: t, containment: { _, _ in .partial })
        XCTAssertTrue(partial.contains { $0.severity == .info && $0.message.contains("cropped") }, "\(partial)")
        XCTAssertFalse(partial.contains { $0.severity == .warning && $0.message.contains("outline") })
        XCTAssertTrue(t.isCropped(t.fields[0]) { _, _ in .partial })
        XCTAssertFalse(t.isCropped(t.fields[0]) { _, _ in .inside })
        let outside = SaveChecks.run(template: t, containment: { _, _ in .outside })
        XCTAssertTrue(outside.contains { $0.severity == .warning && $0.message.contains("invisible") })
        XCTAssertLessThan(SaveIssue.Severity.info, .warning)
    }
}

final class RectHandleTests: XCTestCase {
    let r = PDFRect(x: 100, y: 100, width: 200, height: 100)

    func testResizeCornersAndEdges() {
        XCTAssertEqual(RectHandle.resize(r, handle: 4, to: PDFPoint(350, 250)), PDFRect(x: 100, y: 100, width: 250, height: 150))
        XCTAssertEqual(RectHandle.resize(r, handle: 0, to: PDFPoint(50, 80)), PDFRect(x: 50, y: 80, width: 250, height: 120))
        XCTAssertEqual(RectHandle.resize(r, handle: 3, to: PDFPoint(320, 999)), PDFRect(x: 100, y: 100, width: 220, height: 100), "edge handle moves one edge only")
        // Dragging past the opposite edge clamps to the minimum size instead of flipping.
        XCTAssertEqual(RectHandle.resize(r, handle: 3, to: PDFPoint(0, 0)).width, 4)
    }

    func testAspectAndCentre() {
        let a = RectHandle.resize(r, handle: 4, to: PDFPoint(500, 120), keepAspect: true)
        XCTAssertEqual(a.width / a.height, 2, accuracy: 1e-9)
        XCTAssertEqual(a.minX, 100); XCTAssertEqual(a.minY, 100)
        let c = RectHandle.resize(r, handle: 3, to: PDFPoint(320, 150), fromCenter: true)
        XCTAssertEqual(c, PDFRect(x: 80, y: 100, width: 240, height: 100))
        XCTAssertEqual(RectHandle.point(r, 5), PDFPoint(200, 200))
    }
}

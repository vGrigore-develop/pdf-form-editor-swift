import XCTest
@testable import MuPDFEngine
import PDFEngine
import VoucherModel

/// Regression tests for templates exported by Illustrator/InDesign/Acrobat that store
/// values indirectly (down to single numbers) and split field and widget (/Kids).
/// The fixture is built in memory from synthetic_voucher.pdf, so no user file is needed.
final class IndirectValuesTests: XCTestCase {
    /// synthetic_voucher.pdf plus:
    /// - `indirect_rect`: merged text field whose /Rect is `n 0 R` -> `[a 0 R b 0 R c 0 R d 0 R]`,
    ///   with an indirect /DA, indirect /MK /BG numbers and an indirect /A JavaScript action;
    /// - `kid_field`: a parent text field with one widget under /Kids (rect on the widget).
    func makeFixture() throws -> Data {
        let base = try Data(contentsOf: MuPDFEngineTests.fixtures.appendingPathComponent("synthetic_voucher.pdf"))
        let doc = try MuPDFDocument(data: base)
        let page = try doc.pageObjectNumber(0)
        func num(_ v: Double) throws -> PDFValue { .ref(try doc.newObject(.real(v)), 0) }

        let corners = try [100.5, 200.25, 300.5, 250.75].map(num)
        let rectArray = try doc.newObject(.array(corners))
        let da = try doc.newObject(.text("/Helv 10 Tf 1 1 1 rg"))
        let action = try doc.newObject(.dict(["S": .name("JavaScript"), "JS": .text("app.alert(1);")]))
        let merged = try doc.newObject(.dict([
            "Type": .name("Annot"), "Subtype": .name("Widget"), "FT": .name("Tx"),
            "T": .text("indirect_rect"), "Rect": .ref(rectArray, 0), "DA": .ref(da, 0),
            "MK": .dict(["BG": .array([try num(1), try num(0), try num(0)])]),
            "A": .ref(action, 0), "P": .ref(page, 0), "F": .int(4),
        ]))

        let parent = try doc.newObject(.dict([
            "FT": .name("Tx"), "T": .text("kid_field"), "DA": .text("/Helv 8 Tf 0 g"),
        ]))
        let kid = try doc.newObject(.dict([
            "Type": .name("Annot"), "Subtype": .name("Widget"), "Parent": .ref(parent, 0),
            "Rect": .numbers([400, 100, 500, 120]), "P": .ref(page, 0), "F": .int(4),
        ]))
        try doc.set(parent, "Kids", .array([.ref(kid, 0)]))

        try doc.set(page, "Annots", .array([.ref(merged, 0), .ref(kid, 0)]))
        let font = try doc.newObject(.dict(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica")]))
        let acro = try doc.newObject(.dict([
            "Fields": .array([.ref(merged, 0), .ref(parent, 0)]),
            "DR": .dict(["Font": .dict(["Helv": .ref(font, 0)])]),
            "DA": .text("/Helv 0 Tf 0 g"),
        ]))
        try doc.set(try doc.catalogObjectNumber(), "AcroForm", .ref(acro, 0))
        return try doc.write(incremental: true)
    }

    func testIndirectRectIsResolved() throws {
        let engine = try MuPDFEngine(data: try makeFixture())
        let r = try engine.readTemplate()
        let f = try XCTUnwrap(r.template.fields.first { $0.name == "indirect_rect" })
        // Before the fix this read as (0, 0, 0, 0): the field was drawn at the page's
        // bottom-left corner and the save checks reported "/Rect has zero or negative size".
        XCTAssertEqual(f.rect, PDFRect(x1: 100.5, y1: 200.25, x2: 300.5, y2: 250.75))
        XCTAssertTrue(f.isEditable)
        XCTAssertEqual(f.text.fontSize, 10)
        XCTAssertEqual(f.text.color, RGBColor.white)
        XCTAssertEqual(f.text.backgroundColor, RGBColor(1, 0, 0))
        XCTAssertTrue(r.facts.hasJavaScript, "an indirect /A JavaScript action must be detected")

        let issues = SaveChecks.run(template: r.template, facts: r.facts)
        XCTAssertFalse(issues.contains { $0.severity == .error }, "\(issues.map(\.message))")
    }

    func testSingleKidFieldIsNotReportedAsLinked() throws {
        let engine = try MuPDFEngine(data: try makeFixture())
        let r = try engine.readTemplate()
        let f = try XCTUnwrap(r.template.fields.first { $0.name == "kid_field" })
        XCTAssertEqual(f.rect, PDFRect(x1: 400, y1: 100, x2: 500, y2: 120))
        XCTAssertEqual(f.origin?.widgetCount, 1)
        XCTAssertFalse(f.isEditable)
        let reason = try XCTUnwrap(f.origin?.readOnlyReason)
        XCTAssertFalse(reason.contains("several widgets"), reason)
        XCTAssertTrue(reason.contains("/Kids"), reason)
    }

    func testMovingIndirectRectFieldSavesIncrementally() throws {
        let original = try makeFixture()
        let engine = try MuPDFEngine(data: original)
        let base = try engine.readTemplate().template
        var edited = base
        let i = try XCTUnwrap(edited.fields.firstIndex { $0.name == "indirect_rect" })
        edited.fields[i].rect = edited.fields[i].rect.offsetBy(dx: 10, dy: -20)
        let saved = try engine.save(baseline: base, edited: edited, incremental: true)
        XCTAssertEqual(saved.data.prefix(original.count), original)

        let reread = try MuPDFEngine(data: saved.data).readTemplate().template
        let f = try XCTUnwrap(reread.fields.first { $0.name == "indirect_rect" })
        XCTAssertEqual(f.rect.x, 110.5, accuracy: 0.01)
        XCTAssertEqual(f.rect.y, 180.25, accuracy: 0.01)
        XCTAssertEqual(f.rect.width, 200, accuracy: 0.01)
        XCTAssertEqual(f.rect.height, 50.5, accuracy: 0.01)
    }
}

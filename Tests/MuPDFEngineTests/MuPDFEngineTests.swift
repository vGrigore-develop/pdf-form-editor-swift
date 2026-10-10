import XCTest
@testable import MuPDFEngine
import PDFEngine
import VoucherModel
import VoucherGeometry

/// Round-trip and integrity tests against the spike fixtures (SPEC 9: Round-trip,
/// Integrity, Cut). They run MuPDF through the real C shim.
final class MuPDFEngineTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
    }

    func textField(_ name: String, _ rect: PDFRect, page: Int = 0) -> FieldDef {
        var f = FieldDef(kind: .text, name: name, page: page, rect: rect, tooltip: "Tip \(name)")
        f.text.fontSize = 14
        f.text.color = RGBColor(0.1, 0.1, 0.1)
        return f
    }

    func imageField(_ name: String, _ rect: PDFRect, js: Bool = true) -> FieldDef {
        var f = FieldDef(kind: .image, name: name, page: 0, rect: rect)
        f.image.importAction = js
        f.image.scaleWhen = .tooBig
        f.image.alignX = 0
        return f
    }

    // MARK: Fields

    func testOpenSyntheticVoucher() throws {
        let engine = try MuPDFEngine(data: try fixture("synthetic_voucher.pdf"))
        let r = try engine.readTemplate()
        XCTAssertEqual(r.template.pages.count, 1)
        XCTAssertEqual(r.template.pages[0].mediaBox, PDFRect(x: 0, y: 0, width: 842, height: 595))
        XCTAssertTrue(r.template.fields.isEmpty)
        XCTAssertFalse(r.facts.wasRepaired)
    }

    func testAddFieldsIncrementalRoundTrip() throws {
        let original = try fixture("synthetic_voucher.pdf")
        let engine = try MuPDFEngine(data: original)
        let base = try engine.readTemplate().template
        var edited = base
        var name = textField("recipient_name", PDFRect(x: 422, y: 377, width: 356, height: 36))
        name.text.defaultValue = "Țară Ștefan"
        name.text.alignment = .center
        var code = textField("voucher_code", PDFRect(x: 422, y: 257, width: 216, height: 36))
        code.text.maxLength = 10
        code.required = true
        edited.fields = [name, code, imageField("photo", PDFRect(x: 110, y: 295, width: 240, height: 160)),
                         imageField("logo", PDFRect(x: 150, y: 60, width: 150, height: 70), js: false)]

        let result = try engine.save(baseline: base, edited: edited)
        XCTAssertTrue(result.wasIncremental)
        XCTAssertGreaterThan(result.data.count, original.count)
        XCTAssertEqual(result.data.prefix(original.count), original, "original bytes must be an exact prefix")
        XCTAssertFalse(String(decoding: result.data, as: UTF8.self).contains("NeedAppearances"))

        // Read back with a fresh engine.
        let back = try MuPDFEngine(data: result.data).readTemplate().template
        XCTAssertEqual(Set(back.fields.map(\.name)), ["recipient_name", "voucher_code", "photo", "logo"])
        let rn = try XCTUnwrap(back.fields.first { $0.name == "recipient_name" })
        XCTAssertEqual(rn.kind, .text)
        XCTAssertEqual(rn.rect, PDFRect(x: 422, y: 377, width: 356, height: 36))
        XCTAssertEqual(rn.text.defaultValue, "Țară Ștefan")
        XCTAssertEqual(rn.text.alignment, .center)
        XCTAssertEqual(rn.text.fontName, "Helv")
        XCTAssertEqual(rn.text.fontSize, 14)
        XCTAssertEqual(rn.tooltip, "Tip recipient_name")
        XCTAssertEqual(rn.origin?.widgetCount, 1)
        XCTAssertEqual(rn.origin?.inAcroFormFields, true)
        XCTAssertEqual(rn.origin?.hasPageRef, true)
        let vc = try XCTUnwrap(back.fields.first { $0.name == "voucher_code" })
        XCTAssertEqual(vc.text.maxLength, 10)
        XCTAssertTrue(vc.required)
        let photo = try XCTUnwrap(back.fields.first { $0.name == "photo" })
        XCTAssertEqual(photo.kind, .image)
        XCTAssertTrue(photo.image.importAction)
        XCTAssertEqual(photo.image.scaleWhen, .tooBig)
        XCTAssertEqual(photo.image.alignX, 0)
        XCTAssertEqual(photo.flags & FieldFlags.pushButton, FieldFlags.pushButton)
        let logo = try XCTUnwrap(back.fields.first { $0.name == "logo" })
        XCTAssertEqual(logo.kind, .image)
        XCTAssertFalse(logo.image.importAction)
        XCTAssertFalse(back.fields.contains { !$0.isEditable })

        // The save checks pass on what was read back (no errors).
        let issues = SaveChecks.run(template: back)
        XCTAssertFalse(issues.contains { $0.severity == .error }, "\(issues)")
    }

    func testEditRenameDeleteAcrossSaves() throws {
        let original = try fixture("synthetic_voucher.pdf")
        let engine = try MuPDFEngine(data: original)
        let t0 = try engine.readTemplate().template
        var t1 = t0
        let a = textField("a_field", PDFRect(x: 100, y: 100, width: 100, height: 20))
        let b = textField("b_field", PDFRect(x: 100, y: 200, width: 100, height: 20))
        t1.fields = [a, b]
        let s1 = try engine.save(baseline: t0, edited: t1)

        // Save 2: rename + move a, delete b. No re-read in between (ids are tracked).
        var t2 = t1
        t2.fields[0].name = "renamed"
        t2.fields[0].rect = PDFRect(x: 300, y: 300, width: 120, height: 30)
        t2.fields[0].text.multiline = true
        t2.fields.remove(at: 1)
        let s2 = try engine.save(baseline: t1, edited: t2)
        XCTAssertEqual(s2.data.prefix(s1.data.count), s1.data, "each save appends")

        let back = try MuPDFEngine(data: s2.data).readTemplate().template
        XCTAssertEqual(back.fields.map(\.name), ["renamed"])
        XCTAssertEqual(back.fields[0].rect, PDFRect(x: 300, y: 300, width: 120, height: 30))
        XCTAssertTrue(back.fields[0].text.multiline)

        // Save 3: undo-like restore of the deleted field creates it again.
        var t3 = t2
        t3.fields.append(b)
        let s3 = try engine.save(baseline: t2, edited: t3)
        let back3 = try MuPDFEngine(data: s3.data).readTemplate().template
        XCTAssertEqual(Set(back3.fields.map(\.name)), ["renamed", "b_field"])
    }

    func testJSFormPreservedAndFieldsAdded() throws {
        let original = try fixture("js_form.pdf")
        let engine = try MuPDFEngine(data: original)
        let r = try engine.readTemplate()
        XCTAssertTrue(r.facts.hasJavaScript)
        XCTAssertEqual(Set(r.template.fields.map(\.name)), ["amount", "total", "reset"])
        let reset = try XCTUnwrap(r.template.fields.first { $0.name == "reset" })
        XCTAssertEqual(reset.kind, .other, "a push-button without icon is not an image field")
        XCTAssertFalse(reset.isEditable)

        var edited = r.template
        edited.fields.append(textField("added", PDFRect(x: 422, y: 300, width: 200, height: 30)))
        let out = try engine.save(baseline: r.template, edited: edited).data
        XCTAssertEqual(out.prefix(original.count), original)
        // Every JS string of the original is still present byte-for-byte in the output's objects.
        for js in ["AFNumber_Keystroke(2, 0, 0, 0, \"\", true);", "this.resetForm();"] {
            XCTAssertTrue(out.range(of: Data(js.utf8)) != nil || original.range(of: Data(js.utf8)) == nil)
        }
        let back = try MuPDFEngine(data: out).readTemplate().template
        XCTAssertEqual(Set(back.fields.map(\.name)), ["amount", "total", "reset", "added"])
    }

    func testSignedDocumentKeepsPrefixAndRefusesCut() throws {
        let original = try fixture("signed_approval.pdf")
        let engine = try MuPDFEngine(data: original)
        let r = try engine.readTemplate()
        XCTAssertEqual(r.facts.signatureCount, 1)
        var edited = r.template
        edited.fields.append(textField("after_sign", PDFRect(x: 422, y: 300, width: 200, height: 30)))
        let out = try engine.save(baseline: r.template, edited: edited).data
        XCTAssertEqual(out.prefix(original.count), original)
        let issues = SaveChecks.run(template: edited, facts: r.facts)
        XCTAssertTrue(issues.contains { $0.message.contains("signed") })

        var cut = edited
        cut.outlines[0] = Outline.rectangle(PDFRect(x: 20, y: 20, width: 800, height: 550))
        XCTAssertThrowsError(try engine.save(baseline: edited, edited: cut))
    }

    // MARK: Cut

    static func referenceOutline() -> Outline {
        Outline(start: PDFPoint(564.5, 545), segments: [
            .line(to: PDFPoint(40, 545)), .line(to: PDFPoint(40, 460)), .line(to: PDFPoint(60, 460)),
            .line(to: PDFPoint(60, 380)), .line(to: PDFPoint(80, 380)), .line(to: PDFPoint(80, 215)),
            .line(to: PDFPoint(60, 215)), .line(to: PDFPoint(60, 135)), .line(to: PDFPoint(40, 135)),
            .line(to: PDFPoint(40, 50)), .line(to: PDFPoint(564.5, 50)),
            .arc(to: PDFPoint(564.5, 545), center: PDFPoint(564.5, 297.5), clockwise: false),
        ])
    }

    func contentsSyntax(_ data: Data) throws -> (contents: String, resources: String) {
        let doc = try MuPDFDocument(data: data)
        let p = try doc.pageObjectNumber(0)
        return (try doc.get(p, "Contents").syntax, try doc.get(p, "Resources").syntax)
    }

    func testCutApplyEditRemoveWrap() throws {
        let original = try fixture("synthetic_voucher.pdf")
        let before = try contentsSyntax(original)
        let engine = try MuPDFEngine(data: original)
        let t0 = try engine.readTemplate().template
        var t1 = t0
        t1.outlines[0] = Self.referenceOutline()
        let s1 = try engine.save(baseline: t0, edited: t1)
        XCTAssertTrue(s1.summary.contains { $0.contains("Wrap") }, "\(s1.summary)")

        // Read back: the outline comes back from /PieceInfo exactly.
        let r1 = try MuPDFEngine(data: s1.data).readTemplate().template
        XCTAssertEqual(r1.outlines[0], Self.referenceOutline())
        let c1 = try contentsSyntax(s1.data)
        XCTAssertNotEqual(c1.contents, before.contents)

        // Edit
        var t2 = t1
        t2.outlines[0] = Outline.rectangle(PDFRect(x: 30, y: 30, width: 700, height: 500))
        let s2 = try engine.save(baseline: t1, edited: t2)
        XCTAssertEqual(s2.data.prefix(s1.data.count), s1.data)
        let r2 = try MuPDFEngine(data: s2.data).readTemplate().template
        XCTAssertEqual(r2.outlines[0], t2.outlines[0])

        // Remove: /Contents restored exactly.
        var t3 = t2
        t3.outlines[0] = nil
        let s3 = try engine.save(baseline: t2, edited: t3)
        let after = try contentsSyntax(s3.data)
        XCTAssertEqual(after.contents, before.contents)
        XCTAssertEqual(after.resources, before.resources)
        XCTAssertNil(try MuPDFEngine(data: s3.data).readTemplate().template.outlines[0])
    }

    func testCutUnbalancedUsesXObjectAndReverses() throws {
        let original = try fixture("unbalanced_qQ_2.pdf")
        let before = try contentsSyntax(original)
        let engine = try MuPDFEngine(data: original)
        let t0 = try engine.readTemplate().template
        var t1 = t0
        t1.outlines[0] = Self.referenceOutline()
        let s1 = try engine.save(baseline: t0, edited: t1)
        XCTAssertTrue(s1.summary.contains { $0.contains("XObject") }, "\(s1.summary)")
        let c1 = try contentsSyntax(s1.data)
        XCTAssertTrue(c1.resources.contains("VEOrig"))

        var t2 = t1
        t2.outlines[0] = nil
        let s2 = try engine.save(baseline: t1, edited: t2)
        let after = try contentsSyntax(s2.data)
        XCTAssertEqual(after.contents, before.contents)
        XCTAssertEqual(after.resources, before.resources)
    }

    func testMalformedInputThrowsInsteadOfCrashing() {
        XCTAssertThrowsError(try MuPDFEngine(data: Data("not a pdf at all".utf8)))
        XCTAssertThrowsError(try MuPDFEngine(data: Data()))
    }

    func testShimObjectAPI() throws {
        let doc = try MuPDFDocument(data: try fixture("synthetic_voucher.pdf"))
        let n = try doc.newObject(.dict(["A": .int(1), "B": .dict(["C": .text("x(y)")])]))
        XCTAssertEqual(try doc.get(n, "A"), .int(1))
        XCTAssertEqual(try doc.get(n, "B/C").text, "x(y)")
        try doc.set(n, "B/D", .name("Q"))
        XCTAssertEqual(try doc.get(n, "B/D"), .name("Q"))
        try doc.set(n, "B/C", .null)
        XCTAssertEqual(try doc.get(n, "B/C"), .null, "null deletes (pdf_dict_del), not stores null")
        XCTAssertFalse(try doc.objectSyntax(n).contains("null"))
        XCTAssertEqual(try doc.get(n, "Missing/Path"), .null)
        let s = try doc.newStream(dict: .dict([:]), data: Data("q Q".utf8))
        XCTAssertEqual(try doc.streamData(s), Data("q Q".utf8))
        XCTAssertTrue(try doc.isStream(s))
        XCTAssertThrowsError(try doc.set(n, "A/B/C", .int(1)))
    }
}

/// Writes a Swift-made template (S1 fields + S5 reference cut) to spikes/out/swift/
/// so the Python S9 fill checks can run against the real engine's output:
///   cd spikes && S9_TEMPLATE=out/swift/swift_fields_and_cut.pdf ../.venv/bin/python s9_fill.py
final class ExternalCheckOutputTests: XCTestCase {
    func testWriteTemplateForPythonChecks() throws {
        let repo = MuPDFEngineTests.fixtures.deletingLastPathComponent().deletingLastPathComponent()
        let outDir = repo.appendingPathComponent("spikes/out/swift")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let original = try Data(contentsOf: MuPDFEngineTests.fixtures.appendingPathComponent("synthetic_voucher.pdf"))
        let engine = try MuPDFEngine(data: original)
        let t0 = try engine.readTemplate().template
        var t1 = t0
        func text(_ n: String, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, size: Double = 12) -> FieldDef {
            var f = FieldDef(kind: .text, name: n, page: 0, rect: PDFRect(x1: x1, y1: y1, x2: x2, y2: y2))
            f.text.fontSize = size
            return f
        }
        var code = text("voucher_code", 422, 257, 638, 293)
        code.text.maxLength = 10
        code.text.alignment = .center
        var photo = FieldDef(kind: .image, name: "photo", page: 0, rect: PDFRect(x1: 110, y1: 295, x2: 350, y2: 455))
        photo.image.importAction = true
        var logo = FieldDef(kind: .image, name: "logo", page: 0, rect: PDFRect(x1: 150, y1: 60, x2: 300, y2: 130))
        logo.image.importAction = false
        t1.fields = [text("recipient_name", 422, 377, 778, 413, size: 14), text("valid_until", 422, 317, 778, 353), code, photo, logo]
        let s1 = try engine.save(baseline: t0, edited: t1)
        try s1.data.write(to: outDir.appendingPathComponent("swift_fields_only.pdf"))
        var t2 = t1
        t2.outlines[0] = MuPDFEngineTests.referenceOutline()
        let s2 = try engine.save(baseline: t1, edited: t2)
        try s2.data.write(to: outDir.appendingPathComponent("swift_fields_and_cut.pdf"))
        XCTAssertEqual(s2.data.prefix(original.count), original)

        // S10: the photo slot crosses the stepped left edge and is cropped to the outline.
        //   cd spikes && ../.venv/bin/python s10_crop.py out/swift/swift_crossing_cut.pdf  (S10_TEMPLATE_IS_SWIFT=1)
        var t3 = t2
        t3.fields[3].rect = PDFRect(x1: 20, y1: 250, x2: 260, y2: 410)
        let s3 = try engine.save(baseline: t2, edited: t3)
        try s3.data.write(to: outDir.appendingPathComponent("swift_crossing_cut.pdf"))
    }
}

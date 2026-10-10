import XCTest
@testable import MuPDFEngine
import PDFEngine
import VoucherModel

/// "Merge field and widget" (DECISIONS 29): a terminal field whose only widget is a
/// separate /Kids object becomes one merged field/widget dictionary on save.
/// Fixtures are built in memory from synthetic_voucher.pdf.
@MainActor
final class WidgetMergeTests: XCTestCase {
    struct Fixture {
        var data: Data
        var page: Int
        var group: Int      // non-terminal grandparent: /FT /Ff /DA live here
        var field: Int      // "group.kid_field": /T /TU only, one widget kid
        var widget: Int
        var imageField: Int // "photo_split": push-button, one widget kid
        var imageWidget: Int
        var objr: Int       // structure-tree style /OBJR pointing at the text widget
        var acroForm: Int
        var apStream: Int
    }

    /// synthetic_voucher.pdf plus:
    /// - `group` (no widget) > `kid_field` (/T, /TU) > widget (/Rect, /MK, /AP, JS /A, /AA /E,
    ///   a conflicting /DA); /FT, /Ff (multiline) and /DA come from `group`;
    /// - `photo_split`: image push-button with one widget kid carrying /MK /TP 1 and the
    ///   import-icon action;
    /// - an /OBJR and /AcroForm /CO entries referencing the widget / field.
    static func makeFixture(base: Data? = nil, extraFields: Bool = true) throws -> Fixture {
        let original = try base ?? Data(contentsOf: MuPDFEngineTests.fixtures.appendingPathComponent("synthetic_voucher.pdf"))
        let doc = try MuPDFDocument(data: original)
        let page = try doc.pageObjectNumber(0)
        let group = try doc.newObject(.dict([
            "T": .text("group"), "FT": .name("Tx"), "Ff": .int(FieldFlags.multiline),
            "DA": .text("/Helv 9 Tf 0 0 1 rg"),
        ]))
        let field = try doc.newObject(.dict(["T": .text("kid_field"), "TU": .text("Tip"), "Parent": .ref(group, 0)]))
        let ap = try doc.newStream(dict: .dict([
            "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .numbers([0, 0, 100, 30]),
            "Resources": .dict([:]),
        ]), data: Data("1 1 0 rg 0 0 100 30 re f\n".utf8))
        let widget = try doc.newObject(.dict([
            "Type": .name("Annot"), "Subtype": .name("Widget"), "Parent": .ref(field, 0),
            "Rect": .numbers([400.125, 100, 500, 130]), "P": .ref(page, 0), "F": .int(4),
            "MK": .dict(["BG": .numbers([1, 1, 0])]), "AP": .dict(["N": .ref(ap, 0)]),
            "A": .dict(["S": .name("JavaScript"), "JS": .text("app.alert(1);")]),
            "AA": .dict(["E": .dict(["S": .name("JavaScript"), "JS": .text("app.beep(0);")])]),
            "DA": .text("/Helv 11 Tf 0 g"),
        ]))
        try doc.set(field, "Kids", .array([.ref(widget, 0)]))
        try doc.set(group, "Kids", .array([.ref(field, 0)]))

        let imageField = try doc.newObject(.dict([
            "T": .text("photo_split"), "FT": .name("Btn"), "Ff": .int(FieldFlags.pushButton), "DA": .text("/Helv 0 Tf 0 g"),
        ]))
        let imageWidget = try doc.newObject(.dict([
            "Type": .name("Annot"), "Subtype": .name("Widget"), "Parent": .ref(imageField, 0),
            "Rect": .numbers([150, 300, 300, 450]), "P": .ref(page, 0), "F": .int(4),
            "MK": .dict(["TP": .int(1)]),
            "A": .dict(["S": .name("JavaScript"), "JS": .text(TemplateReader.importIconJS)]),
        ]))
        try doc.set(imageField, "Kids", .array([.ref(imageWidget, 0)]))

        let objr = try doc.newObject(.dict(["Type": .name("OBJR"), "Obj": .ref(widget, 0), "Pg": .ref(page, 0)]))
        try doc.set(try doc.catalogObjectNumber(), "VETestRefs", .array([.ref(objr, 0)]))

        var annots = (try doc.resolve(try doc.get(page, "Annots"))).array ?? []
        annots += [.ref(widget, 0), .ref(imageWidget, 0)]
        try doc.set(page, "Annots", .array(annots))
        let font = try doc.newObject(.dict(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica")]))
        var acro: Int
        if let existing = try doc.get(try doc.catalogObjectNumber(), "AcroForm").refNumber {
            acro = existing
            let fields = (try doc.resolve(try doc.get(acro, "Fields"))).array ?? []
            try doc.set(acro, "Fields", .array(fields + [.ref(group, 0), .ref(imageField, 0)]))
        } else {
            acro = try doc.newObject(.dict([
                "Fields": .array([.ref(group, 0), .ref(imageField, 0)]),
                "DR": .dict(["Font": .dict(["Helv": .ref(font, 0)])]),
                "DA": .text("/Helv 0 Tf 0 g"),
            ]))
            try doc.set(try doc.catalogObjectNumber(), "AcroForm", .ref(acro, 0))
        }
        try doc.set(acro, "CO", .array([.ref(field, 0)]))
        return Fixture(data: try doc.write(incremental: true), page: page, group: group, field: field, widget: widget,
                       imageField: imageField, imageWidget: imageWidget, objr: objr, acroForm: acro, apStream: ap)
    }

    /// The editor's merge command applied to a read template (one undo step).
    func merged(_ t: Template, names: Set<String>) -> Template {
        let ed = TemplateEditor(template: t)
        for f in t.fields where names.contains(f.qualifiedName) { ed.mergeFieldAndWidget(f.id) }
        return ed.template
    }

    // MARK: Detection

    func testDetectionOffersMergeAndListsConflicts() throws {
        let fx = try Self.makeFixture()
        let r = try MuPDFEngine(data: fx.data).readTemplate()
        let f = try XCTUnwrap(r.template.fields.first { $0.qualifiedName == "group.kid_field" })
        XCTAssertFalse(f.isEditable)
        XCTAssertTrue(f.hasSeparateWidget)
        XCTAssertTrue(f.canMergeWidget)
        XCTAssertEqual(f.origin?.separateWidget, fx.widget)
        let notes = f.origin?.widgetMergeNotes ?? []
        XCTAssertTrue(notes.contains { $0.hasPrefix("/DA differs") && $0.contains("field's") && $0.contains("kept") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.hasPrefix("/FT is inherited") }, "\(notes)")
        let img = try XCTUnwrap(r.template.fields.first { $0.qualifiedName == "photo_split" })
        XCTAssertEqual(img.kind, .image)
        XCTAssertTrue(img.canMergeWidget)
        XCTAssertEqual(img.origin?.widgetMergeNotes, [])
    }

    // MARK: Merge

    func testMergeProducesOneDictionaryWithSameNameAndRect() throws {
        let fx = try Self.makeFixture()
        let engine = try MuPDFEngine(data: fx.data)
        let base = try engine.readTemplate().template
        let before = Dictionary(uniqueKeysWithValues: base.fields.map { ($0.qualifiedName, $0) })
        let edited = merged(base, names: ["group.kid_field", "photo_split"])
        XCTAssertTrue(edited.fields.filter { ["group.kid_field", "photo_split"].contains($0.qualifiedName) }.allSatisfy(\.isEditable))

        let saved = try engine.save(baseline: base, edited: edited, incremental: true)
        XCTAssertEqual(saved.data.prefix(fx.data.count), fx.data, "original bytes must be an exact prefix")
        XCTAssertTrue(saved.summary.contains("Merged field and widget of group.kid_field"), "\(saved.summary)")
        XCTAssertTrue(saved.summary.contains("Merged field and widget of photo_split"), "\(saved.summary)")

        // Read back: one merged, editable field per name, same qualified name and rect.
        let back = try MuPDFEngine(data: saved.data).readTemplate().template
        XCTAssertEqual(Set(back.fields.map(\.qualifiedName)), Set(before.keys))
        for name in ["group.kid_field", "photo_split"] {
            let f = try XCTUnwrap(back.fields.first { $0.qualifiedName == name })
            XCTAssertTrue(f.isEditable, name)
            XCTAssertNil(f.origin?.separateWidget, name)
            XCTAssertEqual(f.origin?.widgetCount, 1)
            XCTAssertEqual(f.origin?.inAcroFormFields, true)
            XCTAssertEqual(f.origin?.hasPageRef, true)
            XCTAssertEqual(f.rect, before[name]?.rect, name)
            XCTAssertEqual(f.kind, before[name]?.kind, name)
        }
        let kid = try XCTUnwrap(back.fields.first { $0.qualifiedName == "group.kid_field" })
        XCTAssertEqual(kid.origin?.objectNumber, fx.field, "the field object survives")
        XCTAssertEqual(kid.name, "kid_field")
        XCTAssertEqual(kid.origin?.isHierarchical, true)
        XCTAssertEqual(kid.tooltip, "Tip")
        XCTAssertEqual(kid.text.fontSize, 9, "the field's inherited /DA wins over the widget's")
        XCTAssertEqual(kid.text.color, RGBColor(0, 0, 1))
        XCTAssertTrue(kid.text.multiline)
        XCTAssertEqual(kid.text.backgroundColor, RGBColor(1, 1, 0))
        let photo = try XCTUnwrap(back.fields.first { $0.qualifiedName == "photo_split" })
        XCTAssertTrue(photo.image.importAction)

        // Structure, object by object.
        let doc = try MuPDFDocument(data: saved.data)
        let annots = (try doc.resolve(try doc.get(fx.page, "Annots"))).array?.compactMap(\.refNumber) ?? []
        XCTAssertTrue(annots.contains(fx.field) && annots.contains(fx.imageField), "\(annots)")
        XCTAssertFalse(annots.contains(fx.widget) || annots.contains(fx.imageWidget), "\(annots)")
        XCTAssertEqual(Set(annots).count, annots.count, "no duplicate /Annots entries")
        let fields = (try doc.resolve(try doc.get(fx.acroForm, "Fields"))).array?.compactMap(\.refNumber) ?? []
        XCTAssertTrue(fields.contains(fx.group) && fields.contains(fx.imageField))
        XCTAssertEqual((try doc.get(fx.group, "Kids")).array?.compactMap(\.refNumber), [fx.field])
        XCTAssertEqual((try doc.get(fx.acroForm, "CO")).array?.compactMap(\.refNumber), [fx.field])
        XCTAssertEqual(try doc.get(fx.objr, "Obj").refNumber, fx.field, "references to the widget are retargeted")

        let m = try doc.object(fx.field)
        XCTAssertTrue(m["Kids"].isNull)
        XCTAssertEqual(m["Subtype"].name, "Widget")
        XCTAssertEqual(m["Type"].name, "Annot")
        XCTAssertEqual(m["P"].refNumber, fx.page)
        XCTAssertEqual(m["Parent"].refNumber, fx.group, "the hierarchy above the field is kept")
        XCTAssertEqual(m["T"].text, "kid_field")
        XCTAssertEqual(m["FT"].name, "Tx")
        XCTAssertEqual(m["Ff"].int, FieldFlags.multiline)
        XCTAssertEqual(m["DA"].text, "/Helv 9 Tf 0 0 1 rg")
        XCTAssertEqual(m["F"].int, 4)
        XCTAssertEqual(try doc.get(fx.field, "AP/N").refNumber, fx.apStream, "the appearance is not regenerated")
        XCTAssertEqual(try doc.get(fx.field, "A/JS").text, "app.alert(1);")
        XCTAssertEqual(try doc.get(fx.field, "AA/E/JS").text, "app.beep(0);")
        XCTAssertEqual((try doc.get(fx.field, "Rect")).numbers?.first ?? 0, 400.125, accuracy: 0.0001)
        XCTAssertEqual(try doc.object(fx.widget), .null, "the old widget object is nulled")
        XCTAssertEqual(try doc.object(fx.imageWidget), .null)
        XCTAssertFalse(doc.wasRepaired)
    }

    func testMergeTogetherWithAnEditAndUndoBeforeSave() throws {
        let fx = try Self.makeFixture()
        let engine = try MuPDFEngine(data: fx.data)
        let base = try engine.readTemplate().template
        let um = UndoManager()
        um.groupsByEvent = false
        let ed = TemplateEditor(template: base, undoManager: um)
        let id = try XCTUnwrap(base.fields.first { $0.qualifiedName == "group.kid_field" }?.id)

        ed.mergeFieldAndWidget(id)
        XCTAssertTrue(ed.template.field(id)?.isEditable ?? false)
        XCTAssertEqual(um.undoActionName, "Merge Field and Widget")
        um.undo()
        XCTAssertEqual(ed.template, base, "undo before save restores the read state exactly")
        um.redo()
        XCTAssertTrue(ed.template.field(id)?.origin?.mergeWidgetOnSave ?? false)

        ed.updateField(id, "Move") { $0.rect = $0.rect.offsetBy(dx: 10, dy: 0) }
        let saved = try engine.save(baseline: base, edited: ed.template, incremental: true)
        let back = try MuPDFEngine(data: saved.data).readTemplate().template
        let f = try XCTUnwrap(back.fields.first { $0.qualifiedName == "group.kid_field" })
        XCTAssertEqual(f.rect.x, 410.125, accuracy: 0.01)
        XCTAssertTrue(f.isEditable)

        // Undo after the save: the model shows the field read-only again, the file stays merged.
        // Pressing merge again is a no-op on the already merged object.
        let afterSave = ed.template
        um.undo(); um.undo()
        XCTAssertFalse(ed.template.field(id)?.isEditable ?? true)
        let undone = ed.template
        let s2 = try engine.save(baseline: afterSave, edited: undone, incremental: true)
        ed.mergeFieldAndWidget(id)
        XCTAssertTrue(ed.template.field(id)?.isEditable ?? false)
        let s3 = try engine.save(baseline: undone, edited: ed.template, incremental: true)
        XCTAssertFalse(s3.summary.contains { $0.hasPrefix("Merged") }, "\(s3.summary)")
        XCTAssertEqual(s3.data.prefix(s2.data.count), s2.data)
        let again = try MuPDFEngine(data: s3.data).readTemplate().template
        XCTAssertTrue(again.fields.first { $0.qualifiedName == "group.kid_field" }?.isEditable ?? false)
    }

    func testMergeThenDeleteInOneSave() throws {
        let fx = try Self.makeFixture()
        let engine = try MuPDFEngine(data: fx.data)
        let base = try engine.readTemplate().template
        let ed = TemplateEditor(template: base)
        let id = try XCTUnwrap(base.fields.first { $0.qualifiedName == "photo_split" }?.id)
        ed.deleteField(id)
        XCTAssertNotNil(ed.template.field(id), "a read-only field cannot be deleted before merging")
        ed.mergeFieldAndWidget(id)
        ed.deleteField(id)
        XCTAssertNil(ed.template.field(id))
        let saved = try engine.save(baseline: base, edited: ed.template, incremental: true)
        let doc = try MuPDFDocument(data: saved.data)
        let annots = (try doc.resolve(try doc.get(fx.page, "Annots"))).array?.compactMap(\.refNumber) ?? []
        XCTAssertFalse(annots.contains(fx.imageField) || annots.contains(fx.imageWidget))
        let fields = (try doc.resolve(try doc.get(fx.acroForm, "Fields"))).array?.compactMap(\.refNumber) ?? []
        XCTAssertFalse(fields.contains(fx.imageField))
        let back = try MuPDFEngine(data: saved.data).readTemplate().template
        XCTAssertNil(back.fields.first { $0.qualifiedName == "photo_split" })
    }

    // MARK: Refusals

    func testRefusals() throws {
        let fx = try Self.makeFixture()
        let doc = try MuPDFDocument(data: fx.data)
        let merger = WidgetMerger(doc: doc)
        func refusal(_ field: Int, signatures: Int = 0) -> String {
            do { _ = try merger.plan(field: field, signatureCount: signatures); return "" } catch { return error.localizedDescription }
        }
        XCTAssertTrue(refusal(fx.field, signatures: 1).contains("signed"))
        XCTAssertTrue(refusal(fx.group).contains("own /T"), "a parent whose kid has /T is a real hierarchy")

        // Two kids
        let second = try doc.newObject(.dict(["Type": .name("Annot"), "Subtype": .name("Widget"), "Parent": .ref(fx.imageField, 0),
                                               "Rect": .numbers([0, 0, 10, 10])]))
        try doc.set(fx.imageField, "Kids", .array([.ref(fx.imageWidget, 0), .ref(second, 0)]))
        XCTAssertTrue(refusal(fx.imageField).contains("2 kids"))

        // Not terminal: no /FT anywhere
        let noType = try doc.newObject(.dict(["T": .text("x")]))
        let w = try doc.newObject(.dict(["Type": .name("Annot"), "Subtype": .name("Widget"), "Parent": .ref(noType, 0),
                                          "Rect": .numbers([0, 0, 10, 10]), "P": .ref(fx.page, 0)]))
        try doc.set(noType, "Kids", .array([.ref(w, 0)]))
        XCTAssertTrue(refusal(noType).contains("not terminal"))

        // Already merged: nothing to do
        let merged = try doc.newObject(.dict(["Type": .name("Annot"), "Subtype": .name("Widget"), "T": .text("m"),
                                              "FT": .name("Tx"), "Rect": .numbers([0, 0, 10, 10])]))
        XCTAssertNil(try merger.plan(field: merged, signatureCount: 0))
    }

    func testSignedDocumentRefusesMerge() throws {
        let signed = try Data(contentsOf: MuPDFEngineTests.fixtures.appendingPathComponent("signed_approval.pdf"))
        let fx = try Self.makeFixture(base: signed)
        let engine = try MuPDFEngine(data: fx.data)
        let r = try engine.readTemplate()
        XCTAssertEqual(r.facts.signatureCount, 1)
        let f = try XCTUnwrap(r.template.fields.first { $0.qualifiedName == "photo_split" })
        XCTAssertTrue(f.hasSeparateWidget)
        XCTAssertFalse(f.canMergeWidget)
        XCTAssertTrue(f.origin?.widgetMergeBlocker?.contains("signed") ?? false)
        let ed = TemplateEditor(template: r.template)
        ed.mergeFieldAndWidget(f.id)
        XCTAssertEqual(ed.template, r.template, "the command does nothing when the merge is blocked")

        // Forced past the UI, the engine still refuses.
        var forced = r.template
        let i = try XCTUnwrap(forced.index(of: f.id))
        forced.fields[i].origin?.mergeWidgetOnSave = true
        XCTAssertThrowsError(try engine.save(baseline: r.template, edited: forced, incremental: true)) { e in
            XCTAssertTrue(e.localizedDescription.contains("signed"), e.localizedDescription)
        }
    }

    // MARK: Outputs for the Python checks (spikes/README.md)

    /// Splits merged field/widget dictionaries into field + one /Kids widget, the way
    /// Illustrator/InDesign export them.
    static func split(_ data: Data, names: Set<String>) throws -> Data {
        let doc = try MuPDFDocument(data: data)
        let acro = try XCTUnwrap(try doc.get(try doc.catalogObjectNumber(), "AcroForm").refNumber)
        var fields = (try doc.resolve(try doc.get(acro, "Fields"))).array ?? []
        for (i, ref) in fields.enumerated() {
            guard let n = ref.refNumber, let t = try doc.get(n, "T").text, names.contains(t) else { continue }
            var parent: [String: PDFValue] = [:]
            for key in ["T", "TU", "FT", "Ff", "V", "DV", "MaxLen", "Q", "DA"] {
                let v = try doc.get(n, key)
                if !v.isNull { parent[key] = v; try doc.set(n, key, .null) }
            }
            parent["Kids"] = .array([.ref(n, 0)])
            let p = try doc.newObject(.dict(parent))
            try doc.set(n, "Parent", .ref(p, 0))
            fields[i] = .ref(p, 0)
        }
        try doc.set(acro, "Fields", .array(fields))
        return try doc.write(incremental: true)
    }

    func testWriteMergedTemplatesForPythonChecks() throws {
        let repo = MuPDFEngineTests.fixtures.deletingLastPathComponent().deletingLastPathComponent()
        let outDir = repo.appendingPathComponent("spikes/out/swift")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // The S9 template (fields + cut), as ExternalCheckOutputTests writes it.
        try ExternalCheckOutputTests().testWriteTemplateForPythonChecks()
        let template = try Data(contentsOf: outDir.appendingPathComponent("swift_fields_and_cut.pdf"))
        let names: Set<String> = ["voucher_code", "photo"]
        let splitData = try Self.split(template, names: names)
        try splitData.write(to: outDir.appendingPathComponent("swift_split.pdf"))

        let engine = try MuPDFEngine(data: splitData)
        let base = try engine.readTemplate().template
        XCTAssertEqual(base.fields.filter(\.hasSeparateWidget).map(\.name).sorted(), ["photo", "voucher_code"])
        let saved = try engine.save(baseline: base, edited: merged(base, names: names), incremental: true)
        XCTAssertEqual(saved.data.prefix(splitData.count), splitData)
        try saved.data.write(to: outDir.appendingPathComponent("swift_merged.pdf"))
        let back = try MuPDFEngine(data: saved.data).readTemplate().template
        XCTAssertTrue(back.fields.allSatisfy(\.isEditable))
        XCTAssertEqual(back.fields.map(\.rect), base.fields.map(\.rect))

        // The hierarchical fixture, before and after.
        let fx = try Self.makeFixture()
        try fx.data.write(to: outDir.appendingPathComponent("swift_merge_hier_split.pdf"))
        let e2 = try MuPDFEngine(data: fx.data)
        let b2 = try e2.readTemplate().template
        let s2 = try e2.save(baseline: b2, edited: merged(b2, names: ["group.kid_field", "photo_split"]), incremental: true)
        try s2.data.write(to: outDir.appendingPathComponent("swift_merge_hier_merged.pdf"))
    }
}

/// Runs the merge on a real file without the app (skipped unless VE_MERGE_INPUT is set):
///   VE_MERGE_INPUT=in.pdf VE_MERGE_OUTPUT=out.pdf swift test --filter MergeRealFileTests
/// Every field with a mergeable separate widget is merged; the output is an incremental save.
@MainActor
final class MergeRealFileTests: XCTestCase {
    func testMergeFileFromEnvironment() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["VE_MERGE_INPUT"], let output = env["VE_MERGE_OUTPUT"] else {
            throw XCTSkip("set VE_MERGE_INPUT and VE_MERGE_OUTPUT")
        }
        let original = try Data(contentsOf: URL(fileURLWithPath: input))
        let engine = try MuPDFEngine(data: original)
        let base = try engine.readTemplate().template
        let ed = TemplateEditor(template: base)
        for f in base.fields where f.canMergeWidget { ed.mergeFieldAndWidget(f.id) }
        let saved = try engine.save(baseline: base, edited: ed.template, incremental: true)
        XCTAssertEqual(saved.data.prefix(original.count), original)
        try saved.data.write(to: URL(fileURLWithPath: output))
        print("MERGE SUMMARY:\n" + saved.summary.joined(separator: "\n"))
        for f in try MuPDFEngine(data: saved.data).readTemplate().template.fields {
            print("FIELD \(f.qualifiedName) kind=\(f.kind) editable=\(f.isEditable) rect=\(f.rect)")
        }
    }
}

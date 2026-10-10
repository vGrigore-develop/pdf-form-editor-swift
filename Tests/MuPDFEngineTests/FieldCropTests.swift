import XCTest
import PDFKit
import CoreGraphics
@testable import MuPDFEngine
import PDFEngine
import VoucherModel
import VoucherGeometry

/// "Crop fields to outline" (spike S10, DECISIONS 30): a field crossing the stepped
/// outline is clipped to it (appearance wrapper), a cover annotation sits last in /Annots,
/// both follow outline and field edits, and removing the cut or turning the setting off
/// restores the appearances, /Annots and the page content exactly.
final class FieldCropTests: XCTestCase {
    func fixture(_ name: String = "synthetic_voucher.pdf") throws -> Data {
        try Data(contentsOf: MuPDFEngineTests.fixtures.appendingPathComponent(name))
    }

    /// Crosses the reference outline's stepped left edge (x = 80 between y 215 and 380).
    static let crossingRect = PDFRect(x: 20, y: 250, width: 180, height: 100)
    static let insideRect = PDFRect(x: 300, y: 300, width: 200, height: 40)
    static let textCrossingRect = PDFRect(x: 30, y: 480, width: 150, height: 30) // crosses x = 40 at the top step

    func fields() -> [FieldDef] {
        var photo = FieldDef(kind: .image, name: "photo", page: 0, rect: Self.crossingRect)
        photo.image.backgroundColor = RGBColor(gray: 0.5)
        photo.image.borderColor = RGBColor(1, 0, 0)
        photo.image.borderWidth = 2
        var inside = FieldDef(kind: .text, name: "inside", page: 0, rect: Self.insideRect)
        inside.text.fontSize = 12
        var crossing = FieldDef(kind: .text, name: "crossing", page: 0, rect: Self.textCrossingRect)
        crossing.text.fontSize = 12
        crossing.text.backgroundColor = RGBColor(0, 0, 1)
        return [photo, inside, crossing]
    }

    struct PageState: Equatable {
        var contents: String
        var resources: String
        var annots: String
        var appearances: [String: String] // field name -> /AP value syntax
    }

    func state(_ data: Data, _ engine: MuPDFEngine, _ t: Template) throws -> PageState {
        let doc = try MuPDFDocument(data: data)
        let p = try doc.pageObjectNumber(0)
        var aps: [String: String] = [:]
        for f in t.fields { if let n = engine.objectNumbers[f.id] { aps[f.name] = try doc.get(n, "AP").syntax } }
        let annots = try doc.get(p, "Annots")
        let annotsSyntax = try annots.refNumber.map { try doc.objectSyntax($0) } ?? annots.syntax
        return PageState(contents: try doc.get(p, "Contents").syntax, resources: try doc.get(p, "Resources").syntax,
                         annots: annotsSyntax, appearances: aps)
    }

    func appearanceRef(_ data: Data, _ num: Int) throws -> Int {
        try XCTUnwrap(try MuPDFDocument(data: data).get(num, "AP/N").refNumber)
    }

    func isWrapper(_ data: Data, _ num: Int) throws -> (wrapped: Bool, original: Int?) {
        let doc = try MuPDFDocument(data: data)
        let ap = try XCTUnwrap(try doc.get(num, "AP/N").refNumber)
        let orig = try FieldCropper(doc: doc).wrappedOriginal(ap)
        return (orig != nil, orig)
    }

    func covers(_ data: Data) throws -> (refs: [Int], last: Int?, objects: [PDFValue]) {
        let doc = try MuPDFDocument(data: data)
        let p = try doc.pageObjectNumber(0)
        let annots = (try doc.resolve(try doc.get(p, "Annots"))).array?.compactMap(\.refNumber) ?? []
        let objs = try annots.map { try doc.object($0) }
        let c = zip(annots, objs).filter { $0.1["NM"].text == FieldCropper.coverName }
        return (c.map(\.0), annots.last, c.map(\.1))
    }

    /// PDFKit render (the engine of macOS Preview and of the app's Preview) at 1 px per pt,
    /// annotations included; returns the grey level at a page point.
    func pdfkitGray(_ data: Data, _ points: [PDFPoint]) throws -> [UInt8] {
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        let w = Int(box.width), h = Int(box.height)
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            page.draw(with: .mediaBox, to: ctx)
            return true
        }
        XCTAssertTrue(ok)
        // Row 0 of the buffer is the top of the page.
        return points.map { px[(h - 1 - Int($0.y)) * w + Int($0.x)] }
    }

    // MARK: Apply, edit, toggle, remove

    func testCrossingFieldsAreClippedAndEverythingReverses() throws {
        let original = try fixture()
        let engine = try MuPDFEngine(data: original)
        let t0 = try engine.readTemplate().template
        XCTAssertTrue(t0.cropFieldsToOutline, "on by default for a document without a cut")
        var t1 = t0
        t1.fields = fields()
        let s1 = try engine.save(baseline: t0, edited: t1)
        let before = try state(s1.data, engine, t1)
        let photoNum = try XCTUnwrap(engine.objectNumbers[t1.fields[0].id])
        let insideNum = try XCTUnwrap(engine.objectNumbers[t1.fields[1].id])
        let crossingNum = try XCTUnwrap(engine.objectNumbers[t1.fields[2].id])
        let photoAP = try appearanceRef(s1.data, photoNum)
        let docBefore = try MuPDFDocument(data: s1.data)
        let photoAPSyntax = try docBefore.objectSyntax(photoAP), photoAPData = try docBefore.streamData(photoAP, raw: true)
        // Without a cut, the placeholder shows at (50, 300).
        XCTAssertEqual(try pdfkitGray(s1.data, [PDFPoint(50, 300)])[0], 128, accuracy: 3)

        // Cut with cropping on.
        var t2 = t1
        t2.outlines[0] = MuPDFEngineTests.referenceOutline()
        let s2 = try engine.save(baseline: t1, edited: t2)
        XCTAssertTrue(s2.summary.contains { $0.contains("Cropped 2 field appearance") }, "\(s2.summary)")
        XCTAssertEqual(try isWrapper(s2.data, photoNum).original, photoAP, "the wrapper points at the original appearance")
        XCTAssertTrue(try isWrapper(s2.data, crossingNum).wrapped)
        XCTAssertFalse(try isWrapper(s2.data, insideNum).wrapped, "a field inside the outline is not touched")
        var c = try covers(s2.data)
        XCTAssertEqual(c.refs.count, 1)
        XCTAssertEqual(c.last, c.refs.first, "the cover is last in /Annots")
        XCTAssertEqual(c.objects.first?["Subtype"].name, "Watermark")
        XCTAssertEqual(c.objects.first?["F"].int, FieldCropper.coverFlags)
        let doc2 = try MuPDFDocument(data: s2.data)
        let page2 = try doc2.pageObjectNumber(0)
        XCTAssertEqual(try doc2.get(page2, CutWriter.cutPath + "/CropFields"), .bool(true))
        XCTAssertEqual(try doc2.get(page2, CutWriter.cutPath + "/CoverAnnot").refNumber, c.refs.first)
        // The wrapper keeps the appearance's space: same /BBox, identity /Matrix.
        let wrapper = try doc2.object(try appearanceRef(s2.data, photoNum))
        XCTAssertEqual(wrapper["BBox"].numbers, [0, 0, 180, 100])
        let wrapperText = String(decoding: try doc2.streamData(try appearanceRef(s2.data, photoNum)), as: UTF8.self)
        XCTAssertTrue(wrapperText.contains("60 130 l"), "outline in form space: (80, 380) - (20, 250)\n\(wrapperText)")
        XCTAssertTrue(wrapperText.contains("1 0 0 RG 4 w [6 4] 0 d"), "dashed red border along the outline\n\(wrapperText)")
        // PDFKit: the outside part of the placeholder is gone, the inside part stays.
        let g = try pdfkitGray(s2.data, [PDFPoint(50, 300), PDFPoint(150, 300), PDFPoint(35, 495), PDFPoint(100, 495)])
        XCTAssertEqual(g[0], 255, "outside the outline: blank")
        XCTAssertEqual(g[1], 128, accuracy: 3, "inside: the placeholder")
        XCTAssertEqual(g[2], 255, "text field outside: blank")
        XCTAssertLessThan(g[3], 100, "text field inside: its blue background")
        // Reads back as on.
        XCTAssertTrue(try MuPDFEngine(data: s2.data).readTemplate().template.cropFieldsToOutline)

        // Edit the outline: wrappers follow (new path), still one cover, its appearance updated.
        var t3 = t2
        t3.outlines[0] = MuPDFEngineTests.referenceOutline().translated(dx: 10, dy: 0)
        let s3 = try engine.save(baseline: t2, edited: t3)
        XCTAssertEqual(try isWrapper(s3.data, photoNum).original, photoAP, "rewrapped around the same original")
        let wt3 = String(decoding: try MuPDFDocument(data: s3.data).streamData(try appearanceRef(s3.data, photoNum)), as: UTF8.self)
        XCTAssertTrue(wt3.contains("70 130 l"), wt3)
        c = try covers(s3.data)
        XCTAssertEqual(c.refs.count, 1)
        XCTAssertEqual(try pdfkitGray(s3.data, [PDFPoint(85, 300)])[0], 255, "(85, 300) is now outside")

        // An unrelated save does not touch the page or the widgets.
        var t4 = t3
        t4.fields[1].tooltip = "changed"
        let s4 = try engine.save(baseline: t3, edited: t4)
        XCTAssertEqual(try appearanceRef(s4.data, photoNum), try appearanceRef(s3.data, photoNum))
        XCTAssertFalse(s4.summary.contains { $0.contains("Cropped") }, "\(s4.summary)")

        // Move the crossing text field fully inside: its regenerated appearance is not wrapped.
        var t5 = t4
        t5.fields[2].rect = PDFRect(x: 300, y: 400, width: 150, height: 30)
        let s5 = try engine.save(baseline: t4, edited: t5)
        XCTAssertFalse(try isWrapper(s5.data, crossingNum).wrapped)
        // A new field is added below the cover.
        var t6 = t5
        t6.fields.append(FieldDef(kind: .text, name: "added", page: 0, rect: PDFRect(x: 10, y: 100, width: 100, height: 20)))
        let s6 = try engine.save(baseline: t5, edited: t6)
        c = try covers(s6.data)
        XCTAssertEqual(c.last, c.refs.first, "the cover stays last after a field is added")
        XCTAssertTrue(try isWrapper(s6.data, try XCTUnwrap(engine.objectNumbers[t6.fields[3].id])).wrapped)

        // Turn cropping off: everything is unwrapped, the cover leaves /Annots, the cut stays.
        var t7 = t6
        t7.cropFieldsToOutline = false
        let s7 = try engine.save(baseline: t6, edited: t7)
        XCTAssertEqual(try appearanceRef(s7.data, photoNum), photoAP)
        XCTAssertTrue(try covers(s7.data).refs.isEmpty)
        XCTAssertEqual(try pdfkitGray(s7.data, [PDFPoint(50, 300)])[0], 128, accuracy: 3, "uncropped again")
        let r7 = try MuPDFEngine(data: s7.data).readTemplate().template
        XCTAssertFalse(r7.cropFieldsToOutline)
        XCTAssertNotNil(r7.outlines[0])

        // On again, then remove the cut: page content, /Annots and appearances as before the cut.
        var t8 = t7
        t8.cropFieldsToOutline = true
        let s8 = try engine.save(baseline: t7, edited: t8)
        XCTAssertEqual(try covers(s8.data).refs.count, 1)
        var t9 = t8
        t9.outlines[0] = nil
        t9.fields.removeLast() // drop "added" so /Annots can be compared with the pre-cut state
        t9.fields[2].rect = Self.textCrossingRect
        let s9 = try engine.save(baseline: t8, edited: t9)
        let after = try state(s9.data, engine, t9)
        XCTAssertEqual(after.contents, before.contents)
        XCTAssertEqual(after.resources, before.resources)
        XCTAssertEqual(after.annots, before.annots, "/Annots exactly as before the cut")
        XCTAssertEqual(after.appearances["photo"], before.appearances["photo"], "the original /AP /N reference is back")
        let doc9 = try MuPDFDocument(data: s9.data)
        XCTAssertEqual(try doc9.objectSyntax(photoAP), photoAPSyntax, "the original appearance object was never modified")
        XCTAssertEqual(try doc9.streamData(photoAP, raw: true), photoAPData)
        XCTAssertTrue(try covers(s9.data).refs.isEmpty)
        XCTAssertEqual(try pdfkitGray(s9.data, [PDFPoint(50, 300)])[0], 128, accuracy: 3)
        XCTAssertEqual(s9.data.prefix(original.count), original)
    }

    func testCropOffWritesNothingForFields() throws {
        let engine = try MuPDFEngine(data: try fixture())
        let t0 = try engine.readTemplate().template
        var t1 = t0
        t1.fields = fields()
        t1.cropFieldsToOutline = false
        _ = try engine.save(baseline: t0, edited: t1)
        var t2 = t1
        t2.outlines[0] = MuPDFEngineTests.referenceOutline()
        let s2 = try engine.save(baseline: t1, edited: t2)
        XCTAssertFalse(try isWrapper(s2.data, try XCTUnwrap(engine.objectNumbers[t1.fields[0].id])).wrapped)
        XCTAssertTrue(try covers(s2.data).refs.isEmpty)
        XCTAssertFalse(try MuPDFEngine(data: s2.data).readTemplate().template.cropFieldsToOutline)
    }

    /// A cut saved before S10 has no /CropFields: it reads as off, so opening an old file
    /// never changes its widgets until the setting is turned on.
    func testCutWithoutCropFlagReadsAsOff() throws {
        let engine = try MuPDFEngine(data: try fixture())
        let t0 = try engine.readTemplate().template
        var t1 = t0
        t1.outlines[0] = MuPDFEngineTests.referenceOutline()
        let s1 = try engine.save(baseline: t0, edited: t1)
        let doc = try MuPDFDocument(data: s1.data)
        let p = try doc.pageObjectNumber(0)
        try doc.set(p, CutWriter.cutPath + "/CropFields", .null)
        let old = try doc.write(incremental: true)
        XCTAssertFalse(try MuPDFEngine(data: old).readTemplate().template.cropFieldsToOutline)
    }

    /// Unbalanced q/Q takes the XObject route; cropping works the same and reverses.
    func testXObjectModeCutWithCrop() throws {
        let original = try fixture("unbalanced_qQ_2.pdf")
        let engine = try MuPDFEngine(data: original)
        let t0 = try engine.readTemplate().template
        var t1 = t0
        t1.fields = [fields()[0]]
        let s1 = try engine.save(baseline: t0, edited: t1)
        let before = try state(s1.data, engine, t1)
        var t2 = t1
        t2.outlines[0] = MuPDFEngineTests.referenceOutline()
        let s2 = try engine.save(baseline: t1, edited: t2)
        XCTAssertTrue(s2.summary.contains { $0.contains("XObject") })
        XCTAssertTrue(try isWrapper(s2.data, try XCTUnwrap(engine.objectNumbers[t1.fields[0].id])).wrapped)
        XCTAssertEqual(try pdfkitGray(s2.data, [PDFPoint(50, 300)])[0], 255)
        var t3 = t2
        t3.outlines[0] = nil
        let s3 = try engine.save(baseline: t2, edited: t3)
        XCTAssertEqual(try state(s3.data, engine, t3), before)
    }

    /// The Preview build crops the sample text and sample image too.
    func testPreviewIsCropped() throws {
        let engine = try MuPDFEngine(data: try fixture())
        let t0 = try engine.readTemplate().template
        var t1 = t0
        t1.fields = fields()
        t1.outlines[0] = MuPDFEngineTests.referenceOutline()
        _ = try engine.save(baseline: t0, edited: t1)
        var preview = t1
        // A solid black sample image, scaled to fill the whole slot.
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("crop-sample-\(UUID()).png")
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        defer { try? FileManager.default.removeItem(at: png) }
        preview.fields[0].image.sampleImagePath = png.path
        preview.fields[0].image.scaleHow = .stretch
        preview.fields[2].text.defaultValue = "WWWWWWWWWWWWWWWWWWWW"
        let data = try engine.previewData(baseline: t1, edited: preview)
        let g = try pdfkitGray(data, [PDFPoint(50, 300), PDFPoint(150, 300), PDFPoint(35, 495)])
        XCTAssertEqual(g[0], 255, "sample image cropped outside the outline")
        XCTAssertLessThan(g[1], 20, "sample image inside")
        XCTAssertEqual(g[2], 255, "sample text field cropped")
    }

    // MARK: Fit to outline

    func testLargestRectInsideSteppedOutline() throws {
        let o = MuPDFEngineTests.referenceOutline()
        let r = try XCTUnwrap(Geometry.largestRect(inside: o, within: Self.crossingRect))
        XCTAssertEqual(Geometry.containment(of: r, in: o), .inside)
        // The field spans y 250-350, inside the x >= 80 band (y 215-380): x 80-200 is the best.
        XCTAssertEqual(r.minX, 80, accuracy: 0.6)
        XCTAssertEqual(r.maxX, 200, accuracy: 0.01)
        XCTAssertEqual(r.minY, 250, accuracy: 0.01)
        XCTAssertEqual(r.maxY, 350, accuracy: 0.01)
        // Across two steps the larger of the two candidate rectangles wins.
        let tall = PDFRect(x: 10, y: 100, width: 150, height: 400)
        let t = try XCTUnwrap(Geometry.largestRect(inside: o, within: tall))
        XCTAssertEqual(Geometry.containment(of: t, in: o), .inside)
        // x 80-160 over the full height (32000) beats x 60-160 over y 380-460 or 135-215.
        XCTAssertEqual(t.width * t.height, 32000, accuracy: 200)
        // Fully inside: unchanged; fully outside: nil.
        XCTAssertEqual(Geometry.largestRect(inside: o, within: Self.insideRect), Self.insideRect)
        XCTAssertNil(Geometry.largestRect(inside: o, within: PDFRect(x: 0, y: 0, width: 30, height: 30)))
        // An arc edge: the result stays inside.
        let arcField = PDFRect(x: 700, y: 200, width: 120, height: 200)
        let a = try XCTUnwrap(Geometry.largestRect(inside: o, within: arcField))
        XCTAssertEqual(Geometry.containment(of: a, in: o), .inside)
        XCTAssertGreaterThan(a.width * a.height, 0.5 * 100 * 200)
    }

    // MARK: The example template (Tests/Fixtures/example_voucher_template.pdf)

    /// Applies an outline matching the example template's die line (11 lines, 1 arc) and
    /// writes the cut, cropped template for spikes/s10_crop.py when VE_CROP_OUT names a
    /// folder. The pixel probes are measured on the example template (stepped left edge at
    /// x 36 / 96 / 150, semicircular right end). VE_TEMPLATE_PDF points the test at a copy of
    /// your own template instead (never the original); the outline and probes then need
    /// adjusting. VE_TEMPLATE_IMAGE_FIELD names the image field that crosses the outline
    /// (default: product_image of the example, else the first image field).
    func testExampleTemplateCrop() throws {
        let env = ProcessInfo.processInfo.environment
        let path = env["VE_TEMPLATE_PDF"] ?? MuPDFEngineTests.fixtures.appendingPathComponent("example_voucher_template.pdf").path
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path), "no template at \(path)")
        let engine = try MuPDFEngine(data: data)
        let t0 = try engine.readTemplate().template
        XCTAssertFalse(t0.fields.isEmpty)
        var t1 = t0
        t1.outlines[0] = Self.exampleOutline
        let s1 = try engine.save(baseline: t0, edited: t1)
        let imageName = env["VE_TEMPLATE_IMAGE_FIELD"] ?? (env["VE_TEMPLATE_PDF"] == nil ? "product_image" : nil)
        let image = try XCTUnwrap(t0.fields.first { $0.kind == .image && (imageName == nil || $0.name == imageName) })
        let num = try XCTUnwrap(engine.objectNumbers[image.id])
        XCTAssertTrue(try isWrapper(s1.data, num).wrapped, "\(s1.summary)")
        let g = try pdfkitGray(s1.data, [PDFPoint(25, 300), PDFPoint(60, 150), PDFPoint(200, 300)])
        XCTAssertEqual(g[0], 255, "left of the steps: blank")
        XCTAssertEqual(g[1], 255, "left of the second step: blank")
        XCTAssertLessThan(g[2], 200, "inside: the artwork shows through the image slot")
        XCTAssertGreaterThan(g[2], 60, "inside: the artwork shows through the image slot")
        var t2 = t1
        t2.outlines[0] = nil
        let s2 = try engine.save(baseline: t1, edited: t2)
        let a = try MuPDFDocument(data: data), b = try MuPDFDocument(data: s2.data)
        let pa = try a.pageObjectNumber(0), pb = try b.pageObjectNumber(0)
        XCTAssertEqual(try b.get(pb, "Contents"), try a.get(pa, "Contents"))
        XCTAssertEqual(try b.objectSyntax(try XCTUnwrap(try b.get(pb, "Annots").refNumber)),
                       try a.objectSyntax(try XCTUnwrap(try a.get(pa, "Annots").refNumber)))
        XCTAssertEqual(try b.get(num, "AP"), try a.get(num, "AP"))
        if let dir = env["VE_CROP_OUT"] {
            try s1.data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("swift_example_cut_crop.pdf"))
            try s2.data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("swift_example_removed.pdf"))
            let e2 = try MuPDFEngine(data: data)
            let r0 = try e2.readTemplate().template
            var o1 = r0
            o1.outlines[0] = Self.exampleOutline
            o1.cropFieldsToOutline = false
            try e2.save(baseline: r0, edited: o1).data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("swift_example_cut_nocrop.pdf"))
        }
    }

    /// The example template's die line (what the smart outline finds on its page 1).
    static let exampleOutline = Outline(start: PDFPoint(150, 70), segments: [
        .line(to: PDFPoint(150, 126)), .line(to: PDFPoint(96, 126)), .line(to: PDFPoint(96, 182)),
        .line(to: PDFPoint(36, 182)), .line(to: PDFPoint(36, 418)), .line(to: PDFPoint(96, 418)),
        .line(to: PDFPoint(96, 474)), .line(to: PDFPoint(150, 474)), .line(to: PDFPoint(150, 525)),
        .line(to: PDFPoint(590, 525)),
        .arc(to: PDFPoint(590, 70), center: PDFPoint(590, 297.5), clockwise: true),
        .line(to: PDFPoint(150, 70)),
    ])
}

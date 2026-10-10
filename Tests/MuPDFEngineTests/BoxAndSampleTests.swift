import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MuPDFEngine
import PDFEngine
import VoucherModel

/// Regression tests for "border, background and sample are invisible on my voucher":
/// the inspector's box properties must reach /MK, /BS and the stored /AP /N, the
/// appearance must be drawable by PDFKit (it needs /Resources), a field that already has
/// an indirect /MK with a white /BG must take the new background, samples stay out of the
/// saved file, and the Preview build carries the sample image placed with the field's /IF.
final class BoxAndSampleTests: XCTestCase {
    func fixture() throws -> Data {
        try Data(contentsOf: MuPDFEngineTests.fixtures.appendingPathComponent("synthetic_voucher.pdf"))
    }

    /// The widget's /AP /N: its dictionary and decoded content.
    func appearance(_ data: Data, _ num: Int) throws -> (dict: PDFValue, content: String) {
        let doc = try MuPDFDocument(data: data)
        let ref = try XCTUnwrap(try doc.get(num, "AP/N").refNumber, "no /AP /N on \(num)")
        return (try doc.object(ref), String(decoding: try doc.streamData(ref), as: UTF8.self))
    }

    func value(_ data: Data, _ num: Int, _ path: String) throws -> PDFValue {
        let doc = try MuPDFDocument(data: data)
        return try doc.resolve(try doc.get(num, path))
    }

    /// Saves `edit` applied to the field named `name` and returns the new bytes.
    func saveEditing(_ engine: MuPDFEngine, _ base: inout Template, _ name: String, _ edit: (inout FieldDef) -> Void) throws -> SaveResult {
        var edited = base
        let i = try XCTUnwrap(edited.fields.firstIndex { $0.name == name })
        edit(&edited.fields[i])
        let r = try engine.save(baseline: base, edited: edited)
        base = edited
        return r
    }

    func testBorderAndBackgroundReachMKBSAndAppearance() throws {
        let engine = try MuPDFEngine(data: try fixture())
        var base = try engine.readTemplate().template
        var edited = base
        edited.fields = [FieldDef(kind: .text, name: "name", page: 0, rect: PDFRect(x: 400, y: 300, width: 200, height: 40)),
                         FieldDef(kind: .image, name: "photo", page: 0, rect: PDFRect(x: 100, y: 300, width: 200, height: 150))]
        _ = try engine.save(baseline: base, edited: edited)
        base = edited
        let textNum = try XCTUnwrap(engine.objectNumbers[edited.fields[0].id])
        let imageNum = try XCTUnwrap(engine.objectNumbers[edited.fields[1].id])

        // Text field: change only the box properties.
        var r = try saveEditing(engine, &base, "name") {
            $0.text.borderColor = RGBColor(1, 0, 0); $0.text.borderWidth = 3; $0.text.backgroundColor = RGBColor(1, 1, 0)
        }
        XCTAssertEqual(try value(r.data, textNum, "MK/BC").numbers, [1, 0, 0])
        XCTAssertEqual(try value(r.data, textNum, "MK/BG").numbers, [1, 1, 0])
        XCTAssertEqual(try value(r.data, textNum, "BS/W").number, 3)
        var ap = try appearance(r.data, textNum)
        XCTAssertTrue(ap.content.contains("1 1 0 rg 0 0 200 40 re f"), ap.content)
        XCTAssertTrue(ap.content.contains("1 0 0 RG 3 w 1.5 1.5 197 37 re S"), ap.content)
        // PDFKit skips a form XObject without /Resources: that made an empty field's box invisible.
        XCTAssertFalse(ap.dict["Resources"].isNull, "appearance needs /Resources for PDFKit")

        // Image field: background, border colour and width.
        r = try saveEditing(engine, &base, "photo") {
            $0.image.borderColor = RGBColor(0, 0, 1); $0.image.borderWidth = 2; $0.image.backgroundColor = RGBColor(0, 1, 0)
        }
        XCTAssertEqual(try value(r.data, imageNum, "MK/BC").numbers, [0, 0, 1])
        XCTAssertEqual(try value(r.data, imageNum, "MK/BG").numbers, [0, 1, 0])
        XCTAssertEqual(try value(r.data, imageNum, "BS/W").number, 2)
        XCTAssertEqual(try value(r.data, imageNum, "BS/S").name, "D")
        ap = try appearance(r.data, imageNum)
        XCTAssertTrue(ap.content.contains("0 1 0 rg 0 0 200 150 re f"), ap.content)
        XCTAssertTrue(ap.content.contains("0 0 1 RG 2 w [6 4] 0 d 1 1 198 148 re S"), ap.content)

        // "No colour" removes the key and the drawing.
        r = try saveEditing(engine, &base, "name") { $0.text.borderColor = nil; $0.text.backgroundColor = nil }
        XCTAssertTrue(try value(r.data, textNum, "MK/BC").isNull)
        XCTAssertTrue(try value(r.data, textNum, "MK/BG").isNull)
        XCTAssertEqual(try value(r.data, textNum, "BS/W").number, 0)
        ap = try appearance(r.data, textNum)
        XCTAssertFalse(ap.content.contains(" re f"), ap.content)
        XCTAssertFalse(ap.content.contains(" RG "), ap.content)
        XCTAssertFalse(ap.dict["Resources"].isNull)

        // Read back.
        let back = try MuPDFEngine(data: r.data).readTemplate().template
        let photo = try XCTUnwrap(back.fields.first { $0.name == "photo" })
        XCTAssertEqual(photo.image.backgroundColor, RGBColor(0, 1, 0))
        XCTAssertEqual(photo.image.borderColor, RGBColor(0, 0, 1))
        XCTAssertEqual(photo.image.borderWidth, 2)
        let name = try XCTUnwrap(back.fields.first { $0.name == "name" })
        XCTAssertNil(name.text.backgroundColor)
        XCTAssertNil(name.text.borderColor)
    }

    /// An existing image button (as exported by Acrobat/InDesign) with an indirect /MK that
    /// holds a white /BG and a grey /BC, no /CA and no /BS.
    func makeIndirectMKFixture() throws -> (data: Data, num: Int, mk: Int) {
        let doc = try MuPDFDocument(data: try fixture())
        let page = try doc.pageObjectNumber(0)
        let mk = try doc.newObject(.dict([
            "BG": .numbers([1, 1, 1]), "BC": .numbers([0.75]), "TP": .int(1),
            "IF": .dict(["SW": .name("A"), "S": .name("A"), "A": .numbers([0.5, 0.5])]),
        ]))
        let old = try doc.newStream(dict: .dict(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .numbers([0, 0, 200, 100])]),
                                    data: Data("q 1 g 0 0 200 100 re f Q\n".utf8))
        let w = try doc.newObject(.dict([
            "Type": .name("Annot"), "Subtype": .name("Widget"), "FT": .name("Btn"), "Ff": .int(65536),
            "T": .text("logo_af_image"), "Rect": .numbers([100, 100, 300, 200]), "MK": .ref(mk, 0),
            "AP": .dict(["N": .ref(old, 0)]), "P": .ref(page, 0), "F": .int(4),
        ]))
        try doc.set(page, "Annots", .array([.ref(w, 0)]))
        let acro = try doc.newObject(.dict(["Fields": .array([.ref(w, 0)])]))
        try doc.set(try doc.catalogObjectNumber(), "AcroForm", .ref(acro, 0))
        return (try doc.write(incremental: true), w, mk)
    }

    func testIndirectMKWhiteBackgroundIsReplaced() throws {
        let fx = try makeIndirectMKFixture()
        let engine = try MuPDFEngine(data: fx.data)
        var base = try engine.readTemplate().template
        let read = try XCTUnwrap(base.fields.first)
        XCTAssertEqual(read.kind, .image)
        XCTAssertEqual(read.image.backgroundColor, RGBColor.white)
        XCTAssertEqual(read.image.label, "", "an existing field without /CA has no label (none is added on edit)")

        let r = try saveEditing(engine, &base, "logo_af_image") { $0.image.backgroundColor = RGBColor(1, 0, 0); $0.image.borderWidth = 3 }
        XCTAssertEqual(r.data.prefix(fx.data.count), fx.data)
        // /MK is still the same indirect object, now with the new /BG; other keys kept.
        let doc = try MuPDFDocument(data: r.data)
        XCTAssertEqual(try doc.get(fx.num, "MK").refNumber, fx.mk)
        XCTAssertEqual(try doc.get(fx.mk, "BG").numbers, [1, 0, 0])
        XCTAssertEqual(try doc.get(fx.mk, "BC").numbers, [0.75])
        XCTAssertEqual(try doc.get(fx.mk, "IF/S").name, "A")
        XCTAssertEqual(try value(r.data, fx.num, "BS/W").number, 3)
        let ap = try appearance(r.data, fx.num)
        XCTAssertTrue(ap.content.hasPrefix("q 1 0 0 rg 0 0 200 100 re f Q"), ap.content)
        XCTAssertFalse(ap.content.contains("1 1 1 rg"), ap.content)
        XCTAssertFalse(ap.content.contains("Tj"), "no label drawn: \(ap.content)")
        let back = try MuPDFEngine(data: r.data).readTemplate().template.fields[0]
        XCTAssertEqual(back.image.backgroundColor, RGBColor(1, 0, 0))
    }

    /// A PNG of `w` x `h` pixels, solid magenta, at 72 dpi.
    static func writePNG(_ w: Int, _ h: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ve-sample-\(UUID().uuidString).png")
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testSamplesAreNeverSavedButPreviewShowsSampleImageWithFit() throws {
        let png = try Self.writePNG(100, 50)
        defer { try? FileManager.default.removeItem(at: png) }
        let engine = try MuPDFEngine(data: try fixture())
        var base = try engine.readTemplate().template
        var edited = base
        var photo = FieldDef(kind: .image, name: "photo", page: 0, rect: PDFRect(x: 100, y: 300, width: 200, height: 200))
        photo.image.borderColor = nil // icon box = whole widget
        edited.fields = [photo, FieldDef(kind: .text, name: "name", page: 0, rect: PDFRect(x: 400, y: 300, width: 200, height: 40))]
        _ = try engine.save(baseline: base, edited: edited)
        base = edited
        let imageNum = try XCTUnwrap(engine.objectNumbers[photo.id])

        // Changing only the samples is not a change to the saved file.
        var withSamples = base
        withSamples.fields[0].image.sampleImagePath = png.path
        withSamples.fields[1].text.sampleValue = "Ana Maria"
        let r = try engine.save(baseline: base, edited: withSamples)
        XCTAssertTrue(r.summary.isEmpty, "\(r.summary)")
        XCTAssertTrue(try value(r.data, imageNum, "MK/I").isNull)
        base = withSamples

        // Preview: /MK /I plus an appearance that draws it, proportional and centred
        // (100x50 pt into 200x200 -> 200x100 at y 50).
        let preview = try engine.previewData(baseline: base, edited: base)
        let icon = try value(preview, imageNum, "MK/I")
        XCTAssertEqual(icon["Subtype"].name, "Form")
        var ap = try appearance(preview, imageNum)
        XCTAssertTrue(ap.content.contains("2 0 0 2 0 50 cm /Icon Do"), ap.content)
        XCTAssertFalse(ap.dict["Resources"]["XObject"]["Icon"].isNull)
        // The pixels arrive: opaque magenta, so no /SMask.
        let pdoc = try MuPDFDocument(data: preview)
        let imgRef = try XCTUnwrap(try pdoc.get(try XCTUnwrap(try pdoc.get(imageNum, "MK/I").refNumber), "Resources/XObject/Img").refNumber)
        XCTAssertTrue(try pdoc.get(imgRef, "SMask").isNull)
        XCTAssertEqual(Array(try pdoc.streamData(imgRef).prefix(3)), [255, 0, 255])

        // Top-right alignment, never scale: natural size at the top-right corner.
        var fit = base
        fit.fields[0].image.scaleWhen = .never
        fit.fields[0].image.alignX = 1
        fit.fields[0].image.alignY = 1
        ap = try appearance(try engine.previewData(baseline: base, edited: fit), imageNum)
        XCTAssertTrue(ap.content.contains("1 0 0 1 100 150 cm /Icon Do"), ap.content)
        // Stretch fills the box.
        fit.fields[0].image.scaleWhen = .always
        fit.fields[0].image.scaleHow = .stretch
        ap = try appearance(try engine.previewData(baseline: base, edited: fit), imageNum)
        XCTAssertTrue(ap.content.contains("2 0 0 4 0 0 cm /Icon Do"), ap.content)

        // The engine's own bytes are untouched by previews.
        XCTAssertTrue(try value(engine.currentData, imageNum, "MK/I").isNull)
    }
}

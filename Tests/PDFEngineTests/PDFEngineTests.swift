import XCTest
@testable import PDFEngine
import VoucherModel

final class PDFValueTests: XCTestCase {
    func testParseMuPDFSyntax() throws {
        let v = try PDFParser.parse("<</Type/Annot/Rect[422 377 778 413.5]/T(recipient\\(1\\))/P 5 0 R/F 4/MK<</BG[1]/IF<</SW/A/FB false>>>>/N#20x null>>")
        XCTAssertEqual(v["Type"], .name("Annot"))
        XCTAssertEqual(v["Rect"].numbers, [422, 377, 778, 413.5])
        XCTAssertEqual(v["T"].text, "recipient(1)")
        XCTAssertEqual(v["P"], .ref(5, 0))
        XCTAssertEqual(v["F"], .int(4))
        XCTAssertEqual(v["MK"]["IF"]["FB"], .bool(false))
        XCTAssertEqual(v["N x"], .null)
        XCTAssertEqual(try PDFParser.parse("[1 0 R 2 0 R 3]"), .array([.ref(1, 0), .ref(2, 0), .int(3)]))
        XCTAssertEqual(try PDFParser.parse("12 0 R"), .ref(12, 0))
        XCTAssertEqual(try PDFParser.parse("-.5"), .real(-0.5))
    }

    func testStringsAndEscapes() throws {
        XCTAssertEqual(try PDFParser.parse("(a\\nb\\051\\\\)").stringData, Data("a\nb)\\".utf8))
        XCTAssertEqual(try PDFParser.parse("<FEFF021A0061>").text, "Ța")
        XCTAssertEqual(try PDFParser.parse("<48656C6C6F>").text, "Hello")
        XCTAssertEqual(try PDFParser.parse("(\\222)").text, "™", "PDFDocEncoding 0x92")
        XCTAssertEqual(PDFValue.text("Țară").syntax, "<FEFF021A006100720103>")
        XCTAssertEqual(PDFValue.text("plain (x)").syntax, "(plain \\(x\\))")
        // Round trip
        for s in ["", "abc", "Ștefan ăâî ȘȚ", "a\\b(c)"] {
            XCTAssertEqual(try PDFParser.parse(PDFValue.text(s).syntax).text, s)
        }
    }

    func testSerialisationRoundTrip() throws {
        let v: PDFValue = .dict(["A": .array([.real(1.5), .int(2), .name("N a"), .ref(7, 0)]), "B": .bool(true), "C": .null])
        XCTAssertEqual(try PDFParser.parse(v.syntax), v)
        XCTAssertEqual(PDFValue.name("a/b").syntax, "/a#2Fb")
    }
}

final class ContentScannerTests: XCTestCase {
    func bal(_ s: String) -> (Int, Int) {
        let b = ContentScanner.qBalance(Data(s.utf8))
        return (b.minDepth, b.finalDepth)
    }

    func testBalance() {
        XCTAssert(bal("q 1 0 0 1 0 0 cm Q") == (0, 0))
        XCTAssert(bal("q q Q Q Q") == (-1, -1))
        XCTAssert(bal("q (a Q b) Tj Q") == (0, 0), "Q inside a string")
        XCTAssert(bal("q % Q in a comment\nQ") == (0, 0))
        XCTAssert(bal("q /Q gs Q") == (0, 0), "/Q is a name")
        XCTAssert(bal("q <51> Tj Q") == (0, 0))
        XCTAssert(bal("q BI /W 1 /H 1 ID \u{0}Q\u{1} EI Q") == (0, 0), "inline image data")
        XCTAssert(bal("q q Q") == (0, 1), "unclosed q")
        XCTAssert(bal("q (nested (paren Q) still) Tj Q") == (0, 0))
        XCTAssert(bal("q (esc \\) Q) Tj Q") == (0, 0))
        XCTAssertFalse(ContentScanner.isBalanced(Data("Q q".utf8)))
    }
}

final class CutCodecTests: XCTestCase {
    func testSegmentsRoundTripAndRecovery() throws {
        let o = Outline(start: PDFPoint(564.5, 545), segments: [
            .line(to: PDFPoint(40, 545)), .line(to: PDFPoint(40, 50)), .line(to: PDFPoint(564.5, 50)),
            .arc(to: PDFPoint(564.5, 545), center: PDFPoint(564.5, 297.5), clockwise: false),
        ])
        let start = try PDFParser.parse(CutCodec.startValue(o).syntax)
        let segs = try PDFParser.parse(CutCodec.segmentsValue(o).syntax)
        XCTAssertEqual(CutCodec.outline(start: start, segments: segs), o)
        XCTAssertTrue(CutCodec.segmentsValue(o).syntax.contains("/A 564.5 545 564.5 297.5 /CCW"))

        // Marker recovery: lines exact, the arc as cubics ending at the same point.
        let rec = try XCTUnwrap(CutCodec.outline(fromStartStream: CutCodec.wrapStartStream(o)))
        XCTAssertEqual(rec.start, o.start)
        XCTAssertEqual(Array(rec.segments.prefix(3)), Array(o.segments.prefix(3)))
        XCTAssertEqual(rec.segments.count, 3 + 2)
        XCTAssertEqual(rec.segments.last?.end, PDFPoint(564.5, 545))
        XCTAssertTrue(String(decoding: CutCodec.endStream, as: UTF8.self).hasSuffix("Q\nQ\n"))
        XCTAssertTrue(String(decoding: CutCodec.xobjectStartStream(o), as: UTF8.self).contains("W n\n/VEOrig Do\nQ"))
    }
}

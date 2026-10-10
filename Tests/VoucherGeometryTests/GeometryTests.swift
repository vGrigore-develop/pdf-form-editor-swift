import XCTest
@testable import VoucherGeometry
import VoucherModel

final class GeometryTests: XCTestCase {
    /// The S5 reference shape: stepped left edge, semicircular right end (11 lines + 1 arc).
    static let reference = Outline(start: PDFPoint(564.5, 545), segments: [
        .line(to: PDFPoint(40, 545)), .line(to: PDFPoint(40, 460)), .line(to: PDFPoint(60, 460)),
        .line(to: PDFPoint(60, 380)), .line(to: PDFPoint(80, 380)), .line(to: PDFPoint(80, 215)),
        .line(to: PDFPoint(60, 215)), .line(to: PDFPoint(60, 135)), .line(to: PDFPoint(40, 135)),
        .line(to: PDFPoint(40, 50)), .line(to: PDFPoint(564.5, 50)),
        .arc(to: PDFPoint(564.5, 545), center: PDFPoint(564.5, 297.5), clockwise: false),
    ])

    func testArcToBezierErrorBound() {
        // SPEC 5.1 / spike S5 finding 10: max radial error < 0.03 % of r for <= 90 degree pieces.
        let c = PDFPoint(0, 0), r = 100.0
        for (cw, sweepEnd) in [(false, PDFPoint(-r, 0)), (true, PDFPoint(0, -r)), (false, PDFPoint(0, -r))] {
            let cubics = Geometry.arcToBeziers(from: PDFPoint(r, 0), to: sweepEnd, center: c, clockwise: cw)
            var cur = PDFPoint(r, 0)
            var maxErr = 0.0
            for b in cubics {
                for i in 0...50 {
                    let t = Double(i) / 50, mt = 1 - t
                    let x = mt * mt * mt * cur.x + 3 * mt * mt * t * b.c1.x + 3 * mt * t * t * b.c2.x + t * t * t * b.to.x
                    let y = mt * mt * mt * cur.y + 3 * mt * mt * t * b.c1.y + 3 * mt * t * t * b.c2.y + t * t * t * b.to.y
                    maxErr = max(maxErr, abs(hypot(x, y) - r))
                }
                cur = b.to
            }
            XCTAssertLessThan(maxErr / r, 3e-4)
            XCTAssertEqual(cubics.last!.to, sweepEnd)
        }
        // A semicircle is two pieces; three quarters is three.
        XCTAssertEqual(Geometry.arcToBeziers(from: PDFPoint(r, 0), to: PDFPoint(-r, 0), center: c, clockwise: false).count, 2)
        XCTAssertEqual(Geometry.arcToBeziers(from: PDFPoint(r, 0), to: PDFPoint(0, -r), center: c, clockwise: false).count, 3)
    }

    func testReferenceShapeIsValid() {
        XCTAssertEqual(Geometry.validate(Self.reference), [])
        XCTAssertEqual(Self.reference.counts.lines, 11)
        XCTAssertEqual(Self.reference.counts.arcs, 1)
        XCTAssertGreaterThan(Geometry.signedArea(Self.reference), 0, "reference runs counter-clockwise")
        let bb = Geometry.boundingBox(Self.reference)
        XCTAssertEqual(bb.minX, 40, accuracy: 1e-9)
        XCTAssertEqual(bb.maxX, 564.5 + 247.5, accuracy: 0.01)
        XCTAssertEqual(bb.minY, 50, accuracy: 1e-9)
        XCTAssertEqual(bb.maxY, 545, accuracy: 1e-9)
    }

    func testValidationProblems() {
        var open = Outline.rectangle(PDFRect(x: 0, y: 0, width: 10, height: 10))
        open.segments.removeLast()
        open.segments.append(.line(to: PDFPoint(0, 2)))
        XCTAssertTrue(Geometry.validate(open).contains { if case .notClosed = $0 { return true } else { return false } })

        let bowtie = Outline(start: PDFPoint(0, 0), segments: [
            .line(to: PDFPoint(10, 10)), .line(to: PDFPoint(10, 0)), .line(to: PDFPoint(0, 10)), .line(to: PDFPoint(0, 0)),
        ])
        XCTAssertTrue(Geometry.validate(bowtie).contains { if case .selfIntersection = $0 { return true } else { return false } })

        let badArc = Outline(start: PDFPoint(0, 0), segments: [
            .line(to: PDFPoint(10, 0)), .arc(to: PDFPoint(0, 0), center: PDFPoint(6, 3), clockwise: false),
        ])
        XCTAssertTrue(Geometry.validate(badArc).contains { if case .arcRadiusMismatch = $0 { return true } else { return false } })
        XCTAssertEqual(Geometry.validate(Outline(start: PDFPoint(0, 0), segments: [.line(to: PDFPoint(1, 1))])), [.tooFewSegments])
    }

    func testContainment() {
        let o = Self.reference
        XCTAssertTrue(Geometry.contains(o, PDFPoint(300, 300)))
        XCTAssertFalse(Geometry.contains(o, PDFPoint(50, 300)), "inside the left notch is outside the shape")
        XCTAssertFalse(Geometry.contains(o, PDFPoint(830, 300)))
        XCTAssertTrue(Geometry.contains(o, PDFPoint(800, 297.5)))
        // S1 field rects are inside the reference outline.
        XCTAssertEqual(Geometry.containment(of: PDFRect(x1: 422, y1: 377, x2: 778, y2: 413), in: o), .inside)
        XCTAssertEqual(Geometry.containment(of: PDFRect(x1: 110, y1: 295, x2: 350, y2: 455), in: o), .inside)
        // Crossing the arc, crossing a step, and fully outside.
        XCTAssertEqual(Geometry.containment(of: PDFRect(x: 780, y: 280, width: 60, height: 30), in: o), .partial)
        XCTAssertEqual(Geometry.containment(of: PDFRect(x: 50, y: 250, width: 60, height: 30), in: o), .partial)
        XCTAssertEqual(Geometry.containment(of: PDFRect(x: 0, y: 0, width: 30, height: 30), in: o), .outside)
        // A rect that straddles a notch corner without any sampled corner outside still counts as partial.
        XCTAssertEqual(Geometry.containment(of: PDFRect(x: 55, y: 370, width: 40, height: 20), in: o), .partial)
    }

    func testInsertRemovePointAndRecenter() {
        let r = Outline.rectangle(PDFRect(x: 0, y: 0, width: 10, height: 10))
        let ins = Geometry.insertPoint(in: r, segment: 0)
        XCTAssertEqual(ins.segments.count, 5)
        XCTAssertEqual(ins.segments[0].end, PDFPoint(5, 0))
        XCTAssertEqual(Geometry.removePoint(in: ins, vertex: 1), r)

        // Moving an arc end keeps the centre on the perpendicular bisector.
        let c = Geometry.recenterArc(from: PDFPoint(0, 0), to: PDFPoint(10, 0), oldCenter: PDFPoint(4, 3))
        XCTAssertEqual(c.x, 5, accuracy: 1e-9)
        XCTAssertEqual(c.y, 3, accuracy: 1e-9)
        XCTAssertEqual(PDFPoint(0, 0).distance(to: c), PDFPoint(10, 0).distance(to: c), accuracy: 1e-9)

        let arcOutline = Self.reference
        let split = Geometry.insertPoint(in: arcOutline, segment: 11)
        XCTAssertEqual(split.segments.count, 13)
        XCTAssertEqual(split.segments[11].end.x, 564.5 + 247.5, accuracy: 1e-6, "midpoint of the right semicircle")
        XCTAssertEqual(Geometry.validate(split), [])
    }

    func testNearestSegment() {
        let o = Self.reference
        XCTAssertEqual(Geometry.nearestSegment(o, to: PDFPoint(300, 548))?.index, 0)
        XCTAssertEqual(Geometry.nearestSegment(o, to: PDFPoint(815, 297))?.index, 11)
    }
}

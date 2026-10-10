import XCTest
@testable import VoucherGeometry
import VoucherModel

final class SnappingTests: XCTestCase {
    let page = PDFRect(x: 0, y: 0, width: 600, height: 800)

    func targets(fields: [PDFRect] = [], outline: PDFRect? = nil) -> Snapping.Targets {
        .build(page: page, fields: fields, outlineBounds: outline)
    }

    func testMoveSnapsLeftEdgeToFieldEdge() {
        let other = PDFRect(x: 200, y: 300, width: 100, height: 40)
        let moving = PDFRect(x: 197.5, y: 100, width: 60, height: 20)
        let r = Snapping.snapMove(rect: moving, targets: targets(fields: [other]), threshold: 6, grid: nil)
        XCTAssertEqual(r.dx, 2.5, accuracy: 1e-9)
        XCTAssertEqual(r.dy, 0, accuracy: 1e-9)
        XCTAssertEqual(r.guides, [.init(axis: .x, position: 200, from: 100, to: 340)])
    }

    func testMoveSnapsCentreAndPicksNearestCandidate() {
        let other = PDFRect(x: 100, y: 500, width: 200, height: 40) // centre x = 200
        let moving = PDFRect(x: 172, y: 100, width: 60, height: 20) // centre x = 202; right 232
        let r = Snapping.snapMove(rect: moving, targets: targets(fields: [other]), threshold: 6, grid: nil)
        XCTAssertEqual(r.dx, -2, accuracy: 1e-9, "centre to centre")
        XCTAssertEqual(r.xMatch?.value, 200)
    }

    func testBothAxesAndPageTargets() {
        let moving = PDFRect(x: 3, y: 779, width: 50, height: 17) // left near page minX 0, top near 800 -> maxY 796
        let r = Snapping.snapMove(rect: moving, targets: targets(), threshold: 6, grid: nil)
        XCTAssertEqual(r.dx, -3, accuracy: 1e-9)
        XCTAssertEqual(r.dy, 4, accuracy: 1e-9)
        XCTAssertEqual(r.guides.count, 2)
    }

    func testPageCentre() {
        let moving = PDFRect(x: 270, y: 100, width: 60, height: 20) // centre 300 exactly
        let r = Snapping.snapMove(rect: moving, targets: targets(), threshold: 6, grid: nil)
        XCTAssertEqual(r.dx, 0, accuracy: 1e-9)
        XCTAssertEqual(r.xMatch?.value, 300)
    }

    func testOutsideThresholdDoesNotSnap() {
        let other = PDFRect(x: 200, y: 300, width: 100, height: 40)
        let moving = PDFRect(x: 180, y: 100.4, width: 60, height: 20)
        let r = Snapping.snapMove(rect: moving, targets: targets(fields: [other]), threshold: 6, grid: nil)
        XCTAssertEqual(r.dx, 0)
        XCTAssertNil(r.xMatch)
        XCTAssertEqual(r.dy, 0)
        XCTAssertTrue(r.guides.isEmpty)
    }

    func testGridWhenNoTargetAndTargetsWinOverGrid() {
        let moving = PDFRect(x: 53.4, y: 101.7, width: 60, height: 20)
        let g = Snapping.snapMove(rect: moving, targets: targets(), threshold: 6, grid: 10)
        XCTAssertEqual(g.dx, -3.4, accuracy: 1e-9)
        XCTAssertEqual(g.dy, -1.7, accuracy: 1e-9)
        XCTAssertTrue(g.guides.isEmpty, "the grid draws no guide")
        // A field edge at x=56 is within threshold, so it beats the grid line at 50.
        let other = PDFRect(x: 56, y: 400, width: 30, height: 30)
        let t = Snapping.snapMove(rect: moving, targets: targets(fields: [other]), threshold: 6, grid: 10)
        XCTAssertEqual(t.dx, 2.6, accuracy: 1e-9)
        XCTAssertEqual(t.xMatch?.value, 56)
        XCTAssertEqual(t.dy, -1.7, accuracy: 1e-9, "y still on the grid")
    }

    func testThresholdFollowsZoom() {
        // 6 screen pixels: 6 pt at 100 %, 1.5 pt at 400 %, 12 pt at 50 %.
        let outline = PDFRect(x: 40, y: 50, width: 520, height: 700)
        let t = targets(outline: outline)
        let near = PDFRect(x: 45, y: 200, width: 60, height: 20)
        XCTAssertEqual(Snapping.snapMove(rect: near, targets: t, threshold: 6 / 1, grid: nil).dx, -5, accuracy: 1e-9)
        XCTAssertEqual(Snapping.snapMove(rect: near, targets: t, threshold: 6 / 4, grid: nil).dx, 0)
        let far = PDFRect(x: 28, y: 200, width: 60, height: 20) // 12 pt from x = 40, no other candidate close
        XCTAssertEqual(Snapping.snapMove(rect: far, targets: t, threshold: 6 / 1, grid: nil).dx, 0)
        XCTAssertEqual(Snapping.snapMove(rect: far, targets: t, threshold: 6 / 0.5, grid: nil).dx, 12, accuracy: 1e-9)
    }

    func testOutlineBoundsAreTargets() {
        let outline = PDFRect(x: 40, y: 50, width: 520, height: 700)
        let moving = PDFRect(x: 43, y: 200, width: 60, height: 20)
        let r = Snapping.snapMove(rect: moving, targets: targets(outline: outline), threshold: 6, grid: nil)
        XCTAssertEqual(r.dx, -3, accuracy: 1e-9)
        XCTAssertEqual(r.xMatch?.value, 40)
    }

    func testResizeSnapsOnlyTheDraggedEdge() {
        let other = PDFRect(x: 300, y: 500, width: 80, height: 40)
        let start = PDFRect(x: 100, y: 100, width: 100, height: 30)
        // Right handle (3) dragged to x=297: snaps to 300; y is not touched even if close to a target.
        let r = Snapping.snapResize(rect: start, handle: 3, point: PDFPoint(297, 502), targets: targets(fields: [other]), threshold: 6, grid: nil)
        XCTAssertEqual(r.dx, 3, accuracy: 1e-9)
        XCTAssertEqual(r.dy, 0)
        XCTAssertNil(r.yMatch)
        XCTAssertEqual(r.guides.count, 1)
        XCTAssertEqual(r.guides[0].axis, .x)
        XCTAssertEqual(r.guides[0].position, 300)
    }

    func testResizeCornerSnapsBothAxesAndGrid() {
        let start = PDFRect(x: 100, y: 100, width: 100, height: 30)
        let r = Snapping.snapResize(rect: start, handle: 4, point: PDFPoint(251.6, 161.2), targets: targets(), threshold: 6, grid: 5)
        XCTAssertEqual(r.dx, -1.6, accuracy: 1e-9)
        XCTAssertEqual(r.dy, -1.2, accuracy: 1e-9)
    }

    func testGuidesDroppedWhenClampMovedTheRect() {
        let other = PDFRect(x: 200, y: 300, width: 100, height: 40)
        let moving = PDFRect(x: 197, y: 100, width: 60, height: 20)
        let r = Snapping.snapMove(rect: moving, targets: targets(fields: [other]), threshold: 6, grid: nil)
        XCTAssertEqual(r.guides(for: moving.offsetBy(dx: 3, dy: 0)).count, 1)
        XCTAssertTrue(r.guides(for: moving.offsetBy(dx: 10, dy: 0)).isEmpty)
    }

    func testVisibleGridStep() {
        XCTAssertEqual(Snapping.visibleGridStep(grid: 1, scale: 1), 6)
        XCTAssertEqual(Snapping.visibleGridStep(grid: 10, scale: 1), 10)
        XCTAssertEqual(Snapping.visibleGridStep(grid: 5, scale: 4), 5)
    }
}

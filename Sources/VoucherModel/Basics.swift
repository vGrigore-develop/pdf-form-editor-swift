import Foundation

/// A point in PDF user space (points, origin bottom-left, y up).
public struct PDFPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public static func + (a: PDFPoint, b: PDFPoint) -> PDFPoint { PDFPoint(a.x + b.x, a.y + b.y) }
    public static func - (a: PDFPoint, b: PDFPoint) -> PDFPoint { PDFPoint(a.x - b.x, a.y - b.y) }
    public func distance(to p: PDFPoint) -> Double { hypot(x - p.x, y - p.y) }
}

/// A rectangle in PDF user space. Always normalised (width, height >= 0) when
/// built through `init(x1:y1:x2:y2:)`.
public struct PDFRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// From two corners in any order (normalises, as SPEC 6.1 requires for /Rect).
    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        x = min(x1, x2); y = min(y1, y2); width = abs(x2 - x1); height = abs(y2 - y1)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: PDFPoint { PDFPoint(midX, midY) }
    public var corners: [PDFPoint] {
        [PDFPoint(minX, minY), PDFPoint(maxX, minY), PDFPoint(maxX, maxY), PDFPoint(minX, maxY)]
    }

    public func contains(_ p: PDFPoint) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }

    /// True if `r` lies inside this rect, with `tolerance` slack.
    public func contains(_ r: PDFRect, tolerance: Double = 1e-6) -> Bool {
        r.minX >= minX - tolerance && r.minY >= minY - tolerance &&
            r.maxX <= maxX + tolerance && r.maxY <= maxY + tolerance
    }

    public func intersects(_ r: PDFRect) -> Bool {
        r.minX < maxX && r.maxX > minX && r.minY < maxY && r.maxY > minY
    }

    public func offsetBy(dx: Double, dy: Double) -> PDFRect {
        PDFRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// This rect moved (not resized) to lie inside `bounds` where possible.
    public func clamped(into bounds: PDFRect) -> PDFRect {
        var r = self
        r.width = min(r.width, bounds.width)
        r.height = min(r.height, bounds.height)
        r.x = min(max(r.x, bounds.minX), bounds.maxX - r.width)
        r.y = min(max(r.y, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// Rounded to a 0.01 pt grid, so stored /Rect values stay short and stable.
    public var rounded: PDFRect {
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        return PDFRect(x: r(x), y: r(y), width: r(width), height: r(height))
    }
}

public struct RGBColor: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public init(gray: Double) { self.init(gray, gray, gray) }

    public static let black = RGBColor(gray: 0)
    public static let white = RGBColor(gray: 1)
}

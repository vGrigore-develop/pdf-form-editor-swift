import Foundation

/// Resize handles, numbered counter-clockwise from the bottom-left corner in page
/// space: 0 BL, 1 bottom, 2 BR, 3 right, 4 TR, 5 top, 6 TL, 7 left.
public enum RectHandle {
    public static func point(_ r: PDFRect, _ h: Int) -> PDFPoint {
        switch h {
        case 0: return PDFPoint(r.minX, r.minY)
        case 1: return PDFPoint(r.midX, r.minY)
        case 2: return PDFPoint(r.maxX, r.minY)
        case 3: return PDFPoint(r.maxX, r.midY)
        case 4: return PDFPoint(r.maxX, r.maxY)
        case 5: return PDFPoint(r.midX, r.maxY)
        case 6: return PDFPoint(r.minX, r.maxY)
        default: return PDFPoint(r.minX, r.midY)
        }
    }

    public static func isCorner(_ h: Int) -> Bool { h % 2 == 0 }

    /// `r` with handle `h` dragged to `p` (SPEC 4: Shift keeps the aspect ratio,
    /// Option resizes from the centre). The result is normalised and at least `minSize`.
    public static func resize(_ r: PDFRect, handle h: Int, to p: PDFPoint, keepAspect: Bool = false,
                              fromCenter: Bool = false, minSize: Double = 4) -> PDFRect {
        let movesMinX = [0, 6, 7].contains(h), movesMaxX = [2, 3, 4].contains(h)
        let movesMinY = [0, 1, 2].contains(h), movesMaxY = [4, 5, 6].contains(h)
        var x1 = r.minX, x2 = r.maxX, y1 = r.minY, y2 = r.maxY
        if movesMinX { x1 = min(p.x, r.maxX - minSize) }
        if movesMaxX { x2 = max(p.x, r.minX + minSize) }
        if movesMinY { y1 = min(p.y, r.maxY - minSize) }
        if movesMaxY { y2 = max(p.y, r.minY + minSize) }
        if fromCenter {
            if movesMinX { x2 = r.maxX + (r.minX - x1) }
            if movesMaxX { x1 = r.minX - (x2 - r.maxX) }
            if movesMinY { y2 = r.maxY + (r.minY - y1) }
            if movesMaxY { y1 = r.minY - (y2 - r.maxY) }
        }
        var out = PDFRect(x1: x1, y1: y1, x2: x2, y2: y2)
        if keepAspect && isCorner(h) && r.height > 0 && r.width > 0 {
            let aspect = r.width / r.height
            // Follow the larger relative change, anchor the opposite corner (or the centre).
            let w = max(out.width, out.height * aspect)
            let hgt = w / aspect
            if fromCenter {
                out = PDFRect(x: r.midX - w / 2, y: r.midY - hgt / 2, width: w, height: hgt)
            } else {
                let ax = movesMinX ? r.maxX : r.minX
                let ay = movesMinY ? r.maxY : r.minY
                out = PDFRect(x1: ax, y1: ay, x2: movesMinX ? ax - w : ax + w, y2: movesMinY ? ay - hgt : ay + hgt)
            }
        }
        if out.width < minSize { out.width = minSize }
        if out.height < minSize { out.height = minSize }
        return out
    }
}

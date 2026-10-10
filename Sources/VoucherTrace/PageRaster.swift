import Foundation
import CoreGraphics
import VoucherModel

/// An RGBA raster of one page, in the page's own user space (no /Rotate applied), so
/// pixel <-> point conversion is a plain scale and offset and the overlay's PDFView
/// conversions handle rotation and the CropBox origin as for every other outline point.
///
/// Row 0 is the top of the page (largest y). Pixel (i, j) covers user-space
/// x in origin.x + [i, i+1] / scale and y in origin.y + [h - j - 1, h - j] / scale.
public struct PageRaster: Sendable {
    public let width: Int
    public let height: Int
    /// Pixels per point (dpi / 72).
    public let scale: Double
    /// User-space point at the bitmap's bottom-left corner.
    public let origin: PDFPoint
    /// RGBA8, premultiplied over white (so effectively opaque), row-major from the top.
    public let rgba: [UInt8]

    public init(width: Int, height: Int, scale: Double, origin: PDFPoint, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4)
        self.width = width; self.height = height; self.scale = scale; self.origin = origin; self.rgba = rgba
    }

    /// Continuous pixel coordinates (pixel centres at integers) of a user-space point.
    public func pixel(of p: PDFPoint) -> (x: Double, y: Double) {
        ((p.x - origin.x) * scale - 0.5, Double(height) - (p.y - origin.y) * scale - 0.5)
    }

    /// User-space point of continuous pixel coordinates (pixel centres at integers).
    public func point(x: Double, y: Double) -> PDFPoint {
        PDFPoint(origin.x + (x + 0.5) / scale, origin.y + (Double(height) - y - 0.5) / scale)
    }

    public func pointOfPixel(_ index: Int) -> PDFPoint {
        point(x: Double(index % width), y: Double(index / width))
    }

    /// Nearest pixel index to a user-space point, clamped into the raster.
    public func pixelIndex(of p: PDFPoint) -> Int {
        let (x, y) = pixel(of: p)
        let i = min(max(Int(x.rounded()), 0), width - 1), j = min(max(Int(y.rounded()), 0), height - 1)
        return j * width + i
    }

    public func contains(_ p: PDFPoint) -> Bool {
        let (x, y) = pixel(of: p)
        return x >= -0.5 && y >= -0.5 && x <= Double(width) - 0.5 && y <= Double(height) - 0.5
    }

    /// Render page `pageIndex` (0-based) of a PDF with CoreGraphics: page content only
    /// (CoreGraphics never draws annotations, so widgets do not show), over white, in
    /// user space (no /Rotate), covering `box` at `dpi`.
    ///
    /// The bytes passed in should be the page without a cut (the caller builds them),
    /// otherwise the clip hides the artwork outside the current outline.
    public static func render(pdfData: Data, pageIndex: Int, box: PDFRect, dpi: Double = 150) -> PageRaster? {
        guard let provider = CGDataProvider(data: pdfData as CFData), let doc = CGPDFDocument(provider),
              let page = doc.page(at: pageIndex + 1), box.width > 0, box.height > 0 else { return nil }
        let scale = dpi / 72
        let w = Int((box.width * scale).rounded(.up)), h = Int((box.height * scale).rounded(.up))
        guard w > 0, h > 0, w * h <= 40_000_000 else { return nil }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx.translateBy(x: CGFloat(-box.minX), y: CGFloat(-box.minY))
            // drawPDFPage draws in the page's default user space; it does not apply /Rotate
            // (that only happens through getDrawingTransform, which is not used here).
            ctx.drawPDFPage(page)
            return true
        }
        guard ok else { return nil }
        return PageRaster(width: w, height: h, scale: scale, origin: PDFPoint(box.minX, box.minY), rgba: bytes)
    }
}

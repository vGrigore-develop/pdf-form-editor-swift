import Foundation
import CoreGraphics
import ImageIO

/// A decoded Preview sample image (SPEC 7.2: "sample images as /MK /I plus appearance
/// using the field's /IF"). Pixels are 8-bit RGB plus an optional 8-bit alpha plane,
/// ready to become an image XObject and its /SMask. Only the Preview build uses it;
/// nothing here reaches a saved file.
public struct SampleImage: Sendable {
    /// Pixel size of the decoded planes (downscaled when the source is very large).
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Natural size in points (source pixels at the file's DPI, 72 when unknown):
    /// the icon size /IF scales from.
    public var pointWidth: Double
    public var pointHeight: Double
    public var rgb: Data
    /// nil when the image is fully opaque.
    public var alpha: Data?

    /// Longest side kept for the Preview copy; larger images are downscaled.
    public static let maxPixels = 1600

    public static func load(path: String) -> SampleImage? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpiX = (props?[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let dpiY = (props?[kCGImagePropertyDPIHeight] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        return from(image, pointWidth: Double(image.width) * 72 / dpiX, pointHeight: Double(image.height) * 72 / dpiY)
    }

    public static func from(_ image: CGImage, pointWidth: Double? = nil, pointHeight: Double? = nil) -> SampleImage? {
        let sw = image.width, sh = image.height
        guard sw > 0, sh > 0 else { return nil }
        let k = min(1, Double(maxPixels) / Double(max(sw, sh)))
        let w = max(1, Int((Double(sw) * k).rounded())), h = max(1, Int((Double(sh) * k).rounded()))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var rgb = Data(count: w * h * 3)
        var alpha = Data(count: w * h)
        var opaque = true
        rgb.withUnsafeMutableBytes { (c: UnsafeMutableRawBufferPointer) in
            alpha.withUnsafeMutableBytes { (a: UnsafeMutableRawBufferPointer) in
                for i in 0..<(w * h) {
                    let al = rgba[i * 4 + 3]
                    // Un-premultiply so the /SMask composites the true colour.
                    for ch in 0..<3 {
                        let v = rgba[i * 4 + ch]
                        c[i * 3 + ch] = al == 0 ? 0 : (al == 255 ? v : UInt8(min(255, Int(v) * 255 / Int(al))))
                    }
                    a[i] = al
                    if al != 255 { opaque = false }
                }
            }
        }
        return SampleImage(pixelWidth: w, pixelHeight: h,
                           pointWidth: pointWidth ?? Double(sw), pointHeight: pointHeight ?? Double(sh),
                           rgb: rgb, alpha: opaque ? nil : alpha)
    }
}

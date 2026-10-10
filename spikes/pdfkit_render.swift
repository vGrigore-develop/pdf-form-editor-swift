// Renders page 1 of a PDF with PDFKit (the engine behind macOS Preview and the app's
// Preview mode), annotations included, at an exact scale into a white RGB bitmap.
// Build once:  swiftc -O spikes/pdfkit_render.swift -o spikes/out/pdfkit_render
// Usage:       spikes/out/pdfkit_render <in.pdf> <out.png> [dpi=150]
import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])), let page = doc.page(at: 0) else {
    FileHandle.standardError.write(Data("usage: pdfkit_render in.pdf out.png [dpi]\n".utf8))
    exit(2)
}
let dpi = args.count > 3 ? Double(args[3]) ?? 150 : 150
let s = dpi / 72
let box = page.bounds(for: .mediaBox)
// Same pixel grid as MuPDF and common.render_pdfium: the size rounded up, an exact scale.
let w = Int((Double(box.width) * s - 1e-6).rounded(.up)), h = Int((Double(box.height) * s - 1e-6).rounded(.up))
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
// CoreGraphics is y-up like PDF: the page's bottom-left lands at the bitmap's bottom-left.
ctx.translateBy(x: 0, y: CGFloat(h) - box.height * s)
ctx.scaleBy(x: s, y: s)
page.displaysAnnotations = true
page.draw(with: .mediaBox, to: ctx)
let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)

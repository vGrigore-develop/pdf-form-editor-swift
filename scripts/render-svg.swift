// Renders an SVG to a square transparent PNG with AppKit, adding the soft drop shadow
// that AppKit's SVG renderer drops (it ignores SVG filters).
// Usage: render-svg <in.svg> <out.png> <pixels>
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]), let image = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: render-svg in.svg out.png pixels\n".utf8))
    exit(1)
}
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
let scale = CGFloat(size) / 1024

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.set()
rect.fill(using: .copy)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
shadow.shadowBlurRadius = 44 * scale
shadow.shadowOffset = NSSize(width: 0, height: -16 * scale)
shadow.set()
image.draw(in: rect)
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))

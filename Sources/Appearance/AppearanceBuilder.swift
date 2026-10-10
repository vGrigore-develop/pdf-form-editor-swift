import Foundation
import CoreText
import VoucherModel
import PDFEngine

/// Builds the `/AP /N` content for widgets the app writes (SPEC 7.7 step 4).
///
/// Text fields show only the background, the border and the default value (never
/// sample text, SPEC 6.1). Image fields show the placeholder: background, dashed
/// border and a label. Text is set in the base-14 Helvetica with WinAnsi encoding
/// (resource /Helv) until S2 settles the Noto Sans embedding; characters outside
/// WinAnsi are written as "?" in the stored appearance (the field value itself is
/// stored as a UTF-16 text string, so fillers still get the right characters).
public enum AppearanceBuilder {
    public struct Stream {
        public var content: Data
        public var usesFont: Bool
        public var bbox: PDFRect
    }

    public static let fontResourceName = "Helv"

    private static func f(_ v: Double) -> String { PDFNumber.format(v) }
    private static func rgb(_ c: RGBColor) -> String { "\(f(c.r)) \(f(c.g)) \(f(c.b))" }

    // MARK: Text metrics (Helvetica; macOS Helvetica shares the base-14 metrics)

    nonisolated(unsafe) private static let helvetica: CTFont = CTFontCreateWithName("Helvetica" as CFString, 1000, nil)

    /// Width of `s` in Helvetica at `size` points.
    public static func textWidth(_ s: String, size: Double) -> Double {
        let chars = Array(s.utf16)
        guard !chars.isEmpty else { return 0 }
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(helvetica, chars, &glyphs, chars.count)
        var advances = [CGSize](repeating: .zero, count: chars.count)
        let total = CTFontGetAdvancesForGlyphs(helvetica, .horizontal, glyphs, &advances, chars.count)
        return Double(total) / 1000 * size
    }

    /// WinAnsi bytes for the base-14 font, as a PDF literal string.
    public static func winAnsiLiteral(_ s: String) -> String {
        let data = s.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data(s.utf8)
        var out = "("
        for b in data {
            switch b {
            case 0x28: out += "\\("
            case 0x29: out += "\\)"
            case 0x5C: out += "\\\\"
            case 0x20..<0x7F: out.append(Character(Unicode.Scalar(b)))
            default: out += String(format: "\\%03o", b)
            }
        }
        return out + ")"
    }

    /// Effective size for display when the field uses auto size (0).
    public static func displaySize(_ field: FieldDef) -> Double {
        if field.text.fontSize > 0 { return field.text.fontSize }
        return max(4, min(12, (field.rect.height - 4) / 1.15))
    }

    // MARK: Text field

    public static func textField(_ field: FieldDef) -> Stream {
        let w = field.rect.width, h = field.rect.height
        let t = field.text
        var s = ""
        if let bg = t.backgroundColor { s += "q \(rgb(bg)) rg 0 0 \(f(w)) \(f(h)) re f Q\n" }
        if let bc = t.borderColor, t.borderWidth > 0 {
            let bw = t.borderWidth
            s += "q \(rgb(bc)) RG \(f(bw)) w \(f(bw / 2)) \(f(bw / 2)) \(f(w - bw)) \(f(h - bw)) re S Q\n"
        }
        s += "/Tx BMC\n"
        var usesFont = false
        let value = t.defaultValue
        if !value.isEmpty {
            usesFont = true
            let size = displaySize(field)
            let pad = 2 + t.borderWidth
            s += "q \(f(pad / 2)) \(f(pad / 2)) \(f(w - pad)) \(f(h - pad)) re W n\nBT /\(fontResourceName) \(f(size)) Tf \(rgb(t.color)) rg\n"
            if t.comb, let n = t.maxLength, n > 0 {
                let cell = w / Double(n)
                let baseline = (h - size * 0.718) / 2
                for (i, ch) in value.prefix(n).enumerated() {
                    let cw = textWidth(String(ch), size: size)
                    let x = cell * Double(i) + (cell - cw) / 2
                    s += "1 0 0 1 \(f(x)) \(f(baseline)) Tm \(winAnsiLiteral(String(ch))) Tj\n"
                }
            } else if t.multiline {
                let lineHeight = size * 1.15
                var y = h - pad - size * 0.77
                for line in wrap(value, width: w - 2 * pad, size: size) {
                    let x = alignedX(line, width: w, pad: pad, size: size, alignment: t.alignment)
                    s += "1 0 0 1 \(f(x)) \(f(y)) Tm \(winAnsiLiteral(line)) Tj\n"
                    y -= lineHeight
                    if y < pad - size { break }
                }
            } else {
                let baseline = (h - size * 0.718) / 2
                let x = alignedX(value, width: w, pad: pad, size: size, alignment: t.alignment)
                s += "1 0 0 1 \(f(x)) \(f(baseline)) Tm \(winAnsiLiteral(value)) Tj\n"
            }
            s += "ET Q\n"
        }
        s += "EMC\n"
        return Stream(content: Data(s.utf8), usesFont: usesFont, bbox: PDFRect(x: 0, y: 0, width: w, height: h))
    }

    private static func alignedX(_ text: String, width: Double, pad: Double, size: Double, alignment: TextAlignment) -> Double {
        let tw = textWidth(text, size: size)
        switch alignment {
        case .left: return pad
        case .center: return (width - tw) / 2
        case .right: return width - pad - tw
        }
    }

    /// Greedy word wrap on spaces and explicit newlines.
    public static func wrap(_ text: String, width: Double, size: Double) -> [String] {
        var lines: [String] = []
        for para in text.components(separatedBy: "\n") {
            var cur = ""
            for word in para.split(separator: " ", omittingEmptySubsequences: false) {
                let candidate = cur.isEmpty ? String(word) : cur + " " + word
                if textWidth(candidate, size: size) <= width || cur.isEmpty {
                    cur = candidate
                } else {
                    lines.append(cur)
                    cur = String(word)
                }
            }
            lines.append(cur)
        }
        return lines
    }

    // MARK: Image field placeholder

    /// The image field's normal appearance: background, dashed border, then either the
    /// label (the stored placeholder) or, in the Preview build only, the sample icon
    /// placed with the field's /IF (`icon` = resource name and natural size in points).
    public static func imagePlaceholder(_ field: FieldDef, icon: (name: String, width: Double, height: Double)? = nil) -> Stream {
        let w = field.rect.width, h = field.rect.height
        let p = field.image
        var s = ""
        if let bg = p.backgroundColor { s += "q \(rgb(bg)) rg 0 0 \(f(w)) \(f(h)) re f Q\n" }
        let bw = p.borderColor == nil ? 0 : max(0, p.borderWidth)
        var usesFont = false
        if let icon {
            let r = iconPlacement(field, iconWidth: icon.width, iconHeight: icon.height)
            let box = iconBox(field)
            s += "q \(f(box.x)) \(f(box.y)) \(f(box.width)) \(f(box.height)) re W n\n"
            s += "\(f(r.width / icon.width)) 0 0 \(f(r.height / icon.height)) \(f(r.x)) \(f(r.y)) cm /\(icon.name) Do Q\n"
        } else if !p.label.isEmpty {
            usesFont = true
            var size = 9.0
            var tw = textWidth(p.label, size: size)
            if tw > w - 6 { size = max(4, size * (w - 6) / tw); tw = textWidth(p.label, size: size) }
            s += "q BT /\(fontResourceName) \(f(size)) Tf 0.35 0.35 0.35 rg \(f((w - tw) / 2)) \(f(h / 2 - size / 3)) Td \(winAnsiLiteral(p.label)) Tj ET Q\n"
        }
        if let bc = p.borderColor, bw > 0 {
            let dash = "[\(f(3 * max(bw, 1))) \(f(2 * max(bw, 1)))] 0 d"
            s += "q \(rgb(bc)) RG \(f(bw)) w \(dash) \(f(bw / 2)) \(f(bw / 2)) \(f(w - bw)) \(f(h - bw)) re S Q\n"
        }
        return Stream(content: Data(s.utf8), usesFont: usesFont, bbox: PDFRect(x: 0, y: 0, width: w, height: h))
    }

    /// The area the icon is fitted into (ISO 32000 12.5.6.19 /IF /FB): the whole widget
    /// with /FB true, otherwise the widget inside its border.
    public static func iconBox(_ field: FieldDef) -> PDFRect {
        let w = field.rect.width, h = field.rect.height
        let p = field.image
        if p.fitBounds { return PDFRect(x: 0, y: 0, width: w, height: h) }
        let bw = p.borderColor == nil ? 0 : max(0, p.borderWidth)
        return PDFRect(x: bw, y: bw, width: max(0, w - 2 * bw), height: max(0, h - 2 * bw))
    }

    /// Where an icon of natural size `iconWidth` x `iconHeight` points lands in the
    /// widget's form space, following /IF: /SW (when to scale), /S (proportional or
    /// stretch) and /A (how leftover space is split; 0,0 = bottom-left).
    public static func iconPlacement(_ field: FieldDef, iconWidth iw: Double, iconHeight ih: Double) -> PDFRect {
        let box = iconBox(field)
        let p = field.image
        guard iw > 0, ih > 0 else { return box }
        let bigger = iw > box.width || ih > box.height
        let smaller = iw < box.width && ih < box.height
        let scale: Bool
        switch p.scaleWhen {
        case .always: scale = true
        case .tooBig: scale = bigger
        case .tooSmall: scale = smaller
        case .never: scale = false
        }
        var dw = iw, dh = ih
        if scale {
            switch p.scaleHow {
            case .proportional:
                let k = min(box.width / iw, box.height / ih)
                dw = iw * k; dh = ih * k
            case .stretch:
                dw = box.width; dh = box.height
            }
        }
        let ax = min(1, max(0, p.alignX)), ay = min(1, max(0, p.alignY))
        return PDFRect(x: box.x + (box.width - dw) * ax, y: box.y + (box.height - dh) * ay, width: dw, height: dh)
    }

    public static func stream(for field: FieldDef) -> Stream {
        field.kind == .image ? imagePlaceholder(field) : textField(field)
    }
}

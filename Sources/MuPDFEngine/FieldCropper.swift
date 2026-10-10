import Foundation
import PDFEngine
import VoucherModel
import VoucherGeometry

/// "Crop fields to outline" (spike S10, DECISIONS 30). The cut clips page content only;
/// widgets are annotations drawn above it, and what filling code appends to the page
/// after the cut's end stream is outside the clip too (SPEC 5.3). Two template-side parts,
/// both key-level and reversible:
///
/// 1. **Appearance clip.** Every widget whose /Rect is not fully inside the outline gets
///    each appearance stream (/AP /N, /R, /D, or each state of a state dictionary)
///    replaced by a wrapper form: `q <outline in form space> W n /VEAP Do Q`, plus a border
///    stroked along the outline where the widget has a /MK /BC border. The wrapper
///    references the original stream as /Resources /XObject /VEAP, so unwrapping is
///    `/AP /N := that reference`, and the original stream object is never modified. The
///    wrapper's space is the original form's space after its /Matrix (identity /Matrix,
///    /BBox = the transformed original /BBox), so the bbox-to-/Rect mapping is unchanged.
///    MuPDF, PDFium and PDFKit all draw it clipped (S10).
/// 2. **Cover annotation.** A /Watermark annotation, last in /Annots, flags Print +
///    ReadOnly + Locked + LockedContents, whose appearance fills the page box minus the
///    outline (even-odd) with white. Annotations draw above page content in every viewer,
///    so it hides what fillers draw or flatten into the page outside the shape (PyMuPDF
///    insert_image, pypdf merge_page and flatten, pdf-lib flatten). MuPDF and PDFium draw
///    widgets after all other annotations, so it does not cover an appearance a filler
///    rebuilds without flattening (pdf-lib setImage); PDFKit draws in /Annots order and
///    does. Outside the cut the page is blank, which every viewer shows as white, so the
///    cover is invisible on the unfilled template apart from a sub-pixel lighter edge.
///
/// `sync` is idempotent: it compares what is in the file with what the outline and the
/// setting call for, and writes only the differences.
struct FieldCropper {
    let doc: MuPDFDocument

    static let clipMarker = "% VoucherEditor field crop v1"
    static let coverMarker = "% VoucherEditor cover v1"
    static let coverName = "VoucherEditor cover"
    static let originalName = "VEAP"
    /// Appearance entries that are clipped: normal, rollover, down.
    static let appearanceKeys = ["N", "R", "D"]
    /// Print 4 + ReadOnly 64 + Locked 128 + LockedContents 512.
    static let coverFlags = 708

    struct Result {
        var clipped = 0
        var unclipped = 0
        var cover: Int?
        var coverChanged = false
        var changed: Bool { clipped > 0 || unclipped > 0 || coverChanged }
    }

    private struct Border {
        var color: [Double]
        var width: Double
        var dash: [Double]?
    }

    // MARK: Entry point

    @discardableResult
    func sync(pageNum: Int, outline: Outline?, crop: Bool) throws -> Result {
        var result = Result()
        let active = crop && outline != nil
        let annotsValue = try doc.get(pageNum, "Annots")
        let annots = (try doc.resolve(annotsValue)).array ?? []
        var covers: [Int] = []
        for item in annots {
            guard let n = item.refNumber, let obj = try? doc.object(n) else { continue }
            if obj["Subtype"].name == "Widget" {
                if fieldType(obj) == "Sig" { continue } // signature fields are never touched (SPEC 7.7)
                let rect = numbers(obj["Rect"]).flatMap { $0.count == 4 ? PDFRect(x1: $0[0], y1: $0[1], x2: $0[2], y2: $0[3]) : nil }
                let want = active && rect.map { Geometry.containment(of: $0, in: outline!) != .inside } ?? false
                try syncAppearances(widget: n, obj, rect: rect, outline: want ? outline : nil, result: &result)
            } else if obj["NM"].text == Self.coverName {
                covers.append(n)
            }
        }

        // The cover: exactly one, last in /Annots, while cropping is on.
        var wanted = annots.filter { v in !(v.refNumber.map(covers.contains) ?? false) }
        if active, let o = outline {
            let box = try mediaBox(pageNum)
            let content = Self.coverContent(box: box, outline: o)
            let cover: Int
            if let existing = covers.first {
                cover = existing
                let ap = try doc.get(existing, "AP/N").refNumber
                if try ap.map({ try doc.streamData($0) }) != content {
                    try doc.set(existing, "AP", .dict(["N": .ref(try coverAppearance(box: box, content: content), 0)]))
                    try doc.set(existing, "Rect", Self.rectValue(box))
                    result.coverChanged = true
                }
            } else {
                cover = try doc.newObject(.dict([
                    "Type": .name("Annot"), "Subtype": .name("Watermark"), "Rect": Self.rectValue(box),
                    "F": .int(Self.coverFlags), "NM": .text(Self.coverName), "P": .ref(pageNum, 0),
                    "AP": .dict(["N": .ref(try coverAppearance(box: box, content: content), 0)]),
                ]))
                result.coverChanged = true
            }
            wanted.append(.ref(cover, 0))
            result.cover = cover
        }
        if wanted != annots {
            try writeAnnots(pageNum: pageNum, current: annotsValue, wanted)
            result.coverChanged = true
        }
        return result
    }

    // MARK: Appearance clip

    private func syncAppearances(widget n: Int, _ obj: PDFValue, rect: PDFRect?, outline: Outline?, result: inout Result) throws {
        let border = outline == nil ? nil : borderStyle(obj)
        for key in Self.appearanceKeys {
            let path = "AP/\(key)"
            let v = try doc.get(n, path)
            if let s = v.refNumber, try doc.isStream(s) {
                try syncStream(widget: n, path: path, stream: s, rect: rect, outline: outline, border: border, result: &result)
            } else if let states = (try doc.resolve(v)).dict {
                for (state, sv) in states.sorted(by: { $0.key < $1.key }) {
                    guard let s = sv.refNumber, try doc.isStream(s) else { continue }
                    try syncStream(widget: n, path: "\(path)/\(state)", stream: s,
                                   rect: rect, outline: outline, border: border, result: &result)
                }
            }
        }
    }

    /// The original appearance a wrapper points at; nil when `s` is not the app's wrapper.
    func wrappedOriginal(_ s: Int) throws -> Int? {
        guard try doc.streamData(s).starts(with: Data(Self.clipMarker.utf8)) else { return nil }
        return try doc.get(s, "Resources/XObject/\(Self.originalName)").refNumber
    }

    private func syncStream(widget n: Int, path: String, stream s: Int, rect: PDFRect?, outline: Outline?,
                            border: Border?, result: inout Result) throws {
        let original = try wrappedOriginal(s)
        let base = original ?? s
        guard let o = outline, let rect else {
            if let original {
                try doc.set(n, path, .ref(original, 0))
                result.unclipped += 1
            }
            return
        }
        guard let (bbox, content) = try wrapper(base: base, rect: rect, outline: o, border: border) else { return }
        if original != nil, try doc.streamData(s) == content { return } // already clipped to this outline
        let w = try doc.newStream(dict: .dict([
            "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": Self.rectValue(bbox),
            "Resources": .dict(["XObject": .dict([Self.originalName: .ref(base, 0)])]),
        ]), data: content)
        try doc.set(n, path, .ref(w, 0))
        result.clipped += 1
    }

    /// The wrapper's /BBox and content for the original form `base` on a widget at `rect`.
    private func wrapper(base: Int, rect: PDFRect, outline o: Outline, border: Border?) throws -> (PDFRect, Data)? {
        guard let bb = numbers(try doc.get(base, "BBox")), bb.count == 4 else { return nil }
        let m = numbers(try doc.get(base, "Matrix")).flatMap { $0.count == 6 ? $0 : nil } ?? [1, 0, 0, 1, 0, 0]
        let corners = [(bb[0], bb[1]), (bb[2], bb[1]), (bb[0], bb[3]), (bb[2], bb[3])].map { x, y in
            (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])
        }
        let t = PDFRect(x1: corners.map(\.0).min()!, y1: corners.map(\.1).min()!,
                        x2: corners.map(\.0).max()!, y2: corners.map(\.1).max()!)
        guard t.width > 0, t.height > 0, rect.width > 0, rect.height > 0 else { return nil }
        // ISO 32000 12.5.5: the transformed bbox is mapped onto /Rect by scale and translation.
        let sx = rect.width / t.width, sy = rect.height / t.height
        let path = CutCodec.pathOperators(o) { p in
            PDFPoint((p.x - rect.minX) / sx + t.minX, (p.y - rect.minY) / sy + t.minY)
        }
        var s = Self.clipMarker + "\nq\n" + path + "\nW n\n/\(Self.originalName) Do\nQ\n"
        if let b = border, b.width > 0 {
            // The border along the outline: stroked at twice the width and clipped to the
            // inside, so the visible half has the field's border width.
            let color: String
            switch b.color.count {
            case 1: color = "\(PDFSyntax.number(b.color[0])) G"
            case 4: color = b.color.map(PDFSyntax.number).joined(separator: " ") + " K"
            default: color = b.color.prefix(3).map(PDFSyntax.number).joined(separator: " ") + " RG"
            }
            let w = 2 * b.width / min(sx, sy)
            let dash = b.dash.map { "[" + $0.map { PDFSyntax.number($0 / min(sx, sy)) }.joined(separator: " ") + "] 0 d " } ?? ""
            s += "q\n" + path + "\nW n\n\(color) \(PDFSyntax.number(w)) w \(dash)\n" + path + "\nS\nQ\n"
        }
        return (t, Data(s.utf8))
    }

    /// The widget's border as viewers draw it from /MK /BC and /BS (ISO 32000 12.5.4, 12.5.6.19).
    private func borderStyle(_ obj: PDFValue) -> Border? {
        let mk = (try? doc.resolve(obj["MK"])) ?? .null
        guard let bc = numbers(mk["BC"]), !bc.isEmpty else { return nil }
        let bs = (try? doc.resolve(obj["BS"])) ?? .null
        let width = ((try? doc.resolve(bs["W"])) ?? .null).number ?? 1
        var dash: [Double]?
        if bs["S"].name == "D" { dash = numbers(bs["D"]).flatMap { $0.isEmpty ? nil : $0 } ?? [3] }
        return Border(color: bc, width: width, dash: dash)
    }

    // MARK: Cover

    static func coverContent(box: PDFRect, outline o: Outline) -> Data {
        let r = "\(PDFSyntax.number(box.minX)) \(PDFSyntax.number(box.minY)) \(PDFSyntax.number(box.width)) \(PDFSyntax.number(box.height)) re"
        return Data((coverMarker + "\n1 g\n" + r + "\n" + CutCodec.pathOperators(o) + "\nf*\n").utf8)
    }

    private func coverAppearance(box: PDFRect, content: Data) throws -> Int {
        try doc.newStream(dict: .dict([
            "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": Self.rectValue(box), "Resources": .dict([:]),
        ]), data: content)
    }

    // MARK: Helpers

    /// /FT of the widget's field, inherited through /Parent.
    private func fieldType(_ obj: PDFValue) -> String? {
        var cur = obj
        for _ in 0..<16 {
            if let ft = cur["FT"].name { return ft }
            guard let p = cur["Parent"].refNumber, let po = try? doc.object(p) else { return nil }
            cur = po
        }
        return nil
    }

    private static func rectValue(_ r: PDFRect) -> PDFValue { .numbers([r.minX, r.minY, r.maxX, r.maxY]) }

    private func mediaBox(_ pageNum: Int) throws -> PDFRect {
        var n = pageNum
        for _ in 0..<32 {
            if let a = numbers(try doc.get(n, "MediaBox")), a.count == 4 { return PDFRect(x1: a[0], y1: a[1], x2: a[2], y2: a[3]) }
            guard let p = try doc.get(n, "Parent").refNumber else { break }
            n = p
        }
        return PDFRect(x: 0, y: 0, width: 612, height: 792)
    }

    /// Numbers of an array, resolving indirect arrays and indirect numbers inside it
    /// (Illustrator/InDesign write `/Rect 291 0 R` holding `[292 0 R ...]`).
    private func numbers(_ v: PDFValue) -> [Double]? {
        guard let a = (try? doc.resolve(v))?.array else { return nil }
        var out: [Double] = []
        for item in a {
            guard let x = ((try? doc.resolve(item)) ?? .null).number else { return nil }
            out.append(x)
        }
        return out
    }

    /// Key-level: an indirect /Annots array object is updated in place, a direct one is
    /// replaced; a direct array that becomes empty is removed (the cover created it).
    private func writeAnnots(pageNum: Int, current: PDFValue, _ items: [PDFValue]) throws {
        if let n = current.refNumber {
            try doc.update(n, .array(items))
        } else if items.isEmpty {
            try doc.set(pageNum, "Annots", .null)
        } else {
            try doc.set(pageNum, "Annots", .array(items))
        }
    }
}

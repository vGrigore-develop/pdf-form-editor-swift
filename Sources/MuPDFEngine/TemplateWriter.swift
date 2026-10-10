import Foundation
import Appearance
import PDFEngine
import VoucherModel

/// Applies a model diff to the document with key-level edits (SPEC 6.1, 7.7).
/// Changed objects are re-emitted whole in the update section, but only the keys
/// the app manages change; every other key is carried over verbatim.
struct TemplateWriter {
    let doc: MuPDFDocument
    /// Field id -> object number, for fields present in the current file.
    var objectNumbers: [UUID: Int]
    var summary: [String] = []
    /// True for the in-memory Preview build (SPEC 7.2): fields with a sample image get it
    /// as /MK /I and in their appearance. Saves never set this, so samples are never written.
    var preview = false

    private var acroFormNum: Int?
    private var fontRef: PDFValue?

    init(doc: MuPDFDocument, objectNumbers: [UUID: Int]) {
        self.doc = doc
        self.objectNumbers = objectNumbers
    }

    // MARK: Entry point

    mutating func apply(baseline: Template, edited: Template, signatureCount: Int) throws {
        let base = Dictionary(uniqueKeysWithValues: baseline.fields.map { ($0.id, $0) })
        let editedIDs = Set(edited.fields.map(\.id))

        // Deleted fields
        for f in baseline.fields where !editedIDs.contains(f.id) {
            guard let num = objectNumbers[f.id] else { continue }
            // Read-only fields are never removed. The editor deletes only editable fields, so a
            // read-only baseline field with a separate widget was merged in this session first.
            let mergedThenDeleted = !f.isEditable && f.canMergeWidget
            guard f.isEditable || mergedThenDeleted else { continue }
            if mergedThenDeleted { try mergeWidget(fieldNum: num, f, signatureCount: signatureCount) }
            try deleteField(num: num, page: f.page)
            objectNumbers[f.id] = nil
            summary.append("Deleted field \(f.qualifiedName)")
        }
        // New and changed fields
        var newRefsByPage: [Int: [Int]] = [:]
        for f in edited.fields {
            if let old = base[f.id], let num = objectNumbers[f.id] {
                // "Merge field and widget" pressed since the last save (DECISIONS 29). Undoing it
                // after a save leaves the file merged; pressing it again is then a no-op.
                if f.origin?.mergeWidgetOnSave == true && old.origin?.mergeWidgetOnSave != true {
                    try mergeWidget(fieldNum: num, f, signatureCount: signatureCount)
                }
                // Preview-only values (samples) never count as a change on save, and neither does
                // the read state in `origin` (the merge alone must not regenerate the appearance).
                // The Preview build regenerates every field that shows a sample image.
                var oldContent = old.persistentForm
                oldContent.origin = f.origin
                let changed = oldContent != f.persistentForm || (preview && hasSampleImage(f))
                if changed && f.isEditable {
                    try updateField(num: num, old: old, new: f)
                    summary.append("Changed field \(f.qualifiedName)")
                }
            } else if f.kind != .other {
                let num = try createField(f)
                objectNumbers[f.id] = num
                newRefsByPage[f.page, default: []].append(num)
                summary.append("Added field \(f.qualifiedName)")
            }
        }
        for (page, refs) in newRefsByPage.sorted(by: { $0.key < $1.key }) {
            let pn = try doc.pageObjectNumber(page)
            try appendToArrayKey(holder: pn, key: "Annots", refs: refs)
            try appendToArrayKey(holder: try ensureAcroForm(), key: "Fields", refs: refs)
        }

        // Cuts
        let pages = Set(baseline.outlines.keys).union(edited.outlines.keys)
        for p in pages.sorted() {
            let a = baseline.outlines[p], b = edited.outlines[p]
            if a == b { continue }
            if (signatureCount > 0) {
                throw EngineError("A shape cut changes page content, so it is refused on signed documents (SPEC 7.7).")
            }
            var cut = CutWriter(doc: doc)
            let pn = try doc.pageObjectNumber(p)
            switch (a, b) {
            case (nil, let o?):
                let mode = try cut.apply(pageNum: pn, outline: o)
                summary.append("Cut page \(p + 1) (\(mode.rawValue) mode)")
            case (_?, let o?):
                if try cut.hasCut(pageNum: pn) {
                    try cut.edit(pageNum: pn, outline: o)
                } else {
                    _ = try cut.apply(pageNum: pn, outline: o)
                }
                summary.append("Changed cut on page \(p + 1)")
            case (_?, nil):
                if try cut.hasCut(pageNum: pn) { try cut.remove(pageNum: pn) }
                summary.append("Removed cut on page \(p + 1)")
            default: break
            }
        }

        // Crop fields to the outline (S10, DECISIONS 30) on every page that has or had a cut:
        // after the field edits (a regenerated appearance is unclipped again, a new widget
        // must stay below the cover) and after the cut (a removed cut unclips everything).
        // Signed documents refuse cuts, and their widgets are not touched either.
        if signatureCount == 0 {
            for p in pages.sorted() {
                let pn = try doc.pageObjectNumber(p)
                let o = edited.outlines[p]
                let r = try FieldCropper(doc: doc).sync(pageNum: pn, outline: o, crop: edited.cropFieldsToOutline)
                if o != nil {
                    try setIfChanged(pn, CutWriter.cutPath + "/CropFields", .bool(edited.cropFieldsToOutline))
                    try setIfChanged(pn, CutWriter.cutPath + "/CoverAnnot", r.cover.map { .ref($0, 0) } ?? .null)
                }
                if r.clipped > 0 { summary.append("Cropped \(r.clipped) field appearance(s) to the outline on page \(p + 1)") }
                if r.unclipped > 0 { summary.append("Restored \(r.unclipped) uncropped field appearance(s) on page \(p + 1)") }
            }
        }
    }

    /// Set a key only when its value differs, so an unchanged page is not re-emitted.
    private func setIfChanged(_ num: Int, _ path: String, _ value: PDFValue) throws {
        if try doc.get(num, path) != value { try doc.set(num, path, value) }
    }

    // MARK: AcroForm plumbing

    /// /AcroForm object number; creates it when missing and promotes a direct one
    /// to an indirect object, so later edits stay key-level (spike S1 finding 3).
    private mutating func ensureAcroForm() throws -> Int {
        if let n = acroFormNum { return n }
        let cat = try doc.catalogObjectNumber()
        let current = try doc.get(cat, "AcroForm")
        let n: Int
        if let r = current.refNumber {
            n = r
        } else if case .dict = current {
            n = try doc.newObject(current)
            try doc.set(cat, "AcroForm", .ref(n, 0))
        } else {
            n = try doc.newObject(.dict(["Fields": .array([])]))
            try doc.set(cat, "AcroForm", .ref(n, 0))
        }
        acroFormNum = n
        return n
    }

    /// The /Helv font in /AcroForm /DR /Font, added only if missing; plus a default /DA.
    private mutating func ensureFont() throws -> PDFValue {
        if let f = fontRef { return f }
        let af = try ensureAcroForm()
        if try doc.get(af, "DR").isNull { try doc.set(af, "DR", .dict([:])) }
        if try doc.get(af, "DR/Font").isNull { try doc.set(af, "DR/Font", .dict([:])) }
        let name = AppearanceBuilder.fontResourceName
        var ref = try doc.get(af, "DR/Font/\(name)")
        if ref.isNull {
            let n = try doc.newObject(.dict([
                "Type": .name("Font"), "Subtype": .name("Type1"),
                "BaseFont": .name("Helvetica"), "Encoding": .name("WinAnsiEncoding"),
            ]))
            ref = .ref(n, 0)
            try doc.set(af, "DR/Font/\(name)", ref)
        }
        if try doc.get(af, "DA").isNull { try doc.set(af, "DA", .text("/\(name) 0 Tf 0 g")) }
        fontRef = ref
        return ref
    }

    // MARK: Fields

    private func hasSampleImage(_ f: FieldDef) -> Bool {
        f.kind == .image && !f.image.sampleImagePath.isEmpty
    }

    /// Preview only: the sample image as an image XObject (with /SMask for transparency)
    /// wrapped in a form XObject of its natural size, the shape /MK /I expects.
    private func sampleIcon(_ f: FieldDef) throws -> (ref: PDFValue, width: Double, height: Double)? {
        guard preview, hasSampleImage(f), let img = SampleImage.load(path: f.image.sampleImagePath) else { return nil }
        var imageDict: [String: PDFValue] = [
            "Type": .name("XObject"), "Subtype": .name("Image"),
            "Width": .int(img.pixelWidth), "Height": .int(img.pixelHeight),
            "ColorSpace": .name("DeviceRGB"), "BitsPerComponent": .int(8),
        ]
        if let a = img.alpha {
            let mask = try doc.newStream(dict: .dict([
                "Type": .name("XObject"), "Subtype": .name("Image"),
                "Width": .int(img.pixelWidth), "Height": .int(img.pixelHeight),
                "ColorSpace": .name("DeviceGray"), "BitsPerComponent": .int(8),
            ]), data: a)
            imageDict["SMask"] = .ref(mask, 0)
        }
        let image = try doc.newStream(dict: .dict(imageDict), data: img.rgb)
        let w = img.pointWidth, h = img.pointHeight
        let content = "q \(PDFNumber.format(w)) 0 0 \(PDFNumber.format(h)) 0 0 cm /Img Do Q\n"
        let icon = try doc.newStream(dict: .dict([
            "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .numbers([0, 0, w, h]),
            "Resources": .dict(["XObject": .dict(["Img": .ref(image, 0)])]),
        ]), data: Data(content.utf8))
        return (.ref(icon, 0), w, h)
    }

    /// The /AP /N stream for `f`, plus the /MK /I icon it draws (Preview sample images only).
    private mutating func appearanceStream(_ f: FieldDef) throws -> (ap: PDFValue, icon: PDFValue?) {
        let icon = try sampleIcon(f)
        let ap = f.kind == .image
            ? AppearanceBuilder.imagePlaceholder(f, icon: icon.map { ("Icon", $0.width, $0.height) })
            : AppearanceBuilder.stream(for: f)
        var dict: [String: PDFValue] = [
            "Type": .name("XObject"), "Subtype": .name("Form"),
            "BBox": .numbers([0, 0, ap.bbox.width, ap.bbox.height]),
        ]
        // Always give the form a /Resources dictionary, even an empty one: PDFKit (the app's
        // Preview and macOS Preview) silently skips an appearance stream without it, which
        // made the background and border of an empty text field invisible there.
        var resources: [String: PDFValue] = [:]
        if ap.usesFont {
            resources["Font"] = .dict([AppearanceBuilder.fontResourceName: try ensureFont()])
        }
        if let icon { resources["XObject"] = .dict(["Icon": icon.ref]) }
        dict["Resources"] = .dict(resources)
        return (.ref(try doc.newStream(dict: .dict(dict), data: ap.content), 0), icon?.ref)
    }

    private func rectValue(_ r: PDFRect) -> PDFValue {
        let n = r.rounded
        return .numbers([n.minX, n.minY, n.maxX, n.maxY])
    }

    private func colorValue(_ c: RGBColor?) -> PDFValue? {
        c.map { .numbers([$0.r, $0.g, $0.b]) }
    }

    /// The placeholder border is drawn dashed, so /BS says so (viewers that rebuild the
    /// appearance from /MK and /BS then draw the same border).
    private func imageBorderStyle(_ p: ImageProps) -> PDFValue {
        let w = p.borderColor == nil ? 0 : max(0, p.borderWidth)
        return .dict(["W": .real(w), "S": .name("D"), "D": .numbers([3 * max(w, 1), 2 * max(w, 1)])])
    }

    private func importAction() -> PDFValue {
        .dict(["S": .name("JavaScript"), "JS": .text(TemplateReader.importIconJS)])
    }

    private func fitValue(_ p: ImageProps) -> PDFValue {
        .dict(["SW": .name(p.scaleWhen.rawValue), "S": .name(p.scaleHow.rawValue),
               "A": .numbers([p.alignX, p.alignY]), "FB": .bool(p.fitBounds)])
    }

    private mutating func createField(_ f: FieldDef) throws -> Int {
        _ = try ensureFont() // /DA's font must be in /DR (SPEC 6.1)
        let pn = try doc.pageObjectNumber(f.page)
        var d: [String: PDFValue] = [
            "Type": .name("Annot"), "Subtype": .name("Widget"),
            "T": .text(f.name), "Rect": rectValue(f.rect), "P": .ref(pn, 0), "F": .int(4),
            "DA": .text(f.defaultAppearance),
        ]
        let appearance = try appearanceStream(f)
        d["AP"] = .dict(["N": appearance.ap])
        if !f.tooltip.isEmpty { d["TU"] = .text(f.tooltip) }
        var mk: [String: PDFValue] = [:]
        switch f.kind {
        case .text:
            d["FT"] = .name("Tx")
            d["Q"] = .int(f.text.alignment.rawValue)
            if let m = f.text.maxLength { d["MaxLen"] = .int(m) }
            if !f.text.defaultValue.isEmpty { d["V"] = .text(f.text.defaultValue); d["DV"] = .text(f.text.defaultValue) }
            mk["BC"] = colorValue(f.text.borderColor)
            mk["BG"] = colorValue(f.text.backgroundColor)
            d["BS"] = .dict(["W": .real(f.text.borderColor == nil ? 0 : f.text.borderWidth), "S": .name("S")])
        case .image:
            d["FT"] = .name("Btn")
            mk["TP"] = .int(1)
            mk["IF"] = fitValue(f.image)
            mk["BC"] = colorValue(f.image.borderColor)
            mk["BG"] = colorValue(f.image.backgroundColor)
            mk["I"] = appearance.icon
            d["BS"] = imageBorderStyle(f.image)
            if !f.image.label.isEmpty { mk["CA"] = .text(f.image.label) }
            if f.image.importAction { d["A"] = importAction() }
        case .other:
            throw EngineError("cannot create a field of kind other")
        }
        let flags = f.flags
        if flags != 0 { d["Ff"] = .int(flags) }
        d["MK"] = .dict(mk.compactMapValues { $0 })
        return try doc.newObject(.dict(d))
    }

    private func setOrDelete(_ num: Int, _ key: String, _ v: PDFValue?) throws {
        try doc.set(num, key, v ?? .null)
    }

    private mutating func updateField(num: Int, old: FieldDef, new f: FieldDef) throws {
        if old.name != f.name { try doc.set(num, "T", .text(f.name)) }
        if old.tooltip != f.tooltip { try setOrDelete(num, "TU", f.tooltip.isEmpty ? nil : .text(f.tooltip)) }
        if old.rect != f.rect { try doc.set(num, "Rect", rectValue(f.rect)) }
        if old.flags != f.flags { try setOrDelete(num, "Ff", f.flags == 0 ? nil : .int(f.flags)) }
        if old.defaultAppearance != f.defaultAppearance || old.text.fontName != f.text.fontName {
            if f.text.fontName == AppearanceBuilder.fontResourceName { _ = try ensureFont() }
            try doc.set(num, "DA", .text(f.defaultAppearance))
        }
        if try doc.get(num, "MK").isNull { try doc.set(num, "MK", .dict([:])) }
        switch f.kind {
        case .text:
            if old.text.alignment != f.text.alignment { try doc.set(num, "Q", .int(f.text.alignment.rawValue)) }
            if old.text.maxLength != f.text.maxLength { try setOrDelete(num, "MaxLen", f.text.maxLength.map { .int($0) }) }
            if old.text.defaultValue != f.text.defaultValue {
                let v: PDFValue? = f.text.defaultValue.isEmpty ? nil : .text(f.text.defaultValue)
                try setOrDelete(num, "V", v)
                try setOrDelete(num, "DV", v)
            }
            if old.text.borderColor != f.text.borderColor { try setOrDelete(num, "MK/BC", colorValue(f.text.borderColor)) }
            if old.text.backgroundColor != f.text.backgroundColor { try setOrDelete(num, "MK/BG", colorValue(f.text.backgroundColor)) }
            if old.text.borderWidth != f.text.borderWidth || old.text.borderColor != f.text.borderColor {
                if try doc.get(num, "BS").isNull { try doc.set(num, "BS", .dict(["S": .name("S")])) }
                try doc.set(num, "BS/W", .real(f.text.borderColor == nil ? 0 : f.text.borderWidth))
            }
        case .image:
            if old.image.scaleWhen != f.image.scaleWhen || old.image.scaleHow != f.image.scaleHow ||
                old.image.alignX != f.image.alignX || old.image.alignY != f.image.alignY || old.image.fitBounds != f.image.fitBounds {
                try doc.set(num, "MK/IF", fitValue(f.image))
            }
            if try doc.get(num, "MK/TP").isNull { try doc.set(num, "MK/TP", .int(1)) }
            if old.image.borderColor != f.image.borderColor { try setOrDelete(num, "MK/BC", colorValue(f.image.borderColor)) }
            if old.image.backgroundColor != f.image.backgroundColor { try setOrDelete(num, "MK/BG", colorValue(f.image.backgroundColor)) }
            if old.image.borderWidth != f.image.borderWidth || old.image.borderColor != f.image.borderColor {
                // Key-level: other /BS keys (and an indirect /BS) are kept.
                if try doc.get(num, "BS").isNull { try doc.set(num, "BS", .dict([:])) }
                let bs = imageBorderStyle(f.image)
                for k in ["W", "S", "D"] { try doc.set(num, "BS/\(k)", bs[k]) }
            }
            if old.image.label != f.image.label { try setOrDelete(num, "MK/CA", f.image.label.isEmpty ? nil : .text(f.image.label)) }
            if old.image.importAction != f.image.importAction {
                let hasForeign = f.origin?.hasForeignAction ?? false
                if f.image.importAction && !hasForeign {
                    try doc.set(num, "A", importAction())
                } else if !f.image.importAction && !hasForeign {
                    try doc.set(num, "A", .null) // only ever removes the app's own action
                }
            }
        case .other:
            return
        }
        // Regenerate the normal appearance; other appearance states (/D, /R) are kept.
        let appearance = try appearanceStream(f)
        if let icon = appearance.icon { try doc.set(num, "MK/I", icon) } // Preview build only
        if try doc.get(num, "AP").isNull { try doc.set(num, "AP", .dict([:])) }
        try doc.set(num, "AP/N", appearance.ap)
    }

    /// Merges the field object `fieldNum` with its single /Kids widget (WidgetMerger).
    /// The field object survives, so `objectNumbers` does not change.
    private mutating func mergeWidget(fieldNum: Int, _ f: FieldDef, signatureCount: Int) throws {
        let merger = WidgetMerger(doc: doc)
        do {
            guard let plan = try merger.plan(field: fieldNum, signatureCount: signatureCount) else { return }
            try merger.apply(plan)
            summary.append("Merged field and widget of \(f.qualifiedName)")
            summary.append(contentsOf: plan.notes.map { "  \($0)" })
        } catch let e as EngineError {
            throw EngineError("Cannot merge field and widget of \"\(f.qualifiedName)\": \(e.message)", code: e.code)
        }
    }

    private mutating func deleteField(num: Int, page: Int) throws {
        let pn = try doc.pageObjectNumber(page)
        try removeFromArrayKey(holder: pn, key: "Annots", ref: num)
        if let parent = try doc.get(num, "Parent").refNumber {
            try removeFromArrayKey(holder: parent, key: "Kids", ref: num)
        } else {
            try removeFromArrayKey(holder: try ensureAcroForm(), key: "Fields", ref: num)
        }
    }

    // MARK: Arrays (key-level: an indirect array object is updated in place)

    private func appendToArrayKey(holder: Int, key: String, refs: [Int]) throws {
        let v = try doc.get(holder, key)
        let additions = refs.map { PDFValue.ref($0, 0) }
        if let n = v.refNumber {
            let arr = try doc.object(n).array ?? []
            try doc.update(n, .array(arr + additions))
        } else if let arr = v.array {
            try doc.set(holder, key, .array(arr + additions))
        } else {
            try doc.set(holder, key, .array(additions))
        }
    }

    private func removeFromArrayKey(holder: Int, key: String, ref: Int) throws {
        let v = try doc.get(holder, key)
        if let n = v.refNumber {
            let arr = try doc.object(n).array ?? []
            try doc.update(n, .array(arr.filter { $0.refNumber != ref }))
        } else if let arr = v.array {
            try doc.set(holder, key, .array(arr.filter { $0.refNumber != ref }))
        }
    }
}

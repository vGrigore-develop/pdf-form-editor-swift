import Foundation
import PDFEngine
import VoucherModel

/// Reads pages, AcroForm fields and the stored cut into the model (SPEC 7.6).
struct TemplateReader {
    let doc: MuPDFDocument

    static let importIconJS = "event.target.buttonImportIcon();"

    struct Output {
        var template: Template
        var facts: DocumentFacts
        var notes: [String]
        /// Field id -> object number of its merged field/widget dictionary.
        var objectNumbers: [UUID: Int]
    }

    func read() throws -> Output {
        var notes: [String] = []
        var facts = DocumentFacts()
        facts.wasRepaired = doc.wasRepaired
        facts.isEncrypted = doc.isEncrypted
        facts.signatureCount = (try? doc.signatureCount()) ?? 0

        let catalogNum = try doc.catalogObjectNumber()
        let catalog = try doc.object(catalogNum)
        let acro = leaves((try? doc.resolve(catalog["AcroForm"])) ?? .null)
        facts.hasXFA = !acro["XFA"].isNull
        if let names = try? doc.resolve(catalog["Names"]), !names["JavaScript"].isNull { facts.hasJavaScript = true }
        if let oa = try? doc.resolve(catalog["OpenAction"]), oa["S"].name == "JavaScript" { facts.hasJavaScript = true }
        if let perms = try? doc.resolve(catalog["Perms"]), !perms["DocMDP"].isNull { facts.hasCertification = true }

        // Every object reachable from /AcroForm /Fields (fields and their kids).
        var inFields = Set<Int>()
        func walkFields(_ v: PDFValue, depth: Int) {
            guard depth < 32, let arr = (try? doc.resolve(v))?.array else { return }
            for item in arr {
                guard let n = item.refNumber, !inFields.contains(n) else { continue }
                inFields.insert(n)
                if let o = try? doc.object(n) { walkFields(o["Kids"], depth: depth + 1) }
            }
        }
        walkFields(acro["Fields"], depth: 0)
        let defaultDA = acro["DA"].text

        // Pages
        let pageCount = try doc.pageCount
        var pages: [PageInfo] = []
        var pageNums: [Int] = []
        for i in 0..<pageCount {
            let n = try doc.pageObjectNumber(i)
            pageNums.append(n)
            let media = rectValue(try inherited(n, "MediaBox")) ?? PDFRect(x: 0, y: 0, width: 612, height: 792)
            let crop = rectValue(try inherited(n, "CropBox"))
            var rot = (try inherited(n, "Rotate")).int ?? 0
            rot = ((rot % 360) + 360) % 360
            pages.append(PageInfo(mediaBox: media, cropBox: crop, rotation: rot))
        }

        // Fields, page by page through /Annots (so page and rect are known).
        var fields: [FieldDef] = []
        var numbers: [UUID: Int] = [:]
        var seenFields = Set<Int>()
        for (pi, pn) in pageNums.enumerated() {
            let annots = (try? doc.resolve(try doc.get(pn, "Annots")))?.array ?? []
            for a in annots {
                guard let wn = a.refNumber, let wRaw = try? doc.object(wn), wRaw["Subtype"].name == "Widget" else { continue }
                let w = leaves(wRaw)
                let action = dict(w["A"])
                if w["JS"] != .null || action["S"].name == "JavaScript" || !w["AA"].isNull { facts.hasJavaScript = true }
                // The terminal field: the widget itself when merged (has /T or no parent), else its parent.
                let fieldNum: Int = (!w["T"].isNull || w["Parent"].isNull) ? wn : (w["Parent"].refNumber ?? wn)
                if seenFields.contains(fieldNum) { continue }
                seenFields.insert(fieldNum)
                let field = fieldNum == wn ? w : ((try? doc.object(fieldNum)).map { leaves($0) } ?? w)
                if !field["AA"].isNull { facts.hasJavaScript = true }

                // Inherited attributes and the full name.
                var chain: [PDFValue] = [field]
                var cur = field
                var guardCount = 0
                while let p = cur["Parent"].refNumber, guardCount < 32, let poRaw = try? doc.object(p) {
                    let po = leaves(poRaw)
                    chain.append(po); cur = po; guardCount += 1
                }
                func inh(_ key: String) -> PDFValue { chain.first { !$0[key].isNull }?[key] ?? .null }
                let parts = chain.reversed().compactMap { $0["T"].text }
                let fullName = parts.joined(separator: ".")
                let leaf = field["T"].text ?? ""
                let ft = inh("FT").name ?? ""
                let ff = inh("Ff").int ?? 0
                let kids = (try? doc.resolve(field["Kids"]))?.array ?? []
                let widgetCount = fieldNum == wn ? max(1, kids.count) : max(1, kids.count)
                let rootNum = chainRootNumber(fieldNum: fieldNum)

                var kind: FieldKind = .other
                var reason: String?
                let mk = dict(w["MK"])
                let actionJS = (try? jsText(action["JS"])) ?? nil
                let isOurJS = action["S"].name == "JavaScript" && actionJS == Self.importIconJS
                switch ft {
                case "Tx": kind = .text
                case "Btn" where ff & FieldFlags.pushButton != 0:
                    let looksLikeImage = mk["TP"].int == 1 || !mk["IF"].isNull || !mk["I"].isNull || isOurJS
                    if looksLikeImage { kind = .image } else { reason = "Push-button without an icon (not an image field)" }
                case "Btn": reason = "Checkbox or radio button (not editable yet)"
                case "Ch": reason = "Choice field (not editable yet)"
                case "Sig": reason = "Signature field (never touched)"
                default: reason = "Unknown field type \(ft)"
                }
                var editable = kind != .other
                var separateWidget: Int?
                var mergeBlocker: String?
                var mergeNotes: [String] = []
                if editable && widgetCount > 1 {
                    editable = false; reason = "Field with \(widgetCount) widgets (linked); shown read-only"
                } else if editable && fieldNum != wn {
                    // A parent field with a single /Kids widget: one rect for fillers, but the app
                    // edits only merged field/widget dictionaries (DECISIONS 15). The inspector
                    // offers "Merge field and widget" (DECISIONS 29); the plan is checked here so a
                    // refusal and any conflicting keys are shown before he presses it.
                    editable = false
                    reason = "Field and widget are separate objects (one widget under /Kids); shown read-only. Use \"Merge field and widget\" to make it editable."
                    separateWidget = wn
                    do {
                        mergeNotes = try WidgetMerger(doc: doc).plan(field: fieldNum, signatureCount: facts.signatureCount)?.notes ?? []
                    } catch {
                        mergeBlocker = error.localizedDescription
                    }
                }

                let daString = inh("DA").text ?? defaultDA
                let da = daString.flatMap(DAFormat.parse)
                let rect = rectValue(w["Rect"]) ?? PDFRect(x: 0, y: 0, width: 0, height: 0)

                var def = FieldDef(kind: kind, name: fullName.isEmpty ? leaf : (parts.count > 1 ? leaf : fullName), page: pi, rect: rect)
                def.tooltip = field["TU"].text ?? ""
                def.readOnly = ff & FieldFlags.readOnly != 0
                def.required = ff & FieldFlags.required != 0
                if let da {
                    def.text.fontName = da.fontName
                    def.text.fontSize = da.size
                    def.text.color = da.color
                }
                def.text.alignment = TextAlignment(rawValue: inh("Q").int ?? 0) ?? .left
                def.text.multiline = ff & FieldFlags.multiline != 0
                def.text.doNotScroll = ff & FieldFlags.doNotScroll != 0
                def.text.comb = ff & FieldFlags.comb != 0
                def.text.password = ff & FieldFlags.password != 0
                def.text.fileSelect = ff & FieldFlags.fileSelect != 0
                def.text.maxLength = inh("MaxLen").int
                if kind == .text { def.text.defaultValue = (try? jsText(inh("V"))) .flatMap { $0 } ?? "" }
                let bs = dict(w["BS"])
                if let bw = bs["W"].number { def.text.borderWidth = bw }
                def.text.borderColor = color(mk["BC"])
                def.text.backgroundColor = color(mk["BG"])
                if kind == .image {
                    let fit = dict(mk["IF"])
                    def.image.scaleWhen = ScaleWhen(rawValue: fit["SW"].name ?? "A") ?? .always
                    def.image.scaleHow = ScaleHow(rawValue: fit["S"].name ?? "P") ?? .proportional
                    if let a = fit["A"].numbers, a.count == 2 { def.image.alignX = a[0]; def.image.alignY = a[1] }
                    def.image.fitBounds = fit["FB"].bool ?? false
                    def.image.backgroundColor = color(mk["BG"])
                    def.image.borderColor = color(mk["BC"])
                    if let bw = bs["W"].number { def.image.borderWidth = bw }
                    // An existing field shows its own caption or none; the default label is only
                    // for fields made in the app (otherwise any edit would add a label to it).
                    def.image.label = mk["CA"].text ?? ""
                    def.image.importAction = isOurJS
                }
                def.origin = FieldOrigin(
                    objectNumber: fieldNum, fullName: fullName, isHierarchical: parts.count > 1,
                    widgetCount: widgetCount, editable: editable, readOnlyReason: reason,
                    inPageAnnots: true, hasPageRef: !w["P"].isNull,
                    inAcroFormFields: inFields.contains(fieldNum) || inFields.contains(rootNum),
                    rawFlags: ff, rawDA: daString, daParsed: da != nil || kind == .other,
                    hasForeignAction: !action.isNull && !isOurJS, typeName: ft,
                    separateWidget: separateWidget, widgetMergeBlocker: mergeBlocker, widgetMergeNotes: mergeNotes)
                fields.append(def)
                numbers[def.id] = fieldNum
            }
        }
        if fields.contains(where: { !$0.isEditable }) {
            notes.append("\(fields.filter { !$0.isEditable }.count) field(s) are shown read-only and preserved.")
        }

        // Cuts
        var outlines: [Int: Outline] = [:]
        var cropFlags: [Bool] = []
        for (pi, pn) in pageNums.enumerated() {
            let cut = try doc.get(pn, "PieceInfo/VoucherEditor/Private/Cut")
            if let c = (try? doc.resolve(cut)), !c.isNull, let o = CutCodec.outline(start: c["Start"], segments: c["Segments"]) {
                outlines[pi] = o
                cropFlags.append(c["CropFields"].bool ?? false) // cuts saved before S10 were not cropped
            } else if let first = try? firstContentStream(pn), let data = try? doc.streamData(first),
                      data.starts(with: Data(CutCodec.marker.utf8)) {
                notes.append("Page \(pi + 1) has a VoucherEditor cut but its /PieceInfo is missing; the outline can be rebuilt from the clip path (not automatic yet).")
            }
        }

        // "Crop fields to outline": as stored with the cut; on by default for a new cut.
        let crop = cropFlags.isEmpty ? true : cropFlags.contains(true)
        let template = Template(pages: pages, fields: fields, outlines: outlines, cropFieldsToOutline: crop)
        return Output(template: template, facts: facts, notes: notes, objectNumbers: numbers)
    }

    private func chainRootNumber(fieldNum: Int) -> Int {
        var n = fieldNum
        var count = 0
        while count < 32, let p = (try? doc.get(n, "Parent"))?.refNumber { n = p; count += 1 }
        return n
    }

    private func firstContentStream(_ pageNum: Int) throws -> Int? {
        let c = try doc.get(pageNum, "Contents")
        if let n = c.refNumber {
            if try doc.isStream(n) { return n }
            return (try doc.object(n)).array?.first?.refNumber
        }
        return c.array?.first?.refNumber
    }

    /// A text value that may be a string or a stream (JS can be either).
    private func jsText(_ v: PDFValue) throws -> String? {
        if let n = v.refNumber {
            if try doc.isStream(n) { return PDFText.decode(try doc.streamData(n)) }
            return try doc.object(n).text
        }
        return v.text
    }

    /// An inheritable page attribute (walks /Parent).
    func inherited(_ pageNum: Int, _ key: String) throws -> PDFValue {
        var n = pageNum
        for _ in 0..<32 {
            let v = try doc.get(n, key)
            if !v.isNull { return try doc.resolve(v) }
            guard let p = try doc.get(n, "Parent").refNumber else { break }
            n = p
        }
        return .null
    }

    /// Values inside a dictionary or array may themselves be indirect, down to single
    /// numbers: Illustrator/InDesign exports write `/Rect 291 0 R` with
    /// `291 0 obj [292 0 R 293 0 R 294 0 R 295 0 R]`. This replaces every reference
    /// whose target is not a dictionary (or stream) with the target, recursively
    /// through arrays and dictionary values. References to dictionaries (/P, /Parent,
    /// /Kids entries, /AP, /A ...) stay references, so page and parent cycles are never
    /// followed and object numbers stay available.
    func leaves(_ v: PDFValue, depth: Int = 0) -> PDFValue {
        guard depth < 8 else { return v }
        switch v {
        case .ref(let n, _):
            guard let o = try? doc.object(n) else { return .null }
            if o.dict != nil { return v }
            return leaves(o, depth: depth + 1)
        case .array(let a):
            return .array(a.map { leaves($0, depth: depth + 1) })
        case .dict(let d):
            return .dict(d.mapValues { leaves($0, depth: depth + 1) })
        default:
            return v
        }
    }

    /// A dictionary value, following one reference, with its leaves resolved.
    func dict(_ v: PDFValue) -> PDFValue {
        leaves((try? doc.resolve(v)) ?? .null)
    }

    private func rectValue(_ v: PDFValue) -> PDFRect? {
        guard let a = leaves(v).numbers, a.count == 4 else { return nil }
        return PDFRect(x1: a[0], y1: a[1], x2: a[2], y2: a[3])
    }

    private func color(_ v: PDFValue) -> RGBColor? {
        guard let a = leaves(v).numbers else { return nil }
        switch a.count {
        case 1: return RGBColor(gray: a[0])
        case 3: return RGBColor(a[0], a[1], a[2])
        case 4: return RGBColor((1 - a[0]) * (1 - a[3]), (1 - a[1]) * (1 - a[3]), (1 - a[2]) * (1 - a[3]))
        default: return nil
        }
    }
}

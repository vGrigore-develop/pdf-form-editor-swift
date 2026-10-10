import Foundation
import PDFEngine

/// "Merge field and widget" (DECISIONS 29).
///
/// Illustrator and InDesign export a form field as two objects: a field dictionary
/// (/T, /FT, /Ff, /DA ...) whose /Kids holds one widget annotation (/Subtype /Widget,
/// /Rect, /P, /MK, /AP ...). This turns such a pair into one merged field/widget
/// dictionary, the shape the app writes and edits (SPEC 6.1).
///
/// The field object survives, so /AcroForm /Fields (or a higher parent's /Kids), /CO
/// and anything else that names the field stay valid without change. It loses /Kids and
/// gains the widget's keys; every reference to the widget elsewhere in the file (page
/// /Annots, structure tree /OBJR, other annotations' /Parent or /IRT, form actions'
/// /Fields lists) is pointed at the field object; the old widget object becomes null.
/// All edits are key-level, and the save that carries them is incremental.
struct WidgetMerger {
    let doc: MuPDFDocument

    /// Field-semantic keys: on a conflict the field's value wins (it is what fillers and
    /// the app's model read). Every other key is an annotation key: the widget's value wins,
    /// because it is what viewers draw today.
    static let fieldKeys: Set<String> = [
        "T", "TU", "TM", "FT", "Ff", "V", "DV", "MaxLen", "Q", "DA", "DS", "RV",
        "Opt", "TI", "I", "Lock", "SV", "Kids", "Parent",
    ]
    /// Inheritable field attributes, copied down from ancestors when the field lacks them.
    static let inheritable = ["FT", "Ff", "V", "DV", "DA", "Q", "DS", "RV", "MaxLen"]
    /// /AA triggers that belong to the field (keystroke, format, validate, calculate);
    /// the others (E X D U Fo Bl PO PC PV PI) belong to the widget annotation.
    static let fieldTriggers: Set<String> = ["K", "F", "V", "C"]

    struct Plan {
        var field: Int
        var widget: Int
        /// Page object whose /Annots lists the widget (the merged dictionary's /P).
        var page: Int
        /// Key-level edits on the field object, as MuPDF syntax ("null" deletes).
        var sets: [(key: String, syntax: String)]
        /// Human-readable list of copied inherited values and resolved conflicts.
        var notes: [String]
    }

    /// Checks the structure and works out the edits. Returns nil when the field is
    /// already a merged field/widget (nothing to do); throws `EngineError` with the
    /// reason when the merge is refused.
    func plan(field: Int, signatureCount: Int) throws -> Plan? {
        let f = try doc.object(field)
        guard f.dict != nil else { throw EngineError("Object \(field) is not a field dictionary.") }
        if f["Kids"].isNull && f["Subtype"].name == "Widget" { return nil }
        if signatureCount > 0 {
            throw EngineError("The document is signed. Merging rewrites the field after the signature, which validators report as a modification, so it is refused on signed documents.")
        }
        let kids = (try doc.resolve(f["Kids"])).array ?? []
        guard !kids.isEmpty else { throw EngineError("The field has no widget under /Kids.") }
        guard kids.count == 1 else {
            throw EngineError("The field has \(kids.count) kids; merging needs a field with exactly one widget.")
        }
        guard let wn = kids[0].refNumber else { throw EngineError("The field's kid is not an indirect object.") }
        let w = try doc.object(wn)
        guard w.dict != nil else { throw EngineError("The field's kid is not a dictionary.") }
        guard w["T"].isNull else {
            throw EngineError("The kid has its own /T, so it is a field of its own (a real hierarchy), not a pure widget; it is left as it is.")
        }
        guard w["Subtype"].name == "Widget" else {
            throw EngineError("The field's only kid is not a widget annotation.")
        }
        guard w["Kids"].isNull else { throw EngineError("The kid has kids of its own; it is left as it is.") }
        if let p = w["Parent"].refNumber, p != field {
            throw EngineError("The widget's /Parent does not point back to the field.")
        }

        // Ancestors of the field (for inherited attributes), nearest first.
        var ancestors: [(num: Int, obj: PDFValue)] = []
        var cur = f
        while let p = cur["Parent"].refNumber, ancestors.count < 32, let po = try? doc.object(p), po.dict != nil {
            ancestors.append((p, po)); cur = po
        }
        let ft = f["FT"].isNull ? ancestors.first { !$0.obj["FT"].isNull }?.obj["FT"].name : f["FT"].name
        guard let ft else { throw EngineError("The field is not terminal (no /FT on it or its ancestors).") }
        if ft == "Sig" { throw EngineError("Signature fields are never touched.") }

        guard let page = try pageListing(widget: wn) else {
            throw EngineError("The widget is not listed in any page's /Annots.")
        }

        let reader = TemplateReader(doc: doc)
        func same(_ a: PDFValue, _ b: PDFValue) -> Bool { reader.leaves(a) == reader.leaves(b) }
        var sets: [(key: String, syntax: String)] = []
        var notes: [String] = []

        sets.append(("Kids", "null"))
        // The field's effective values: its own keys plus inherited ones copied down.
        var effective = f.dict ?? [:]
        for key in Self.inheritable where f[key].isNull {
            guard let a = ancestors.first(where: { !$0.obj[key].isNull }) else { continue }
            sets.append((key, try doc.getSyntax(a.num, key)))
            effective[key] = a.obj[key]
            notes.append("/\(key) is inherited from a parent field; its value \(Self.short(a.obj[key])) is copied onto the merged field.")
        }

        let widgetKeys = (w.dict ?? [:]).keys.sorted()
        for key in widgetKeys where key != "Parent" && key != "P" && key != "AA" {
            let wv = w[key], fv = effective[key] ?? .null
            if fv.isNull {
                sets.append((key, try doc.getSyntax(wn, key)))
            } else if same(fv, wv) {
                continue
            } else if Self.fieldKeys.contains(key) {
                notes.append("/\(key) differs: the field's \(Self.short(fv)) is kept, the widget's \(Self.short(wv)) is dropped.")
            } else {
                sets.append((key, try doc.getSyntax(wn, key)))
                notes.append("/\(key) differs: the widget's \(Self.short(wv)) is kept, the field's \(Self.short(fv)) is dropped.")
            }
        }

        // /P must name the page whose /Annots lists the merged dictionary.
        if w["P"].refNumber != page {
            notes.append(w["P"].isNull
                ? "The widget had no /P; it is set to the page that lists it."
                : "The widget's /P \(Self.short(w["P"])) is not the page that lists it; /P is set to that page.")
        }
        if f["P"].refNumber != page {
            if !f["P"].isNull { notes.append("The field's own /P \(Self.short(f["P"])) is replaced by the widget's page.") }
            sets.append(("P", "\(page) 0 R"))
        }

        // /AA: one dictionary holds both the field's and the widget's triggers.
        if !w["AA"].isNull {
            if f["AA"].isNull {
                sets.append(("AA", try doc.getSyntax(wn, "AA")))
            } else {
                var merged = (try doc.resolve(f["AA"])).dict ?? [:]
                let wAA = (try doc.resolve(w["AA"])).dict ?? [:]
                for (trig, wv) in wAA.sorted(by: { $0.key < $1.key }) {
                    guard let fv = merged[trig] else { merged[trig] = wv; continue }
                    if same(fv, wv) { continue }
                    if Self.fieldTriggers.contains(trig) {
                        notes.append("/AA /\(trig) differs: the field's action is kept, the widget's is dropped.")
                    } else {
                        merged[trig] = wv
                        notes.append("/AA /\(trig) differs: the widget's action is kept, the field's is dropped.")
                    }
                }
                sets.append(("AA", PDFValue.dict(merged).syntax))
            }
        }
        return Plan(field: field, widget: wn, page: page, sets: sets, notes: notes)
    }

    /// Applies a plan: key-level edits on the field, references retargeted, widget nulled.
    func apply(_ plan: Plan) throws {
        for (key, syntax) in plan.sets { try doc.setSyntax(plan.field, key, syntax) }
        try retargetReferences(from: plan.widget, to: plan.field)
        try doc.update(plan.widget, .null)
    }

    /// Page object number whose /Annots lists `widget`.
    private func pageListing(widget: Int) throws -> Int? {
        for i in 0..<(try doc.pageCount) {
            let pn = try doc.pageObjectNumber(i)
            let annots = (try? doc.resolve(try doc.get(pn, "Annots")))?.array ?? []
            if annots.contains(where: { $0.refNumber == widget }) { return pn }
        }
        return nil
    }

    /// Points every reference to object `old` at object `new`, in every object of the file
    /// except those two. Arrays that already list `new` drop `old` instead (no duplicate
    /// entries in /Fields or /Annots). Only top-level keys that contain the reference are
    /// rewritten, so everything else in those objects stays as it was.
    @discardableResult
    func retargetReferences(from old: Int, to new: Int) throws -> [Int] {
        let count = try doc.xrefLength
        let pattern = try NSRegularExpression(pattern: "(?<![0-9])\(old) [0-9]+ R")
        var touched: [Int] = []
        for num in 1..<max(count, 1) where num != old && num != new {
            guard let s = try? doc.objectSyntax(num),
                  pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil else { continue }
            let value = try PDFParser.parse(s)
            if case .dict(let d) = value {
                var changed = false
                for (k, v) in d {
                    let nv = Self.replacing(v, old: old, new: new)
                    if nv != v { try doc.set(num, k, nv); changed = true }
                }
                if changed { touched.append(num) }
            } else {
                let nv = Self.replacing(value, old: old, new: new)
                if nv != value { try doc.update(num, nv); touched.append(num) }
            }
        }
        return touched
    }

    static func replacing(_ v: PDFValue, old: Int, new: Int) -> PDFValue {
        switch v {
        case .ref(let n, _) where n == old:
            return .ref(new, 0)
        case .array(let a):
            let hasNew = a.contains { $0.refNumber == new }
            return .array(a.compactMap { item in
                if item.refNumber == old { return hasNew ? nil : .ref(new, 0) }
                return replacing(item, old: old, new: new)
            })
        case .dict(let d):
            return .dict(d.mapValues { replacing($0, old: old, new: new) })
        default:
            return v
        }
    }

    /// A short printable form of a value for notes.
    static func short(_ v: PDFValue) -> String {
        let s: String
        if let t = v.text { s = "\"\(t)\"" } else { s = v.syntax }
        return s.count > 60 ? String(s.prefix(57)) + "..." : s
    }
}

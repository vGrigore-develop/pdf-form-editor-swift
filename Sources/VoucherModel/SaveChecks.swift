import Foundation

/// One finding of the programmatic-fill checks (SPEC 6.2).
public struct SaveIssue: Hashable, Sendable, Identifiable {
    public enum Severity: Int, Hashable, Sendable, Comparable {
        /// Information only: listed in the inspector, never opens the save sheet.
        case info = -1, warning = 0, error = 1
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { "\(severity)|\(fieldID?.uuidString ?? "-")|\(message)" }
    public var severity: Severity
    public var message: String
    public var fieldID: UUID?

    public init(_ severity: Severity, _ message: String, field: UUID? = nil) {
        self.severity = severity
        self.message = message
        self.fieldID = field
    }
}

public enum OutlineContainment: Sendable {
    case inside, partial, outside
}

/// SPEC 6.2. Errors need an explicit "Save anyway"; warnings are listed only.
public enum SaveChecks {
    /// - Parameters:
    ///   - template: the edited model.
    ///   - baselineNames: qualified names at the last save/open, by field id (for the rename list).
    ///   - facts: document facts (signatures, JS, XFA, repair).
    ///   - containment: field-vs-outline test for pages that have an outline (Geometry supplies it).
    public static func run(template: Template,
                           baselineNames: [UUID: String] = [:],
                           facts: DocumentFacts = DocumentFacts(),
                           containment: (FieldDef, Outline) -> OutlineContainment = { _, _ in .inside }) -> [SaveIssue] {
        var issues: [SaveIssue] = []
        func err(_ m: String, _ f: FieldDef? = nil) { issues.append(SaveIssue(.error, m, field: f?.id)) }
        func warn(_ m: String, _ f: FieldDef? = nil) { issues.append(SaveIssue(.warning, m, field: f?.id)) }
        func info(_ m: String, _ f: FieldDef? = nil) { issues.append(SaveIssue(.info, m, field: f?.id)) }

        let fields = template.fields

        // --- Names
        var byName: [String: [FieldDef]] = [:]
        var byLower: [String: Set<String>] = [:]
        for f in fields {
            byName[f.qualifiedName, default: []].append(f)
            byLower[f.qualifiedName.lowercased(), default: []].insert(f.qualifiedName)
        }
        for f in fields where f.name.isEmpty { err("A field has an empty name.", f) }
        for (name, list) in byName.sorted(by: { $0.key < $1.key }) where list.count > 1 && !name.isEmpty {
            // Fields read with several widgets are one field; duplicates here are distinct defs.
            err("Duplicate field name \"\(name)\" (\(list.count) fields).", list[0])
        }
        for (_, variants) in byLower.sorted(by: { $0.key < $1.key }) where variants.count > 1 {
            warn("Names differ only in case: \(variants.sorted().joined(separator: ", ")).")
        }
        for f in fields where !f.name.isEmpty {
            let problems = Naming.problems(for: f.name, isNew: f.isNew)
            if problems.contains(.containsDot) { err("\"\(f.name)\": \(Naming.Problem.containsDot.message)", f) }
            if problems.contains(.containsSpace) || problems.contains(.nonASCII) || (f.origin?.isHierarchical == false && f.name.contains(".")) {
                warn("\"\(f.qualifiedName)\" contains spaces, dots or non-ASCII characters.", f)
            }
            if f.origin?.isHierarchical == true {
                warn("\"\(f.qualifiedName)\" is a hierarchical name; code must address it by the full dotted name.", f)
            }
        }

        // --- Structure (fields read from the file)
        for f in fields {
            guard let o = f.origin else { continue }
            if o.widgetCount > 1 { err("\"\(f.qualifiedName)\" has \(o.widgetCount) widgets (not marked as linked).", f) }
            if !o.inPageAnnots { err("\"\(f.qualifiedName)\": widget is not in its page's /Annots.", f) }
            if !o.hasPageRef { err("\"\(f.qualifiedName)\": widget has no /P (page) entry.", f) }
            if !o.inAcroFormFields { err("\"\(f.qualifiedName)\" is missing from /AcroForm /Fields.", f) }
            if f.kind != .other && !o.daParsed && !f.isEditable {
                err("\"\(f.qualifiedName)\": /DA is not parseable.", f)
            }
        }

        // --- Rects and pages
        for f in fields {
            if f.rect.width <= 0 || f.rect.height <= 0 {
                err("\"\(f.qualifiedName)\": /Rect has zero or negative size.", f)
            }
            if template.pages.indices.contains(f.page) {
                let box = template.pages[f.page].mediaBox
                if !box.contains(f.rect, tolerance: 0.01) { err("\"\(f.qualifiedName)\": /Rect is outside the page.", f) }
                if template.pages[f.page].rotation != 0 {
                    warn("\"\(f.qualifiedName)\" is on a rotated page (/Rotate \(template.pages[f.page].rotation)); code that uses raw rects may place content rotated.", f)
                }
            } else {
                err("\"\(f.qualifiedName)\" is on a page that does not exist.", f)
            }
            let outlinePages = Set(template.outlines.keys)
            if f.page != 0 && !outlinePages.contains(f.page) {
                warn("\"\(f.qualifiedName)\" is on page \(f.page + 1) (expected page 1 or the page with the outline).", f)
            }
        }

        // --- Text field properties
        for f in fields where f.kind == .text {
            let t = f.text
            if t.comb && t.maxLength == nil { err("\"\(f.qualifiedName)\": comb requires a max length.", f) }
            if t.comb && (t.multiline || t.password || t.fileSelect) {
                err("\"\(f.qualifiedName)\": comb cannot be combined with multiline, password or file select.", f)
            }
            if let m = t.maxLength, m <= 0 { err("\"\(f.qualifiedName)\": max length must be positive.", f) }
            if t.fontSize == 0 { warn("\"\(f.qualifiedName)\": auto font size (0); fillers handle it inconsistently.", f) }
            if t.comb || t.maxLength != nil { warn("\"\(f.qualifiedName)\": comb / max length support varies between filling libraries.", f) }
            if !t.defaultValue.isEmpty {
                warn("\"\(f.qualifiedName)\" has a value (/V); the filled output shows it unless code overwrites it.", f)
            }
            if f.isEditable && !DAFormat.isValidFontName(t.fontName) {
                err("\"\(f.qualifiedName)\": font name \"\(t.fontName)\" is not a plain ASCII resource name.", f)
            }
        }

        // --- Outline and overlaps
        for f in fields {
            guard let o = template.outlines[f.page] else { continue }
            switch (containment(f, o), template.cropFieldsToOutline) {
            case (.inside, _): break
            case (.partial, false): warn("\"\(f.qualifiedName)\" is partly outside the outline; it will show outside the cut shape.", f)
            case (.outside, false): warn("\"\(f.qualifiedName)\" is outside the outline; it will show outside the cut shape.", f)
            // Cropped (S10): the template shows only the part inside the shape. What filling code
            // regenerates without flattening (pdf-lib setImage, setText) is not cropped in
            // Chrome or MuPDF-based viewers, so this stays visible as information.
            case (.partial, true): info("\"\(f.qualifiedName)\" crosses the outline and is cropped to it. An appearance that filling code rebuilds without flattening can still show outside in Chrome; Fit to Outline avoids that.", f)
            case (.outside, true): warn("\"\(f.qualifiedName)\" is outside the outline; cropped to the outline, it is invisible.", f)
            }
        }
        for i in fields.indices {
            for j in fields.indices where j > i {
                let a = fields[i], b = fields[j]
                if a.page == b.page && a.rect.intersects(b.rect) {
                    warn("\"\(a.qualifiedName)\" and \"\(b.qualifiedName)\" overlap.", a)
                }
            }
        }

        // --- Renames since the last save
        for f in fields {
            if let old = baselineNames[f.id], old != f.qualifiedName {
                warn("Renamed \"\(old)\" to \"\(f.qualifiedName)\"; code that fills the template by name will break.", f)
            }
        }

        // --- Document-level
        if facts.signatureCount > 0 {
            warn(facts.hasCertification
                 ? "The document has a certification signature; Acrobat shows added fields as a disallowed change."
                 : "The document is signed; the signed bytes stay intact, but strict validators report added fields as a modification.")
        }
        if facts.hasXFA { warn("The document contains XFA; Acrobat may show the XFA layer rather than the edited AcroForm.") }
        if facts.hasJavaScript { warn("The document contains JavaScript (preserved, never run).") }

        return issues.sorted { ($0.severity, $1.message) > ($1.severity, $0.message) }
    }
}

/// Parsing and validation of the minimal /DA form SPEC 6.1 requires.
public enum DAFormat {
    public struct Parsed: Equatable, Sendable {
        public var fontName: String
        public var size: Double
        public var color: RGBColor
    }

    public static func isValidFontName(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value < 127 && !"()<>[]{}/%#".unicodeScalars.contains($0) }
    }

    /// Parse `/Font size Tf` plus an optional colour (`g`, `rg` or `k`). Returns nil if
    /// there is no `Tf`. Tolerates extra operators (read side); the app writes only the minimal form.
    public static func parse(_ da: String) -> Parsed? {
        let toks = da.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).map(String.init)
        var font: String?
        var size: Double?
        var color = RGBColor.black
        var stack: [String] = []
        for t in toks {
            switch t {
            case "Tf":
                if stack.count >= 2, stack[stack.count - 2].hasPrefix("/"), let s = Double(stack[stack.count - 1]) {
                    font = String(stack[stack.count - 2].dropFirst())
                    size = s
                }
                stack.removeAll()
            case "g":
                if let v = stack.last.flatMap(Double.init) { color = RGBColor(gray: v) }
                stack.removeAll()
            case "rg":
                if stack.count >= 3, let r = Double(stack[stack.count - 3]), let g = Double(stack[stack.count - 2]), let b = Double(stack[stack.count - 1]) {
                    color = RGBColor(r, g, b)
                }
                stack.removeAll()
            case "k":
                if stack.count >= 4, let c = Double(stack[stack.count - 4]), let m = Double(stack[stack.count - 3]),
                   let y = Double(stack[stack.count - 2]), let k = Double(stack[stack.count - 1]) {
                    color = RGBColor((1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k))
                }
                stack.removeAll()
            default:
                stack.append(t)
            }
        }
        guard let f = font, let s = size else { return nil }
        return Parsed(fontName: f, size: s, color: color)
    }
}

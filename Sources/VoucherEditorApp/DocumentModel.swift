import AppKit
import PDFKit
import Combine
import VoucherModel
import VoucherGeometry
import PDFEngine
import MuPDFEngine

enum Tool: String, CaseIterable, Identifiable {
    case select, text, image, outline
    var id: String { rawValue }
    var label: String {
        switch self {
        case .select: return "Select"
        case .text: return "Text Field"
        case .image: return "Image Field"
        case .outline: return "Outline"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .text: return "character.textbox"
        case .image: return "photo"
        case .outline: return "scribble.variable"
        }
    }
    var key: String {
        switch self {
        case .select: return "V"
        case .text: return "T"
        case .image: return "I"
        case .outline: return "O"
        }
    }
}

/// Per-document state shared by the canvas, sidebar, inspector and status bar.
/// The model (`TemplateEditor.template`) is what the UI changes; the engine owns
/// the bytes (single writer, SPEC 7.2).
@MainActor
final class DocumentModel: ObservableObject {
    let editor: TemplateEditor
    private(set) var engine: MuPDFEngine
    /// What was read or last saved; the save diffs `editor.template` against it.
    private(set) var baseline: Template
    private var baselineNames: [UUID: String]

    /// Bytes PDFKit displays: the original on open, the engine's bytes after a save.
    @Published private(set) var displayData: Data
    @Published private(set) var previewData: Data?
    @Published var isPreview = false { didSet { if isPreview != oldValue { updatePreview() } } }
    @Published private(set) var facts: DocumentFacts
    @Published private(set) var notes: [String]
    @Published var tool: Tool = .select
    @Published var currentPage = 0
    @Published var selectedVertex: Int?
    @Published private(set) var lastSave: String?
    @Published var errorMessage: String?

    weak var pdfView: PDFView?
    private var bag: Set<AnyCancellable> = []

    init(data: Data, undoManager: UndoManager?) throws {
        let engine = try MuPDFEngine(data: data)
        let read = try engine.readTemplate()
        self.engine = engine
        self.baseline = read.template
        self.baselineNames = Dictionary(uniqueKeysWithValues: read.template.fields.map { ($0.id, $0.qualifiedName) })
        self.displayData = data
        self.facts = read.facts
        self.notes = read.notes
        self.editor = TemplateEditor(template: read.template, undoManager: undoManager)
        editor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        // Inspector edits made while Preview is showing rebuild it, so a changed colour,
        // border or sample shows at once instead of only after leaving and re-entering Preview.
        editor.$template.dropFirst().sink { [weak self] _ in self?.schedulePreviewUpdate() }.store(in: &bag)
    }

    var template: Template { editor.template }
    var hasUnsavedModelChanges: Bool { editor.template != baseline }

    // MARK: Checks

    func containment(_ f: FieldDef, _ o: Outline) -> OutlineContainment {
        Geometry.containment(of: f.rect, in: o)
    }

    func runChecks() -> [SaveIssue] {
        var issues = SaveChecks.run(template: template, baselineNames: baselineNames, facts: facts,
                                    containment: { [weak self] f, o in self?.containment(f, o) ?? .inside })
        for (page, o) in template.outlines.sorted(by: { $0.key < $1.key }) {
            for p in Geometry.validate(o) {
                issues.insert(SaveIssue(.error, "Outline on page \(page + 1): \(p.message)"), at: 0)
            }
            if facts.signatureCount > 0 && baseline.outlines[page] != o {
                issues.insert(SaveIssue(.error, "Page \(page + 1): a shape cut changes page content, so it is refused on signed documents."), at: 0)
            }
        }
        if facts.wasRepaired {
            issues.append(SaveIssue(.warning, "MuPDF repaired this file on open; it can only be saved as a full rewrite (Save As)."))
        }
        return issues
    }

    /// Live warnings per field, for the canvas and the field list.
    func fieldWarnings(_ f: FieldDef) -> [String] {
        var out: [String] = []
        // A field cropped to the outline (S10) crossing it is not a problem; fully outside is
        // (cropped, it is invisible), and so is any crossing when cropping is off.
        if let o = template.outlines[f.page] {
            let c = containment(f, o)
            if c == .outside || (c == .partial && !template.cropFieldsToOutline) { out.append("Partly or fully outside the outline") }
        }
        if f.name.isEmpty { out.append("Empty name") }
        if template.fields.contains(where: { $0.id != f.id && $0.qualifiedName == f.qualifiedName }) { out.append("Duplicate name") }
        if let old = baselineNames[f.id], old != f.qualifiedName { out.append("Renamed from \"\(old)\"") }
        if let reason = f.origin?.readOnlyReason, !f.isEditable { out.append(reason) }
        return out
    }

    func originalName(of id: UUID) -> String? { baselineNames[id] }

    /// The field crosses its page's outline and the save crops it (S10, DECISIONS 30).
    func isCropped(_ f: FieldDef) -> Bool {
        template.isCropped(f) { [weak self] f, o in self?.containment(f, o) ?? .inside }
    }

    /// "Fit to Outline": the largest rectangle inside both the field and the outline,
    /// rounded inward to 0.01 pt. nil when the field has no outline or is not crossing it.
    func fittedRect(_ f: FieldDef) -> PDFRect? {
        guard let o = template.outlines[f.page], containment(f, o) == .partial,
              let r = Geometry.largestRect(inside: o, within: f.rect) else { return nil }
        func up(_ v: Double) -> Double { (v * 100).rounded(.up) / 100 }
        func down(_ v: Double) -> Double { (v * 100).rounded(.down) / 100 }
        return PDFRect(x1: up(r.minX), y1: up(r.minY), x2: down(r.maxX), y2: down(r.maxY))
    }

    /// "Merge field and widget" was pressed since the last save (the save applies it).
    func isWidgetMergePending(_ id: UUID) -> Bool {
        template.field(id)?.origin?.mergeWidgetOnSave == true && baseline.field(id)?.origin?.mergeWidgetOnSave != true
    }

    // MARK: Save

    /// Produce the bytes to write (called from NSDocument's data(ofType:)).
    func saveData(incremental: Bool) throws -> Data {
        let edited = template
        let result = try engine.save(baseline: baseline, edited: edited, incremental: incremental)
        baseline = edited
        baselineNames = Dictionary(uniqueKeysWithValues: edited.fields.map { ($0.id, $0.qualifiedName) })
        displayData = result.data
        let kb = Double(result.appendedBytes) / 1024
        lastSave = result.wasIncremental ? String(format: "Saved (incremental, +%.1f KB)", kb) : "Saved (full rewrite)"
        if isPreview { updatePreview() }
        return result.data
    }

    // MARK: Preview (SPEC 7.2: an in-memory copy, shown with annotations visible)

    private var previewUpdatePending = false

    /// Rebuild the Preview after the current change has been applied (the publisher fires
    /// before the new template is stored); consecutive changes coalesce into one build.
    func schedulePreviewUpdate() {
        guard isPreview, !previewUpdatePending else { return }
        previewUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.previewUpdatePending = false
            if self.isPreview { self.updatePreview() }
        }
    }

    func updatePreview() {
        guard isPreview else { previewData = nil; return }
        var t = template
        for i in t.fields.indices where t.fields[i].kind == .text {
            let sample = t.fields[i].text.sampleValue.isEmpty ? t.fields[i].name : t.fields[i].text.sampleValue
            t.fields[i].text.defaultValue = sample
        }
        do {
            previewData = try engine.previewData(baseline: baseline, edited: t)
        } catch {
            errorMessage = "Preview failed: \(error.localizedDescription)"
            isPreview = false
        }
    }

    // MARK: Field creation helpers

    func newField(kind: FieldKind, rect: PDFRect, page: Int) -> FieldDef {
        let base = kind == .image ? "image" : "text"
        let name = Naming.uniqueName(base: base, existing: Set(template.fields.map(\.name)))
        var f = FieldDef(kind: kind, name: name, page: page, rect: rect.rounded)
        if kind == .text { f.text.fontSize = 12 }
        return f
    }

    func pageBounds(_ page: Int) -> PDFRect {
        template.pages.indices.contains(page) ? template.pages[page].mediaBox : PDFRect(x: 0, y: 0, width: 612, height: 792)
    }

    // MARK: Outline helpers

    func defaultOutline(page: Int) -> Outline {
        let b = pageBounds(page)
        return Outline.rectangle(PDFRect(x: b.minX + 20, y: b.minY + 20, width: b.width - 40, height: b.height - 40))
    }

    /// A voucher-like starting shape: stepped left edge and a semicircular right end.
    func voucherOutline(page: Int) -> Outline {
        let b = pageBounds(page)
        let top = b.maxY - 50, bottom = b.minY + 50
        let r = (top - bottom) / 2
        let cx = b.maxX - 30 - r
        let left = b.minX + 40
        let step = 20.0
        let h = top - bottom
        return Outline(start: PDFPoint(cx, top), segments: [
            .line(to: PDFPoint(left, top)),
            .line(to: PDFPoint(left, top - h * 0.17)), .line(to: PDFPoint(left + step, top - h * 0.17)),
            .line(to: PDFPoint(left + step, top - h * 0.33)), .line(to: PDFPoint(left + 2 * step, top - h * 0.33)),
            .line(to: PDFPoint(left + 2 * step, bottom + h * 0.33)), .line(to: PDFPoint(left + step, bottom + h * 0.33)),
            .line(to: PDFPoint(left + step, bottom + h * 0.17)), .line(to: PDFPoint(left, bottom + h * 0.17)),
            .line(to: PDFPoint(left, bottom)), .line(to: PDFPoint(cx, bottom)),
            .arc(to: PDFPoint(cx, top), center: PDFPoint(cx, (top + bottom) / 2), clockwise: false),
        ])
    }
}

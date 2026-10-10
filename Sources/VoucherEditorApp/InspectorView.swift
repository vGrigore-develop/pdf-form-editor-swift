import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VoucherModel
import VoucherGeometry

/// Right-hand inspector (SPEC 3 "Inspector"): every property that matters for
/// code fillers, with a hint line explaining how libraries treat it.
struct InspectorView: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.tool == .outline {
                    OutlineInspector(model: model)
                } else if let f = model.editor.selectedField {
                    FieldInspector(model: model, field: f)
                        .id(f.id)
                } else {
                    DocumentSummary(model: model)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled) // titles, hints, warnings, read-only notes can be copied
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Helpers

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }
}

extension VoucherModel.RGBColor {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
    init(_ c: Color) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
        self.init((Double(ns.redComponent) * 1000).rounded() / 1000,
                  (Double(ns.greenComponent) * 1000).rounded() / 1000,
                  (Double(ns.blueComponent) * 1000).rounded() / 1000)
    }
}

private let numberFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))

// MARK: - Field inspector

struct FieldInspector: View {
    @ObservedObject var model: DocumentModel
    let field: FieldDef

    private var editor: TemplateEditor { model.editor }
    private var current: FieldDef { editor.template.field(field.id) ?? field }

    private func bind<T: Equatable>(_ kp: WritableKeyPath<FieldDef, T>, _ action: String) -> Binding<T> {
        let id = field.id
        let fallback = field[keyPath: kp]
        return Binding(
            get: { editor.template.field(id)?[keyPath: kp] ?? fallback },
            set: { v in editor.updateField(id, action, coalesceKey: action) { $0[keyPath: kp] = v } }
        )
    }

    private func colorBinding(_ kp: WritableKeyPath<FieldDef, VoucherModel.RGBColor>, _ action: String) -> Binding<Color> {
        let b = bind(kp, action)
        return Binding(get: { b.wrappedValue.color }, set: { b.wrappedValue = VoucherModel.RGBColor($0) })
    }

    private func optionalColor(_ kp: WritableKeyPath<FieldDef, VoucherModel.RGBColor?>, _ action: String, defaultColor: VoucherModel.RGBColor) -> some View {
        let b = bind(kp, action)
        return HStack {
            Toggle("", isOn: Binding(get: { b.wrappedValue != nil }, set: { b.wrappedValue = $0 ? defaultColor : nil }))
                .labelsHidden().toggleStyle(.checkbox)
            ColorPicker("", selection: Binding(get: { (b.wrappedValue ?? defaultColor).color }, set: { b.wrappedValue = VoucherModel.RGBColor($0) }),
                        supportsOpacity: false)
                .labelsHidden().disabled(b.wrappedValue == nil)
            if b.wrappedValue == nil { Text("none").foregroundStyle(.secondary).font(.caption) }
        }
    }

    var body: some View {
        let f = current
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: f.kind == .image ? "photo" : (f.kind == .text ? "character.textbox" : "lock"))
                Text(f.kind == .image ? "Image field" : (f.kind == .text ? "Text field" : "Field (\(f.origin?.typeName ?? "?"))"))
                    .font(.headline)
                Spacer()
                if f.isNew { Text("new").font(.caption).padding(.horizontal, 5).background(Capsule().fill(Color.accentColor.opacity(0.2))) }
            }
            if !f.isEditable {
                Label(f.origin?.readOnlyReason ?? "Read-only", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.orange)
                if f.hasSeparateWidget {
                    MergeWidgetBox(model: model, field: f)
                } else {
                    Hint("This field is shown read-only and preserved exactly as it is in the file.")
                }
            }
            if model.isWidgetMergePending(f.id) {
                Label("Field and widget are merged into one object when you save. Undo puts them back until then.",
                      systemImage: "arrow.triangle.merge")
                    .font(.caption)
            }

            Group {
                SectionHeader("Identity")
                LabeledContent("Name") {
                    TextField("name", text: bind(\.name, "Rename")).textFieldStyle(.roundedBorder)
                }
                ForEach(Naming.problems(for: f.name, isNew: f.isNew), id: \.message) { p in
                    Label(p.message, systemImage: p.isError ? "xmark.octagon.fill" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(p.isError ? .red : .orange)
                }
                if let old = model.originalName(of: f.id), old != f.qualifiedName {
                    Label("Renamed from \"\(old)\". Code that fills the template by name will break.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if f.origin?.isHierarchical == true {
                    Hint("Hierarchical name: code addresses it as \"\(f.qualifiedName)\". Only the last part can be renamed.")
                }
                LabeledContent("Tooltip") {
                    TextField("shown on hover", text: bind(\.tooltip, "Tooltip")).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Toggle("Required", isOn: bind(\.required, "Required"))
                    Toggle("Read-only", isOn: bind(\.readOnly, "Read-only"))
                }
                Hint("Required and read-only are /Ff bits 2 and 1. Fillers ignore them; viewers enforce them for people typing.")
            }
            .disabled(!f.isEditable)

            Group {
                SectionHeader("Position (pt, origin bottom-left)")
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        numberField("x", bind(\.rect.x, "Move"))
                        numberField("y", bind(\.rect.y, "Move"))
                    }
                    GridRow {
                        numberField("w", bind(\.rect.width, "Resize"))
                        numberField("h", bind(\.rect.height, "Resize"))
                    }
                }
                Hint("Page \(f.page + 1). This is the /Rect code reads to place text or images.")
                ForEach(model.fieldWarnings(f).filter { $0.hasPrefix("Partly") }, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                }
                if model.isCropped(f) {
                    Label("Crosses the outline: cropped to it when saved, so the part outside is hidden.", systemImage: "scissors")
                        .font(.caption)
                }
                if model.template.outlines[f.page] != nil, model.containment(f, model.template.outlines[f.page]!) == .partial {
                    Button("Fit to Outline") {
                        if let r = model.fittedRect(f) { editor.updateField(f.id, "Fit to Outline") { $0.rect = r } }
                    }
                    Hint("Shrinks the field to the largest rectangle inside the outline. Then nothing of it can show outside the shape, whatever the filling code does (cropping does not reach an appearance that code rebuilds without flattening).")
                }
            }
            .disabled(!f.isEditable)

            if f.kind == .text { textSection(f).disabled(!f.isEditable) }
            if f.kind == .image { imageSection(f).disabled(!f.isEditable) }

            if f.isEditable {
                HStack {
                    Button("Duplicate") { editor.duplicateField(f.id) }
                    Button("Delete", role: .destructive) { editor.deleteField(f.id) }
                }
                .padding(.top, 6)
            }
        }
    }

    private func numberField(_ label: String, _ b: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).frame(width: 12, alignment: .leading)
            TextField(label, value: b, format: numberFormat).textFieldStyle(.roundedBorder).frame(width: 80)
        }
    }

    @ViewBuilder
    private func textSection(_ f: FieldDef) -> some View {
        SectionHeader("Text")
        LabeledContent("Font") {
            Text("/\(f.text.fontName)").font(.body.monospaced())
        }
        Hint(f.text.fontName == "Helv"
             ? "Base-14 Helvetica, WinAnsi. Romanian ă ș ț need a Unicode font supplied by the filling code (pdf-lib: updateFieldAppearances(font)). Noto Sans embedding is pending spike S2."
             : "Font from the file's /DR, kept as it is.")
        LabeledContent("Size") {
            HStack {
                TextField("size", value: bind(\.text.fontSize, "Font Size"), format: numberFormat)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                Stepper("", value: bind(\.text.fontSize, "Font Size"), in: 0...144, step: 1).labelsHidden()
                Text(f.text.fontSize == 0 ? "auto" : "pt").foregroundStyle(.secondary)
            }
        }
        if f.text.fontSize == 0 {
            Hint("Auto size: pdf-lib shrinks to fit; PyMuPDF and pypdf use a default size.")
        }
        LabeledContent("Colour") {
            ColorPicker("", selection: colorBinding(\.text.color, "Text Colour"), supportsOpacity: false).labelsHidden()
        }
        LabeledContent("Alignment") {
            Picker("", selection: bind(\.text.alignment, "Alignment")) {
                Text("Left").tag(VoucherModel.TextAlignment.left)
                Text("Center").tag(VoucherModel.TextAlignment.center)
                Text("Right").tag(VoucherModel.TextAlignment.right)
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        Hint("Alignment is /Q. pdf-lib, PyMuPDF and pypdf honour it when they regenerate the appearance.")
        Toggle("Multiline", isOn: bind(\.text.multiline, "Multiline"))
        Toggle("Do not scroll", isOn: bind(\.text.doNotScroll, "Do Not Scroll"))
        HStack {
            Toggle("Max length", isOn: Binding(get: { current.text.maxLength != nil },
                                               set: { on in editor.updateField(field.id, "Max Length") { $0.text.maxLength = on ? 10 : nil; if !on { $0.text.comb = false } } }))
            if f.text.maxLength != nil {
                TextField("", value: Binding(get: { current.text.maxLength ?? 10 },
                                             set: { v in editor.updateField(field.id, "Max Length", coalesceKey: "maxlen") { $0.text.maxLength = max(1, v) } }),
                          format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
            }
        }
        Toggle("Comb (one character per cell)", isOn: bind(\.text.comb, "Comb"))
            .disabled(f.text.maxLength == nil || f.text.multiline)
        if f.text.comb || f.text.maxLength != nil {
            Hint("Comb and max length support varies between filling libraries.")
        }
        LabeledContent("Default value") {
            TextField("written as /V and /DV", text: bind(\.text.defaultValue, "Default Value")).textFieldStyle(.roundedBorder)
        }
        if !f.text.defaultValue.isEmpty {
            Hint("A default value shows in the filled output unless code overwrites it.")
        }
        LabeledContent("Sample (Preview)") {
            TextField("never written as /V", text: bind(\.text.sampleValue, "Sample Value")).textFieldStyle(.roundedBorder)
        }
        Hint("The sample shows only in Preview (Cmd-P), in this field's font, size and colour; the field name is used when it is empty. It is never saved.")
        SectionHeader("Box")
        LabeledContent("Border") { optionalColor(\.text.borderColor, "Border Colour", defaultColor: VoucherModel.RGBColor(gray: 0.45)) }
        LabeledContent("Border width") {
            TextField("", value: bind(\.text.borderWidth, "Border Width"), format: numberFormat).textFieldStyle(.roundedBorder).frame(width: 60)
        }
        LabeledContent("Background") { optionalColor(\.text.backgroundColor, "Background", defaultColor: .white) }
    }

    private func chooseSampleImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a sample image for Preview (it is not saved in the PDF)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editor.updateField(field.id, "Sample Image") { $0.image.sampleImagePath = url.path }
    }

    @ViewBuilder
    private func imageSection(_ f: FieldDef) -> some View {
        SectionHeader("Image fit (/MK /IF)")
        Picker("Scale when", selection: bind(\.image.scaleWhen, "Scale When")) {
            Text("Always").tag(ScaleWhen.always)
            Text("Image too big").tag(ScaleWhen.tooBig)
            Text("Image too small").tag(ScaleWhen.tooSmall)
            Text("Never").tag(ScaleWhen.never)
        }
        Picker("Scale how", selection: bind(\.image.scaleHow, "Scale How")) {
            Text("Proportional").tag(ScaleHow.proportional)
            Text("Stretch").tag(ScaleHow.stretch)
        }
        LabeledContent("Alignment") {
            VStack(alignment: .leading, spacing: 6) {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    ForEach([1.0, 0.5, 0.0], id: \.self) { y in
                        GridRow {
                            ForEach([0.0, 0.5, 1.0], id: \.self) { x in
                                let on = abs(f.image.alignX - x) < 0.01 && abs(f.image.alignY - y) < 0.01
                                Button {
                                    editor.updateField(field.id, "Image Alignment") { $0.image.alignX = x; $0.image.alignY = y }
                                } label: {
                                    RoundedRectangle(cornerRadius: 2).fill(on ? Color.accentColor : Color.secondary.opacity(0.25))
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                HStack {
                    numberField("x", bind(\.image.alignX, "Image Alignment"))
                    numberField("y", bind(\.image.alignY, "Image Alignment"))
                }
            }
        }
        Toggle("Fit to bounds (ignore border)", isOn: bind(\.image.fitBounds, "Fit Bounds"))
        Hint("These are hints. Most filling libraries ignore /IF and place images themselves: pdf-lib setImage fits proportionally and centred; PyMuPDF insert_image and pypdf draw where the code says.")
        SectionHeader("Placeholder")
        LabeledContent("Label") {
            TextField("label", text: bind(\.image.label, "Placeholder Label")).textFieldStyle(.roundedBorder)
        }
        LabeledContent("Background") { optionalColor(\.image.backgroundColor, "Placeholder Background", defaultColor: VoucherModel.RGBColor(gray: 0.92)) }
        LabeledContent("Border") { optionalColor(\.image.borderColor, "Placeholder Border", defaultColor: VoucherModel.RGBColor(gray: 0.5)) }
        LabeledContent("Border width") {
            TextField("", value: bind(\.image.borderWidth, "Placeholder Border Width"), format: numberFormat).textFieldStyle(.roundedBorder).frame(width: 60)
        }
        SectionHeader("Sample image (Preview)")
        HStack {
            Button("Choose…") { chooseSampleImage() }
            if !f.image.sampleImagePath.isEmpty {
                Text((f.image.sampleImagePath as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    .help(f.image.sampleImagePath)
                Button("Clear") { editor.updateField(field.id, "Sample Image") { $0.image.sampleImagePath = "" } }
            } else {
                Text("none").foregroundStyle(.secondary).font(.caption)
            }
        }
        Hint("Shown only in Preview (Cmd-P), placed with the fit settings above. It is never saved.")
        Hint("Fillers that draw the image as page content (PyMuPDF insert_image, pypdf) must delete the widget afterwards, or this placeholder covers the image (spike S9).")
        SectionHeader("Acrobat")
        Toggle("Click-to-insert action", isOn: bind(\.image.importAction, "Click-to-insert"))
        Hint("Writes event.target.buttonImportIcon(); as the mouse-up action, so Acrobat opens an image chooser. Harmless to code fillers, but some security scanners flag any JavaScript.")
        if f.origin?.hasForeignAction == true {
            Label("This field has its own action; the app leaves it untouched.", systemImage: "info.circle").font(.caption)
        }
    }
}

// MARK: - Merge field and widget (DECISIONS 29)

struct MergeWidgetBox: View {
    @ObservedObject var model: DocumentModel
    let field: FieldDef

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.editor.mergeFieldAndWidget(field.id)
            } label: {
                Label("Merge field and widget", systemImage: "arrow.triangle.merge")
            }
            .disabled(!field.canMergeWidget)
            if let blocker = field.origin?.widgetMergeBlocker {
                Label(blocker, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }
            Hint("Combines the field and its single widget into one object, the shape the app edits. The name stays \"\(field.qualifiedName)\", so code that fills by name is unaffected; filling libraries still see exactly one widget with the same rect, and nothing changes in how it looks. Applied on save as an incremental update.")
            ForEach(field.origin?.widgetMergeNotes ?? [], id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.caption)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - Document summary (nothing selected)

struct DocumentSummary: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        let t = model.template
        VStack(alignment: .leading, spacing: 10) {
            Text("Template").font(.headline)
            Text("\(t.pages.count) page(s), \(t.fields.count) field(s)")
            if let p = t.pages.first {
                Text("Page 1: \(PDFNumber.format(p.mediaBox.width)) × \(PDFNumber.format(p.mediaBox.height)) pt\(p.rotation != 0 ? ", rotated \(p.rotation)°" : "")")
                    .foregroundStyle(.secondary)
            }
            SectionHeader("How to add fields")
            Hint("Pick Text (T) or Image (I) in the toolbar and drag on the page; a click creates a default-size field. Select (V) to move, resize with the handles, arrows nudge 1 pt (Shift: 10 pt). Delete removes, Cmd-D duplicates.")
            SectionHeader("Shape cut")
            Hint("Switch to the Outline tool (O) to draw the cut outline or start from a preset; the outside is dimmed, and Save writes a real clip that viewers render as die-cut.")
            let issues = model.runChecks()
            SectionHeader("Save checks (\(issues.count))")
            if issues.isEmpty {
                Label("No problems found.", systemImage: "checkmark.seal").foregroundStyle(.green)
            }
            ForEach(issues) { i in
                Button {
                    if let id = i.fieldID { model.editor.selection = id }
                } label: {
                    Label(i.message, systemImage: i.severity == .error ? "xmark.octagon.fill" : (i.severity == .info ? "info.circle" : "exclamationmark.triangle"))
                        .foregroundStyle(i.severity == .error ? .red : (i.severity == .info ? .secondary : .orange))
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
            if !model.notes.isEmpty {
                SectionHeader("Notes from opening")
                ForEach(model.notes, id: \.self) { Hint($0) }
            }
        }
    }
}

// MARK: - Outline inspector

struct OutlineInspector: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        let page = model.currentPage
        let outline = model.template.outlines[page]
        VStack(alignment: .leading, spacing: 10) {
            Text("Outline, page \(page + 1)").font(.headline)
            if let o = outline {
                let c = o.counts
                Text("\(c.lines) lines, \(c.arcs) arcs, \(c.curves) curves").foregroundStyle(.secondary)
                ForEach(Geometry.validate(o), id: \.message) { p in
                    Label(p.message, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                }
                Hint("Drag points (snaps to the 1 pt grid and to other points' x/y). Option-click a segment to insert a point; select a point and press Delete to remove it. Drag an arc's centre cross to change its bulge.")
                Toggle("Keep fields inside outline", isOn: Binding(
                    get: { model.template.keepFieldsInsideOutline },
                    set: { v in model.editor.perform("Keep Inside Outline") { $0.keepFieldsInsideOutline = v } }))
                Hint("Moving or resizing stops a field at the outline once it is inside.")
                Toggle("Crop fields to outline", isOn: Binding(
                    get: { model.template.cropFieldsToOutline },
                    set: { v in model.editor.perform(v ? "Crop Fields to Outline" : "Don't Crop Fields") { $0.cropFieldsToOutline = v } }))
                Hint(cropHelp)
                if let vi = model.selectedVertex, vi < o.points.count { vertexEditor(o, vi, page) }
                SectionHeader("Segments")
                ForEach(Array(o.segments.enumerated()), id: \.offset) { i, s in
                    segmentRow(o, i, s, page)
                }
                HStack {
                    Button("Remove Cut", role: .destructive) {
                        model.editor.setOutline(nil, page: page, actionName: "Remove Cut")
                        model.selectedVertex = nil
                    }
                }
                Hint("Removing the cut restores the page content exactly (the original streams are never modified).")
            } else {
                Hint("Click on the page to place points; Shift constrains to 0/45/90°. Click the first point (or press Return) to close the path. Esc cancels.")
                SmartOutlineSettings()
                Button("New from Rectangle") {
                    model.editor.setOutline(model.defaultOutline(page: page), page: page, actionName: "New Outline")
                }
                Button("New Voucher Shape (steps + semicircle)") {
                    model.editor.setOutline(model.voucherOutline(page: page), page: page, actionName: "New Outline")
                }
            }
            if model.facts.signatureCount > 0 {
                Label("This document is signed: a cut changes page content and is refused on save.", systemImage: "signature")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var cropHelp: String {
        "On (default): a field that crosses the outline is saved with its appearance clipped to the shape, its border drawn along the outline, and a white cover annotation (last on the page) hides what filling code draws outside the shape: images placed with PyMuPDF insert_image or pypdf, and flattened fields (pdf-lib, PyMuPDF, pypdf). "
        + "Not covered: an appearance the filling code rebuilds without flattening (pdf-lib setImage or setText) still shows outside in Chrome and MuPDF-based viewers (Preview hides it); flatten, or use Fit to Outline on the field. "
        + "The cover paints the outside white, which looks the same as the blank page in every viewer; turn this off if the voucher will be placed on a coloured background or the extra annotation gets in the way. Off restores the fields' own appearances exactly."
    }

    private func vertexEditor(_ o: Outline, _ vi: Int, _ page: Int) -> some View {
        let p = o.points[vi]
        func set(_ np: PDFPoint) {
            var n = o
            n.moveVertex(vi, to: np)
            model.editor.setOutline(n, page: page, actionName: "Move Outline Point")
        }
        return VStack(alignment: .leading) {
            SectionHeader("Point \(vi + 1)")
            HStack {
                Text("x").foregroundStyle(.secondary)
                TextField("x", value: Binding(get: { p.x }, set: { set(PDFPoint($0, p.y)) }), format: numberFormat)
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                Text("y").foregroundStyle(.secondary)
                TextField("y", value: Binding(get: { p.y }, set: { set(PDFPoint(p.x, $0)) }), format: numberFormat)
                    .textFieldStyle(.roundedBorder).frame(width: 80)
            }
        }
    }

    private func segmentRow(_ o: Outline, _ i: Int, _ s: Segment, _ page: Int) -> some View {
        let from = i == 0 ? o.start : o.segments[i - 1].end
        let kind: Binding<String> = Binding(get: { s.kindName }, set: { k in
            var n = o
            switch k {
            case "line": n.segments[i] = .line(to: s.end)
            case "arc":
                // A semicircle bulging to the left of the chord direction.
                let m = PDFPoint((from.x + s.end.x) / 2, (from.y + s.end.y) / 2)
                n.segments[i] = .arc(to: s.end, center: m, clockwise: true)
            default: return
            }
            model.editor.setOutline(n, page: page, actionName: "Change Segment")
        })
        return HStack {
            Text("\(i + 1)").font(.caption.monospacedDigit()).frame(width: 20, alignment: .trailing)
            Picker("", selection: kind) {
                Text("Line").tag("line")
                Text("Arc").tag("arc")
                if case .curve = s { Text("Curve").tag("curve") }
            }
            .labelsHidden().frame(width: 80)
            Text("→ \(PDFNumber.format(s.end.x)), \(PDFNumber.format(s.end.y))").font(.caption.monospacedDigit())
            if case .arc(let to, let c, let cw) = s {
                Button(cw ? "CW" : "CCW") {
                    var n = o
                    n.segments[i] = .arc(to: to, center: c, clockwise: !cw)
                    model.editor.setOutline(n, page: page, actionName: "Flip Arc")
                }
                .controlSize(.small)
            }
        }
    }
}

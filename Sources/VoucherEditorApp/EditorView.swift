import SwiftUI
import PDFKit
import VoucherModel

/// The document window: toolbar, sidebar (pages, fields, outline), canvas,
/// inspector and status bar (SPEC 4 layout).
struct EditorView: View {
    @ObservedObject var model: DocumentModel
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ToolbarRow(model: model, onSave: onSave)
            Divider()
            HSplitView {
                SidebarView(model: model)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                CanvasView(model: model)
                    .frame(minWidth: 400, minHeight: 300)
                InspectorView(model: model)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            }
            Divider()
            StatusBar(model: model)
        }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: OpenPDF.handleDrop)
        .id(ObjectIdentifier(model)) // Revert installs a new model: rebuild the canvas and its coordinator
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct ToolbarRow: View {
    @ObservedObject var model: DocumentModel
    var onSave: () -> Void
    @AppStorage(SnapPrefs.enabledKey) private var snapEnabled = true
    @AppStorage(SnapPrefs.gridKey) private var snapGrid = 1.0
    @AppStorage(SnapPrefs.showGridKey) private var showGrid = false

    var body: some View {
        HStack(spacing: 12) {
            Button { OpenPDF.showPanel() } label: { Label("Open PDF…", systemImage: "folder") }
                .help("Open a PDF template in a new window (Cmd-O)")

            Picker("Mode", selection: $model.isPreview) {
                Text("Edit").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            .help("Preview (Cmd-P): the page as a filled voucher, with sample text and the cut applied. Nothing is written.")

            Picker("Tool", selection: $model.tool) {
                ForEach(Tool.allCases) { t in
                    Label(t.label, systemImage: t.symbol).labelStyle(.iconOnly).tag(t).help("\(t.label) (\(t.key))")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .disabled(model.isPreview)

            Text(model.tool.label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)

            Toggle("Snap", isOn: $snapEnabled)
                .toggleStyle(.button)
                .help("Snap moving and resizing fields to the grid, other fields, the page and the outline. Hold Cmd while dragging to disable.")
            Picker("Grid", selection: $snapGrid) {
                ForEach(SnapPrefs.gridSizes, id: \.self) { g in Text("\(Int(g)) pt").tag(g) }
            }
            .labelsHidden()
            .frame(width: 70)
            .help("Grid size in points")
            Toggle(isOn: $showGrid) { Image(systemName: "grid") }
                .toggleStyle(.button)
                .help("Show the grid")

            Spacer()

            Button { model.pdfView?.zoomOut(nil) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out (Cmd-−)")
            Button { model.pdfView?.autoScales = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Zoom to fit (Cmd-9)")
            Button { model.pdfView?.zoomIn(nil) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in (Cmd-+)")

            Button("Save", action: onSave).keyboardShortcut("s", modifiers: .command).help("Save incrementally (Cmd-S)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

struct SidebarView: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        List(selection: Binding(get: { model.editor.selection }, set: { id in
            model.editor.selection = id
            if let id, let f = model.template.field(id) { reveal(f) }
        })) {
            Section("Pages") {
                ForEach(0..<model.template.pages.count, id: \.self) { i in
                    PageThumb(model: model, index: i)
                        .onTapGesture {
                            if let pg = model.pdfView?.document?.page(at: i) { model.pdfView?.go(to: pg) }
                            model.currentPage = i
                        }
                }
            }
            Section("Fields (\(model.template.fields.count))") {
                ForEach(model.template.fields) { f in
                    let warnings = model.fieldWarnings(f)
                    HStack(spacing: 6) {
                        Image(systemName: f.kind == .image ? "photo" : (f.kind == .text ? "character.textbox" : "lock"))
                            .foregroundStyle(f.kind == .image ? .green : (f.kind == .text ? .blue : .gray))
                            .frame(width: 16)
                        Text(f.qualifiedName.isEmpty ? "(no name)" : f.qualifiedName).lineLimit(1)
                        Spacer()
                        if f.page > 0 { Text("p\(f.page + 1)").font(.caption2).foregroundStyle(.secondary) }
                        if !warnings.isEmpty && f.isEditable {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(warnings.joined(separator: "\n"))
                        }
                    }
                    .tag(f.id)
                    .contextMenu {
                        if f.hasSeparateWidget {
                            Button("Merge Field and Widget") {
                                model.editor.selection = f.id
                                model.editor.mergeFieldAndWidget(f.id)
                            }
                            .disabled(!f.canMergeWidget)
                        }
                    }
                }
            }
            Section("Outline") {
                ForEach(0..<model.template.pages.count, id: \.self) { i in
                    HStack {
                        Image(systemName: "scribble.variable").foregroundStyle(.pink)
                        Text(model.template.outlines[i] != nil ? "Cut on page \(i + 1)" : "Page \(i + 1): no cut")
                            .foregroundStyle(model.template.outlines[i] != nil ? .primary : .secondary)
                    }
                    .onTapGesture { model.currentPage = i; model.tool = .outline }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func reveal(_ f: FieldDef) {
        guard let pv = model.pdfView, let page = pv.document?.page(at: f.page) else { return }
        let r = CGRect(x: f.rect.x - 40, y: f.rect.y - 40, width: f.rect.width + 80, height: f.rect.height + 80)
        pv.go(to: r, on: page)
    }
}

struct PageThumb: View {
    @ObservedObject var model: DocumentModel
    let index: Int

    var body: some View {
        HStack {
            if let page = model.pdfView?.document?.page(at: index) {
                Image(nsImage: page.thumbnail(of: NSSize(width: 120, height: 90), for: .mediaBox))
                    .resizable().aspectRatio(contentMode: .fit).frame(width: 80, height: 60)
                    .border(model.currentPage == index ? Color.accentColor : Color.secondary.opacity(0.3), width: model.currentPage == index ? 2 : 1)
            }
            Text("\(index + 1)").foregroundStyle(.secondary)
        }
    }
}

struct StatusBar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        let t = model.template
        let errors = model.runChecks()
        HStack(spacing: 14) {
            Text("Page \(model.currentPage + 1) of \(t.pages.count)")
            Text("\(t.fields.count) fields")
            if !t.outlines.isEmpty {
                Text("Cut on page \(t.outlines.keys.sorted().map { String($0 + 1) }.joined(separator: ", "))")
            }
            Text(model.lastSave ?? (model.hasUnsavedModelChanges ? "Edited" : "Opened"))
                .foregroundStyle(model.hasUnsavedModelChanges ? .orange : .secondary)
            Spacer()
            let e = errors.filter { $0.severity == .error }.count, w = errors.filter { $0.severity == .warning }.count
            if e > 0 { Label("\(e) error\(e == 1 ? "" : "s")", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            if w > 0 { Label("\(w) warning\(w == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if model.facts.signatureCount > 0 { Label("signed", systemImage: "signature").foregroundStyle(.orange) }
            if model.facts.hasJavaScript { Label("contains JS", systemImage: "curlybraces").foregroundStyle(.orange) }
            if model.facts.hasXFA { Label("XFA", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if model.facts.wasRepaired { Label("repaired on open", systemImage: "wrench").foregroundStyle(.orange) }
        }
        .font(.caption)
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Save sheet (SPEC 6.2): errors need an explicit "Save Anyway"; warnings are listed.
struct SaveSheet: View {
    let issues: [SaveIssue]
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        let errors = issues.filter { $0.severity == .error }
        let warnings = issues.filter { $0.severity == .warning }
        VStack(alignment: .leading, spacing: 12) {
            Text(errors.isEmpty ? "Save with \(warnings.count) warning\(warnings.count == 1 ? "" : "s")?" : "The template has \(errors.count) problem\(errors.count == 1 ? "" : "s") for code that fills it")
                .font(.headline)
                .textSelection(.enabled)
            Text("These checks guarantee what filling libraries (pdf-lib, PyMuPDF, pypdf) rely on: unique names, one widget per field, correct rects and pages.")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(errors) { i in
                        Label(i.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    ForEach(warnings) { i in
                        Label(i.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 320)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(errors.isEmpty ? "Save" : "Save Anyway", action: onSave)
                    .keyboardShortcut(errors.isEmpty ? .defaultAction : KeyboardShortcut("s", modifiers: [.command, .shift]))
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

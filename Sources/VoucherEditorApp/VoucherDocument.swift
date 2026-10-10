import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoucherModel

/// One open PDF. NSDocument provides open/save/revert, the dirty dot and the undo
/// manager; the bytes come from the MuPDF engine (single writer, SPEC 7.2).
@objc(VoucherDocument)
final class VoucherDocument: NSDocument, NSWindowDelegate {
    static let pdfType = UTType.pdf.identifier

    private(set) var model: DocumentModel?
    private var acknowledgedWarnings: Set<String> = []
    private var hostingView: NSHostingView<EditorView>?

    override class var autosavesInPlace: Bool { false }
    /// No autosave at all: producing bytes advances the engine's baseline, so bytes are
    /// only produced for a real Save / Save As.
    override var autosavingFileType: String? { nil }
    override class var readableTypes: [String] { [pdfType] }
    override class var writableTypes: [String] { [pdfType] }
    override class func isNativeType(_ type: String) -> Bool { type == pdfType }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func read(from data: Data, ofType typeName: String) throws {
        let m = try MainActor.assumeIsolated { try DocumentModel(data: data, undoManager: undoManager) }
        model = m
        undoManager?.removeAllActions()
        if let hostingView { // Revert
            hostingView.rootView = makeRootView(m)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let model else { throw CocoaError(.fileWriteUnknown) }
        return try MainActor.assumeIsolated {
            try model.saveData(incremental: !model.engine.wasRepaired)
        }
    }

    private func makeRootView(_ m: DocumentModel) -> EditorView {
        EditorView(model: m, onSave: { [weak self] in self?.save(nil) })
    }

    override func makeWindowControllers() {
        guard let model else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: makeRootView(model))
        hostingView = host
        window.contentView = host
        window.minSize = NSSize(width: 900, height: 560)
        window.center()
        window.setFrameAutosaveName("VoucherEditorDocumentWindow")
        let wc = NSWindowController(window: window)
        addWindowController(wc)
        window.delegate = self
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undoManager }

    // MARK: Save with checks (SPEC 6.2)

    override func save(_ sender: Any?) {
        runChecks { super.save(sender) }
    }

    override func saveAs(_ sender: Any?) {
        runChecks { super.saveAs(sender) }
    }

    /// Show the save sheet when there are errors, or warnings not yet acknowledged.
    private func runChecks(then action: @escaping () -> Void) {
        guard let model, let window = windowForSheet else { action(); return }
        let issues = MainActor.assumeIsolated { model.runChecks() }
        let hasErrors = issues.contains { $0.severity == .error }
        let newWarnings = Set(issues.filter { $0.severity == .warning }.map(\.message)).subtracting(acknowledgedWarnings)
        if !hasErrors && newWarnings.isEmpty { action(); return }
        var sheet: NSWindow?
        let view = SaveSheet(issues: issues, onCancel: {
            if let s = sheet { window.endSheet(s) }
        }, onSave: { [weak self] in
            if let s = sheet { window.endSheet(s) }
            self?.acknowledgedWarnings.formUnion(issues.filter { $0.severity == .warning }.map(\.message))
            action()
        })
        let host = NSHostingController(rootView: view)
        let s = NSWindow(contentViewController: host)
        sheet = s
        window.beginSheet(s)
    }

    // MARK: Menu actions (reachable through the responder chain)

    private var overlay: OverlayView? {
        model?.pdfView?.subviews.compactMap { $0 as? OverlayView }.first
    }

    @objc func deleteField(_ sender: Any?) {
        MainActor.assumeIsolated { overlay?.deleteSelection() }
    }

    @objc func duplicateField(_ sender: Any?) {
        MainActor.assumeIsolated {
            if let id = model?.editor.selection { model?.editor.duplicateField(id) }
        }
    }

    @objc func togglePreview(_ sender: Any?) {
        MainActor.assumeIsolated { model?.isPreview.toggle() }
    }

    @objc func chooseTool(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            if let t = Tool(rawValue: sender.representedObject as? String ?? "") { model?.tool = t }
        }
    }

    @objc func veZoomIn(_ sender: Any?) { model?.pdfView?.zoomIn(nil) }
    @objc func veZoomOut(_ sender: Any?) { model?.pdfView?.zoomOut(nil) }
    @objc func veZoomFit(_ sender: Any?) { model?.pdfView?.autoScales = true }
    @objc func veZoomActual(_ sender: Any?) { model?.pdfView?.scaleFactor = 1 }

    @objc func newRectangleOutline(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let model else { return }
            let p = model.currentPage
            if model.template.outlines[p] == nil {
                model.editor.setOutline(model.defaultOutline(page: p), page: p, actionName: "New Outline")
            }
            model.tool = .outline
        }
    }

    @objc func removeCut(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let model else { return }
            model.editor.setOutline(nil, page: model.currentPage, actionName: "Remove Cut")
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(deleteField(_:)), #selector(duplicateField(_:)):
            return MainActor.assumeIsolated { model?.editor.selectedField?.isEditable ?? false }
        case #selector(removeCut(_:)):
            return MainActor.assumeIsolated { model.map { $0.template.outlines[$0.currentPage] != nil } ?? false }
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

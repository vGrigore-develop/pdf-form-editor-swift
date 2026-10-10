import SwiftUI
import AppKit
import PDFKit
import Combine
import VoucherModel

/// PDFView host plus the editing overlay (SPEC 7.3 "Canvas").
/// PDFKit only displays: it shows page content with widget annotations hidden
/// (the overlay draws fields from the model), and reloads only after a save or
/// when Preview toggles (SPEC 7.2).
struct CanvasView: NSViewRepresentable {
    @ObservedObject var model: DocumentModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.backgroundColor = NSColor(white: 0.32, alpha: 1)
        let overlay = OverlayView(frame: pdfView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.pdfView = pdfView
        overlay.model = model
        pdfView.addSubview(overlay)
        model.pdfView = pdfView
        context.coordinator.attach(pdfView: pdfView, overlay: overlay)
        // Load once the view is in the window, so PDFKit lays out and renders at the real size.
        DispatchQueue.main.async { context.coordinator.load(model.displayData, annotationsVisible: false) }
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: DocumentModel
        weak var pdfView: PDFView?
        weak var overlay: OverlayView?
        private var loadedData: Data?
        private var showingPreview = false
        private var bag: Set<AnyCancellable> = []

        init(model: DocumentModel) { self.model = model }

        func attach(pdfView: PDFView, overlay: OverlayView) {
            self.pdfView = pdfView
            self.overlay = overlay
            let nc = NotificationCenter.default
            for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDisplayModeChanged, .PDFViewDocumentChanged] {
                nc.publisher(for: name, object: pdfView).sink { [weak self] _ in self?.redraw() }.store(in: &bag)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let clip = pdfView.documentView?.enclosingScrollView?.contentView else { return }
                clip.postsBoundsChangedNotifications = true
                nc.publisher(for: NSView.boundsDidChangeNotification, object: clip).sink { [weak self] _ in self?.redraw() }.store(in: &self.bag)
                nc.publisher(for: NSView.frameDidChangeNotification, object: clip).sink { [weak self] _ in self?.redraw() }.store(in: &self.bag)
            }
            nc.publisher(for: .PDFViewPageChanged, object: pdfView).sink { [weak self] _ in
                guard let self, let pv = self.pdfView, let page = pv.currentPage, let doc = pv.document else { return }
                let i = doc.index(for: page)
                if self.model.currentPage != i { self.model.currentPage = i }
            }.store(in: &bag)
        }

        func redraw() { overlay?.needsDisplay = true }

        /// Load bytes into PDFKit. In Edit mode widget annotations are hidden.
        func load(_ data: Data, annotationsVisible: Bool) {
            guard let pv = pdfView, let doc = PDFDocument(data: data) else { return }
            let page = pv.currentPage.flatMap { pv.document?.index(for: $0) }
            let scale = pv.scaleFactor
            let auto = pv.autoScales || pv.document == nil
            for i in 0..<doc.pageCount {
                guard let p = doc.page(at: i) else { continue }
                // PDFAnnotation.type is the subtype without the slash ("Widget"). In Edit mode the
                // widgets are removed from PDFKit's in-memory copy (PDFKit never writes, SPEC 7.2), so
                // only the overlay shows fields and a moved field never leaves a stale appearance behind.
                // The crop cover (S10) is not a widget, but it belongs to the saved output only.
                for a in p.annotations where a.type == "Widget" || a.value(forAnnotationKey: .name) as? String == "VoucherEditor cover" {
                    if annotationsVisible {
                        a.shouldDisplay = true
                    } else {
                        p.removeAnnotation(a)
                    }
                }
            }
            pv.document = doc
            if auto { pv.autoScales = true } else { pv.scaleFactor = scale }
            if let page, let pg = doc.page(at: min(page, doc.pageCount - 1)) { pv.go(to: pg) }
            loadedData = data
            if let o = overlay, !o.isHidden, pv.window?.firstResponder == nil || pv.window?.firstResponder === pv.window {
                pv.window?.makeFirstResponder(o) // tool keys (V/T/I/O) work right after opening
            }
            redraw()
        }

        func sync() {
            let preview = model.isPreview
            overlay?.isHidden = preview
            if preview, let data = model.previewData {
                if !showingPreview || loadedData != data { load(data, annotationsVisible: true); showingPreview = true }
            } else if !preview {
                if showingPreview || loadedData != model.displayData { load(model.displayData, annotationsVisible: false); showingPreview = false }
            }
            redraw()
        }
    }
}

import Foundation
import VoucherModel
import VoucherGeometry
import VoucherTrace

/// Builds and caches the smart outline's `TraceContext` (page raster + edge map) per page.
///
/// The raster is rendered from the page *without* a cut: if the last saved bytes carry a
/// cut on that page, the engine builds throwaway bytes with that cut removed (the same
/// in-memory path Preview uses; nothing is written), so the clip never hides artwork.
/// CoreGraphics renders page content only (no widgets) in user space, so the raster lines
/// up with the outline's coordinates whatever the page's /Rotate and CropBox origin.
@MainActor
final class TraceProvider {
    private struct Key: Equatable {
        var page: Int
        var data: Data
        var box: PDFRect
    }

    private var cached: (key: Key, ctx: TraceContext)?
    private var building: Key?
    private(set) var lastError: String?

    /// The bytes to render page `page` from, and its box.
    private func source(page: Int, model: DocumentModel) -> Key? {
        let box = model.pageBounds(page)
        var data = model.displayData
        if model.baseline.outlines[page] != nil {
            var t = model.baseline
            t.outlines[page] = nil
            do { data = try model.engine.previewData(baseline: model.baseline, edited: t) } catch {
                lastError = "Could not prepare the page without its cut: \(error.localizedDescription)"
                return nil
            }
        }
        return Key(page: page, data: data, box: box)
    }

    /// The context for `page` at the current sensitivity, built now if needed (about
    /// 100 ms for an A4 page at 150 dpi in a release build).
    func context(page: Int, model: DocumentModel) -> TraceContext? {
        guard let key = source(page: page, model: model) else { return nil }
        let ctx: TraceContext
        if let c = cached, c.key == key {
            ctx = c.ctx
        } else {
            guard let built = Self.build(key) else {
                lastError = "Could not render page \(page + 1) for tracing."
                return nil
            }
            cached = (key, built)
            ctx = built
        }
        ctx.setSensitivity(TracePrefs.sensitivity)
        return ctx
    }

    /// Build the context for `page` in the background, so the first click is instant.
    func prefetch(page: Int, model: DocumentModel) {
        guard let key = source(page: page, model: model), cached?.key != key, building != key else { return }
        building = key
        let box = UncheckedBox<TraceContext?>(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            box.value = Self.build(key)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.building == key { self.building = nil }
                if let ctx = box.value, self.cached?.key != key { self.cached = (key, ctx) }
            }
        }
    }

    nonisolated private static func build(_ key: Key) -> TraceContext? {
        guard let raster = PageRaster.render(pdfData: key.data, pageIndex: key.page, box: key.box, dpi: TraceDefaults.dpi) else { return nil }
        return TraceContext(raster: raster, sensitivity: TraceDefaults.sensitivity)
    }
}

/// Hands a value built on a background queue to the main queue (never shared concurrently).
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

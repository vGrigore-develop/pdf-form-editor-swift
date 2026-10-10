import AppKit
import PDFKit
import Combine
import VoucherModel
import VoucherGeometry
import VoucherTrace

/// The editing overlay drawn on top of PDFView (SPEC 7.2, 7.5). It draws fields,
/// the outline and the dimmed outside from the model, and handles the tools.
/// All geometry is in each page's user space and converted with PDFView's
/// convert(_:from:) / convert(_:to:), so zoom, scroll and /Rotate are handled by PDFKit.
final class OverlayView: NSView, NSUserInterfaceValidations {
    weak var pdfView: PDFView?
    var model: DocumentModel! {
        didSet { observe() }
    }
    private var bag: Set<AnyCancellable> = []

    private enum Drag {
        case none
        case moving(id: UUID, page: Int, start: PDFPoint, startRect: PDFRect)
        case resizing(id: UUID, page: Int, handle: Int, startRect: PDFRect)
        case creating(kind: FieldKind, page: Int, start: PDFPoint, current: PDFPoint)
        case vertex(page: Int, index: Int)
        case arcCenter(page: Int, segment: Int)
    }
    private var drag: Drag = .none
    private(set) var pendingOutline: [PDFPoint] = []
    private var pendingPage: Int?
    private var hoverPoint: PDFPoint?

    // Smart outline (VoucherTrace): the outline follows the page's own artwork.
    /// pendingSegments[k] runs from pendingOutline[k] to pendingOutline[k + 1].
    private(set) var pendingSegments: [TracedSegment] = []
    /// Live edge-following preview from the last anchor to the cursor.
    private(set) var hoverTrace: [PDFPoint]?
    /// Shortest-path tree rooted at the last anchor.
    private var wire: LiveWire?
    /// The trace context of the page being placed on (kept for the whole placement).
    private var sessionTrace: TraceContext?
    let traceProvider = TraceProvider()
    /// Why the last smart outline could not be made (shown in the hint bar).
    private(set) var traceMessage: String?
    /// Snap guide lines shown while a field is dragged (page index, lines); cleared on mouse-up.
    private(set) var guides: (page: Int, lines: [Snapping.Guide])?
    private let snapPixels: CGFloat = 6

    private let handleSize: CGFloat = 7
    private let hitTolerance: CGFloat = 5

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override var isHidden: Bool {
        didSet { if isHidden && !oldValue { cancelInProgress() } }
    }

    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeKeyMonitor()
        guard window != nil else { return }
        // Escape / Delete must still reach an outline being placed when focus has drifted to a
        // toolbar control or the sidebar. Never steals keys from text editing or sheets.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isInProgress, !self.isHidden, let w = self.window, event.window === w,
                  w.attachedSheet == nil, w.firstResponder !== self, !(w.firstResponder is NSText),
                  [53, 51, 117].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            self.keyDown(with: event)
            return nil
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelInProgress(); removeKeyMonitor() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    deinit { if let m = keyMonitor { NSEvent.removeMonitor(m) } }

    private func observe() {
        bag.removeAll()
        // Switching tool or entering Preview abandons anything half-built (outline points, drags).
        model.$tool.removeDuplicates().dropFirst().sink { [weak self] tool in
            self?.cancelInProgress()
            if tool == .outline { DispatchQueue.main.async { self?.prefetchTrace() } }
        }.store(in: &bag)
        model.$isPreview.removeDuplicates().dropFirst().sink { [weak self] _ in self?.cancelInProgress() }.store(in: &bag)
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }.store(in: &bag)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    // MARK: Coordinates

    private var document: PDFDocument? { pdfView?.document }

    private func page(_ index: Int) -> PDFPage? {
        guard let d = document, index >= 0, index < d.pageCount else { return nil }
        return d.page(at: index)
    }

    private func viewPoint(_ p: PDFPoint, _ page: PDFPage) -> NSPoint {
        guard let pv = pdfView else { return .zero }
        return convert(pv.convert(NSPoint(x: p.x, y: p.y), from: page), from: pv)
    }

    private func viewRect(_ r: PDFRect, _ page: PDFPage) -> NSRect {
        let a = viewPoint(PDFPoint(r.minX, r.minY), page), b = viewPoint(PDFPoint(r.maxX, r.maxY), page)
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// (page index, point in that page's user space) under a view point.
    private func pagePoint(_ v: NSPoint, preferPage: Int? = nil) -> (Int, PDFPoint)? {
        guard let pv = pdfView, let doc = document else { return nil }
        let p = pv.convert(v, from: self)
        let page: PDFPage?
        if let pref = preferPage, let pg = self.page(pref) { page = pg } else { page = pv.page(for: p, nearest: true) }
        guard let page else { return nil }
        let q = pv.convert(p, to: page)
        return (doc.index(for: page), PDFPoint(Double(q.x), Double(q.y)))
    }

    /// Screen pixels per page point (for tolerances in page space).
    private var scale: CGFloat { max(0.01, pdfView?.scaleFactor ?? 1) }

    private func visiblePageIndices() -> [Int] {
        guard let pv = pdfView, let doc = document else { return [] }
        return pv.visiblePages.map { doc.index(for: $0) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model, !model.isPreview else { return }
        let t = model.template
        for pi in visiblePageIndices() {
            guard let pg = page(pi) else { continue }
            if SnapPrefs.showGrid { drawGrid(page: pg, pageIndex: pi) }
            if let o = t.outlines[pi] { drawOutline(o, page: pg, pageIndex: pi) }
            for f in t.fields where f.page == pi { drawField(f, page: pg) }
            if let g = guides, g.page == pi { drawGuides(g.lines, page: pg) }
            if pendingPage == pi { drawPendingOutline(page: pg) }
            if case .creating(_, let p, let s, let c) = drag, p == pi {
                let r = viewRect(PDFRect(x1: s.x, y1: s.y, x2: c.x, y2: c.y), pg)
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                r.fill()
                NSColor.controlAccentColor.setStroke()
                NSBezierPath(rect: r).stroke()
            }
        }
        drawPlacementHint()
    }

    private func drawGrid(page: PDFPage, pageIndex: Int) {
        let b = model.pageBounds(pageIndex)
        let step = Snapping.visibleGridStep(grid: SnapPrefs.grid, scale: Double(scale))
        guard step > 0, b.width / step < 2000, b.height / step < 2000 else { return }
        let path = NSBezierPath()
        var x = (b.minX / step).rounded(.up) * step
        while x <= b.maxX {
            path.move(to: viewPoint(PDFPoint(x, b.minY), page)); path.line(to: viewPoint(PDFPoint(x, b.maxY), page))
            x += step
        }
        var y = (b.minY / step).rounded(.up) * step
        while y <= b.maxY {
            path.move(to: viewPoint(PDFPoint(b.minX, y), page)); path.line(to: viewPoint(PDFPoint(b.maxX, y), page))
            y += step
        }
        path.lineWidth = 0.5
        NSColor.systemTeal.withAlphaComponent(0.28).setStroke()
        path.stroke()
    }

    private func drawGuides(_ lines: [Snapping.Guide], page: PDFPage) {
        let path = NSBezierPath()
        for g in lines {
            switch g.axis {
            case .x:
                path.move(to: viewPoint(PDFPoint(g.position, g.from), page)); path.line(to: viewPoint(PDFPoint(g.position, g.to), page))
            case .y:
                path.move(to: viewPoint(PDFPoint(g.from, g.position), page)); path.line(to: viewPoint(PDFPoint(g.to, g.position), page))
            }
        }
        path.lineWidth = 1
        NSColor.systemOrange.setStroke()
        path.stroke()
    }

    private func outlinePath(_ o: Outline, _ page: PDFPage) -> NSBezierPath {
        let path = NSBezierPath()
        let pts = Geometry.flatten(o, step: max(0.5, 2 / Double(scale)))
        for (i, p) in pts.enumerated() {
            let v = viewPoint(p, page)
            if i == 0 { path.move(to: v) } else { path.line(to: v) }
        }
        path.close()
        return path
    }

    private func drawOutline(_ o: Outline, page: PDFPage, pageIndex: Int) {
        let shape = outlinePath(o, page)
        // Dim the outside of the outline (SPEC 4, Display).
        let box = page.bounds(for: .mediaBox)
        let pageRect = viewRect(PDFRect(x: Double(box.minX), y: Double(box.minY), width: Double(box.width), height: Double(box.height)), page)
        let dim = NSBezierPath(rect: pageRect)
        dim.append(shape)
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()
        let invalid = !Geometry.validate(o).isEmpty
        (invalid ? NSColor.systemRed : NSColor.systemPink).setStroke()
        shape.lineWidth = model.tool == .outline ? 2 : 1.25
        shape.stroke()

        guard model.tool == .outline else { return }
        // Vertices and arc centres.
        for (i, p) in o.points.enumerated() where i < o.points.count - 1 || o.points.last != o.start {
            let v = viewPoint(p, page)
            let r = NSRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)
            let selected = model.selectedVertex == i
            (selected ? NSColor.systemPink : NSColor.white).setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor.systemPink.setStroke()
            NSBezierPath(ovalIn: r).stroke()
        }
        for s in o.segments {
            if case .arc(_, let c, _) = s {
                let v = viewPoint(c, page)
                let cross = NSBezierPath()
                cross.move(to: NSPoint(x: v.x - 5, y: v.y)); cross.line(to: NSPoint(x: v.x + 5, y: v.y))
                cross.move(to: NSPoint(x: v.x, y: v.y - 5)); cross.line(to: NSPoint(x: v.x, y: v.y + 5))
                NSColor.systemPink.setStroke()
                cross.lineWidth = 1.5
                cross.stroke()
            }
        }
    }

    /// Text of the placement hint; nil when no outline is being placed.
    var placementHint: String? {
        if let m = traceMessage { return m }
        guard !pendingOutline.isEmpty else { return nil }
        if pendingSegments.contains(where: \.magnetic) || sessionTrace != nil {
            let close = canClosePending ? "Return or the first anchor closes, " : ""
            return "Click anchors along the artwork (Shift: straight, Cmd/Option: no snap). \(close)Delete removes an anchor, Esc cancels"
        }
        let close = pendingOutline.count >= 3 ? "click the first point or press Return to close, " : ""
        return "Click to add points, \(close)Esc or right-click to cancel, Delete removes the last point"
    }

    private func drawPlacementHint() {
        guard let text = placementHint else { return }
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let sz = s.size()
        let r = NSRect(x: bounds.midX - sz.width / 2 - 10, y: bounds.minY + 12, width: sz.width + 20, height: sz.height + 8)
        (traceMessage != nil ? NSColor.systemRed.withAlphaComponent(0.85) : NSColor.black.withAlphaComponent(0.72)).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        s.draw(at: NSPoint(x: r.minX + 10, y: r.minY + 4))
    }

    private func drawPendingOutline(page: PDFPage) {
        guard !pendingOutline.isEmpty else { return }
        let path = NSBezierPath()
        path.move(to: viewPoint(pendingOutline[0], page))
        for (i, p) in pendingOutline.enumerated().dropFirst() {
            // Committed segments: the traced edge, or a straight line.
            if pendingSegments.indices.contains(i - 1) {
                for q in pendingSegments[i - 1].points.dropFirst() { path.line(to: viewPoint(q, page)) }
            } else {
                path.line(to: viewPoint(p, page))
            }
        }
        if hoverTrace == nil, let h = hoverPoint { path.line(to: viewPoint(h, page)) }
        NSColor.systemPink.setStroke()
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
        if let trace = hoverTrace, trace.count > 1 {
            // The live edge-following preview, in its own colour.
            let live = NSBezierPath()
            live.move(to: viewPoint(trace[0], page))
            for q in trace.dropFirst() { live.line(to: viewPoint(q, page)) }
            live.lineWidth = 2
            NSColor.systemCyan.setStroke()
            live.stroke()
            let end = viewPoint(trace[trace.count - 1], page)
            NSColor.systemCyan.setFill()
            NSBezierPath(ovalIn: NSRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)).fill()
        }
        for (i, p) in pendingOutline.enumerated() {
            let v = viewPoint(p, page)
            let r = NSRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)
            (i == 0 ? NSColor.systemPink : NSColor.white).setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor.systemPink.setStroke()
            NSBezierPath(ovalIn: r).stroke()
        }
    }

    private func drawField(_ f: FieldDef, page: PDFPage) {
        let r = viewRect(f.rect, page)
        let selected = model.editor.selection == f.id
        let warnings = model.fieldWarnings(f).filter { !$0.hasPrefix("Renamed") && $0 != f.origin?.readOnlyReason }
        let base: NSColor
        switch f.kind {
        case .text: base = .systemBlue
        case .image: base = .systemGreen
        case .other: base = .systemGray
        }
        // The field's own background and border, as the stored appearance draws them
        // (PDFKit shows the page without widgets in Edit mode, so this is the only place
        // the user sees them before saving).
        let box = fieldBox(f)
        // Cropped to the outline (S10): the field's own look is drawn only inside the shape,
        // as the saved appearance and Preview show it; outside, a faint dashed edge keeps the
        // full /Rect (what code reads) visible.
        let cropShape = model.isCropped(f) ? model.template.outlines[f.page].map { outlinePath($0, page) } : nil
        if let shape = cropShape {
            let ghost = NSBezierPath(rect: r)
            ghost.lineWidth = 1
            ghost.setLineDash([2, 3], count: 2, phase: 0)
            base.withAlphaComponent(0.6).setStroke()
            ghost.stroke()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
        }
        if let bg = box.background {
            NSColor(srgbRed: bg.r, green: bg.g, blue: bg.b, alpha: 1).setFill()
            r.fill()
        } else {
            base.withAlphaComponent(f.isEditable ? 0.14 : 0.08).setFill()
            r.fill()
        }
        if let bc = box.border, box.width > 0 {
            let w = CGFloat(box.width) * scale
            let path = NSBezierPath(rect: r.insetBy(dx: w / 2, dy: w / 2))
            path.lineWidth = w
            if f.kind == .image {
                let unit = CGFloat(max(box.width, 1)) * scale
                path.setLineDash([3 * unit, 2 * unit], count: 2, phase: 0)
            }
            NSColor(srgbRed: bc.r, green: bc.g, blue: bc.b, alpha: 1).setStroke()
            path.stroke()
            if let shape = cropShape {
                // The saved appearance also draws the border along the outline inside the field.
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: r).addClip()
                let edge = shape.copy() as! NSBezierPath
                edge.lineWidth = 2 * w
                if f.kind == .image {
                    let unit = CGFloat(max(box.width, 1)) * scale
                    edge.setLineDash([3 * unit, 2 * unit], count: 2, phase: 0)
                }
                edge.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if cropShape != nil {
            // Default value and label are clipped too; the identification edge, the name tag and
            // the handles are not.
            NSGraphicsContext.restoreGraphicsState()
        }

        // Identification outline: always for selection and warnings, otherwise only when the
        // field has no border of its own (so it never hides the real border's colour).
        if selected || !warnings.isEmpty || box.border == nil || box.width <= 0 {
            let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = selected ? 2 : 1
            if f.kind == .image || !f.isEditable { border.setLineDash([4, 3], count: 2, phase: 0) }
            (warnings.isEmpty ? (selected ? NSColor.controlAccentColor : base) : NSColor.systemRed).setStroke()
            border.stroke()
        }

        // Default value preview for text fields (the stored appearance shows it too).
        if f.kind == .text, !f.text.defaultValue.isEmpty {
            let size = CGFloat(f.text.fontSize > 0 ? f.text.fontSize : 12) * scale
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size),
                .foregroundColor: NSColor(red: f.text.color.r, green: f.text.color.g, blue: f.text.color.b, alpha: 0.8),
            ]
            let s = NSAttributedString(string: f.text.defaultValue, attributes: attrs)
            let sz = s.size()
            var x = r.minX + 3
            if f.text.alignment == .center { x = r.midX - sz.width / 2 }
            if f.text.alignment == .right { x = r.maxX - 3 - sz.width }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).addClip()
            cropShape?.addClip()
            s.draw(at: NSPoint(x: x, y: r.midY - sz.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }

        // Name tag
        let icon = f.kind == .image ? "▣ " : (f.kind == .text ? "T " : "🔒 ")
        let label = NSAttributedString(string: icon + f.qualifiedName, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let ls = label.size()
        let tag = NSRect(x: r.minX, y: r.maxY, width: ls.width + 8, height: ls.height + 2)
        (warnings.isEmpty ? (selected ? NSColor.controlAccentColor : base.withAlphaComponent(0.85)) : NSColor.systemRed).setFill()
        NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
        label.draw(at: NSPoint(x: tag.minX + 4, y: tag.minY + 1))

        if f.kind == .image {
            let s = NSAttributedString(string: f.image.label, attributes: [
                .font: NSFont.systemFont(ofSize: max(8, 9 * scale)), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let sz = s.size()
            if sz.width < r.width - 4 {
                NSGraphicsContext.saveGraphicsState()
                cropShape?.addClip()
                s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        if selected && f.isEditable {
            for h in 0..<8 {
                let v = viewPoint(RectHandle.point(f.rect, h), page)
                let hr = NSRect(x: v.x - handleSize / 2, y: v.y - handleSize / 2, width: handleSize, height: handleSize)
                NSColor.white.setFill()
                hr.fill()
                NSColor.controlAccentColor.setStroke()
                NSBezierPath(rect: hr).stroke()
            }
        }
    }

    /// Background, border colour and border width the field's stored appearance uses.
    private func fieldBox(_ f: FieldDef) -> (background: VoucherModel.RGBColor?, border: VoucherModel.RGBColor?, width: Double) {
        switch f.kind {
        case .text: return (f.text.backgroundColor, f.text.borderColor, f.text.borderWidth)
        case .image: return (f.image.backgroundColor, f.image.borderColor, f.image.borderWidth)
        case .other: return (nil, nil, 0)
        }
    }

    // MARK: Hit testing

    private func handleHit(_ v: NSPoint) -> (FieldDef, Int)? {
        guard let id = model.editor.selection, let f = model.template.field(id), f.isEditable, let pg = page(f.page) else { return nil }
        for h in 0..<8 {
            let hp = viewPoint(RectHandle.point(f.rect, h), pg)
            if abs(hp.x - v.x) <= hitTolerance && abs(hp.y - v.y) <= hitTolerance { return (f, h) }
        }
        return nil
    }

    private func fieldHit(_ v: NSPoint) -> FieldDef? {
        for f in model.template.fields.reversed() {
            guard let pg = page(f.page) else { continue }
            let r = viewRect(f.rect, pg).insetBy(dx: -2, dy: -2)
            if r.contains(v) { return f }
            // The name tag above the field also selects it.
            if NSRect(x: r.minX, y: r.maxY, width: 120, height: 14).contains(v) { return f }
        }
        return nil
    }

    // MARK: Mouse

    /// Right-click, or Ctrl-click (which macOS treats as a right-click): cancel whatever is in progress.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        cancelInProgress()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        let v = convert(event.locationInWindow, from: nil)
        guard let (pi, p) = pagePoint(v) else { return }
        model.currentPage = pi
        switch model.tool {
        case .select:
            if let (f, h) = handleHit(v) {
                model.editor.beginGesture()
                drag = .resizing(id: f.id, page: f.page, handle: h, startRect: f.rect)
            } else if let f = fieldHit(v) {
                model.editor.selection = f.id
                if f.isEditable {
                    var target = f
                    if event.modifierFlags.contains(.option), let dupID = model.editor.duplicateField(f.id, offset: 0),
                       let dup = model.template.field(dupID) {
                        target = dup // Option-drag duplicates in place (SPEC 4)
                    }
                    model.editor.beginGesture()
                    drag = .moving(id: target.id, page: target.page, start: p, startRect: target.rect)
                }
            } else {
                model.editor.selection = nil
            }
        case .text, .image:
            drag = .creating(kind: model.tool == .image ? .image : .text, page: pi, start: p, current: p)
        case .outline:
            outlineMouseDown(v: v, page: pi, point: p, event: event)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .moving(let id, let page, let start, let startRect):
            guard let (_, p) = pagePoint(v, preferPage: page) else { return }
            let dx = p.x - start.x, dy = p.y - start.y
            var r: PDFRect
            var snap: Snapping.Result?
            if snapActive(event) {
                let raw = startRect.offsetBy(dx: dx, dy: dy)
                let s = Snapping.snapMove(rect: raw, targets: snapTargets(page: page, excluding: id), threshold: snapThreshold, grid: SnapPrefs.grid)
                snap = s
                r = raw.offsetBy(dx: s.dx, dy: s.dy)
            } else {
                r = startRect.offsetBy(dx: dx.rounded(), dy: dy.rounded())
            }
            r = r.clamped(into: model.pageBounds(page))
            if applyFieldRect(id: id, page: page, r, startRect: startRect) { setGuides(snap, rect: r, page: page) } else { guides = nil }
        case .resizing(let id, let page, let handle, let startRect):
            guard let (_, p) = pagePoint(v, preferPage: page), let f = model.template.field(id) else { return }
            let keep = event.modifierFlags.contains(.shift) && f.kind != .other
            var target = PDFPoint(p.x.rounded(), p.y.rounded())
            var snap: Snapping.Result?
            if snapActive(event) {
                let s = Snapping.snapResize(rect: startRect, handle: handle, point: p, targets: snapTargets(page: page, excluding: id),
                                            threshold: snapThreshold, grid: SnapPrefs.grid)
                snap = s
                target = PDFPoint(p.x + s.dx, p.y + s.dy)
            }
            var r = RectHandle.resize(startRect, handle: handle, to: target,
                                      keepAspect: keep, fromCenter: event.modifierFlags.contains(.option))
            let bounds = model.pageBounds(page)
            r = PDFRect(x1: max(r.minX, bounds.minX), y1: max(r.minY, bounds.minY), x2: min(r.maxX, bounds.maxX), y2: min(r.maxY, bounds.maxY))
            if applyFieldRect(id: id, page: page, r, startRect: startRect) { setGuides(snap, rect: r, page: page) } else { guides = nil }
        case .creating(let kind, let page, let start, _):
            guard let (_, p) = pagePoint(v, preferPage: page) else { return }
            let b = model.pageBounds(page)
            drag = .creating(kind: kind, page: page, start: start,
                             current: PDFPoint(min(max(p.x, b.minX), b.maxX), min(max(p.y, b.minY), b.maxY)))
        case .vertex(let page, let index):
            guard let (_, p) = pagePoint(v, preferPage: page), var o = model.template.outlines[page] else { return }
            let snapped = snapOutlinePoint(p, outline: o, excluding: index)
            moveOutlineVertex(&o, index: index, to: snapped)
            model.editor.updateDuringGesture { $0.outlines[page] = o }
        case .arcCenter(let page, let seg):
            guard let (_, p) = pagePoint(v, preferPage: page), var o = model.template.outlines[page],
                  case .arc(let to, _, let cw) = o.segments[seg] else { return }
            let from = seg == 0 ? o.start : o.segments[seg - 1].end
            let c = Geometry.recenterArc(from: from, to: to, oldCenter: p)
            o.segments[seg] = .arc(to: to, center: c, clockwise: cw)
            model.editor.updateDuringGesture { $0.outlines[page] = o }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guides = nil
        switch drag {
        case .moving:
            model.editor.endGesture("Move Field")
        case .resizing:
            model.editor.endGesture("Resize Field")
        case .creating(let kind, let page, let start, let current):
            var r = PDFRect(x1: start.x, y1: start.y, x2: current.x, y2: current.y)
            if r.width < 3 || r.height < 3 {
                // A click without dragging creates a default-size field (SPEC 4).
                let size = kind == .image ? (w: 120.0, h: 90.0) : (w: 160.0, h: 24.0)
                r = PDFRect(x: start.x, y: start.y - size.h, width: size.w, height: size.h)
            }
            r = r.clamped(into: model.pageBounds(page))
            model.editor.addField(model.newField(kind: kind, rect: r, page: page))
            if !event.modifierFlags.contains(.option) { model.tool = .select }
        case .vertex:
            model.editor.endGesture("Move Outline Point")
        case .arcCenter:
            model.editor.endGesture("Change Arc")
        case .none:
            break
        }
        drag = .none
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard model.tool == .outline, let pp = pendingPage, !pendingOutline.isEmpty else { return }
        let v = convert(event.locationInWindow, from: nil)
        if let (_, p) = pagePoint(v, preferPage: pp) {
            hoverPoint = constrained(PDFPoint(p.x.rounded(), p.y.rounded()), from: pendingOutline.last!, shift: event.modifierFlags.contains(.shift))
            hoverTrace = nil
            if magneticClick(event), let ctx = sessionTrace, let last = pendingOutline.last {
                // Rubber band along the artwork: to the first anchor when hovering it (closing),
                // otherwise to where a click here would land.
                let target = isOverFirstAnchor(v, page: pp) ? pendingOutline[0] : ctx.snapAnchor(p, radiusPx: snapRadiusPixels(ctx))
                // A bounded amount of work per mouse move (about 15 ms in a release build); a far
                // jump finishes over the next few moves, since the wire keeps what it expanded.
                if let w = liveWire(ctx), let seg = ctx.segment(w, from: last, to: target, maxSettle: 400_000) {
                    hoverTrace = seg.magnetic ? seg.points : nil
                    hoverPoint = target
                }
            }
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func scrollWheel(with event: NSEvent) {
        pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event) ?? super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        pdfView?.magnify(with: event)
    }

    /// Apply a moved/resized rect, honouring "keep fields inside outline" (SPEC 5.3).
    /// Returns false when the rect was refused (it would leave the outline).
    @discardableResult
    private func applyFieldRect(id: UUID, page: Int, _ r: PDFRect, startRect: PDFRect) -> Bool {
        let t = model.template
        if t.keepFieldsInsideOutline, let o = t.outlines[page],
           Geometry.containment(of: startRect, in: o) == .inside, Geometry.containment(of: r, in: o) != .inside {
            return false
        }
        model.editor.updateDuringGesture { t in
            if let i = t.index(of: id) { t.fields[i].rect = r }
        }
        return true
    }

    // MARK: Snapping

    /// Snapping applies while the toolbar toggle is on and Cmd is not held (SPEC 4).
    private func snapActive(_ event: NSEvent) -> Bool {
        SnapPrefs.enabled && !event.modifierFlags.contains(.command)
    }

    /// 6 screen pixels in page points, so snapping feels the same at any zoom.
    private var snapThreshold: Double { Double(snapPixels / scale) }

    private func snapTargets(page: Int, excluding id: UUID) -> Snapping.Targets {
        let t = model.template
        return Snapping.Targets.build(page: model.pageBounds(page),
                                      fields: t.fields.filter { $0.page == page && $0.id != id }.map(\.rect),
                                      outlineBounds: t.outlines[page].map { Geometry.boundingBox($0) })
    }

    private func setGuides(_ snap: Snapping.Result?, rect: PDFRect, page: Int) {
        let lines = snap?.guides(for: rect) ?? []
        guides = lines.isEmpty ? nil : (page, lines)
    }

    // MARK: Outline tool

    private func constrained(_ p: PDFPoint, from q: PDFPoint, shift: Bool) -> PDFPoint {
        guard shift else { return p }
        let dx = p.x - q.x, dy = p.y - q.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let len = hypot(dx, dy)
        return PDFPoint((q.x + len * cos(angle)).rounded(), (q.y + len * sin(angle)).rounded())
    }

    /// Snap to the 1 pt grid and to the x/y of other points (essential for steps, SPEC 4).
    private func snapOutlinePoint(_ p: PDFPoint, outline o: Outline, excluding index: Int) -> PDFPoint {
        var x = p.x.rounded(), y = p.y.rounded()
        let tol = Double(6 / scale)
        let others = o.points.enumerated().filter { $0.offset != index && !($0.offset == o.points.count - 1 && index == 0) }.map(\.element)
        if let sx = others.map(\.x).min(by: { abs($0 - p.x) < abs($1 - p.x) }), abs(sx - p.x) < tol { x = sx }
        if let sy = others.map(\.y).min(by: { abs($0 - p.y) < abs($1 - p.y) }), abs(sy - p.y) < tol { y = sy }
        return PDFPoint(x, y)
    }

    private func moveOutlineVertex(_ o: inout Outline, index: Int, to p: PDFPoint) {
        let count = o.segments.count
        o.moveVertex(index, to: p)
        // Keep adjacent arcs valid by moving their centres along the chord bisector (SPEC 4).
        func fix(_ s: Int) {
            guard o.segments.indices.contains(s), case .arc(let to, let c, let cw) = o.segments[s] else { return }
            let from = s == 0 ? o.start : o.segments[s - 1].end
            o.segments[s] = .arc(to: to, center: Geometry.recenterArc(from: from, to: to, oldCenter: c), clockwise: cw)
        }
        if index == 0 { fix(0); fix(count - 1) } else { fix(index - 1); fix(index) }
    }

    private func outlineMouseDown(v: NSPoint, page pi: Int, point p: PDFPoint, event: NSEvent) {
        guard let pg = page(pi) else { return }
        if let o = model.template.outlines[pi] {
            // Vertex?
            for (i, q) in o.points.enumerated() where i < o.segments.count {
                let vq = viewPoint(q, pg)
                if hypot(vq.x - v.x, vq.y - v.y) <= hitTolerance + 2 {
                    model.selectedVertex = i
                    model.editor.beginGesture()
                    drag = .vertex(page: pi, index: i)
                    return
                }
            }
            // Arc centre?
            for (i, s) in o.segments.enumerated() {
                if case .arc(_, let c, _) = s {
                    let vc = viewPoint(c, pg)
                    if hypot(vc.x - v.x, vc.y - v.y) <= hitTolerance + 2 {
                        model.editor.beginGesture()
                        drag = .arcCenter(page: pi, segment: i)
                        return
                    }
                }
            }
            // Option-click on a segment inserts a point.
            if event.modifierFlags.contains(.option), let near = Geometry.nearestSegment(o, to: p),
               near.distance * Double(scale) <= Double(hitTolerance + 3) {
                model.editor.setOutline(Geometry.insertPoint(in: o, segment: near.index), page: pi, actionName: "Insert Outline Point")
                model.selectedVertex = near.index + 1
                return
            }
            model.selectedVertex = nil
            return
        }
        // No outline yet: click points; clicking the first point closes the path.
        traceMessage = nil
        if pendingPage != pi { cancelPendingOutline(); pendingPage = pi }
        let smart = TracePrefs.smart && !event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.command)
        if pendingOutline.isEmpty {
            sessionTrace = TracePrefs.smart ? traceProvider.context(page: pi, model: model) : nil
            if TracePrefs.smart && sessionTrace == nil { traceMessage = traceProvider.lastError }
            if smart, TracePrefs.mode == .detect, let ctx = sessionTrace {
                detectShape(at: p, page: pi, context: ctx)
                return
            }
        }
        if canClosePending, isOverFirstAnchor(v, page: pi) {
            closePendingOutline(magnetic: magneticClick(event))
            return
        }
        var q = PDFPoint(p.x.rounded(), p.y.rounded())
        var segment: TracedSegment?
        if let last = pendingOutline.last {
            if event.modifierFlags.contains(.shift) {
                q = constrained(q, from: last, shift: true)
            } else if smart, let ctx = sessionTrace {
                q = ctx.snapAnchor(p, radiusPx: snapRadiusPixels(ctx))
                if let w = liveWire(ctx) { segment = ctx.segment(w, from: last, to: q) }
            }
            pendingSegments.append(segment ?? TracedSegment(points: [last, q], magnetic: false))
        } else if smart, let ctx = sessionTrace {
            q = ctx.snapAnchor(p, radiusPx: snapRadiusPixels(ctx))
        }
        pendingOutline.append(q)
        wire = nil // re-rooted at the new anchor on the next trace
        hoverTrace = nil
    }

    // MARK: Smart outline

    /// Magnetic unless smart is off, the page could not be traced, or Shift/Cmd/Option is held.
    private func magneticClick(_ event: NSEvent) -> Bool {
        TracePrefs.smart && sessionTrace != nil && event.modifierFlags.intersection([.shift, .option, .command]).isEmpty
    }

    private func isOverFirstAnchor(_ v: NSPoint, page pi: Int) -> Bool {
        guard let first = pendingOutline.first, let pg = page(pi) else { return false }
        let vf = viewPoint(first, pg)
        return hypot(vf.x - v.x, vf.y - v.y) <= hitTolerance + 3
    }

    /// Three anchors, or two with a traced segment between them, make a closable outline.
    private var canClosePending: Bool {
        pendingOutline.count >= 3 || (pendingOutline.count == 2 && pendingSegments.contains(where: \.magnetic))
    }

    /// The edge-snap radius (screen points, a setting) in raster pixels at the current zoom.
    private func snapRadiusPixels(_ ctx: TraceContext) -> Double {
        TracePrefs.snapRadius / Double(scale) * ctx.pixelsPerPoint
    }

    private func liveWire(_ ctx: TraceContext) -> LiveWire? {
        guard let last = pendingOutline.last else { return nil }
        if wire == nil { wire = ctx.wire(from: last) }
        return wire
    }

    /// Build the page's trace context in the background when the Outline tool is chosen.
    func prefetchTrace() {
        guard let model, model.tool == .outline, TracePrefs.smart, model.template.outlines[model.currentPage] == nil else { return }
        traceProvider.prefetch(page: model.currentPage, model: model)
    }

    /// Auto-detect: the region of similar colour at `p` (or the shape the clicked background
    /// surrounds), fitted with lines and arcs; one undo step.
    private func detectShape(at p: PDFPoint, page pi: Int, context ctx: TraceContext) {
        let result = ctx.detectRegion(at: p, threshold: TracePrefs.regionThreshold).flatMap {
            OutlineTracer.outline(polyline: $0, tolerance: TracePrefs.tolerance, context: ctx)
        }
        switch result {
        case .success(let o):
            model.editor.setOutline(o, page: pi, actionName: "Detect Outline")
            cancelPendingOutline()
        case .failure(let f):
            cancelPendingOutline()
            traceMessage = f.message
        }
        needsDisplay = true
    }

    /// Close the outline being placed. With traced segments the path is closed along the
    /// artwork back to the first anchor (unless `magnetic` is false), then fitted with lines
    /// and arcs (SPEC 5.6.3) and validated; a crossing trace is refused with a message and
    /// the anchors stay so the last one can be removed. One undo step for the whole outline.
    func closePendingOutline(magnetic: Bool = true) {
        guard let pi = pendingPage, canClosePending else { return }
        guard pendingSegments.contains(where: \.magnetic) || (magnetic && sessionTrace != nil && TracePrefs.smart) else {
            let segs = pendingOutline.dropFirst().map { Segment.line(to: $0) } + [Segment.line(to: pendingOutline[0])]
            model.editor.setOutline(Outline(start: pendingOutline[0], segments: segs), page: pi, actionName: "Draw Outline")
            cancelPendingOutline()
            return
        }
        let first = pendingOutline[0], last = pendingOutline[pendingOutline.count - 1]
        var closing = TracedSegment(points: [last, first], magnetic: false)
        if magnetic, TracePrefs.smart, let ctx = sessionTrace, let w = liveWire(ctx), let seg = ctx.segment(w, from: last, to: first) {
            closing = seg
        }
        switch OutlineTracer.outline(segments: pendingSegments + [closing], context: sessionTrace, tolerance: TracePrefs.tolerance) {
        case .success(let o):
            model.editor.setOutline(o, page: pi, actionName: "Trace Outline")
            cancelPendingOutline()
        case .failure(let f):
            traceMessage = f.message
            needsDisplay = true
        }
    }

    func cancelPendingOutline() {
        pendingOutline = []
        pendingSegments = []
        pendingPage = nil
        hoverPoint = nil
        hoverTrace = nil
        wire = nil
        sessionTrace = nil
        needsDisplay = true
    }

    /// True while an outline is being placed or a field/vertex drag is under way.
    var isInProgress: Bool {
        if !pendingOutline.isEmpty { return true }
        if case .none = drag { return false }
        return true
    }

    /// Abandon whatever is in progress: pending outline points, a draw drag, or a move/resize/vertex
    /// drag (the original geometry is restored and no undo step is recorded). Clears snap guides.
    /// Returns whether anything was cancelled. The tool is left as it is (Outline stays armed).
    @discardableResult
    func cancelInProgress() -> Bool {
        let had = isInProgress || guides != nil
        if case .none = drag {} else {
            drag = .none
            model?.editor.cancelGesture()
        }
        guides = nil
        let hadMessage = traceMessage != nil
        traceMessage = nil
        cancelPendingOutline()
        return had || hadMessage
    }

    /// Delete/Backspace/Cmd-Z while placing: drop only the last point.
    func removeLastPendingPoint() {
        guard !pendingOutline.isEmpty else { return }
        pendingOutline.removeLast()
        if pendingSegments.count >= pendingOutline.count, !pendingSegments.isEmpty { pendingSegments.removeLast() }
        hoverPoint = nil
        hoverTrace = nil
        wire = nil
        traceMessage = nil
        if pendingOutline.isEmpty { cancelPendingOutline() }
        needsDisplay = true
    }

    @objc func undo(_ sender: Any?) {
        if !pendingOutline.isEmpty { removeLastPendingPoint() } else { undoManager?.undo() }
    }

    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return !pendingOutline.isEmpty || (undoManager?.canUndo ?? false)
        case #selector(redo(_:)): return undoManager?.canRedo ?? false
        default: return true
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: nudge(dx: -step, dy: 0); return  // left
        case 124: nudge(dx: step, dy: 0); return   // right
        case 125: nudge(dx: 0, dy: -step); return  // down
        case 126: nudge(dx: 0, dy: step); return   // up
        case 51, 117:                               // delete, forward delete
            if !pendingOutline.isEmpty { removeLastPendingPoint() } else if case .none = drag { deleteSelection() }
            return
        case 53:                                    // escape
            if !cancelInProgress() { model.editor.selection = nil; model.selectedVertex = nil }
            return
        case 36, 76: if !pendingOutline.isEmpty { closePendingOutline() }; return // return
        case 48: cycleSelection(backwards: event.modifierFlags.contains(.shift)); return // tab
        default: break
        }
        if mods.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "v": model.tool = .select; return
            case "t": model.tool = .text; return
            case "i": model.tool = .image; return
            case "o": model.tool = .outline; return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    private func nudge(dx: Double, dy: Double) {
        if model.tool == .outline, let vi = model.selectedVertex, var o = model.template.outlines[model.currentPage] {
            let p = o.points[vi]
            moveOutlineVertex(&o, index: vi, to: PDFPoint(p.x + dx, p.y + dy))
            model.editor.setOutline(o, page: model.currentPage, actionName: "Nudge Outline Point")
            return
        }
        guard let id = model.editor.selection, let f = model.template.field(id), f.isEditable else { return }
        let r = f.rect.offsetBy(dx: dx, dy: dy).clamped(into: model.pageBounds(f.page))
        model.editor.updateField(id, "Nudge", coalesceKey: "nudge") { $0.rect = r }
    }

    func deleteSelection() {
        if model.tool == .outline, let vi = model.selectedVertex, let o = model.template.outlines[model.currentPage] {
            let n = Geometry.removePoint(in: o, vertex: vi)
            if n != o { model.editor.setOutline(n, page: model.currentPage, actionName: "Delete Outline Point") }
            model.selectedVertex = nil
            return
        }
        if let id = model.editor.selection { model.editor.deleteField(id) }
    }

    private func cycleSelection(backwards: Bool) {
        let fields = model.template.fields
        guard !fields.isEmpty else { return }
        let i = model.editor.selection.flatMap { id in fields.firstIndex { $0.id == id } }
        let next = i.map { (backwards ? $0 - 1 + fields.count : $0 + 1) % fields.count } ?? 0
        model.editor.selection = fields[next].id
    }
}

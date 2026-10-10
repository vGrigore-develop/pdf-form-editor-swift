import Foundation
import Combine

/// Owns the editable `Template` and turns every change into one undo step on the
/// document's single undo stack (SPEC 4, "Undo/redo"). Snapshots are whole
/// `Template` values, which are small and make undo trivially correct.
///
/// - Continuous drags: `beginGesture()`, then `updateDuringGesture`, then
///   `endGesture(_:)` registers exactly one step.
/// - Typing into an inspector field: `perform(_:coalesceKey:)` with the same key
///   coalesces consecutive edits into one step until another command runs.
@MainActor
public final class TemplateEditor: ObservableObject {
    @Published public private(set) var template: Template
    @Published public var selection: UUID? {
        didSet { if selection != oldValue { lastCoalesceKey = nil } }
    }
    public weak var undoManager: UndoManager?

    private var lastCoalesceKey: String?
    private var gestureStart: Template?

    public init(template: Template, undoManager: UndoManager? = nil) {
        self.template = template
        self.undoManager = undoManager
    }

    public var selectedField: FieldDef? { selection.flatMap { template.field($0) } }

    /// Replace the template without undo (after open or save re-read).
    public func reset(to t: Template) {
        template = t
        lastCoalesceKey = nil
        gestureStart = nil
        if let s = selection, t.field(s) == nil { selection = nil }
    }

    // MARK: Commands

    public func perform(_ actionName: String, coalesceKey: String? = nil, _ body: (inout Template) -> Void) {
        var t = template
        body(&t)
        guard t != template else { return }
        if let key = coalesceKey, key == lastCoalesceKey, gestureStart == nil {
            template = t
            return
        }
        registerUndo(restoring: template, actionName: actionName)
        template = t
        lastCoalesceKey = coalesceKey
    }

    public func updateField(_ id: UUID, _ actionName: String, coalesceKey: String? = nil, _ body: (inout FieldDef) -> Void) {
        perform(actionName, coalesceKey: coalesceKey.map { "\(id)|\($0)" }) { t in
            guard let i = t.index(of: id) else { return }
            body(&t.fields[i])
        }
    }

    @discardableResult
    public func addField(_ f: FieldDef, select: Bool = true) -> UUID {
        perform(f.kind == .image ? "New Image Field" : "New Text Field") { $0.fields.append(f) }
        if select { selection = f.id }
        return f.id
    }

    public func deleteField(_ id: UUID) {
        guard let f = template.field(id), f.isEditable else { return }
        perform("Delete \(f.name)") { $0.fields.removeAll { $0.id == id } }
        if selection == id { selection = nil }
    }

    /// "Merge field and widget" (DECISIONS 29): one undo step that makes the field
    /// editable; the save turns the parent field and its single /Kids widget into one
    /// dictionary. Nothing changes in the file until then, so undo before saving is exact.
    public func mergeFieldAndWidget(_ id: UUID) {
        guard let f = template.field(id), f.canMergeWidget else { return }
        perform("Merge Field and Widget") { t in
            guard let i = t.index(of: id) else { return }
            t.fields[i].origin?.mergeWidgetOnSave = true
            t.fields[i].origin?.editable = true
            t.fields[i].origin?.readOnlyReason = nil
        }
    }

    @discardableResult
    public func duplicateField(_ id: UUID, offset: Double = 10) -> UUID? {
        guard let f = template.field(id), f.kind != .other else { return nil }
        var copy = f
        copy.id = UUID()
        copy.origin = nil
        copy.name = Naming.duplicateName(of: f.name, existing: Set(template.fields.map(\.name)))
        copy.rect = f.rect.offsetBy(dx: offset, dy: -offset)
        if template.pages.indices.contains(f.page) {
            copy.rect = copy.rect.clamped(into: template.pages[f.page].mediaBox)
        }
        perform("Duplicate \(f.name)") { $0.fields.append(copy) }
        selection = copy.id
        return copy.id
    }

    public func setOutline(_ o: Outline?, page: Int, actionName: String) {
        perform(actionName) { $0.outlines[page] = o }
    }

    // MARK: Gestures (drags coalesce into one step)

    public var isInGesture: Bool { gestureStart != nil }

    public func beginGesture() {
        if gestureStart == nil { gestureStart = template }
    }

    public func updateDuringGesture(_ body: (inout Template) -> Void) {
        if gestureStart == nil { gestureStart = template }
        var t = template
        body(&t)
        if t != template { template = t }
    }

    public func endGesture(_ actionName: String) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        lastCoalesceKey = nil
        if start != template { registerUndo(restoring: start, actionName: actionName) }
    }

    public func cancelGesture() {
        if let start = gestureStart { template = start }
        gestureStart = nil
    }

    // MARK: Undo

    private func registerUndo(restoring previous: Template, actionName: String) {
        guard let um = undoManager else { return }
        // Outside an event loop (tests, scripted use) there is no automatic group: make one.
        let ownGroup = !um.groupsByEvent && um.groupingLevel == 0
        if ownGroup { um.beginUndoGrouping() }
        um.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(previous, actionName: actionName) }
        }
        um.setActionName(actionName)
        if ownGroup { um.endUndoGrouping() }
    }

    private func restore(_ t: Template, actionName: String) {
        let current = template
        registerUndo(restoring: current, actionName: actionName)
        template = t
        lastCoalesceKey = nil
        if let s = selection, t.field(s) == nil { selection = nil }
    }
}

import AppKit
import UniformTypeIdentifiers

/// Document controller that knows the PDF type even when the app runs without an
/// Info.plist (e.g. `swift run`); the bundled app declares the same in Info.plist.
final class VoucherDocumentController: NSDocumentController {
    override var documentClassNames: [String] { ["VoucherDocument"] }
    override var defaultType: String? { VoucherDocument.pdfType }
    override func documentClass(forType typeName: String) -> AnyClass? { VoucherDocument.self }
    override func typeForContents(of url: URL) throws -> String { VoucherDocument.pdfType }
    override func displayName(forType typeName: String) -> String? { "PDF Document" }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        NSApp.activate(ignoringOtherApps: true)
        // Files passed on the command line (`PDFVoucherEditor file.pdf`); `open -a` uses Apple Events instead.
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && $0.lowercased().hasSuffix(".pdf") }
        for p in paths {
            let url = URL(fileURLWithPath: p)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        scheduleSnapshotsIfRequested()
        // Launch state: if nothing was opened (command line, Apple Event, window restoration),
        // show the launcher window with an Open PDF button. Delayed so restoration and the
        // open-file Apple Event get to run first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if paths.isEmpty { LauncherWindowController.shared.showIfNoDocuments() }
        }
    }

    /// Dock-icon click with no visible window: bring the launcher back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { LauncherWindowController.shared.showIfNoDocuments() }
        return !flag ? false : true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Self-check snapshots (debug aid; used to verify the UI renders without screen-recording rights)
    //   VE_SNAPSHOT_DIR=/some/dir  PDFVoucherEditor file.pdf
    // writes 1-edit.png, 2-selected.png, 3-outline.png, 4-preview.png of the document window, then quits.
    func scheduleSnapshotsIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["VE_SNAPSHOT_DIR"] else { return }
        let steps: [(String, (VoucherDocument) -> Void)] = [
            ("1-edit", { _ in }),
            ("2-selected", { d in MainActor.assumeIsolated { d.model?.editor.selection = d.model?.template.fields.first?.id } }),
            ("3-outline", { d in MainActor.assumeIsolated { d.model?.editor.selection = nil; d.model?.tool = .outline; d.model?.selectedVertex = 3 } }),
            ("4-preview", { d in MainActor.assumeIsolated { d.model?.tool = .select; d.model?.isPreview = true } }),
            ("5-edit-again", { d in MainActor.assumeIsolated { d.model?.isPreview = false } }),
        ]
        func run(_ i: Int) {
            guard i < steps.count else { NSApp.terminate(nil); return }
            guard let doc = NSDocumentController.shared.documents.first as? VoucherDocument,
                  let window = doc.windowControllers.first?.window, let view = window.contentView else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { run(i) }
                return
            }
            steps[i].1(doc)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(steps[i].0).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
                run(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { run(0) }
    }

    @objc func toggleSnapping(_ sender: Any?) { SnapPrefs.enabled.toggle() }
    @objc func toggleGrid(_ sender: Any?) { SnapPrefs.showGrid.toggle() }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSnapping(_:)) { item.state = SnapPrefs.enabled ? .on : .off }
        if item.action == #selector(toggleGrid(_:)) { item.state = SnapPrefs.showGrid ? .on : .off }
        return true
    }

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appName = "PDF Voucher Editor"

        let app = NSMenu(title: appName)
        app.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        app.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))

        let file = NSMenu(title: "File")
        file.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        file.items.last?.target = NSDocumentController.shared
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        recentMenu.items.last?.target = NSDocumentController.shared
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(item("Save", #selector(NSDocument.save(_:)), "s"))
        file.addItem(item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]))
        file.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Duplicate Field", #selector(VoucherDocument.duplicateField(_:)), "d"))
        edit.addItem(item("Delete Field", #selector(VoucherDocument.deleteField(_:)), "\u{8}"))

        let view = NSMenu(title: "View")
        view.addItem(item("Edit / Preview", #selector(VoucherDocument.togglePreview(_:)), "p"))
        view.addItem(.separator())
        view.addItem(item("Snapping", #selector(AppDelegate.toggleSnapping(_:))))
        view.addItem(item("Show Grid", #selector(AppDelegate.toggleGrid(_:)), "'"))
        view.addItem(.separator())
        view.addItem(item("Zoom In", #selector(VoucherDocument.veZoomIn(_:)), "+"))
        view.addItem(item("Zoom Out", #selector(VoucherDocument.veZoomOut(_:)), "-"))
        view.addItem(item("Actual Size", #selector(VoucherDocument.veZoomActual(_:)), "0"))
        view.addItem(item("Zoom to Fit", #selector(VoucherDocument.veZoomFit(_:)), "9"))

        let tools = NSMenu(title: "Tools")
        for (title, tool) in [("Select (V)", "select"), ("Text Field (T)", "text"), ("Image Field (I)", "image"), ("Outline (O)", "outline")] {
            let i = item(title, #selector(VoucherDocument.chooseTool(_:)))
            i.representedObject = tool
            tools.addItem(i)
        }
        tools.addItem(.separator())
        tools.addItem(item("New Outline from Rectangle", #selector(VoucherDocument.newRectangleOutline(_:))))
        tools.addItem(item("Remove Cut", #selector(VoucherDocument.removeCut(_:))))

        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        NSApp.windowsMenu = window

        for (title, menu) in [(appName, app), ("File", file), ("Edit", edit), ("View", view), ("Tools", tools), ("Window", window)] {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu
            main.addItem(top)
        }
        return main
    }
}

// The first NSDocumentController instance becomes the shared one.
_ = VoucherDocumentController()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

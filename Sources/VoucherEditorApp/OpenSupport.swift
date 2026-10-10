import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything that opens a PDF goes through here: File > Open, the toolbar and launcher
/// buttons, Open Recent, drag and drop. Documents are still created by NSDocumentController,
/// so the single-writer save pipeline is untouched.
enum OpenPDF {
    /// Shows the standard Open panel (restricted to PDF by VoucherDocument.readableTypes).
    static func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        NSDocumentController.shared.openDocument(nil)
    }

    static func isPDF(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if let t = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return t.conforms(to: .pdf) }
        return url.pathExtension.lowercased() == "pdf"
    }

    /// Opens each PDF URL as a document window; returns how many were accepted.
    @discardableResult
    static func open(_ urls: [URL], completion: ((URL, Error?) -> Void)? = nil) -> Int {
        let pdfs = urls.filter(isPDF)
        for url in pdfs {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
                completion?(url, error)
            }
        }
        return pdfs.count
    }

    /// Drop handler for SwiftUI `.onDrop(of: [.fileURL])`.
    static func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for p in fileProviders {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { open([url]) }
            }
        }
        return true
    }
}

/// Small window shown when no document is open.
@MainActor
final class LauncherWindowController {
    static let shared = LauncherWindowController()
    private var window: NSWindow?
    private var observer: NSObjectProtocol?

    var isShown: Bool { window?.isVisible ?? false }

    func showIfNoDocuments() {
        guard NSDocumentController.shared.documents.isEmpty else { return }
        show()
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "PDF Voucher Editor"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: LauncherView())
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        // Close as soon as a document window exists.
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let win = note.object as? NSWindow, win !== self.window,
                      !NSDocumentController.shared.documents.isEmpty else { return }
                self.window?.close()
            }
        }
    }
}

struct LauncherView: View {
    @State private var targeted = false
    private var recents: [URL] { Array(NSDocumentController.shared.recentDocumentURLs.prefix(5)) }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.badge.plus").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Open a PDF template").font(.title3)
            Button("Open PDF…") { OpenPDF.showPanel() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            Text("or drop a PDF file here").foregroundStyle(.secondary)
            if !recents.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    ForEach(recents, id: \.self) { url in
                        Button(url.lastPathComponent) { OpenPDF.open([url]) }
                            .buttonStyle(.link).help(url.path)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(targeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $targeted, perform: OpenPDF.handleDrop)
    }
}

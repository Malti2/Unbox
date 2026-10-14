import AppKit
import SwiftUI

/// Handles disk images handed to the app: mounts silently, shows the confirmation window, one image at a time.
@MainActor
final class InstallController: NSObject, NSWindowDelegate {
    static let shared = InstallController()

    private var queue: [URL] = []
    private var busy = false
    private var windows: [ObjectIdentifier: (NSWindow, InstallSession)] = [:]
    var onIdle: (@MainActor () -> Void)?

    static func openWithSystem(_ url: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: AppModel.systemMounter, configuration: cfg)
    }

    func handle(_ urls: [URL]) {
        queue.append(contentsOf: urls.filter { $0.pathExtension.lowercased() == "dmg" || $0.isFileURL })
        pump()
    }

    private func pump() {
        guard !busy else { return }
        guard !queue.isEmpty else { onIdle?(); return }
        busy = true
        let dmg = queue.removeFirst()
        Task {
            await process(dmg)
            busy = false
            pump()
        }
    }

    private func process(_ dmg: URL) async {
        let engine = InstallEngine()
        let result = await Task.detached { engine.prepare(dmg: dmg) }.value
        switch result {
        case .done(let o):
            if o.kind == .handedOff {
                Self.openWithSystem(o.dmg)
            } else {
                AppModel.shared.record(o)
                await show(InstallSession(failure: o))
            }
        case .ready(let p):
            await show(InstallSession(prepared: p))
        }
    }

    private func show(_ session: InstallSession) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let hosting = NSHostingController(rootView: InstallView(session: session))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: InstallView.contentSize(for: session)),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentViewController = hosting
            window.setContentSize(InstallView.contentSize(for: session))
            window.title = session.prepared == nil ? "Unbox" : "Install"
            window.isReleasedWhenClosed = false
            window.delegate = self
            WindowPlacement.center(window)
            let key = ObjectIdentifier(window)
            windows[key] = (window, session)
            session.onClose = { [weak self, weak window] in
                if let window { self?.windows[ObjectIdentifier(window)] = nil; window.delegate = nil; window.orderOut(nil) }
                cont.resume()
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    // Closing the window with the red button counts as Cancel.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let (_, session) = windows[ObjectIdentifier(sender)] else { return true }
        switch session.phase {
        case .working: return false
        case .confirm: session.cancel(); return false
        case .finished: session.close(); return false
        }
    }
}

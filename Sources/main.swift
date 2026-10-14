import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var launchedForFiles = false
    private var receivedFiles = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 'odoc' = the system opened a document with us (double-click on a disk image).
        let odoc: AEEventID = 0x6F646F63
        if NSAppleEventManager.shared().currentAppleEvent?.eventID == odoc {
            launchedForFiles = true
            NSApp.setActivationPolicy(.accessory) // no Dock icon while it only handles an image
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            InstallController.shared.onIdle = { [weak self] in self?.idle() }
            guard !launchedForFiles else { return }
            // Launch events can arrive just after this callback. Only open the main window when no image came in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, !self.receivedFiles else { return }
                MainActor.assumeIsolated { self.showMain() }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedFiles = true
        if mainWindow == nil { launchedForFiles = true; NSApp.setActivationPolicy(.accessory) }
        MainActor.assumeIsolated { InstallController.shared.handle(urls) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopen events must not pop the main window while an image is being handled.
        if !flag && !receivedFiles && !launchedForFiles { MainActor.assumeIsolated { showMain() } }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.refreshDefault() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !launchedForFiles }

    @MainActor private func idle() {
        // Quit by itself when it was only started to handle an image.
        guard launchedForFiles, mainWindow == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    @MainActor private func showMain() {
        if let w = mainWindow { w.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: MainView(model: AppModel.shared))
        host.sizingOptions = []
        let size = NSSize(width: 460, height: min(520, WindowPlacement.maxContentHeight()))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(size)
        w.title = "Unbox"
        w.isReleasedWhenClosed = false
        WindowPlacement.center(w)
        mainWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

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
            if !launchedForFiles { showMain() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedFiles = true
        MainActor.assumeIsolated { InstallController.shared.handle(urls) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { showMain() } }
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
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = "Unbox"
        w.isReleasedWhenClosed = false
        w.center()
        mainWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

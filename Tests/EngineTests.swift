import XCTest
import SwiftUI
@testable import Unbox

final class EngineTests: XCTestCase {
    var tmp: URL!
    var apps: URL!
    var trashDir: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("unbox-test-\(UUID().uuidString)")
        apps = tmp.appendingPathComponent("Applications")
        trashDir = tmp.appendingPathComponent("Trash")
        for d in [tmp!, apps!, trashDir!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func engine() -> InstallEngine {
        InstallEngine(applicationsDir: apps, trash: { [trashDir] url in
            try FileManager.default.moveItem(at: url, to: trashDir!.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        })
    }

    @discardableResult
    func sh(_ path: String, _ args: [String]) -> Int32 { Shell.run(path, args).status }

    /// Builds a small DMG. `app == nil` makes an image without an app.
    func makeDMG(name: String = "Sample", app: String? = "Sample", version: String = "1.0", file: String = "Sample.dmg") throws -> URL {
        let root = tmp.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let app {
            let bundle = root.appendingPathComponent("\(app).app/Contents")
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "CFBundleIdentifier": "de.malte.unbox.sample", "CFBundleName": app, "CFBundleExecutable": app,
                "CFBundleShortVersionString": version, "CFBundleVersion": "1", "CFBundlePackageType": "APPL",
                "LSMinimumSystemVersion": "14.0"]
            (plist as NSDictionary).write(to: bundle.appendingPathComponent("Info.plist"), atomically: true)
            let exec = bundle.appendingPathComponent("MacOS/\(app)")
            try "#!/bin/sh\nexit 0\n".write(to: exec, atomically: true, encoding: .utf8)
            chmod(exec.path, 0o755)
            XCTAssertEqual(sh("/usr/bin/codesign", ["--force", "--sign", "-", root.appendingPathComponent("\(app).app").path]), 0)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        } else {
            try "hello".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        }
        let out = tmp.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: out)
        XCTAssertEqual(sh("/usr/bin/hdiutil", ["create", "-srcfolder", root.path, "-format", "UDZO", "-volname", name, "-ov", out.path]), 0)
        return out
    }

    func ready(_ r: PrepareResult, file: StaticString = #filePath, line: UInt = #line) throws -> PreparedInstall {
        guard case .ready(let p) = r else { XCTFail("expected ready", file: file, line: line); throw CancellationError() }
        return p
    }

    func testInstallEjectsAndTrashesImage() throws {
        let dmg = try makeDMG()
        let eng = engine()
        let p = try ready(eng.prepare(dmg: dmg))
        XCTAssertEqual(p.name, "Sample.app")
        XCTAssertEqual(p.version, "1.0")
        XCTAssertEqual(p.bundleID, "de.malte.unbox.sample")
        XCTAssertTrue(p.signed)
        XCTAssertFalse(p.isReplacement)
        var stages: [InstallStage] = []
        let out = eng.commit(p) { stages.append($0) }
        XCTAssertEqual(out.kind, .installed, out.detail)
        XCTAssertEqual(stages.first, .copying(0))
        XCTAssertTrue(stages.contains(.copying(1)))
        XCTAssertTrue(stages.contains(.verifying))
        XCTAssertEqual(stages.last, .trashing)
        var lastFraction = 0.0
        for case .copying(let f) in stages { XCTAssertGreaterThanOrEqual(f, lastFraction); lastFraction = f }
        XCTAssertTrue(FileManager.default.fileExists(atPath: apps.appendingPathComponent("Sample.app/Contents/Info.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dmg.path), "image should be in the trash")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trashDir.path).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.mountPoint.path), "volume should be ejected")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["Sample.app"], "no staging leftovers")
    }

    func testCancelEjectsAndKeepsImage() throws {
        let dmg = try makeDMG()
        let eng = engine()
        let p = try ready(eng.prepare(dmg: dmg))
        let out = eng.cancel(p)
        XCTAssertEqual(out.kind, .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dmg.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.mountPoint.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: apps.path).isEmpty)
    }

    func testExistingAppIsNotOverwrittenWithoutInstall() throws {
        let eng = engine()
        let first = try ready(eng.prepare(dmg: try makeDMG(version: "1.0")))
        XCTAssertEqual(eng.commit(first).kind, .installed)
        let second = try ready(eng.prepare(dmg: try makeDMG(version: "2.0")))
        XCTAssertTrue(second.isReplacement)
        XCTAssertTrue(second.isSameApp)
        XCTAssertFalse(second.isOlderThanInstalled)
        XCTAssertEqual(second.existingVersion, .some("1.0"))
        _ = eng.cancel(second)
        let plist = NSDictionary(contentsOf: apps.appendingPathComponent("Sample.app/Contents/Info.plist"))
        XCTAssertEqual(plist?["CFBundleShortVersionString"] as? String, "1.0")
        // Replace: old goes to the trash, new one is in place.
        let third = try ready(eng.prepare(dmg: try makeDMG(version: "2.0")))
        XCTAssertEqual(eng.commit(third).kind, .installed)
        let plist2 = NSDictionary(contentsOf: apps.appendingPathComponent("Sample.app/Contents/Info.plist"))
        XCTAssertEqual(plist2?["CFBundleShortVersionString"] as? String, "2.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trashDir.path).count, 3) // old image, old app, new image
    }

    func testSameVersionIsDetected() throws {
        let eng = engine()
        XCTAssertEqual(eng.commit(try ready(eng.prepare(dmg: try makeDMG(version: "1.0")))).kind, .installed)
        let again = try ready(eng.prepare(dmg: try makeDMG(version: "1.0")))
        XCTAssertTrue(again.isSameApp)
        XCTAssertTrue(again.isSameVersionInstalled)
        _ = eng.cancel(again)
        let newer = try ready(eng.prepare(dmg: try makeDMG(version: "1.1")))
        XCTAssertFalse(newer.isSameVersionInstalled)
        _ = eng.cancel(newer)
        let older = try ready(eng.prepare(dmg: try makeDMG(version: "0.9")))
        XCTAssertTrue(older.isOlderThanInstalled)
        _ = eng.cancel(older)
    }

    func testWindowFrameIsCentered() {
        let f = WindowPlacement.frame(size: NSSize(width: 400, height: 300), on: nil)
        XCTAssertEqual(f.midX, 720, accuracy: 1)
        XCTAssertEqual(f.midY, 450, accuracy: 1)
    }

    func testImageWithoutAppIsHandedToSystem() throws {
        let eng = engine()
        guard case .done(let o) = eng.prepare(dmg: try makeDMG(app: nil, file: "Docs.dmg")) else { return XCTFail("expected done") }
        XCTAssertEqual(o.kind, .handedOff)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: apps.path).isEmpty)
    }

    func testNotAnImageFails() throws {
        let junk = tmp.appendingPathComponent("junk.dmg")
        try "not an image".write(to: junk, atomically: true, encoding: .utf8)
        guard case .done(let o) = engine().prepare(dmg: junk) else { return XCTFail("expected done") }
        XCTAssertEqual(o.kind, .failed)
    }

    func testQuarantineIsCarriedOver() throws {
        let dmg = try makeDMG()
        let q = "0083;5f000000;Safari;".data(using: .utf8)!
        InstallEngine.writeXattr(dmg, InstallEngine.quarantineKey, q)
        let eng = engine()
        let p = try ready(eng.prepare(dmg: dmg))
        XCTAssertEqual(eng.commit(p).kind, .installed)
        XCTAssertEqual(InstallEngine.readXattr(apps.appendingPathComponent("Sample.app"), InstallEngine.quarantineKey), q)
    }

    func testVersionOrdering() {
        XCTAssertTrue(AppVersion("0.1.0")! < AppVersion("0.1.1")!)
        XCTAssertTrue(AppVersion("0.2.0-beta.1")! < AppVersion("0.2.0")!)
        XCTAssertTrue(AppVersion("0.2.0-beta.1")! < AppVersion("0.2.0-beta.2")!)
        XCTAssertTrue(AppVersion("v0.1.9")! < AppVersion("0.2.0-beta.1")!)
    }

    // MARK: Screenshots (CI uploads them for review)

    @MainActor
    func testRenderScreenshots() throws {
        let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? "/tmp/unbox-shots")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let eng = engine()
        let p = try ready(eng.prepare(dmg: try makeDMG()))
        defer { _ = eng.cancel(p) }

        let confirm = InstallSession(prepared: p)
        try render(InstallView(session: confirm), name: "install-confirm", to: outDir)

        let done = InstallSession(prepared: p)
        done.phase = .finished(InstallOutcome(kind: .installed, title: "Sample", detail: "Sample 1.0 is in /Applications.", dmg: p.dmg))
        try render(InstallView(session: done), name: "install-done", to: outDir)

        let failed = InstallSession(failure: InstallOutcome(kind: .failed, title: "Sample", detail: "Copying Sample.app failed. You do not have permission to write to /Applications. The image was kept.", dmg: p.dmg))
        try render(InstallView(session: failed), name: "install-failed", to: outDir)

        var update = p
        update.existingVersion = .some("0.9"); update.existingBundleID = p.bundleID; update.existingBuild = "1"
        try render(InstallView(session: InstallSession(prepared: update)), name: "install-update", to: outDir)

        var same = p
        same.existingVersion = .some(p.version); same.existingBundleID = p.bundleID; same.existingBuild = p.build
        try render(InstallView(session: InstallSession(prepared: same)), name: "install-reinstall", to: outDir)

        var other = p
        other.existingVersion = .some("3.2"); other.existingBundleID = "com.example.other"; other.existingBuild = "9"
        try render(InstallView(session: InstallSession(prepared: other)), name: "install-different-app", to: outDir)

        let progress = InstallSession(prepared: p)
        progress.phase = .working(.copying(0.42))
        try render(InstallView(session: progress), name: "install-progress", to: outDir)

        let model = AppModel.shared
        model.history = [HistoryItem(date: Date().addingTimeInterval(-300), title: "Sample", detail: "Sample 1.0 is in /Applications.", success: true)]
        try render(MainView(model: model).frame(width: 460, height: 520), name: "main", to: outDir)
    }

    @MainActor
    func render<V: View>(_ view: V, name: String, to dir: URL) throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let rep = window.contentView?.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no rep") }
        window.contentView?.cacheDisplay(in: host.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}

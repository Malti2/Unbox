import Foundation
import AppKit

/// Result of handling one disk image.
struct InstallOutcome {
    enum Kind { case installed, cancelled, failed, handedOff }
    var kind: Kind
    var title: String
    var detail: String
    var dmg: URL
}

/// Everything the confirmation window shows, read from the real .app inside the mounted image.
struct PreparedInstall {
    var dmg: URL
    var mountPoint: URL
    var mountRoot: URL
    var appURL: URL
    var name: String
    var displayName: String
    var version: String?
    var build: String?
    var bundleID: String
    var minimumSystem: String?
    var sizeBytes: Int64
    var signed: Bool
    var icon: NSImage
    var existingVersion: String??   // nil = not installed at the destination; .some(nil) = installed, version unknown
    var existingBundleID: String?
    var existingIsRunning: Bool
    var installedElsewhere: URL?    // same bundle identifier, installed under another path
    var destination: URL
    var isReplacement: Bool { existingVersion != nil }
    /// True when the installed app at the destination has the same bundle identifier, so this really is an update.
    var isSameApp: Bool { existingBundleID == bundleID }
    var isOlderThanInstalled: Bool {
        guard let new = version, let old = existingVersion ?? nil else { return false }
        return new.compare(old, options: .numeric) == .orderedAscending
    }
}

enum PrepareResult {
    case ready(PreparedInstall)
    case done(InstallOutcome)
}

enum Shell {
    struct Result { var status: Int32; var out: Data; var err: String }

    /// Runs a tool with stdin closed, so a tool can never answer an interactive prompt (for example a license agreement) on the user's behalf.
    static func run(_ path: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return Result(status: -1, out: Data(), err: "\(error)") }
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let out = o.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, out: out, err: String(decoding: errData, as: UTF8.self))
    }
}

final class InstallEngine {
    private struct Failure: Error { var message: String }

    let applicationsDir: URL
    let trash: (URL) throws -> Void
    let allowReplacingRunningApp: Bool
    let deleteImageInsteadOfTrashing: Bool

    init(applicationsDir: URL = URL(fileURLWithPath: "/Applications"),
         allowReplacingRunningApp: Bool = false,
         deleteImageInsteadOfTrashing: Bool = false,
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.applicationsDir = applicationsDir
        self.allowReplacingRunningApp = allowReplacingRunningApp
        self.deleteImageInsteadOfTrashing = deleteImageInsteadOfTrashing
        self.trash = trash
    }

    static let quarantineKey = "com.apple.quarantine"

    // MARK: Phase 1: mount silently and read the app

    /// Mounts the image without any Finder window and reads the app inside. Blocking.
    /// `.done` means there is nothing to confirm: the caller should open the image normally (`.handedOff`) or report a failure.
    func prepare(dmg: URL) -> PrepareResult {
        let dmgName = dmg.deletingPathExtension().lastPathComponent
        switch inspect(dmg) {
        case .needsSystem(let why):
            return .done(InstallOutcome(kind: .handedOff, title: dmgName, detail: why, dmg: dmg))
        case .failed(let why):
            return .done(InstallOutcome(kind: .failed, title: dmgName, detail: why, dmg: dmg))
        case .ok: break
        }

        let fm = FileManager.default
        let mountRoot = fm.temporaryDirectory.appendingPathComponent("unbox-\(UUID().uuidString)")
        let mount: URL
        do {
            try fm.createDirectory(at: mountRoot, withIntermediateDirectories: true)
            mount = try attach(dmg, mountRoot: mountRoot)
        } catch let f as Failure {
            try? fm.removeItem(at: mountRoot)
            return .done(InstallOutcome(kind: .failed, title: dmgName, detail: f.message, dmg: dmg))
        } catch {
            try? fm.removeItem(at: mountRoot)
            return .done(InstallOutcome(kind: .failed, title: dmgName, detail: "\(error)", dmg: dmg))
        }

        func release() { _ = detach(mount); try? fm.removeItem(at: mountRoot) }

        let apps = topLevelApps(in: mount)
        if apps.count != 1 {
            release()
            let why = apps.isEmpty
                ? "This image has no app at the top level, so it was opened normally."
                : "This image contains \(apps.count) apps, so it was opened normally."
            return .done(InstallOutcome(kind: .handedOff, title: dmgName, detail: why, dmg: dmg))
        }
        let source = apps[0]
        guard let plist = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist")),
              let bundleID = plist["CFBundleIdentifier"] as? String else {
            release()
            return .done(InstallOutcome(kind: .handedOff, title: dmgName, detail: "The app in this image has no valid Info.plist, so the image was opened normally.", dmg: dmg))
        }
        let signed: Bool
        do { signed = try isSigned(source) } catch let f as Failure {
            release()
            return .done(InstallOutcome(kind: .failed, title: dmgName, detail: f.message, dmg: dmg))
        } catch { release(); return .done(InstallOutcome(kind: .failed, title: dmgName, detail: "\(error)", dmg: dmg)) }

        let name = source.lastPathComponent
        let dest = applicationsDir.appendingPathComponent(name)
        let destExists = (try? fm.attributesOfItem(atPath: dest.path)) != nil
        var existing: String?? = nil
        var running = false
        var existingID: String?
        if destExists {
            let old = NSDictionary(contentsOf: dest.appendingPathComponent("Contents/Info.plist"))
            existingID = old?["CFBundleIdentifier"] as? String
            existing = .some(old?["CFBundleShortVersionString"] as? String)
            running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL == dest.standardizedFileURL }
        }
        let display = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? source.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: source.path)
        var elsewhere: URL?
        if !destExists, applicationsDir.path == "/Applications",
           let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           !found.path.hasPrefix(mountRoot.path), !found.path.hasPrefix("/Volumes/") {
            elsewhere = found
        }
        return .ready(PreparedInstall(
            dmg: dmg, mountPoint: mount, mountRoot: mountRoot, appURL: source, name: name, displayName: display,
            version: plist["CFBundleShortVersionString"] as? String, build: plist["CFBundleVersion"] as? String,
            bundleID: bundleID, minimumSystem: plist["LSMinimumSystemVersion"] as? String,
            sizeBytes: Self.size(of: source), signed: signed, icon: icon,
            existingVersion: existing, existingBundleID: existingID, existingIsRunning: running,
            installedElsewhere: elsewhere, destination: dest))
    }

    // MARK: Phase 2a: cancel

    /// Cancel: eject only. The image stays where it is.
    func cancel(_ p: PreparedInstall) -> InstallOutcome {
        let ok = detach(p.mountPoint)
        try? FileManager.default.removeItem(at: p.mountRoot)
        return InstallOutcome(kind: .cancelled, title: p.displayName,
                              detail: ok ? "Cancelled. The image was ejected." : "Cancelled, but the image could not be ejected because it is in use.", dmg: p.dmg)
    }

    // MARK: Phase 2b: install

    /// Copies the app, ejects the image and moves it to the Trash. The Trash step only happens after a verified copy and a successful eject.
    func commit(_ p: PreparedInstall, progress: (String) -> Void = { _ in }) -> InstallOutcome {
        var outcome: InstallOutcome
        do { outcome = try copyApp(p, progress: progress) }
        catch let f as Failure { outcome = InstallOutcome(kind: .failed, title: p.displayName, detail: f.message, dmg: p.dmg) }
        catch { outcome = InstallOutcome(kind: .failed, title: p.displayName, detail: "\(error)", dmg: p.dmg) }

        progress("Ejecting")
        let ejected = detach(p.mountPoint)
        try? FileManager.default.removeItem(at: p.mountRoot)
        if outcome.kind == .installed {
            if !ejected {
                outcome.detail += " The image could not be ejected because it is in use, so it was left in place."
            } else {
                do {
                    if deleteImageInsteadOfTrashing { try FileManager.default.removeItem(at: p.dmg) } else { try trash(p.dmg) }
                } catch {
                    outcome.detail += " The image was ejected but could not be moved to the Trash (\(error.localizedDescription))."
                }
            }
        }
        return outcome
    }

    // MARK: Inspect

    private enum Inspection { case ok, needsSystem(String), failed(String) }

    private func inspect(_ dmg: URL) -> Inspection {
        guard FileManager.default.isReadableFile(atPath: dmg.path) else { return .failed("The file cannot be read.") }
        let r = Shell.run("/usr/bin/hdiutil", ["imageinfo", "-plist", dmg.path])
        guard r.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: r.out, format: nil) as? [String: Any] else {
            return .failed("This does not look like a valid disk image.")
        }
        let props = plist["Properties"] as? [String: Any] ?? [:]
        if (props["Encrypted"] as? Bool) == true {
            return .needsSystem("This image is encrypted, so it was opened normally to ask for the password.")
        }
        if (props["Software License Agreement"] as? Bool) == true {
            return .needsSystem("This image has a license agreement. It was opened normally so you can read and accept it yourself.")
        }
        return .ok
    }

    // MARK: Mount

    private func attach(_ dmg: URL, mountRoot: URL) throws -> URL {
        // -nobrowse and -noautoopen keep the volume out of Finder and prevent any window from opening.
        let r = Shell.run("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", "-noautoopen", "-readonly",
                                               "-mountrandom", mountRoot.path, dmg.path])
        guard r.status == 0 else {
            let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: msg.isEmpty ? "The image could not be mounted." : "The image could not be mounted: \(msg)")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: r.out, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw Failure(message: "The image mounted, but its volume could not be located.")
        }
        guard let first = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw Failure(message: "The image has no mountable volume.")
        }
        return URL(fileURLWithPath: first)
    }

    private func detach(_ mount: URL) -> Bool {
        for attempt in 0..<4 {
            if Shell.run("/usr/bin/hdiutil", ["detach", mount.path]).status == 0 { return true }
            Thread.sleep(forTimeInterval: 0.5 * Double(attempt + 1))
        }
        return false // never forced: force-ejecting could lose data from a process still using the volume
    }

    // MARK: Copy

    private func topLevelApps(in mount: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.filter { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return url.pathExtension.lowercased() == "app" && v?.isSymbolicLink != true && v?.isDirectory == true
        }
    }

    private func bundleID(_ app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
    }

    private func isSigned(_ app: URL) throws -> Bool {
        let r = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        if r.status == 0 { return true }
        if r.err.contains("not signed at all") { return false }
        throw Failure(message: "The app's code signature is broken, so it was not installed.")
    }

    private func copyApp(_ p: PreparedInstall, progress: (String) -> Void) throws -> InstallOutcome {
        let fm = FileManager.default
        let name = p.name
        let dest = p.destination
        let destExists = (try? fm.attributesOfItem(atPath: dest.path)) != nil
        if destExists {
            let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL == dest.standardizedFileURL }
            if running && !allowReplacingRunningApp {
                throw Failure(message: "\(name) is running. Quit it and try again. The image was kept.")
            }
        }

        progress("Copying \(name)")
        let staging = applicationsDir.appendingPathComponent(".unbox-\(UUID().uuidString)-\(name)")
        let r = Shell.run("/usr/bin/ditto", [p.appURL.path, staging.path])
        guard r.status == 0 else {
            try? fm.removeItem(at: staging)
            let hint = !fm.isWritableFile(atPath: applicationsDir.path) ? " You do not have permission to write to \(applicationsDir.path)." : ""
            throw Failure(message: "Copying \(name) failed.\(hint) The image was kept.")
        }
        guard bundleID(staging) == p.bundleID else {
            try? fm.removeItem(at: staging)
            throw Failure(message: "The copy of \(name) did not match the original. The image was kept.")
        }
        if p.signed, (try? isSigned(staging)) != true {
            try? fm.removeItem(at: staging)
            throw Failure(message: "The copy of \(name) failed signature verification. The image was kept.")
        }
        // Gatekeeper: a quarantine flag on the image is carried over to the installed app. It is never removed.
        if let q = Self.readXattr(p.dmg, Self.quarantineKey) { Self.writeXattr(staging, Self.quarantineKey, q) }

        var trashedExisting = false
        if destExists {
            do { try trash(dest); trashedExisting = true } catch {
                try? fm.removeItem(at: staging)
                throw Failure(message: "The existing \(name) could not be moved to the Trash: \(error.localizedDescription). The image was kept.")
            }
        }
        do { try fm.moveItem(at: staging, to: dest) } catch {
            try? fm.removeItem(at: staging)
            let note = trashedExisting ? " The previous version is in the Trash." : ""
            throw Failure(message: "\(name) could not be put in place: \(error.localizedDescription).\(note) The image was kept.")
        }
        var detail = "\(p.displayName)\(p.version.map { " \($0)" } ?? "") is in \(applicationsDir.path)."
        if !p.signed { detail += " It is unsigned, so macOS may ask you to confirm it on first open." }
        return InstallOutcome(kind: .installed, title: p.displayName, detail: detail, dmg: p.dmg)
    }

    // MARK: Helpers

    static func size(of url: URL) -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [])
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func readXattr(_ url: URL, _ key: String) -> Data? {
        let size = getxattr(url.path, key, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        let n = getxattr(url.path, key, &buf, size, 0, 0)
        return n > 0 ? Data(buf.prefix(n)) : nil
    }

    static func writeXattr(_ url: URL, _ key: String, _ value: Data) {
        value.withUnsafeBytes { raw in _ = setxattr(url.path, key, raw.baseAddress, value.count, 0, 0) }
    }
}

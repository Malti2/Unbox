import AppKit
import Observation
import UniformTypeIdentifiers

struct HistoryItem: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var title: String
    var detail: String
    var success: Bool
}

enum UpdateState: Equatable {
    case idle, checking, upToDate
    case available(String)
    case working(String)
    case failed(String)
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    static let dmgType = UTType("com.apple.disk-image-udif") ?? .diskImage
    static let systemMounter = URL(fileURLWithPath: "/System/Library/CoreServices/DiskImageMounter.app")

    var isDefault = false
    var history: [HistoryItem] = []
    var updateState: UpdateState = .idle
    var message: String?
    var channel: UpdateChannel {
        didSet { UserDefaults.standard.set(channel.rawValue, forKey: "channel") }
    }
    private var pendingRelease: ReleaseInfo?

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    init() {
        channel = UpdateChannel(rawValue: UserDefaults.standard.string(forKey: "channel") ?? "") ?? .stable
        if let data = UserDefaults.standard.data(forKey: "history"),
           let items = try? JSONDecoder().decode([HistoryItem].self, from: data) { history = items }
        refreshDefault()
    }

    // MARK: Default app for disk images

    func refreshDefault() {
        let url = NSWorkspace.shared.urlForApplication(toOpen: Self.dmgType)
        isDefault = url?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    func setDefault(_ useUnbox: Bool) {
        let app = useUnbox ? Bundle.main.bundleURL : Self.systemMounter
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: Self.dmgType) { [weak self] error in
            Task { @MainActor in
                if let error { self?.message = error.localizedDescription } else { self?.message = nil }
                self?.refreshDefault()
            }
        }
    }

    // MARK: History

    func record(_ o: InstallOutcome) {
        history.insert(HistoryItem(date: Date(), title: o.title, detail: o.detail, success: o.kind == .installed), at: 0)
        history = Array(history.prefix(30))
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: "history") }
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: "history")
    }

    // MARK: Updates

    func checkForUpdates() {
        updateState = .checking
        let channel = channel, current = version
        Task {
            do {
                if let r = try await Updater.latest(channel: channel, current: current) {
                    pendingRelease = r
                    updateState = .available(r.tag_name)
                } else {
                    pendingRelease = nil
                    updateState = .upToDate
                }
            } catch { updateState = .failed(error.localizedDescription) }
        }
    }

    func installUpdate() {
        guard let release = pendingRelease else { return }
        updateState = .working("Downloading")
        Task {
            do {
                let dmg = try await Updater.download(release)
                updateState = .working("Installing")
                let result: InstallOutcome = await Task.detached {
                    let engine = InstallEngine(allowReplacingRunningApp: true, deleteImageInsteadOfTrashing: true)
                    switch engine.prepare(dmg: dmg) {
                    case .done(let o): return o
                    case .ready(let p):
                        guard p.bundleID == Bundle.main.bundleIdentifier else {
                            return engine.cancel(p).with(kind: .failed, detail: "The update does not belong to this app.")
                        }
                        return engine.commit(p)
                    }
                }.value
                guard result.kind == .installed else {
                    updateState = .failed(result.detail)
                    return
                }
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Unbox.app"), configuration: cfg) { _, _ in
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            } catch { updateState = .failed(error.localizedDescription) }
        }
    }
}

extension InstallOutcome {
    func with(kind: Kind, detail: String) -> InstallOutcome {
        var c = self; c.kind = kind; c.detail = detail; return c
    }
}

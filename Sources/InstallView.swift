import SwiftUI

@MainActor @Observable
final class InstallSession {
    enum Phase { case confirm, working(String), finished(InstallOutcome) }
    var phase: Phase = .confirm
    let prepared: PreparedInstall?
    let failure: InstallOutcome?
    var onClose: (() -> Void)?
    let engine = InstallEngine()

    init(prepared: PreparedInstall) { self.prepared = prepared; self.failure = nil; phase = .confirm }
    init(failure: InstallOutcome) { self.prepared = nil; self.failure = failure; phase = .finished(failure) }

    var isConfirming: Bool { if case .confirm = phase { return true }; return false }

    func install() {
        guard let p = prepared else { return }
        phase = .working("Copying \(p.name)")
        let engine = engine
        Task {
            let outcome = await Task.detached {
                engine.commit(p)
            }.value
            AppModel.shared.record(outcome)
            phase = .finished(outcome)
        }
    }

    func cancel() {
        guard let p = prepared, isConfirming else { close(); return }
        phase = .working("Ejecting")
        let engine = engine
        Task {
            _ = await Task.detached { engine.cancel(p) }.value
            close()
        }
    }

    func openNormally() {
        if let url = failure?.dmg ?? prepared?.dmg { InstallController.openWithSystem(url) }
        close()
    }

    func close() { let c = onClose; onClose = nil; c?() }
}

struct InstallView: View {
    var session: InstallSession

    var body: some View {
        VStack(spacing: 0) {
            switch session.phase {
            case .confirm: if let p = session.prepared { confirm(p) }
            case .working(let text): working(text)
            case .finished(let o): finished(o)
            }
        }
        .frame(width: 400)
        .padding(24)
    }

    private func confirm(_ p: PreparedInstall) -> some View {
        VStack(spacing: 16) {
            Image(nsImage: p.icon).resizable().frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text(p.displayName).font(.title2.bold())
                Text(p.version.map { "Version \($0)" } ?? "Version unknown").foregroundStyle(.secondary)
            }
            Form {
                LabeledContent("Identifier", value: p.bundleID)
                if let build = p.build { LabeledContent("Build", value: build) }
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: p.sizeBytes, countStyle: .file))
                if let min = p.minimumSystem { LabeledContent("Requires", value: "macOS \(min) or later") }
                LabeledContent("Signature", value: p.signed ? "Signed" : "Unsigned")
                LabeledContent("Install to", value: p.destination.deletingLastPathComponent().path)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: p.minimumSystem == nil ? 190 : 220)

            if let existing = p.existingVersion {
                VStack(alignment: .leading, spacing: 4) {
                    if p.existingIsRunning {
                        Label("\(p.name) is installed and running. Quit it first.", systemImage: "exclamationmark.triangle")
                    } else if p.isSameApp {
                        Label("Version \(existing ?? "unknown") is installed. Updating will replace it. The old version goes to the Trash.",
                              systemImage: "exclamationmark.triangle")
                    } else {
                        Label("A different app with this name is installed (\(p.existingBundleID ?? "unknown identifier")). Updating will replace it with this one. The existing app goes to the Trash.",
                              systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.callout).foregroundStyle(.orange)
                if p.isOlderThanInstalled {
                    Label("This is an older version than the one installed.", systemImage: "arrow.down.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
            } else if let other = p.installedElsewhere {
                Label("This app is already installed at \(other.path). Installing adds a second copy.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { session.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(p.isReplacement ? "Update" : "Install") { session.install() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(p.existingIsRunning)
            }
        }
    }

    private func working(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func finished(_ o: InstallOutcome) -> some View {
        let ok = o.kind == .installed
        return VStack(spacing: 14) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 44)).foregroundStyle(ok ? .green : .red)
            Text(ok ? "\(o.title) installed" : "Not installed").font(.title3.bold())
            Text(o.detail).multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !ok { Button("Open Image Normally") { session.openNormally() } }
                Spacer()
                if ok, let p = session.prepared {
                    Button("Open \(p.displayName)") {
                        NSWorkspace.shared.openApplication(at: p.destination, configuration: .init())
                        session.close()
                    }
                }
                Button("Done") { session.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

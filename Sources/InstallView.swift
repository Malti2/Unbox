import SwiftUI

@MainActor @Observable
final class InstallSession {
    enum Phase { case confirm, working(InstallStage), finished(InstallOutcome) }
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
        phase = .working(.copying(0))
        let engine = engine
        Task {
            let outcome = await Task.detached { [weak self] in
                engine.commit(p) { stage in
                    Task { @MainActor in self?.phase = .working(stage) }
                }
            }.value
            AppModel.shared.record(outcome)
            phase = .finished(outcome)
        }
    }

    func cancel() {
        guard let p = prepared, isConfirming else { close(); return }
        phase = .working(.ejecting)
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

    /// Window content size; the details scroll when they do not fit the screen.
    nonisolated(unsafe) static var testHeight: CGFloat?

    static func contentSize(for session: InstallSession) -> NSSize {
        if session.prepared == nil { return NSSize(width: 440, height: 280) }
        if let h = testHeight { return NSSize(width: 440, height: h) }
        return NSSize(width: 440, height: min(560, WindowPlacement.maxContentHeight()))
    }

    var body: some View {
        let size = Self.contentSize(for: session)
        Group {
            switch session.phase {
            case .confirm: if let p = session.prepared { confirm(p) }
            case .working(let stage): working(stage)
            case .finished(let o): finished(o)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func confirm(_ p: PreparedInstall) -> some View {
        VStack(spacing: 0) {
            ScrollView {
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
                        LabeledContent("Install to") {
                            Text(p.destination.deletingLastPathComponent().path)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .frame(height: CGFloat(detailRows(p)) * 37 + 44)
                }
                .padding(24)
            }
            notes(p)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { session.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(actionTitle(p)) { session.install() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(p.existingIsRunning)
            }
            .padding(16)
        }
    }

    private func detailRows(_ p: PreparedInstall) -> Int {
        4 + (p.build == nil ? 0 : 1) + (p.minimumSystem == nil ? 0 : 1)
    }

    private func actionTitle(_ p: PreparedInstall) -> String {
        if !p.isReplacement { return "Install" }
        return p.isSameVersionInstalled ? "Re-install" : "Update"
    }

    @ViewBuilder private func notes(_ p: PreparedInstall) -> some View {
        if let existing = p.existingVersion {
            VStack(alignment: .leading, spacing: 6) {
                if p.existingIsRunning {
                    Label("\(p.name) is installed and running. Quit it first.", systemImage: "exclamationmark.triangle")
                } else if p.isSameVersionInstalled {
                    Label("This version is already installed.", systemImage: "checkmark.circle")
                    Label("Re-installing will replace the installed copy. The existing copy goes to the Trash.", systemImage: "exclamationmark.triangle")
                } else if p.isSameApp {
                    Label("Version \(existing ?? "unknown") is installed. Updating will replace it. The old version goes to the Trash.",
                          systemImage: "exclamationmark.triangle")
                } else {
                    Label("A different app with this name is installed (\(p.existingBundleID ?? "unknown identifier")). Updating will replace it with this one. The existing app goes to the Trash.",
                          systemImage: "exclamationmark.triangle")
                }
                if p.isOlderThanInstalled {
                    Label("This is an older version than the one installed.", systemImage: "arrow.down.circle")
                }
            }
            .font(.callout).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let other = p.installedElsewhere {
            Label("This app is already installed at \(other.path). Installing adds a second copy.", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func working(_ stage: InstallStage) -> some View {
        VStack(spacing: 14) {
            Spacer()
            if let p = session.prepared { Image(nsImage: p.icon).resizable().frame(width: 64, height: 64) }
            switch stage {
            case .copying(let f):
                ProgressView(value: f).progressViewStyle(.linear)
                Text("Copying \(session.prepared?.displayName ?? "") \(Int((f * 100).rounded()))%").foregroundStyle(.secondary)
            case .verifying:
                ProgressView().progressViewStyle(.linear)
                Text("Verifying the copy").foregroundStyle(.secondary)
            case .replacing:
                ProgressView().progressViewStyle(.linear)
                Text("Putting it in place").foregroundStyle(.secondary)
            case .ejecting:
                ProgressView().progressViewStyle(.linear)
                Text("Ejecting the disk image").foregroundStyle(.secondary)
            case .trashing:
                ProgressView().progressViewStyle(.linear)
                Text("Moving the disk image to the Trash").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(32)
    }

    private func finished(_ o: InstallOutcome) -> some View {
        let ok = o.kind == .installed
        return VStack(spacing: 14) {
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 44)).foregroundStyle(ok ? .green : .red)
            Text(ok ? "\(o.title) installed" : "Not installed").font(.title3.bold())
            ScrollView {
                Text(o.detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 90)
            Spacer()
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
        .padding(24)
    }
}

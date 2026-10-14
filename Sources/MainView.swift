import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Disk images") {
                HStack {
                    Label(model.isDefault ? "Unbox opens disk images" : "macOS opens disk images",
                          systemImage: model.isDefault ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.isDefault ? .green : .secondary)
                    Spacer()
                    if model.isDefault {
                        Button("Use macOS Default") { model.setDefault(false) }
                    } else {
                        Button("Use Unbox") { model.setDefault(true) }.buttonStyle(.borderedProminent)
                    }
                }
                if let m = model.message { Text(m).font(.callout).foregroundStyle(.red) }
            }

            Section("Recent") {
                if model.history.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                } else {
                    ForEach(model.history.prefix(8)) { item in
                        HStack(alignment: .top) {
                            Image(systemName: item.success ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(item.success ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Clear") { model.clearHistory() }
                }
            }

            Section("Updates") {
                LabeledContent("Version", value: model.version)
                Picker("Channel", selection: $model.channel) {
                    ForEach(UpdateChannel.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.channel == .beta {
                    Text("Beta versions are not finished and may break.").font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    statusText
                    Spacer()
                    switch model.updateState {
                    case .available(let tag): Button("Install \(tag)") { model.installUpdate() }.buttonStyle(.borderedProminent)
                    case .checking, .working: ProgressView().controlSize(.small)
                    default: Button("Check for Updates") { model.checkForUpdates() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    @ViewBuilder private var statusText: some View {
        switch model.updateState {
        case .idle: EmptyView()
        case .checking: Text("Checking").foregroundStyle(.secondary)
        case .upToDate: Text("Up to date").foregroundStyle(.secondary)
        case .available(let t): Text("\(t) is available").foregroundStyle(.secondary)
        case .working(let t): Text(t).foregroundStyle(.secondary)
        case .failed(let m): Text(m).font(.callout).foregroundStyle(.red)
        }
    }
}

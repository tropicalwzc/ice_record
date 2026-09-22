import SwiftUI

struct SettingsView: View {
    @Environment(SyncCoordinator.self) private var sync

    var body: some View {
        NavigationStack {
            List {
                syncSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
        }
    }

    // MARK: - iCloud

    private var syncSection: some View {
        Section {
            if sync.isConfigured {
                Toggle(
                    "iCloud 同步",
                    isOn: Binding(
                        get: { sync.isEnabled },
                        set: { sync.setEnabled($0) }
                    )
                )
            }

            HStack(spacing: 10) {
                Image(systemName: sync.symbolName)
                    .foregroundStyle(statusTint)
                    .frame(width: 22)
                Text(sync.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if sync.status.isBusy {
                    ProgressView()
                }
            }

            Button {
                Task { await sync.syncNow() }
            } label: {
                Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!sync.isEnabled || sync.status.isBusy)

            if let warning = sync.lastWarningMessage {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if let error = sync.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            DisclosureGroup("同步诊断") {
                Text(sync.diagnostics.descriptionText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .padding(.vertical, 4)

                Button("重置同步状态", role: .destructive) {
                    sync.resetSyncState()
                }
                .font(.footnote)

                Text("重置只会清掉本机的增量游标和订阅标记，不会动本地数据，也不会删云端数据。下次同步会重新建 zone 并做一次全量拉取。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        } header: {
            Text("iCloud")
        } footer: {
            if sync.isConfigured {
                Text("同一个 Apple 账号下的设备会自动看到相同的资产和每日快照。改动后几秒内自动上传；如果两台设备改了同一条，以最后修改的那台为准。")
            } else {
                Text("这个版本没有配置 iCloud 容器，所有数据只保存在本机。")
            }
        }
    }

    private var statusTint: Color {
        switch sync.status {
        case .idle: .green
        case .syncing: .accentColor
        case .unavailable: .secondary
        case .failed: .orange
        case .disabled: .secondary
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("名称", value: "记账本")
            LabeledContent("版本") {
                Text(Bundle.main.appDisplayVersion)
                    .monospacedDigit()
            }
        }
    }
}

private extension Bundle {
    var appDisplayVersion: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(
            SyncCoordinator(database: .shared, transport: DisabledSyncTransport())
        )
}

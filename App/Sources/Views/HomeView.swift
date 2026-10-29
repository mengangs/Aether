import AetherControl
import AetherIPC
import SwiftUI

/// 首页（docs/12 §4）。M0：连接开关、连接时长、隧道状态与错误提示。
struct HomeView: View {
    let model: AppModel
    let controller: any TunnelControlling

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ConnectionCard(state: controller.state) {
                        Task { await model.toggle() }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if let error = controller.lastError {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(error.message)
                                if let code = error.code {
                                    Text(code).font(.footnote.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        if error.suggestsReinstall || controller.state == .invalid {
                            Button("重新安装 VPN 配置") {
                                Task { await controller.reinstall() }
                            }
                        }
                    }
                } else if controller.state == .invalid {
                    Section {
                        Button("重新安装 VPN 配置") {
                            Task { await controller.reinstall() }
                        }
                    }
                }

                if controller.onDemandPaused {
                    Section {
                        Label("按需连接已暂停", systemImage: "pause.circle")
                    }
                }

                Section("隧道") {
                    LabeledContent("状态", value: tunnelStateText)
                    if let status = model.tunnelStatus {
                        LabeledContent("进入该状态") {
                            Text(status.since, style: .relative)
                        }
                    }
                    if let error = model.statusError {
                        LabeledContent("通信错误", value: error.code.rawValue)
                    }
                }

                Section {
                    Text("当前版本为工程骨架：隧道只接管 198.18.0.0/15，不修改 DNS，不影响正常上网。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Aether")
        }
    }

    private var tunnelStateText: String {
        guard let status = model.tunnelStatus else { return "—" }
        return status.state.rawValue
    }
}

/// 连接开关与连接时长。
struct ConnectionCard: View {
    let state: TunnelConnectionState
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Button(action: toggle) {
                Image(systemName: "power")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 112, height: 112)
                    .background(Circle().fill(state.isActive ? Color.accentColor : Color.gray))
            }
            .buttonStyle(.plain)
            .disabled(state == .loading || state == .disconnecting)
            .accessibilityLabel(state.isActive ? Text("断开") : Text("连接"))

            Text(stateText).font(.headline)

            if case .connected(let since?) = state {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.duration(from: since, to: context.date))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var stateText: LocalizedStringKey {
        switch state {
        case .loading: return "正在读取配置…"
        case .notInstalled: return "未安装 VPN 配置"
        case .disconnected: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .reasserting: return "重新连接中…"
        case .disconnecting: return "断开中…"
        case .invalid: return "VPN 配置无效"
        }
    }

    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

#Preview("未连接") {
    let controller = MockTunnelController(state: .disconnected)
    HomeView(model: AppModel(controller: controller, client: MockTunnelClient.notRunning), controller: controller)
}

#Preview("已连接") {
    let controller = MockTunnelController(state: .connected(since: Date().addingTimeInterval(-3725)))
    HomeView(model: AppModel(controller: controller, client: MockTunnelClient.running), controller: controller)
}

#Preview("未安装（空状态）") {
    let controller = MockTunnelController(state: .notInstalled)
    HomeView(model: AppModel(controller: controller, client: MockTunnelClient.notRunning), controller: controller)
}

#Preview("错误") {
    let controller = MockTunnelController(
        state: .disconnected,
        lastError: TunnelControlError(message: "无法保存 VPN 配置。可能拒绝了「添加 VPN 配置」的授权，请重新安装 VPN 配置后允许。", suggestsReinstall: true)
    )
    HomeView(model: AppModel(controller: controller, client: MockTunnelClient.notRunning), controller: controller)
}

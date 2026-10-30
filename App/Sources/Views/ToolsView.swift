import AetherControl
import AetherIPC
import SwiftUI

/// 工具页（docs/12 §8）。M2 只有诊断；其余条目随后续里程碑加入。
struct ToolsView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    DiagnosticsView(model: model)
                } label: {
                    Label("诊断", systemImage: "stethoscope")
                }
            }
            .navigationTitle("工具")
        }
    }
}

/// 诊断（docs/12 §8）：隧道内存（footprint、剩余额度、组件估算）、hev 统计、网络快照、版本信息。
struct DiagnosticsView: View {
    let model: AppModel

    @State private var memory: MemoryInfo?
    @State private var error: IPCError?

    private var systemDNS: String {
        guard let servers = memory?.systemDNSServers, !servers.isEmpty else { return "—" }
        return servers.joined(separator: ", ")
    }

    var body: some View {
        List {
            Section("版本") {
                LabeledContent("App", value: ProfileStore.appVersion)
            }
            if model.isConnected {
                if let error {
                    Section { ErrorRow(error) }
                }
                if let memory {
                    Section("隧道内存") {
                        LabeledContent("Footprint", value: memory.footprintBytes.map { Formatting.bytes($0) } ?? "—")
                        LabeledContent("剩余额度", value: memory.availableBytes.map { Formatting.bytes($0) } ?? "—")
                        ForEach(memory.components.sorted { $0.key < $1.key }, id: \.key) { item in
                            LabeledContent(item.key, value: String(item.value))
                        }
                    }
                    if let hev = memory.hev {
                        Section("hev") {
                            LabeledContent("发送", value: "\(hev.txPackets) 包 · \(Formatting.bytes(hev.txBytes))")
                            LabeledContent("接收", value: "\(hev.rxPackets) 包 · \(Formatting.bytes(hev.rxBytes))")
                        }
                    }
                }
                if let status = model.tunnelStatus {
                    Section("网络") {
                        LabeledContent("接口", value: status.network.interfaceType ?? "—")
                        LabeledContent("SSID", value: status.network.ssid ?? "—")
                        LabeledContent("修订号", value: String(status.network.revision))
                        LabeledContent("系统 DNS", value: systemDNS)
                    }
                }
            } else {
                Section {
                    Text("连接后显示隧道内存、hev 统计与网络快照。").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("诊断")
        .task(id: model.isConnected) {
            guard model.isConnected else { return }
            while !Task.isCancelled {
                do {
                    memory = try await model.client?.memoryInfo()
                    error = nil
                } catch {
                    self.error = IPCError(error)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

#Preview("诊断") {
    let controller = MockTunnelController(state: .connected(since: Date()))
    NavigationStack {
        DiagnosticsView(model: AppModel(controller: controller, client: MockTunnelClient.running))
    }
}

#Preview("未连接") {
    let controller = MockTunnelController(state: .disconnected)
    NavigationStack {
        DiagnosticsView(model: AppModel(controller: controller, client: MockTunnelClient.notRunning))
    }
}

#Preview("错误") {
    let controller = MockTunnelController(state: .connected(since: Date()))
    NavigationStack {
        DiagnosticsView(model: AppModel(controller: controller, client: MockTunnelClient.failing()))
    }
}

#Preview("工具") {
    let controller = MockTunnelController(state: .connected(since: Date()))
    ToolsView(model: AppModel(controller: controller, client: MockTunnelClient.running))
}

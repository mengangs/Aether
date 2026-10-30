import AetherControl
import AetherIPC
import Charts
import SwiftUI

/// 首页（docs/12 §4）：连接卡片、当前配置、出站模式、流量、常用策略组、提醒。隧道运行时以 1 Hz 刷新。
struct HomeView: View {
    let model: AppModel
    let controller: any TunnelControlling

    @State private var traffic: TrafficReport?
    @State private var actionError: IPCError?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ConnectionCard(state: controller.state) {
                        Task { await model.toggle() }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    if let profile = model.profiles?.currentProfile {
                        LabeledContent("配置", value: profile.name)
                    } else {
                        Label("还没有配置，请在「配置」中导入。", systemImage: "doc.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                }

                controlErrorSection

                if model.isConnected, let status = model.tunnelStatus {
                    OutboundModeSection(status: status, groups: status.primaryGroups.map(\.name)) { mode, global in
                        await apply(mode: mode, global: global)
                    }
                    TrafficSection(status: status, samples: traffic?.samples ?? [])
                    if !status.primaryGroups.isEmpty {
                        Section("常用策略组") {
                            ForEach(status.primaryGroups, id: \.name) { group in
                                LabeledContent(group.name, value: group.current ?? "—")
                            }
                        }
                    }
                    if !status.alerts.isEmpty {
                        Section("提醒") {
                            ForEach(status.alerts, id: \.code) { alert in
                                ErrorRow(message: "隧道报告了一个问题。", code: alert.code.rawValue)
                            }
                        }
                    }
                }

                if let error = model.statusError ?? actionError {
                    Section { ErrorRow(error) }
                }
            }
            .navigationTitle("Aether")
            .task(id: model.isConnected) {
                guard model.isConnected else { return }
                while !Task.isCancelled {
                    traffic = try? await model.client?.traffic()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    @ViewBuilder
    private var controlErrorSection: some View {
        if let error = controller.lastError {
            Section {
                ErrorRow(message: error.message, code: error.code)
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
    }

    private func apply(mode: OutboundMode, global: String?) async {
        guard let client = model.client else { return }
        do {
            try await client.setOutboundMode(mode)
            if let global {
                try await client.setGlobalPolicy(global)
            }
            actionError = nil
        } catch {
            actionError = IPCError(error)
        }
    }
}

/// 出站模式：规则 / 全局 / 直连；全局时选择全局策略（docs/12 §4 第 2 项）。
struct OutboundModeSection: View {
    let status: TunnelStatus
    let groups: [String]
    let apply: (OutboundMode, String?) async -> Void

    @State private var mode: OutboundMode = .rule
    @State private var global = ""

    var body: some View {
        Section("出站模式") {
            Picker("出站模式", selection: $mode) {
                Text("规则").tag(OutboundMode.rule)
                Text("全局").tag(OutboundMode.global)
                Text("直连").tag(OutboundMode.direct)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if mode == .global, !groups.isEmpty {
                Picker("全局策略", selection: $global) {
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
            }
        }
        .onAppear {
            mode = status.outboundMode
            global = status.globalPolicy ?? groups.first ?? ""
        }
        .onChange(of: mode) { _, newMode in
            Task { await apply(newMode, newMode == .global && !global.isEmpty ? global : nil) }
        }
        .onChange(of: global) { _, newGlobal in
            guard mode == .global, !newGlobal.isEmpty else { return }
            Task { await apply(.global, newGlobal) }
        }
    }
}

/// 流量：当前速率、最近 2 分钟曲线、本次连接累计（docs/12 §4 第 3 项）。
struct TrafficSection: View {
    let status: TunnelStatus
    let samples: [TrafficReport.Sample]

    var body: some View {
        Section("流量") {
            HStack {
                Label(Formatting.rate(status.traffic.upBps), systemImage: "arrow.up")
                Spacer()
                Label(Formatting.rate(status.traffic.downBps), systemImage: "arrow.down")
            }
            .font(.headline.monospacedDigit())
            if !samples.isEmpty {
                Chart {
                    ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                        LineMark(x: .value("秒", index), y: .value("下行", Double(sample.down)))
                            .foregroundStyle(by: .value("方向", "下行"))
                        LineMark(x: .value("秒", index), y: .value("上行", Double(sample.up)))
                            .foregroundStyle(by: .value("方向", "上行"))
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 80)
                .accessibilityLabel("最近 2 分钟的速率曲线")
            }
            LabeledContent("本次上传", value: Formatting.bytes(status.traffic.sessionUpBytes))
            LabeledContent("本次下载", value: Formatting.bytes(status.traffic.sessionDownBytes))
        }
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
            .sensoryFeedback(.impact(weight: .light), trigger: state.isActive)
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

#Preview("已连接") {
    let controller = MockTunnelController(state: .connected(since: Date().addingTimeInterval(-3725)))
    HomeView(
        model: AppModel(controller: controller, client: MockTunnelClient.running, profiles: .preview(seeded: true)),
        controller: controller)
}

#Preview("未连接") {
    let controller = MockTunnelController(state: .disconnected)
    HomeView(
        model: AppModel(controller: controller, client: MockTunnelClient.notRunning, profiles: .preview(seeded: true)),
        controller: controller)
}

#Preview("未安装（空状态）") {
    let controller = MockTunnelController(state: .notInstalled)
    HomeView(
        model: AppModel(controller: controller, client: MockTunnelClient.notRunning, profiles: .preview(seeded: false)),
        controller: controller)
}

#Preview("错误") {
    let controller = MockTunnelController(
        state: .disconnected,
        lastError: TunnelControlError(
            message: "无法保存 VPN 配置。可能拒绝了「添加 VPN 配置」的授权，请重新安装 VPN 配置后允许。", suggestsReinstall: true)
    )
    HomeView(
        model: AppModel(controller: controller, client: MockTunnelClient.failing(), profiles: .preview(seeded: true)),
        controller: controller)
}

import AetherControl
import AetherIPC
import SwiftUI

/// 策略页（docs/12 §5）：按配置顺序列出策略组与节点；`select` 组点击成员即选择。M2 没有测速（M3）。
struct PoliciesView: View {
    let model: AppModel

    @State private var list: PolicyList?
    @State private var error: IPCError?
    @State private var showHidden = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("策略")
                .toolbar {
                    Toggle(isOn: $showHidden) {
                        Label("显示隐藏组", systemImage: "eye")
                    }
                }
                .task(id: model.isConnected) { await load() }
                .refreshable { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isConnected {
            NotConnectedView { Task { await model.toggle() } }
        } else if let error {
            List { ErrorRow(error) }
        } else if let list {
            if list.groups.isEmpty && list.nodes.isEmpty {
                ContentUnavailableView(
                    "没有策略组", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("当前配置中没有策略组与节点。可以在「配置」中导入或切换配置。"))
            } else {
                PolicyListView(list: list, showHidden: showHidden) { group, member in
                    await select(group: group, member: member)
                }
            }
        } else {
            ProgressView()
        }
    }

    private func load() async {
        guard model.isConnected, let client = model.client else { return }
        do {
            list = try await client.policies()
            error = nil
        } catch {
            self.error = IPCError(error)
        }
    }

    private func select(group: String, member: String) async {
        guard let client = model.client else { return }
        do {
            try await client.selectPolicy(group: group, policy: member)
            await load()
        } catch {
            self.error = IPCError(error)
        }
    }
}

/// 策略组与节点列表。
struct PolicyListView: View {
    let list: PolicyList
    let showHidden: Bool
    let select: (String, String) async -> Void

    var body: some View {
        List {
            ForEach(list.groups.filter { showHidden || !$0.hidden }, id: \.name) { group in
                Section {
                    ForEach(group.members, id: \.self) { member in
                        Button {
                            guard group.type == "select" else { return }
                            Task { await select(group.name, member) }
                        } label: {
                            HStack {
                                Text(member)
                                Spacer()
                                if member == group.selected {
                                    if group.type == "select" {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    } else {
                                        Text("自动").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(member == group.selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
                    }
                } header: {
                    HStack {
                        Text(group.name)
                        Text(GroupTypeLabel.text(group.type))
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .background(Capsule().fill(.quaternary))
                    }
                } footer: {
                    if let note = group.note {
                        Text(note)
                    }
                }
            }
            if !list.nodes.isEmpty {
                Section("节点") {
                    ForEach(list.nodes, id: \.name) { node in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(node.name)
                                Spacer()
                                Text(node.type).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if node.supportsUDP {
                                    Text("UDP").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let reason = node.unavailableReason {
                                Text(reason).font(.footnote).foregroundStyle(.orange)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

#Preview("策略组") {
    let controller = MockTunnelController(state: .connected(since: Date()))
    PoliciesView(model: AppModel(controller: controller, client: MockTunnelClient.running))
}

#Preview("空状态") {
    let controller = MockTunnelController(state: .connected(since: Date()))
    PoliciesView(model: AppModel(controller: controller, client: MockTunnelClient.empty))
}

#Preview("未连接") {
    let controller = MockTunnelController(state: .disconnected)
    PoliciesView(model: AppModel(controller: controller, client: MockTunnelClient.notRunning))
}

#Preview("错误") {
    let controller = MockTunnelController(state: .connected(since: Date()))
    PoliciesView(model: AppModel(controller: controller, client: MockTunnelClient.failing()))
}

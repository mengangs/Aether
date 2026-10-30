import AetherControl
import AetherIPC
import SwiftUI
import UIKit

/// 请求页（docs/12 §6）：最近 / 活跃请求，可见时以 1 Hz 增量拉取；点击进入基础详情。
struct RequestsView: View {
    let model: AppModel

    @State private var kind: RequestListKind = .recent
    @State private var records: [RequestRecord] = []
    @State private var error: IPCError?
    @State private var search = ""

    /// 列表中保留的记录上限（与隧道的环形缓冲上限一致），超出时丢弃最旧的。
    static let displayLimit = 2000

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("请求")
                .searchable(text: $search, prompt: "主机或目标")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("种类", selection: $kind) {
                            Text("最近").tag(RequestListKind.recent)
                            Text("活跃").tag(RequestListKind.active)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 200)
                    }
                }
                .task(id: "\(model.isConnected)-\(kind.rawValue)") { await poll() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isConnected {
            NotConnectedView { Task { await model.toggle() } }
        } else if let error {
            List { ErrorRow(error) }
        } else if filtered.isEmpty {
            ContentUnavailableView(
                search.isEmpty ? "还没有请求" : "没有匹配的请求", systemImage: "list.bullet.rectangle",
                description: Text(search.isEmpty ? "有流量经过隧道后会显示在这里。" : "换一个关键词试试。"))
        } else {
            List(filtered.reversed(), id: \.id) { record in
                NavigationLink {
                    RequestDetailView(record: record)
                } label: {
                    RequestRow(record: record)
                }
            }
        }
    }

    private var filtered: [RequestRecord] {
        guard !search.isEmpty else { return records }
        return records.filter {
            ($0.host ?? "").localizedCaseInsensitiveContains(search) || $0.destination.contains(search)
        }
    }

    /// 最近：按游标增量追加；活跃：每次整页替换。
    private func poll() async {
        records = []
        error = nil
        var cursor: UInt64?
        while !Task.isCancelled, model.isConnected, let client = model.client {
            do {
                let page = try await client.requests(
                    kind: kind, sinceID: kind == .recent ? cursor : nil, limit: IPCProtocol.maxPageSize)
                if kind == .recent {
                    records.append(contentsOf: page.records)
                    if records.count > Self.displayLimit {
                        records.removeFirst(records.count - Self.displayLimit)
                    }
                    cursor = page.next ?? cursor
                } else {
                    records = page.records
                }
                error = nil
            } catch {
                self.error = IPCError(error)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// 请求行：主机（或目标）、协议徽标、最终节点、命中规则、字节数、状态（docs/12 §6.1）。
struct RequestRow: View {
    let record: RequestRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(record.host ?? record.destination).lineLimit(1)
                Spacer()
                Text(protocolBadge).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                Text(record.policyChain.last ?? "—")
                if let rule = record.rule {
                    Text(rule.raw).lineLimit(1)
                }
                Spacer()
                Text("↑\(Formatting.bytes(record.bytesUp)) ↓\(Formatting.bytes(record.bytesDown))")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var protocolBadge: String {
        switch record.appProtocol {
        case .https: return "HTTPS"
        case .http: return record.method ?? "HTTP"
        case .quic: return "QUIC"
        case .unknown: return record.transport.rawValue.uppercased()
        }
    }

    private var icon: String {
        switch record.state {
        case .active: return "circle.dotted"
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        }
    }

    private var color: Color {
        switch record.state {
        case .active: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
}

/// 请求详情（docs/12 §6.2，M2 为基础字段）：概览、路由、数据、备注。
struct RequestDetailView: View {
    let record: RequestRecord

    var body: some View {
        List {
            Section("概览") {
                LabeledContent("目标", value: record.url ?? record.destination)
                if let host = record.host {
                    LabeledContent("主机", value: host)
                }
                LabeledContent("主机来源", value: hostSource)
                LabeledContent("入站", value: inbound)
                if let remote = record.remoteAddress {
                    LabeledContent("实际连接", value: remote)
                }
                LabeledContent("传输", value: record.transport.rawValue.uppercased())
                if let method = record.method {
                    LabeledContent("方法", value: method)
                }
                if let status = record.statusCode {
                    LabeledContent("状态码", value: String(status))
                }
                LabeledContent("连接耗时", value: Formatting.milliseconds(record.timings.connect))
                LabeledContent("首字节", value: Formatting.milliseconds(record.timings.firstByte))
                if let error = record.errorCode {
                    LabeledContent("错误", value: error)
                }
            }
            Section("路由") {
                if let rule = record.rule {
                    LabeledContent("规则", value: rule.raw)
                    LabeledContent("来源", value: "\(rule.file):\(rule.line)")
                }
                LabeledContent("策略链", value: record.policyChain.joined(separator: " → "))
            }
            Section("数据") {
                LabeledContent("上行", value: Formatting.bytes(record.bytesUp))
                LabeledContent("下行", value: Formatting.bytes(record.bytesDown))
            }
            if !record.notes.isEmpty {
                Section("备注") {
                    ForEach(Array(record.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                    }
                }
            }
        }
        .navigationTitle(record.host ?? record.destination)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = record.url {
                Button {
                    UIPasteboard.general.string = url
                } label: {
                    Label("复制 URL", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var inbound: String {
        switch record.inbound {
        case .tun: return "TUN"
        case .httpProxy: return "HTTP 代理"
        case .socks: return "SOCKS5"
        case .script(let name): return "脚本 \(name)"
        }
    }

    private var hostSource: String {
        switch record.hostSource {
        case .request: return "请求"
        case .fakeIP: return "Fake IP"
        case .dnsReverse: return "反查"
        case .sniffed: return "嗅探"
        case .none: return "—"
        }
    }
}

#Preview("请求列表") {
    let controller = MockTunnelController(state: .connected(since: Date()))
    RequestsView(model: AppModel(controller: controller, client: MockTunnelClient.running))
}

#Preview("空状态") {
    let controller = MockTunnelController(state: .connected(since: Date()))
    RequestsView(model: AppModel(controller: controller, client: MockTunnelClient.empty))
}

#Preview("错误") {
    let controller = MockTunnelController(state: .connected(since: Date()))
    RequestsView(model: AppModel(controller: controller, client: MockTunnelClient.failing()))
}

#Preview("详情") {
    NavigationStack {
        RequestDetailView(record: MockTunnelClient.Fixtures.sample.requests[0])
    }
}

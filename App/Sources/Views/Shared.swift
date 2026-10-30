import AetherIPC
import SwiftUI

/// 依赖隧道的页面在隧道未连接时的占位（docs/12 §11）。
struct NotConnectedView: View {
    var connect: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label("未连接", systemImage: "bolt.horizontal.circle")
        } description: {
            Text("连接后显示实时数据。")
        } actions: {
            if let connect {
                Button("连接", action: connect)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// 错误说明：人能看懂的原因，错误码以小字附在后面（docs/12 §1）。
struct ErrorRow: View {
    let message: String
    var code: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                if let code {
                    Text(code).font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .accessibilityElement(children: .combine)
    }
}

extension ErrorRow {
    init(_ error: IPCError) {
        self.init(message: Self.text(for: error), code: error.code.rawValue)
    }

    /// 按错误码给出文案；未知码用通用文案（docs/12 §11）。
    static func text(for error: IPCError) -> String {
        switch error.code.rawValue {
        case "IPC-001": return "隧道未运行。"
        case "IPC-002": return "App 与隧道版本不一致，请重新连接。"
        case "IPC-004": return "隧道没有及时响应。"
        case "IPC-010": return "还没有可用的配置，请先导入配置。"
        case "IPC-011": return "参数无效。"
        case "IPC-012": return "隧道当前状态不允许该操作。"
        default: return "操作失败。"
        }
    }
}

/// 字节数与速率的显示。
enum Formatting {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    static func rate(_ bytesPerSecond: Int64) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    static func milliseconds(_ value: Int?) -> String {
        value.map { "\($0) ms" } ?? "—"
    }
}

/// 策略组类型的中文标签（docs/12 §5）。
enum GroupTypeLabel {
    static func text(_ type: String) -> String {
        switch type {
        case "select": return "手动"
        case "url-test": return "自动测速"
        case "fallback": return "故障转移"
        case "load-balance": return "负载均衡"
        default: return type
        }
    }
}

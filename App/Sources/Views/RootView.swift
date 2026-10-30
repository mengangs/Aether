import AetherControl
import SwiftUI

/// 根视图：运行环境可用时显示五个标签（docs/12 §2），否则显示错误页。
struct RootView: View {
    let model: AppModel

    var body: some View {
        if let failure = model.failure {
            StartupErrorView(failure: failure)
        } else if let controller = model.controller {
            TabView {
                HomeView(model: model, controller: controller)
                    .tabItem { Label("首页", systemImage: "circle.hexagongrid") }
                PoliciesView(model: model)
                    .tabItem { Label("策略", systemImage: "point.3.connected.trianglepath.dotted") }
                RequestsView(model: model)
                    .tabItem { Label("请求", systemImage: "list.bullet.rectangle") }
                ProfilesView(model: model)
                    .tabItem { Label("配置", systemImage: "doc.text") }
                ToolsView(model: model)
                    .tabItem { Label("工具", systemImage: "wrench.and.screwdriver") }
            }
        }
    }
}

/// 启动失败页：给出错误码与排查方法（docs/03 §8.4、docs/11 §9）。
struct StartupErrorView: View {
    let failure: AppModel.StartupFailure

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text(hint)
                Text("\(failure.code) · \(failure.message)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var title: LocalizedStringKey {
        failure.code == "STO-001" ? "App Group 不可用" : "运行环境无效"
    }

    private var hint: LocalizedStringKey {
        if failure.code == "STO-001" {
            return "签名时使用的描述文件需要包含与 identifiers.txt 一致的 App Group，并为 App 与隧道扩展分别使用对应的 entitlements 文件。"
        }
        return "Info.plist 中缺少或包含无效的标识符。请用 release 工作流重新构建，并检查仓库变量。"
    }
}

#Preview("五个标签") {
    let controller = MockTunnelController(state: .connected(since: Date().addingTimeInterval(-600)))
    RootView(model: AppModel(controller: controller, client: MockTunnelClient.running, profiles: .preview(seeded: true)))
}

#Preview("App Group 不可用") {
    StartupErrorView(failure: .init(code: "STO-001", message: "App Group container group.com.example.aether is unavailable"))
}

#Preview("运行环境无效") {
    StartupErrorView(failure: .init(code: "IPC-020", message: "Info.plist is missing AetherAppGroupIdentifier"))
}

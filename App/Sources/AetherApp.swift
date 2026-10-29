import SwiftUI

/// Aether App 入口（docs/12）。启动时读取运行环境；失败时显示错误页，不崩溃（docs/03 §8.4）。
@main
struct AetherApp: App {
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    model.setForeground(phase == .active)
                }
        }
    }
}

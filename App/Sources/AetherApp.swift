import SwiftUI

/// Aether App 入口。界面结构见 docs/12-ui.md；M0-07 起由 AppModel 驱动首页。
@main
struct AetherApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}

/// M0-04 的占位界面，M0-07 替换为首页。
struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Aether")
                .font(.largeTitle.bold())
        }
        .padding()
    }
}

#Preview {
    PlaceholderView()
}

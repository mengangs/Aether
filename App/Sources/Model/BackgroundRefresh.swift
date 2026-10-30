import AetherFoundation
import BackgroundTasks
import Foundation

/// 外部资源的后台刷新（docs/11 §5.4）：`BGAppRefreshTask`，最早执行时间为最近的到期时间，每次最多处理 30 秒，
/// 处理完再按新的到期时间排下一次。标识符来自 `AppEnvironment.resourceRefreshTaskIdentifier`。
@MainActor
enum BackgroundRefresh {
    private static var registered = false

    /// 必须在 App 完成启动前调用（`AppModel.live()`）；重复调用无效果。
    static func register(identifier: String, model: AppModel) {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                handle(task, identifier: identifier, model: model)
            }
        }
    }

    /// 按最近的到期时间提交下一次后台刷新；没有远程资源时取消。
    static func schedule(identifier: String, resources: ResourceRefresher) async {
        guard let date = await resources.nextRefreshDate() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = date
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // 模拟器与关闭了后台刷新的设备上提交会失败；回到前台时仍会检查到期资源。
            Logger(label: "AetherApp").notice("Background refresh not scheduled", metadata: ["error": "\(error)"])
        }
    }

    private static func handle(_ task: BGTask, identifier: String, model: AppModel) {
        guard let resources = model.resources else {
            task.setTaskCompleted(success: true)
            return
        }
        let client = model.client
        let work = Task {
            await resources.update(
                resources.activeRequests(), force: false, client: client,
                timeLimit: ResourceRefresher.backgroundTimeLimit)
        }
        task.expirationHandler = { work.cancel() }
        Task {
            let completed = await work.value
            await schedule(identifier: identifier, resources: resources)
            task.setTaskCompleted(success: completed)
        }
    }
}

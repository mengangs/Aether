import AetherControl
import AetherIPC
import AetherProfile
import SwiftUI
import UniformTypeIdentifiers

/// 配置页（docs/12 §7.1，M2）：配置列表、切换（提交运行包，隧道运行时重载）、从 URL / 文件导入、删除。
struct ProfilesView: View {
    let model: AppModel

    @State private var review: ProfileStore.ImportReview?
    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var pendingDeletion: ProfileEntry?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("配置")
                .toolbar {
                    Menu {
                        Button("从 URL 导入", systemImage: "link") { showURLPrompt = true }
                        Button("从文件导入", systemImage: "doc") { showFileImporter = true }
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                }
                .alert("从 URL 导入", isPresented: $showURLPrompt) {
                    TextField("https://", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button("下载") { Task { await download() } }
                    Button("取消", role: .cancel) {}
                }
                .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.plainText, .data]) { result in
                    readFile(result)
                }
                .sheet(item: $review) { review in
                    ImportReviewView(review: review) {
                        Task {
                            await model.profiles?.confirm(review, client: model.client)
                            self.review = nil
                        }
                    }
                }
                .confirmationDialog(
                    "删除配置？",
                    isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                    presenting: pendingDeletion
                ) { entry in
                    Button("删除「\(entry.name)」", role: .destructive) {
                        model.profiles?.delete(entry)
                        pendingDeletion = nil
                    }
                    Button("取消", role: .cancel) { pendingDeletion = nil }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let store = model.profiles {
            if store.entries.isEmpty {
                ContentUnavailableView {
                    Label("还没有配置", systemImage: "doc.text")
                } description: {
                    Text("从 URL 或文件导入一份配置。")
                } actions: {
                    Button("从 URL 导入") { showURLPrompt = true }
                        .buttonStyle(.borderedProminent)
                    Button("从文件导入") { showFileImporter = true }
                }
            } else {
                List {
                    if let message = importError ?? store.lastError {
                        Section { ErrorRow(message: message) }
                    }
                    Section {
                        ForEach(store.entries) { entry in
                            Button {
                                Task { await store.activate(entry, client: model.isConnected ? model.client : nil) }
                            } label: {
                                ProfileRow(entry: entry, isCurrent: entry.id == store.currentProfileID)
                            }
                            .foregroundStyle(.primary)
                            .swipeActions {
                                if entry.id != store.currentProfileID {
                                    Button("删除", role: .destructive) { pendingDeletion = entry }
                                }
                            }
                        }
                    } footer: {
                        Text("点击切换配置；隧道运行时立即重载。")
                    }
                }
            }
        } else {
            ContentUnavailableView("配置不可用", systemImage: "exclamationmark.triangle")
        }
    }

    private func download() async {
        guard let store = model.profiles else { return }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true
        else {
            importError = "URL 无效"
            return
        }
        do {
            review = try await store.review(url: url)
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }

    private func readFile(_ result: Result<URL, any Error>) {
        guard let store = model.profiles else { return }
        do {
            review = try store.review(file: try result.get())
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// 配置行：名称、来源标签、更新时间、当前配置勾选。
struct ProfileRow: View {
    let entry: ProfileEntry
    let isCurrent: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                HStack(spacing: 6) {
                    Text(sourceLabel)
                    Text(entry.updatedAt, style: .date)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    .accessibilityLabel("当前配置")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var sourceLabel: String {
        switch entry.source {
        case .local: return "本地"
        case .managed: return "托管"
        case .imported: return "导入"
        }
    }
}

/// 导入确认页：来源、内容预览、诊断摘要、将下载的外部资源（docs/12 §7.1）。
struct ImportReviewView: View {
    let review: ProfileStore.ImportReview
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("来源") {
                    LabeledContent("名称", value: review.name)
                    LabeledContent("来源", value: sourceText)
                }
                Section("诊断") {
                    if review.diagnostics.isEmpty {
                        Label("没有问题", systemImage: "checkmark.seal")
                    } else {
                        LabeledContent("错误", value: String(review.errorCount))
                        LabeledContent("警告", value: String(review.warningCount))
                        ForEach(Array(review.diagnostics.prefix(20).enumerated()), id: \.offset) { _, diagnostic in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(diagnostic.message).font(.footnote)
                                Text("\(diagnostic.code.rawValue) · 第 \(diagnostic.line.map { String($0) } ?? "—") 行")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(diagnostic.severity == .error ? Color.red : Color.secondary)
                            }
                        }
                    }
                }
                if !review.resources.isEmpty {
                    Section("将下载的外部资源") {
                        ForEach(review.resources, id: \.self) { Text($0).font(.footnote.monospaced()) }
                    }
                }
                Section("预览") {
                    Text(review.text.prefix(2000))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("导入配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入", action: confirm).disabled(!review.canImport)
                }
            }
        }
    }

    private var sourceText: String {
        switch review.source {
        case .local: return "文件"
        case .managed(let url, _, _), .imported(let url): return ProfileStore.redactQuery(url)
        }
    }
}

#Preview("配置列表") {
    let controller = MockTunnelController(state: .connected(since: Date()))
    ProfilesView(model: AppModel(controller: controller, client: MockTunnelClient.running, profiles: .preview(seeded: true)))
}

#Preview("空状态") {
    let controller = MockTunnelController(state: .disconnected)
    ProfilesView(model: AppModel(controller: controller, client: MockTunnelClient.notRunning, profiles: .preview(seeded: false)))
}

#Preview("导入确认（有错误）") {
    let store = ProfileStore.preview(seeded: false)
    ImportReviewView(
        review: store.review(name: "Broken", text: "[Rule]\nFINAL,Missing\n", source: .imported(url: "https://example.com/a?token=x")),
        confirm: {})
}

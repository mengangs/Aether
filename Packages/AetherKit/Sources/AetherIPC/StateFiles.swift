import AetherFoundation
import Foundation

/// `State/runtime.json`（docs/11 §3.2）：出站模式、全局策略、功能开关。隧道运行时由隧道写，否则由 App 写。
public struct RuntimeStateFile: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var outboundMode: OutboundMode
    public var globalPolicy: String?
    public var features: FeatureFlags

    public init(
        outboundMode: OutboundMode = .rule, globalPolicy: String? = nil, features: FeatureFlags = FeatureFlags()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.outboundMode = outboundMode
        self.globalPolicy = globalPolicy
        self.features = features
    }
}

/// `State/selections.json`（docs/11 §3.2）：配置 ID → 组名 → 选择的成员。
public struct SelectionsFile: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    /// 最多保存的配置数；超出时丢弃（按配置 ID 排序后的）多余条目，避免文件无限增长。
    public static let profileLimit = 64

    public var schemaVersion: Int
    public var selections: [String: [String: String]]

    public init(selections: [String: [String: String]] = [:]) {
        schemaVersion = Self.currentSchemaVersion
        self.selections = selections
    }

    /// 写入一个配置的选择，超出上限时保留当前配置并丢弃其它配置中排序靠后的。
    public mutating func set(_ value: [String: String], for profileID: String) {
        selections[profileID] = value
        if selections.count > Self.profileLimit {
            let keep = Set(
                [profileID] + selections.keys.filter { $0 != profileID }.sorted().prefix(Self.profileLimit - 1))
            selections = selections.filter { keep.contains($0.key) }
        }
    }
}

/// App Group 中 JSON 状态文件的读写（docs/11 §3）：原子替换；读到更高的 `schemaVersion` 时尽力解析（忽略未知字段）。
public enum JSONStateFile {
    /// 读取；文件不存在或无法解析时为 nil。
    public static func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// 原子写入（先写临时文件再替换），父目录不存在时创建。
    public static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

extension SharedContainer {
    /// `State/runtime.json`。
    public var runtimeStateFile: URL { state.appendingPathComponent("runtime.json") }
    /// `State/selections.json`。
    public var selectionsFile: URL { state.appendingPathComponent("selections.json") }
    /// `State/fakeip.bin`。
    public var fakeIPSnapshotFile: URL { state.appendingPathComponent("fakeip.bin") }
}

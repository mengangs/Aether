import AetherFoundation

/// `[Proxy Group]` 条目（docs/04 §6）。
public struct PolicyGroupSpec: Sendable, Equatable {
    public enum GroupType: String, Sendable, Equatable, CaseIterable {
        case select
        case urlTest = "url-test"
        case fallback
        case loadBalance = "load-balance"
        /// M7。
        case subnet

        /// 是否参与周期测速。
        public var isAutomatic: Bool {
            self == .urlTest || self == .fallback || self == .loadBalance
        }
    }

    public var name: String
    public var type: GroupType
    /// 显式成员（策略名），按配置顺序。
    public var members: [String]
    public var policyPath: String?
    public var updateInterval: Double?
    public var policyRegexFilter: String?
    public var includeAllProxies = false
    public var includeOtherGroups: [String] = []
    public var hidden = false
    public var url: String?
    public var interval = 600.0
    public var timeout: Double?
    /// 毫秒。
    public var tolerance = 50
    public var evaluateBeforeUse = false
    public var persistent = false
    public var source: SourceReference

    public init(name: String, type: GroupType, members: [String], source: SourceReference) {
        self.name = name
        self.type = type
        self.members = members
        self.source = source
    }

    /// 是否有成员来源（显式成员、policy-path、include-*）。没有则 `CFG-013`。
    public var hasMemberSource: Bool {
        !members.isEmpty || policyPath != nil || includeAllProxies || !includeOtherGroups.isEmpty
    }
}

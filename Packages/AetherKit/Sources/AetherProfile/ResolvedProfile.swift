import AetherFoundation

/// 类型化、已叠加模块、已校验的配置（docs/04 §15.1）；不含编译后的匹配结构。
public struct ResolvedProfile: Sendable {
    public var general: GeneralSettings
    public var proxies: [ProxySpec]
    public var groups: [PolicyGroupSpec]
    /// 最终顺序：模块规则在前、配置规则在后；FINAL 为最后一条（缺失时隐式追加）。
    public var rules: [RuleSpec]
    public var hosts: [HostSpec]
    public var urlRewrites: [URLRewriteSpec]
    public var headerRewrites: [HeaderRewriteSpec]
    public var bodyRewrites: [BodyRewriteSpec]
    public var mapLocals: [MapLocalSpec]
    public var scripts: [ScriptSpec]
    public var mitm: MITMSpec
    /// 所有需要下载的 URL 及其用途、更新间隔（按 URL 与用途去重）。
    public var externalResources: [ExternalResourceRef]
    public var diagnostics: [Diagnostic]
    /// 所有源文本与参数的 SHA-256（`sha256:<十六进制>`）。
    public var revision: String
    /// 配置文件名（诊断中的 `file`）。
    public var profileFileName: String
    /// 每个启用模块的处理结果，按模块列表顺序。
    public var modules: [ResolvedModule]

    /// 是否可以提交为运行包：配置本身没有 error 级诊断（04 §13）。
    /// 模块中的 error 只会使该模块不生效（04 §12.2），不阻止提交。
    public var isCommittable: Bool {
        !diagnostics.contains { $0.severity == .error && $0.file == profileFileName }
    }
}

/// 一个启用模块的处理结果。
public struct ResolvedModule: Sendable, Equatable {
    public var name: String
    public var metadata: ModuleMetadata
    /// 是否已叠加到配置上；有 error 级诊断的模块整体不生效。
    public var isApplied: Bool
    /// 该模块文件上的诊断（也包含在 `ResolvedProfile.diagnostics` 中）。
    public var diagnostics: [Diagnostic]
}

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

    /// 是否可以提交为运行包（没有 error 级诊断，04 §13）。
    public var isCommittable: Bool { !diagnostics.containsErrors }
}

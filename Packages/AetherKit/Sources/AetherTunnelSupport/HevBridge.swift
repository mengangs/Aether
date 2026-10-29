import CHevSocks5Tunnel

/// hev-socks5-tunnel 的桥接（docs/06 §4）。M2-09 实现启动、停止与统计；目前只确认 C 库已正确链接。
enum HevBridge {
    /// 引用 hev 的公开入口，保证链接器在构建期解析这些符号。
    static let entryPoints: [String: Any] = [
        "hev_socks5_tunnel_main_from_str": hev_socks5_tunnel_main_from_str,
        "hev_socks5_tunnel_quit": hev_socks5_tunnel_quit,
        "hev_socks5_tunnel_stats": hev_socks5_tunnel_stats,
    ]
}

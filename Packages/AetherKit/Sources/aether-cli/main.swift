import AetherEngine

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// aether-cli：开发调试命令行（docs/02 §3.1）。命令在 M1-09（check、match、render）与 M2 起（run）实现。
let usage = """
    用法：aether-cli <命令> [参数]

    命令（随里程碑实现）：
      check <配置文件>                      校验配置并输出诊断（M1-09）
      match <配置文件> --host <主机> ...    规则测试（M1-09）
      render <配置文件> --redact            脱敏渲染（M1-09）
      run --profile <文件> --socks <地址>   在本机运行引擎（M2）
    """

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--help", "-h", "help":
    print(usage)
case nil:
    print(usage)
    exit(64)
default:
    print("未知命令：\(arguments[0])（引擎模块：\(AetherEngineModule.name)）\n\n\(usage)")
    exit(64)
}

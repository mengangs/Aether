# BLAKE3（vendored）

BLAKE3 官方 C 实现中的可移植部分，供 Shadowsocks 2022 的会话密钥派生使用（docs/03 §6.2）。

- 来源：<https://github.com/BLAKE3-team/BLAKE3> 的 `c/` 目录，版本与提交见 `VERSION`。
- 拷贝的文件：`blake3.c`、`blake3.h`、`blake3_dispatch.c`、`blake3_impl.h`、`blake3_portable.c`，未做任何修改。
- 许可证：CC0-1.0 / Apache-2.0 / Apache-2.0 WITH LLVM-exception 三选一（`LICENSE_CC0`、`LICENSE_A2`、`LICENSE_A2LLVM`）。
- `Packages/AetherKit/Sources/CBlake3` 以符号链接引用这些文件，并在编译时关闭全部 SIMD 分支（`BLAKE3_NO_SSE2`、`BLAKE3_NO_SSE41`、`BLAKE3_NO_AVX2`、`BLAKE3_NO_AVX512`、`BLAKE3_USE_NEON=0`），保证 Linux x86_64 与 iOS arm64 行为一致。
- 官方测试向量拷贝在 `Packages/AetherKit/Tests/Fixtures/vectors/blake3/test_vectors.json`。

升级：替换上述文件与 `VERSION`，重新运行 `swift test --filter CBlake3Tests`。

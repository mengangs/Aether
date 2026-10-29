#!/usr/bin/env bash
# 编译 HevSocks5Tunnel.xcframework（docs/03 §6.1）。仅 macOS。
#
# 产物：Packages/AetherKit/Binaries/HevSocks5Tunnel.xcframework，模块名 CHevSocks5Tunnel，含切片：
#   - iOS 设备 arm64
#   - iOS 模拟器 arm64 + x86_64
#   - macOS arm64 + x86_64（在 macOS 主机上运行 `swift test` 时链接 AetherTunnelSupport 需要）
# 产物旁的 VERSION 记录 submodule commit 与本脚本的哈希；两者都未变化时跳过构建。
#
# 不直接调用上游的 build-apple.sh：它还会构建 tvOS 切片（不需要，且 runner 不一定安装了 tvOS 平台），
# 并且模块名为 HevSocks5Tunnel。这里复用上游 Makefile 的 `static` 目标，按上游脚本的方式合并静态库。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC="$ROOT/Vendor/hev-socks5-tunnel"
OUT_DIR="$ROOT/Packages/AetherKit/Binaries"
OUT="$OUT_DIR/HevSocks5Tunnel.xcframework"
MODULE="CHevSocks5Tunnel"
IOS_MIN="17.0"
MACOS_MIN="14.0"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: build-hev.sh only runs on macOS." >&2
    exit 1
fi

git submodule update --init --recursive Vendor/hev-socks5-tunnel

REV="$(git -C "$SRC" rev-parse HEAD)"
SCRIPT_HASH="$(shasum -a 256 "$0" | cut -c1-16)"
STAMP="$REV $SCRIPT_HASH"
if [[ -d "$OUT" && -f "$OUT_DIR/VERSION" && "$(cat "$OUT_DIR/VERSION")" == "$STAMP" ]]; then
    echo "HevSocks5Tunnel.xcframework is up to date (${REV})."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 在副本中构建，保持 submodule 工作区干净。
rsync -a --exclude '.git' "$SRC/" "$WORK/src/"
SHORT_REV="$(git -C "$SRC" rev-parse --short HEAD)"

# build_static <sdk> <arch> <最低版本>
build_static() {
    local sdk="$1" arch="$2" min="$3"
    echo "==> hev: ${sdk} ${arch} (min ${min})"
    local cc="xcrun --sdk $sdk clang"
    # 上游 Makefile 带 -Werror；vendored 代码的新编译器警告不应阻断构建。
    local flags="-arch $arch -m$sdk-version-min=$min -Wno-error"
    make -C "$WORK/src" --no-print-directory -j"$(sysctl -n hw.ncpu)" \
        PP="$cc" CC="$cc" CFLAGS="$flags" LFLAGS="$flags" REV_ID="$SHORT_REV" static >/dev/null
    mkdir -p "$WORK/slices/$sdk-$arch"
    libtool -static -o "$WORK/slices/$sdk-$arch/libhev-socks5-tunnel.a" \
        "$WORK/src/bin/libhev-socks5-tunnel.a" \
        "$WORK/src/third-part/lwip/bin/liblwip.a" \
        "$WORK/src/third-part/yaml/bin/libyaml.a" \
        "$WORK/src/third-part/hev-task-system/bin/libhev-task-system.a"
    make -C "$WORK/src" --no-print-directory clean >/dev/null
}

# merge <sdk> <arch1> <arch2>
merge() {
    local sdk="$1" a="$2" b="$3"
    mkdir -p "$WORK/slices/$sdk-$a-$b"
    lipo -create \
        "$WORK/slices/$sdk-$a/libhev-socks5-tunnel.a" \
        "$WORK/slices/$sdk-$b/libhev-socks5-tunnel.a" \
        -output "$WORK/slices/$sdk-$a-$b/libhev-socks5-tunnel.a"
}

build_static iphoneos arm64 "$IOS_MIN"
build_static iphonesimulator arm64 "$IOS_MIN"
build_static iphonesimulator x86_64 "$IOS_MIN"
merge iphonesimulator arm64 x86_64
build_static macosx arm64 "$MACOS_MIN"
build_static macosx x86_64 "$MACOS_MIN"
merge macosx arm64 x86_64

# 头文件与模块映射：Headers/CHevSocks5Tunnel/{hev-main.h,module.modulemap}
HEADERS="$WORK/include"
mkdir -p "$HEADERS/$MODULE"
cp "$SRC/src/hev-main.h" "$HEADERS/$MODULE/"
cat >"$HEADERS/$MODULE/module.modulemap" <<EOF
module $MODULE {
    header "hev-main.h"
    export *
}
EOF

rm -rf "$OUT"
mkdir -p "$OUT_DIR"
xcodebuild -create-xcframework \
    -library "$WORK/slices/iphoneos-arm64/libhev-socks5-tunnel.a" -headers "$HEADERS" \
    -library "$WORK/slices/iphonesimulator-arm64-x86_64/libhev-socks5-tunnel.a" -headers "$HEADERS" \
    -library "$WORK/slices/macosx-arm64-x86_64/libhev-socks5-tunnel.a" -headers "$HEADERS" \
    -output "$OUT" >/dev/null

for slice in ios-arm64 ios-arm64_x86_64-simulator macos-arm64_x86_64; do
    if [[ ! -f "${OUT}/${slice}/libhev-socks5-tunnel.a" ]]; then
        echo "error: missing slice ${slice} in ${OUT}" >&2
        exit 1
    fi
done
echo "${STAMP}" >"${OUT_DIR}/VERSION"
echo "Generated ${OUT} (hev $(git -C "${SRC}" describe --tags --always))."

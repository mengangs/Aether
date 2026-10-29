#!/usr/bin/env bash
# 一键准备 iOS 工程（docs/03 §6.3）：编译 vendored C 库并由 project.yml 生成 Aether.xcodeproj。仅 macOS。
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
    exit 1
fi

./Scripts/build-hev.sh
xcodegen generate --spec project.yml

# Xcode 不读取本地包自己的 Package.resolved；拷贝到工程的 workspace 中，使 App 构建使用同一组锁定版本。
RESOLVED_DIR="Aether.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "${RESOLVED_DIR}"
cp Packages/AetherKit/Package.resolved "${RESOLVED_DIR}/Package.resolved"

echo "Aether.xcodeproj generated."

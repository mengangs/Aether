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
echo "Aether.xcodeproj generated."

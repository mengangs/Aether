#!/usr/bin/env bash
# 在 CI 中运行一条命令；失败时把编译与测试错误行输出为 GitHub Actions 注解，
# 使错误直接显示在运行摘要中（`gh run view` 可见），不必下载完整日志。
# 用法：Scripts/ci-run.sh <命令> [参数...]
set -uo pipefail
LOG="$(mktemp)"
"$@" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
if [[ ${rc} -ne 0 ]]; then
    sed -E 's/\x1b\[[0-9;]*m//g' "${LOG}" \
        | grep -E "error:|warning: .*(Sendable|concurrency)|✘|Test .* failed|Fatal error|fatal error" \
        | grep -v -E "^error: (fatalError|Build failed)$|^[[:space:]]*\|" \
        | awk '!seen[$0]++' \
        | head -40 \
        | while IFS= read -r line; do
            line="${line//'%'/'%25'}"
            line="${line//$'\r'/'%0D'}"
            echo "::error::${line}"
        done
fi
rm -f "${LOG}"
exit "${rc}"

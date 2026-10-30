#!/usr/bin/env bash
# 在 CI 中运行一条命令；失败时把编译与测试错误行输出为 GitHub Actions 注解，
# 使错误直接显示在运行摘要中（`gh run view` 可见），不必下载完整日志。
# 设置 CI_RUN_TIMEOUT=<秒> 时启用看门狗：超时后先打印仍在运行的测试进程的全部线程调用栈（macOS 用 lldb，
# 失败时退回 sample），再结束整个进程树并以 124 退出，便于定位卡住的测试。
# 用法：[CI_RUN_TIMEOUT=<秒>] Scripts/ci-run.sh <命令> [参数...]
set -uo pipefail
LOG="$(mktemp)"

run() {
    "$@" 2>&1 | tee "${LOG}"
    return "${PIPESTATUS[0]}"
}

kill_tree() {
    local child
    for child in $(pgrep -P "$1"); do
        kill_tree "${child}"
    done
    kill -TERM "$1" 2>/dev/null
}

dump_stacks() {
    local pid
    for pid in $(pgrep -f "swiftpm-testing-helper|\.xctest|xctest "); do
        echo "::group::Stacks of ${pid}: $(ps -o command= -p "${pid}" | cut -c1-200)"
        if [[ "$(uname)" == "Darwin" ]]; then
            lldb --batch -p "${pid}" -o "thread backtrace all" -o "detach" 2>&1 | head -2000 \
                || sample "${pid}" 3 -mayDie 2>&1 | head -2000
        else
            cat "/proc/${pid}/task/"*/stat 2>/dev/null | head -100
        fi
        echo "::endgroup::"
    done
}

if [[ -n "${CI_RUN_TIMEOUT:-}" ]]; then
    run "$@" &
    pid=$!
    deadline=$((SECONDS + CI_RUN_TIMEOUT))
    while kill -0 "${pid}" 2>/dev/null && ((SECONDS < deadline)); do
        sleep 5
    done
    if kill -0 "${pid}" 2>/dev/null; then
        echo "::error::Timed out after ${CI_RUN_TIMEOUT}s: $*"
        dump_stacks
        kill_tree "${pid}"
        wait "${pid}" 2>/dev/null
        rc=124
    else
        wait "${pid}"
        rc=$?
    fi
else
    run "$@"
    rc=$?
fi

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

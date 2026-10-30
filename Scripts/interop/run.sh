#!/usr/bin/env bash
# 运行互通测试（docs/13 §3）：下载并校验服务端、生成证书、启动服务端，运行 AetherInteropTests，
# 结果表写入 $INTEROP_DIR/summary.md（在 GitHub Actions 中同时写入作业摘要）。
# 本地与 CI 相同：在 swift:6.x-noble 容器中运行；simple-obfs 用例需要 PATH 中有 obfs-server（Ubuntu 包 simple-obfs）。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
export INTEROP_DIR="${INTEROP_DIR:-$here/.work}"
work="$INTEROP_DIR"
mkdir -p "$work/logs"

"$here/fetch-servers.sh"
"$here/gen-certs.sh" "$work/certs"
set -a
# shellcheck source=/dev/null
source "$here/servers.env"
# shellcheck source=/dev/null
source "$here/ports.env"
set +a

pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT
start() { # 日志名 命令…
  local log="$work/logs/$1.log"
  shift
  "$@" >"$log" 2>&1 &
  pids+=("$!")
}

ss="$work/bin/ssserver"
pw="$AETHER_INTEROP_PASSWORD"
start ss-aes128 "$ss" -s "127.0.0.1:$SS_AES128_PORT" -m aes-128-gcm -k "$pw" -U
start ss-aes256 "$ss" -s "127.0.0.1:$SS_AES256_PORT" -m aes-256-gcm -k "$pw" -U
start ss-chacha "$ss" -s "127.0.0.1:$SS_CHACHA_PORT" -m chacha20-ietf-poly1305 -k "$pw" -U
start ss2022-aes128 "$ss" -s "127.0.0.1:$SS2022_AES128_PORT" -m 2022-blake3-aes-128-gcm -k "$AETHER_INTEROP_PSK16" -U
start ss2022-aes256 "$ss" -s "127.0.0.1:$SS2022_AES256_PORT" -m 2022-blake3-aes-256-gcm -k "$AETHER_INTEROP_PSK32" -U
start ss2022-chacha "$ss" -s "127.0.0.1:$SS2022_CHACHA_PORT" -m 2022-blake3-chacha20-poly1305 -k "$AETHER_INTEROP_PSK32"
if command -v obfs-server >/dev/null; then
  start ss-obfs-http "$ss" -s "127.0.0.1:$SS_OBFS_HTTP_PORT" -m aes-256-gcm -k "$pw" \
    --plugin obfs-server --plugin-opts "obfs=http"
  start ss-obfs-tls "$ss" -s "127.0.0.1:$SS_OBFS_TLS_PORT" -m aes-256-gcm -k "$pw" \
    --plugin obfs-server --plugin-opts "obfs=tls"
  export AETHER_INTEROP_OBFS=1
else
  echo "obfs-server not found: simple-obfs cases are skipped" >&2
fi
sed -e "s#__CERT__#$work/certs/server.pem#g" -e "s#__KEY__#$work/certs/server.key#g" \
  "$here/xray.json" >"$work/xray.json"
start xray "$work/bin/xray" run -c "$work/xray.json"

# 等待全部端口监听（最多 15 秒）。
for port in $(grep -E '_PORT=' "$here/ports.env" | cut -d= -f2); do
  if [[ ("$port" == "$SS_OBFS_HTTP_PORT" || "$port" == "$SS_OBFS_TLS_PORT") && -z "${AETHER_INTEROP_OBFS:-}" ]]; then
    continue
  fi
  for _ in $(seq 1 150); do
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break
    sleep 0.1
  done
done

export AETHER_INTEROP=1
export AETHER_INTEROP_CA="$work/certs/ca.pem"
export AETHER_INTEROP_REPORT="$work/report.md"
rm -f "$AETHER_INTEROP_REPORT"
status=0
swift test --package-path "$root/Packages/AetherKit" --filter AetherInteropTests || status=$?

{
  echo "## Interop (docs/13 §3)"
  echo
  echo "Xray $XRAY_VERSION, shadowsocks-rust $SSRUST_VERSION, simple-obfs: $([[ -n "${AETHER_INTEROP_OBFS:-}" ]] && echo yes || echo skipped)"
  echo
  echo "| Case | GET | 64 MiB | 50 concurrent | Server abort | Wrong credentials | UDP (DNS, 1000 echoes) | Latency |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
  sort "$AETHER_INTEROP_REPORT" 2>/dev/null || true
} >"$work/summary.md"
cat "$work/summary.md"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$work/summary.md" >>"$GITHUB_STEP_SUMMARY"
fi
if [[ $status -ne 0 ]]; then
  for log in "$work"/logs/*.log; do echo "== $log"; tail -20 "$log"; done
fi
exit $status

#!/usr/bin/env bash
# 下载并校验互通测试服务端到 $INTEROP_DIR/bin（默认 Scripts/interop/.work）。已存在且校验通过时跳过。
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/servers.env"
work="${INTEROP_DIR:-$here/.work}"
mkdir -p "$work/bin" "$work/downloads"

fetch() { # 名称 地址 校验和
  local file="$work/downloads/$1"
  if [[ -f "$file" ]] && echo "$3  $file" | sha256sum -c --status; then
    return
  fi
  curl -fsSL --retry 3 -o "$file" "$2"
  echo "$3  $file" | sha256sum -c --status || { echo "checksum mismatch: $1" >&2; exit 1; }
}

fetch xray.zip "$XRAY_URL" "$XRAY_SHA256"
fetch shadowsocks.tar.xz "$SSRUST_URL" "$SSRUST_SHA256"
unzip -o -q "$work/downloads/xray.zip" xray -d "$work/bin"
tar -xJf "$work/downloads/shadowsocks.tar.xz" -C "$work/bin" ssserver
chmod +x "$work/bin/xray" "$work/bin/ssserver"
"$work/bin/xray" version | head -1
"$work/bin/ssserver" --version

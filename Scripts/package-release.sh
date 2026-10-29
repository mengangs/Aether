#!/usr/bin/env bash
# 把未签名的 Aether.xcarchive 打包为发布产物（docs/03 §8.3–§8.4）。仅 macOS。
#
# 用法：Scripts/package-release.sh <Aether.xcarchive> <输出目录> [配置名，默认 Release]
#
# 产物：
#   Aether-<版本>-<构建号>-unsigned.ipa   Payload/Aether.app（含 PlugIns/AetherTunnel.appex），未签名
#   entitlements/Aether.entitlements       App 的 entitlements（变量已展开，供重签使用）
#   entitlements/AetherTunnel.entitlements Tunnel 的 entitlements（同上）
#   identifiers.json / identifiers.txt     标识符清单：各 Bundle ID、App Group、Keychain 组、Team ID 等
#   Aether-<版本>-<构建号>-dSYMs.zip        调试符号
set -euo pipefail

ARCHIVE="${1:?usage: package-release.sh <xcarchive> <out-dir> [configuration]}"
OUT="${2:?usage: package-release.sh <xcarchive> <out-dir> [configuration]}"
CONFIGURATION="${3:-Release}"
cd "$(dirname "$0")/.."

APP="${ARCHIVE}/Products/Applications/Aether.app"
if [[ ! -d "${APP}" ]]; then
    echo "error: ${APP} not found" >&2
    exit 1
fi

rm -rf "${OUT}"
mkdir -p "${OUT}/entitlements"

SETTINGS_DIR="$(mktemp -d)"
trap 'rm -rf "${SETTINGS_DIR}"' EXIT
for target in Aether AetherTunnel; do
    xcodebuild -showBuildSettings -json -project Aether.xcodeproj -target "${target}" \
        -configuration "${CONFIGURATION}" >"${SETTINGS_DIR}/${target}.json"
done

# 展开 entitlements 中的 $(VAR)，写出标识符清单。
python3 -I - "${SETTINGS_DIR}" "${OUT}" "${APP}" <<'PY'
import json
import pathlib
import plistlib
import re
import subprocess
import sys

settings_dir, out, app = map(pathlib.Path, sys.argv[1:4])


def settings(target):
    data = json.loads((settings_dir / f"{target}.json").read_text())
    return data[0]["buildSettings"]


def expand(value, env):
    if isinstance(value, str):
        def sub(match):
            name = match.group(1)
            if name not in env:
                raise SystemExit(f"error: unresolved build setting $({name})")
            return env[name]
        previous = None
        while previous != value:
            previous, value = value, re.sub(r"\$\(([A-Za-z0-9_]+)\)", sub, value)
        return value
    if isinstance(value, list):
        return [expand(v, env) for v in value]
    if isinstance(value, dict):
        return {k: expand(v, env) for k, v in value.items()}
    return value


app_env, tunnel_env = settings("Aether"), settings("AetherTunnel")
for target, env, source in [
    ("Aether", app_env, "App/Aether.entitlements"),
    ("AetherTunnel", tunnel_env, "Tunnel/AetherTunnel.entitlements"),
]:
    entitlements = expand(plistlib.loads(pathlib.Path(source).read_bytes()), env)
    (out / "entitlements" / f"{target}.entitlements").write_bytes(plistlib.dumps(entitlements))

commit = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
info = plistlib.loads((app / "Info.plist").read_bytes())
tunnel_info = plistlib.loads((app / "PlugIns/AetherTunnel.appex/Info.plist").read_bytes())
manifest = {
    "version": info["CFBundleShortVersionString"],
    "build": info["CFBundleVersion"],
    "commit": commit,
    "teamID": app_env.get("AETHER_TEAM_ID", ""),
    "appBundleID": info["CFBundleIdentifier"],
    "tunnelBundleID": tunnel_info["CFBundleIdentifier"],
    "appGroup": info["AetherAppGroupIdentifier"],
    "keychainAccessGroup": info["AetherKeychainAccessGroup"],
    "urlScheme": info["AetherURLScheme"],
    "bundleIDPrefix": info["AetherBundleIdentifierPrefix"],
}
if manifest["tunnelBundleID"] != info["AetherTunnelBundleIdentifier"]:
    raise SystemExit("error: tunnel bundle ID in the appex differs from AetherTunnelBundleIdentifier in the app")
if not manifest["tunnelBundleID"].startswith(manifest["appBundleID"] + "."):
    print("warning: the tunnel bundle ID is not prefixed by the app bundle ID; iOS will refuse to install it")
(out / "identifiers.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
lines = [
    "Aether 标识符清单（重签时核对）",
    "",
    f"版本            {manifest['version']} ({manifest['build']})",
    f"提交            {manifest['commit']}",
    f"Team ID         {manifest['teamID'] or '(未设置)'}",
    f"App Bundle ID   {manifest['appBundleID']}",
    f"Tunnel Bundle ID {manifest['tunnelBundleID']}",
    f"App Group       {manifest['appGroup']}",
    f"Keychain 访问组 {manifest['keychainAccessGroup']}",
    f"URL Scheme      {manifest['urlScheme']}",
    "",
    "entitlements/Aether.entitlements        → Payload/Aether.app",
    "entitlements/AetherTunnel.entitlements  → Payload/Aether.app/PlugIns/AetherTunnel.appex",
]
(out / "identifiers.txt").write_text("\n".join(lines) + "\n")
(out / ".basename").write_text(f"Aether-{manifest['version']}-{manifest['build']}")
print("\n".join(lines))
PY

BASENAME="$(cat "${OUT}/.basename")"
rm -f "${OUT}/.basename"

# ipa：标准结构 Payload/Aether.app。
STAGE="$(mktemp -d)"
mkdir -p "${STAGE}/Payload"
cp -R "${APP}" "${STAGE}/Payload/"
(cd "${STAGE}" && zip -qry "${OLDPWD}/${OUT}/${BASENAME}-unsigned.ipa" Payload)
rm -rf "${STAGE}"

if [[ -d "${ARCHIVE}/dSYMs" ]]; then
    (cd "${ARCHIVE}/dSYMs" && zip -qry "${OLDPWD}/${OUT}/${BASENAME}-dSYMs.zip" .)
fi

# 结构自检。
IPA="${OUT}/${BASENAME}-unsigned.ipa"
for entry in Payload/Aether.app/Info.plist Payload/Aether.app/PlugIns/AetherTunnel.appex/Info.plist \
    Payload/Aether.app/Aether Payload/Aether.app/PlugIns/AetherTunnel.appex/AetherTunnel; do
    if ! unzip -l "${IPA}" "${entry}" >/dev/null 2>&1; then
        echo "error: ${entry} missing from ${IPA}" >&2
        exit 1
    fi
done
echo "Packaged:"
ls -l "${OUT}" "${OUT}/entitlements"

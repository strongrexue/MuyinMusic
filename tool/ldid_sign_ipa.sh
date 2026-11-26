#!/usr/bin/env bash
# 对 --no-codesign 产出的未签名 IPA 用 ldid 伪签 entitlements。
#
# 背景：巨魔只保留二进制里已有的 entitlements。--no-codesign 产出的二进制
# 里什么都没有，主 App 拿不到 application-identifier，系统不认这个 App，
# 锁屏卡不显示。ldid -S 把 entitlements 写进二进制后巨魔才有东西可保留。
# 轻松签会用自己的证书重签覆盖，不受本脚本影响。
#
# 用法：
#   bash tool/ldid_sign_ipa.sh <输入.ipa> [输出.ipa] [app-id] [group-id]
# 默认：
#   输出 = <输入>-ldid.ipa
#   app-id  = com.panghu.panghumusic（必须等于真实 bundle id，不能带 group. 前缀）
#   group-id = group.com.panghu.panghumusic
# 依赖（macOS）：brew install ldid；系统自带 unzip / zip / PlistBuddy。
set -euo pipefail

IPA_IN="${1:-}"
IPA_OUT="${2:-${IPA_IN%.ipa}-ldid.ipa}"
APP_ID="${3:-com.panghu.panghumusic}"
GROUP_ID="${4:-group.com.panghu.panghumusic}"

if [ -z "$IPA_IN" ] || [ ! -f "$IPA_IN" ]; then
  echo "用法: bash ldid_sign_ipa.sh <输入.ipa> [输出.ipa] [app-id] [group-id]" >&2
  exit 2
fi
for tool in ldid unzip zip PlistBuddy; do
  if [ "$tool" = "PlistBuddy" ]; then
    [ -x /usr/libexec/PlistBuddy ] || { echo "[error] 找不到 /usr/libexec/PlistBuddy（需 macOS）" >&2; exit 2; }
  elif ! command -v "$tool" >/dev/null 2>&1; then
    echo "[error] 找不到 $tool" >&2; exit 2
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[1/5] 解包"
unzip -q "$IPA_IN" -d "$TMP"
APP="$(find "$TMP/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
[ -n "$APP" ] || { echo "[error] IPA 里没有 .app" >&2; exit 1; }

echo "[2/5] 生成 entitlements"
# 不能用工程里的 .entitlements（含 $(AppIdentifierPrefix) 变量，ldid 不展开），
# 这里按实参生成展开后的版本。
ENT="$TMP/entitlements.plist"
cat > "$ENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>${APP_ID}</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${GROUP_ID}</string>
	</array>
</dict>
</plist>
EOF

echo "[3/5] ldid 伪签主 App"
MAIN_EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
ldid -S"$ENT" "$APP/$MAIN_EXE"

echo "[4/5] ldid 伪签扩展（若有 PlugIns/*.appex）"
if [ -d "$APP/PlugIns" ]; then
  while IFS= read -r APPEX; do
    APPEX_EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APPEX/Info.plist" 2>/dev/null || true)"
    if [ -n "$APPEX_EXE" ] && [ -f "$APPEX/$APPEX_EXE" ]; then
      ldid -S"$ENT" "$APPEX/$APPEX_EXE"
      echo "      signed $(basename "$APPEX")"
    fi
  done < <(find "$APP/PlugIns" -maxdepth 1 -name '*.appex' -type d)
else
  echo "      (无 PlugIns，跳过)"
fi

echo "[5/5] 验证并重打包"
ldid -e "$APP/$MAIN_EXE"
# cd 到临时目录前先把输出路径绝对化，否则相对路径的产物会落进 TMP 被 trap 删掉
mkdir -p "$(dirname "$IPA_OUT")"
IPA_OUT_ABS="$(cd "$(dirname "$IPA_OUT")" && pwd)/$(basename "$IPA_OUT")"
rm -f "$IPA_OUT_ABS"
(cd "$TMP" && zip -qry "$IPA_OUT_ABS" Payload)
echo "[ok] $IPA_OUT_ABS"

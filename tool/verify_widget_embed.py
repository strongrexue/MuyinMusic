#!/usr/bin/env python3
"""校验 WidgetKit 扩展是否随主 App 一起产出，并在 no-codesign 场景下补全嵌入与 plist。

设计要点：不依赖 --no-codesign 构建产物 Info.plist 的键（实测该产物
CFBundleIdentifier 缺失，PlistBuddy Print 会直接失败并触发 set -e 静默退出）。
权威数据来源：仓库内的源 plist 与 project.pbxproj。
"""
import os
import re
import shutil
import plistlib
import sys

APP_PATH = sys.argv[1]          # build/ios/iphoneos/Runner.app
BUILD_NAME = sys.argv[2]        # 2.0.9
BUILD_NUMBER = sys.argv[3]      # 24

APPEX = os.path.join(APP_PATH, "PlugIns", "CyShineMusicWidget.appex")
BUILT_APPEX = os.path.join("build", "ios", "iphoneos", "CyShineMusicWidget.appex")
SRC_WIDGET_PLIST = os.path.join("ios", "CyShineMusicWidget", "Info.plist")
PBXPROJ = os.path.join("ios", "Runner.xcodeproj", "project.pbxproj")
APP_PLIST = os.path.join(APP_PATH, "Info.plist")


def fail(msg):
    print("::error::" + msg)
    sys.exit(1)


# 1) 前置硬校验：主 App 必须真实存在，绝不能靠 makedirs 造空壳。
#    实测若 scheme 误把 Widget 加进 BuildActionEntries，flutter build 只产出
#    appex、不产出 Runner.app；此时若继续 mkdir 嵌入会打出只有扩展的废 IPA。
if not os.path.isdir(APP_PATH):
    fail(f"{APP_PATH} 不存在，flutter build 未产出主 App（检查 scheme 是否被加了 Widget entry）")
if not os.path.isfile(os.path.join(APP_PATH, "Info.plist")):
    fail(f"{APP_PATH}/Info.plist 不存在，主 App 构建产物不完整（空壳目录不能当产物）")

# 2) no-codesign 下 Xcode 会编译出 appex 但跳过 Embed phase，手动嵌入。
#    这里 APPEX 不存在时 PlugIns 父目录已随主 App 存在，绝不新建 APP_PATH 本身。
if not os.path.isdir(APPEX) and os.path.isdir(BUILT_APPEX):
    print("no-codesign 下 Embed App Extensions 未执行，手动嵌入 Xcode 编译的 appex")
    os.makedirs(os.path.dirname(APPEX), exist_ok=True)
    shutil.copytree(BUILT_APPEX, APPEX)

if not os.path.isdir(APPEX):
    fail(f"{APPEX} 不存在，灵动岛扩展没打进去")
exe = os.path.join(APPEX, "CyShineMusicWidget")
if not os.path.isfile(exe):
    fail(f"{exe} 不存在，扩展可执行文件缺失")

# 2) 用仓库内权威源 plist 覆盖（no-codesign 生成的 appex plist 可能不完整）。
shutil.copy(SRC_WIDGET_PLIST, os.path.join(APPEX, "Info.plist"))
with open(os.path.join(APPEX, "Info.plist"), "rb") as f:
    widget = plistlib.load(f)
widget["CFBundleShortVersionString"] = BUILD_NAME
widget["CFBundleVersion"] = BUILD_NUMBER
with open(os.path.join(APPEX, "Info.plist"), "wb") as f:
    plistlib.dump(widget, f)

# 3) 诊断：打印主 App 构建产物 plist 的真实键（不用于流程判断）。
try:
    with open(APP_PLIST, "rb") as f:
        app_data = plistlib.load(f)
    print("[diag] 主 App 构建产物 plist 键: " + ",".join(sorted(app_data.keys())))
    print("[diag] 主 App CFBundleIdentifier: " + str(app_data.get("CFBundleIdentifier", "<缺失>")))
except Exception as e:
    print("[diag] 读取主 App 构建产物 plist 失败: " + str(e))

# 4) 主 App bundle id 从 pbxproj 取（Runner target 写死值），不读构建产物 plist。
with open(PBXPROJ, "r", encoding="utf-8") as f:
    pbx = f.read()
ids = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", pbx)
ids = [i.strip() for i in ids]
app_id = next((i for i in ids if i == "com.muyin.muyinmusic"), ids[0] if ids else "")
appex_id = widget.get("CFBundleIdentifier", "")
if not app_id:
    fail("无法从 project.pbxproj 提取主 App bundle id")
if not appex_id.startswith(app_id + "."):
    fail(f"扩展 bundle id ({appex_id}) 未以主 App ({app_id}) 为前缀，iOS 会拒绝加载")

# 5) 版本一致性：三方都用 inputs（build name/number），源 plist 变量已展开。
if widget["CFBundleShortVersionString"] != BUILD_NAME or widget["CFBundleVersion"] != BUILD_NUMBER:
    fail("扩展版本写入失败")

print(f"[ok] 扩展校验通过：{appex_id} / {BUILD_NAME} ({BUILD_NUMBER})，前缀与版本均与主 App 对齐")

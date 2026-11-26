// 实时活动「授权死锁」回归检查。
//
// 背景（第 10 轮定位到的真 bug）：
//   iOS 17 起「实时活动」开关挂在通知授权上。通知处于 notDetermined 时，
//   `ActivityAuthorizationInfo().areActivitiesEnabled` 返回 **false**。
//   而 Dart 侧 live_activity_service.dart 的逻辑是：
//       isSupported == false  ->  不挂监听、也不调用 start
//   如果 `ensureNotificationAuthorization()` 只写在 `case "start"` 里，
//   就形成死锁：不给权限 -> 报不支持 -> 不调 start -> 永远不给权限。
//   上一版（ios-v2.0.1）就是这么写的，所以灵动岛一直不出现。
//
// 本脚本把这条约束变成硬校验，防止以后重构时又踩回去。
// 用法：node tool/verify_live_activity_auth.mjs

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const bridgePath = join(root, 'ios/Runner/PanghuLiveActivityBridge.swift');
const servicePath = join(root, 'lib/features/player/live_activity_service.dart');
const plistPath = join(root, 'ios/Runner/Info.plist');

const bridge = readFileSync(bridgePath, 'utf8');
const service = readFileSync(servicePath, 'utf8');
const plist = readFileSync(plistPath, 'utf8');

/** 取 `case "xxx":` 到下一个 `case "` 之间的片段。 */
function caseBody(source, name) {
  const start = source.indexOf(`case "${name}":`);
  if (start < 0) return null;
  const rest = source.slice(start + `case "${name}":`.length);
  const next = rest.search(/\n\s*case\s+"/);
  return next < 0 ? rest : rest.slice(0, next);
}

const failures = [];
const notes = [];

// ① ★ 核心：`ensureNotificationAuthorization()` 必须在 isSupported 分支里被调用。
//    只在 start 里调用 = 死锁（见文件头注释）。
const isSupported = caseBody(bridge, 'isSupported');
if (isSupported === null) {
  failures.push('ios/Runner/PanghuLiveActivityBridge.swift 里找不到 case "isSupported"');
} else if (!/ensureNotificationAuthorization\s*\(\s*\)/.test(isSupported)) {
  failures.push([
    'case "isSupported" 里没有调用 ensureNotificationAuthorization() —— 这会让灵动岛进入死锁：',
    'iOS 17 起通知未授权时 areActivitiesEnabled 返回 false，Dart 因此不会调用 start，',
    '而问权限的代码只在 start 里，于是永远问不到权限、灵动岛永远不出现。',
    '修法：在 isSupported 分支开头也调一次（该方法是幂等的）。',
  ].join('\n  '));
}

// ② isSupported 不能在「授权弹窗还没回答」时直接把 false 回给 Dart，
//    必须放行（result(true)），否则 Dart 依旧会放弃。
if (isSupported && /isNotificationAuthorizationPending/.test(isSupported) === false) {
  failures.push([
    'case "isSupported" 没有考虑 isNotificationAuthorizationPending ——',
    '「还没回答弹窗」必须与「用户拒绝」区分开：前者要按可用放行(result(true))，',
    '否则 Dart 拿到 false 后不再重试，授权完成后也不会恢复。',
  ].join('\n  '));
}

// ③ Dart 侧必须处理原生推来的 authorizationResolved，否则授权完成后要等
//    下一次播放状态变化才恢复（用户观感是「授权完了还是没反应」）。
if (!/authorizationResolved/.test(service)) {
  failures.push([
    'lib/features/player/live_activity_service.dart 没有处理原生回调 authorizationResolved ——',
    '通知授权刚被回答时 areActivitiesEnabled 才翻成 true，必须立刻重试并补推当前曲目。',
  ].join('\n  '));
}

// ④ _ensureAvailable 必须支持强制重查（force），否则授权回调无法突破
//    「已经判定过 false」的缓存。
if (!/_ensureAvailable\s*\(\s*\{\s*bool\s+force/.test(service)) {
  failures.push([
    'live_activity_service.dart 的 _ensureAvailable 没有 force 参数 ——',
    '授权回调需要强制重新判定一次 areActivitiesEnabled，否则会被缓存挡住。',
  ].join('\n  '));
}

// ⑤ Info.plist 两个键都要为 true（只写键但值是 false 同样静默失败）。
//    注意：曾把这两个键改成 false 导致 areActivitiesEnabled 永远为 false，
//    request 被系统拒绝，而本脚本旧版只查键存在、漏过了这个值错误。
for (const key of ['NSSupportsLiveActivities', 'NSSupportsLiveActivitiesFrequentUpdates']) {
  const trueRe = new RegExp(`<key>${key}</key>\\s*<true\\s*/>`);
  const falseRe = new RegExp(`<key>${key}</key>\\s*<false\\s*/>`);
  if (falseRe.test(plist)) {
    failures.push(`ios/Runner/Info.plist 的 ${key} 是 false，必须为 true`);
  } else if (!trueRe.test(plist)) {
    failures.push(`ios/Runner/Info.plist 缺少 ${key} 或值不是 true`);
  }
}

// ⑥ 扩展侧也必须把 NSSupportsLiveActivities 设为 true
//    （只写主 App 或写成 false 都会「request 成功但不渲染」）。
const widgetPlistPath = join(root, 'ios/PanghuMusicWidget/Info.plist');
const widgetPlist = readFileSync(widgetPlistPath, 'utf8');
{
  const key = 'NSSupportsLiveActivities';
  const trueRe = new RegExp(`<key>${key}</key>\\s*<true\\s*/>`);
  const falseRe = new RegExp(`<key>${key}</key>\\s*<false\\s*/>`);
  if (falseRe.test(widgetPlist)) {
    failures.push('ios/PanghuMusicWidget/Info.plist 的 NSSupportsLiveActivities 是 false，必须为 true');
  } else if (!trueRe.test(widgetPlist)) {
    failures.push('ios/PanghuMusicWidget/Info.plist 缺少 NSSupportsLiveActivities 或值不是 true（扩展侧也要写 true）');
  }
}

// ⑥b ★ UIDeviceFamily —— 手工组装的 .appex 不会被 Xcode 自动补这个键，
//缺失时 iOS 可能直接不加载扩展：灵动岛与桌面小组件一起消失，且**没有任何报错**。
// 2.0.2 的产物里实测就是缺这个键（主 App 有 [1,2]，appex 完全没有）。
if (!widgetPlist.includes('UIDeviceFamily')) {
  failures.push([
    'ios/PanghuMusicWidget/Info.plist 缺少 UIDeviceFamily ——',
    '这个 .appex 是手工组装的（xcrun swiftc），Xcode 不会替它注入这个键。',
    '缺失时 iOS 可能直接不加载扩展：灵动岛不显示 + 桌面搜不到小组件，',
    '而主 App 一切正常、控制台也没有任何报错。',
  ].join('\n  '));
}

// ⑦ 主 App 与扩展必须共用同一个 ActivityAttributes 源文件，
//    否则系统匹配不到已启动的活动（类型不一致 = 灵动岛不渲染）。
if (!/PanghuActivityAttributes\.swift/.test(bridge)) {
  failures.push([
    'PanghuLiveActivityBridge.swift 没有引用 PanghuActivityAttributes ——',
    '主 App 与扩展必须编译同一份 ActivityAttributes 源码，否则活动起不来。',
  ].join('\n  '));
}

// ⑧ 主 App 与扩展的 entitlements 文件必须存在且声明同一个 App Group。
//    扩展通过 UserDefaults(suiteName:) 读写这个 group 里的播放状态/歌词，
//    没有 entitlements = 扩展沙盒里读不到数据 = 灵动岛内容为空或扩展加载失败。
const runnerEntitlementsPath = join(root, 'ios/Runner/Runner.entitlements');
const widgetEntitlementsPath = join(root, 'ios/PanghuMusicWidget/PanghuMusicWidget.entitlements');
const APP_GROUP = 'group.com.panghu.panghumusic';
for (const [label, path] of [
  ['主 App', runnerEntitlementsPath],
  ['扩展', widgetEntitlementsPath],
]) {
  let ent;
  try {
    ent = readFileSync(path, 'utf8');
  } catch {
    failures.push(`缺少 ${path} —— ${label} 没有 entitlements，App Group 声明不了`);
    continue;
  }
  if (!ent.includes(APP_GROUP)) {
    failures.push(`${path.replace(root + '/', '')} 未声明 App Group ${APP_GROUP}`);
  }
  // application-identifier 必须用 $(AppIdentifierPrefix) 占位符，让签名端
  // 自动填团队前缀；硬编码 team id 会在换账号/换签名工具时失效。
  if (!/application-identifier[\s\S]*?\$\(AppIdentifierPrefix\)/.test(ent)) {
    failures.push(`${path.replace(root + '/', '')} 的 application-identifier 未用 $(AppIdentifierPrefix) 占位符`);
  }
}

// ⑨ project.pbxproj 必须有正经的 app-extension target + Embed App Extensions phase，
//    且两个构建的 CODE_SIGN_ENTITLEMENTS 指向各自的 entitlements。
//    早期用 swiftc 手工把 .appex 塞进 PlugIns/，没有 entitlements/前缀，
//    伪签环境下扩展加载失败 —— 这里把它变成硬校验，防止回退到手工拼装。
const pbxprojPath = join(root, 'ios/Runner.xcodeproj/project.pbxproj');
try {
  const pbx = readFileSync(pbxprojPath, 'utf8');
  if (!/productType = "com\.apple\.product-type\.app-extension"/.test(pbx)) {
    failures.push('project.pbxproj 没有 app-extension target（PanghuMusicWidget 未接进工程）');
  }
  const embedPhase = /isa = PBXCopyFilesBuildPhase;[\s\S]*?dstSubfolderSpec = 13;/;
  if (!embedPhase.test(pbx)) {
    failures.push('project.pbxproj 缺少 "Embed App Extensions" phase（dstSubfolderSpec=13），扩展不会被嵌进 Runner.app/PlugIns/');
  }
  if ((pbx.match(/CODE_SIGN_ENTITLEMENTS = Runner\/Runner\.entitlements;/g) || []).length < 1) {
    failures.push('Runner 主 App 构建配置未挂 Runner.entitlements');
  }
  if ((pbx.match(/CODE_SIGN_ENTITLEMENTS = PanghuMusicWidget\/PanghuMusicWidget\.entitlements;/g) || []).length < 1) {
    failures.push('Widget 扩展构建配置未挂 PanghuMusicWidget.entitlements');
  }
} catch {
  failures.push(`读取 ${pbxprojPath.replace(root + '/', '')} 失败`);
}

// ⑩ Runner.xcscheme 的 Build 列表必须【只有】主 App（Runner）一个 entry。
//    若把 Widget target 加进 scheme 的 BuildActionEntries，flutter build ios
//    会把构建目标识别成扩展，只产出 appex、不产出 Runner.app（实测打包出的
//    IPA 只剩扩展、主 App 二进制丢失）。扩展靠 pbxproj 的 target dependency
//    + Embed App Extensions phase 随主 App 编译，不需要也不允许进 scheme。
const schemePath = join(root, 'ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme');
try {
  const scheme = readFileSync(schemePath, 'utf8');
  const buildSection = (scheme.match(/<BuildActionEntries>[\s\S]*?<\/BuildActionEntries>/) || [''])[0];
  const entryCount = (buildSection.match(/<BuildActionEntry\b/g) || []).length;
  if (/BlueprintName = "PanghuMusicWidget"/.test(buildSection) ||
      /C7A0B0000000000000000001/.test(buildSection)) {
    failures.push('Runner.xcscheme 的 Build 列表含 PanghuMusicWidget —— 会导致 flutter build 只产 appex 不产主 App，必须移除');
  } else if (entryCount !== 1) {
    failures.push(`Runner.xcscheme 的 Build 列表应只有主 App 一个 entry，实际 ${entryCount} 个`);
  }
} catch {
  failures.push(`读取 ${schemePath.replace(root + '/', '')} 失败`);
}

// ---- 输出 ----
console.log('实时活动授权链路检查');
console.log('  bridge :', bridgePath.replace(root + '/', ''));
console.log('  service:', servicePath.replace(root + '/', ''));
console.log('');

if (notes.length) {
  for (const n of notes) console.log('  [info]', n);
  console.log('');
}

if (failures.length) {
  console.error(`✗ ${failures.length} 项不通过：\n`);
  failures.forEach((f, i) => {
    console.error(`  ${i + 1}. ${f}\n`);
  });
  process.exit(1);
}

console.log('✓ 全部通过：授权链路、两个 Info.plist 键、App Group entitlements、app-extension target 与 Embed phase 均就位。');
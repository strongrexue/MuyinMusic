import 'dart:convert';

import 'package:crypto/crypto.dart';

/// MiNA / 小米账号协议常量。
///
/// 参数出处：songloft-plugin-miot `src/mina/constants.ts`（主蓝本），
/// 交叉核对 Yonsm/MiService。详细对照见
/// `~/workspace/xiaoai_ref/协议清单与移植对照.md` 第 1 节。

/// 小米账号服务基础 URL。
const String kXiaomiAccountBaseUrl = 'https://account.xiaomi.com';

/// MiNA API 基础 URL。
const String kMinaApiBaseUrl = 'https://api2.mina.mi.com';

/// MiNA 播控 / 对话所用 sid。
const String kMinaSid = 'micoapi';

/// MIoT 签名通道所用 sid（V1 不使用，仅登记）。
const String kXiaomiIoSid = 'xiaomiio';

/// 账号请求 UA 模板，`%s` 替换为客户端 deviceId（miot USER_AGENT_TEMPLATE）。
const String kXiaomiUserAgentTemplate =
    'Android-7.1.1-1.0.0-ONEPLUS A3010-136-%s APP/xiaomi.smarthome APPV/62830';

/// OTP 二次验证全流程专用 UA（miservice `UA_OTP`，逐字沿用）。
///
/// /identity/* 与 /fe/service/identity/* 是米家 App 内嵌浏览器里的
/// H5 验证流程：miservice 的 `_verify_otp` 从打开 authStart 到提交
/// 验证码全程只用这个浏览器 UA。用 App UA 请求时，依赖会话的
/// verifyPhone 触发步会被服务器（跟随重定向后）返回 HTML 验证页
/// 而非 JSON（真机实测 1836 字节 `<!DOCTYPE html>`），故 OTP 流程
/// 的每一步都必须用它，不得与登录 / MiNA 的 App UA 混用。
const String kXiaomiOtpUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 iOS/26.3.1 '
    'MiHome/11.3.203 iPhone/iPhone17,2 '
    'DeviceId/D84D9205859533D504042022029B988E6F7DD180 UserId/8816080 '
    'APP/com.xiaomi.mihome APPV/11.3.203 Platform/iPhone Region/CN '
    '/xiaomi/miuibrowser/4.3/smartHome/ios/iPhone17,2/11.3.203 '
    'APP/com.xiaomi.mihome APPV/11.3.203 iosPassportSDK/4.2.50 iOS/26.3.1 '
    'MK/aVBob25lMTcsMg== DEVT/aVBob25l DEVS/aU9T BRA/QXBwbGU= L/zh_CN';

/// 默认 HTTP 超时（miot DEFAULT_HTTP_TIMEOUT）。
const Duration kMinaHttpTimeout = Duration(seconds: 30);

/// ubus 请求超时（miot UBUS_TIMEOUT_MS）。
const Duration kMinaUbusTimeout = Duration(seconds: 5);

/// serviceToken 假定有效期（miot SERVICE_TOKEN_VALID_HOURS）。
const int kServiceTokenValidHours = 12;

/// serviceToken 主动刷新阈值：剩余有效期低于此值时刷新
/// （miot TOKEN_REFRESH_THRESHOLD_HOURS）。
const int kTokenRefreshThresholdHours = 3;

/// 登录限流（70022）退避：连续命中次数与冷却时长（miservice
/// `_RATE_LIMIT_CODE/_RETRY_MAX/_COOLDOWN`）。
const int kLoginRateLimitCode = 70022;
const int kLoginRateLimitMaxHits = 5;
const Duration kLoginRateLimitCooldown = Duration(hours: 2);

/// 对话记录拉取失败重试次数（miot MAX_RETRIES）。
const int kConversationMaxRetries = 3;

/// 默认走 `player_play_music` 的设备型号（miot DEFAULT_MUSIC_API_MODELS）。
const List<String> kDefaultMusicApiModels = [
  'X08C',
  'X08E',
  'X8S',
  'X8F',
  'X4B',
  'LX05',
  'OH11',
  'OH2',
  'OH2P',
  'X6A',
  'LX04',
  'L05B',
  'L05C',
  'LX06',
  'L06A',
  'X08A',
  'X10A',
  'L15A',
  'L16A',
  'L17A',
];

/// 只能走 ubus `nlp_result_get` 拉对话记录的型号（miot GET_ASK_BY_MINA）。
/// V1 目标设备只有 LX06，不实现该备路径。
const List<String> kAskByMinaModels = ['M01'];

/// player_play_music 的占位 audio_id（miot DEFAULT_MUSIC_AUDIO_ID；
/// miservice 用另一个值，两家不一致，说明它只是占位）。
const String kDefaultMusicAudioId = '1732418460076477549';

/// player_play_music music JSON 里的 cp id（miot MUSIC_CP_ID）。
const String kMusicCpId = '355454500';

/// 对话记录接口 URL 模板。
String formatLatestAskUrl(String hardware, int timestampMs, int limit) {
  return 'https://userprofile.mina.mi.com/device_profile/v2/conversation'
      '?source=dialogu&hardware=$hardware&timestamp=$timestampMs&limit=$limit';
}

/// 按 deviceId 格式化账号 / MiNA 请求 UA。
String formatXiaomiUserAgent(String deviceId) =>
    kXiaomiUserAgentTemplate.replaceAll('%s', deviceId);

/// 指定型号是否默认走 `player_play_music`；
/// [disabledModels] 显式禁用名单优先于默认名单（miot needUsePlayMusicAPI）。
bool needUsePlayMusicApi(String hardware, {List<String>? disabledModels}) {
  if (disabledModels != null && disabledModels.contains(hardware)) {
    return false;
  }
  return kDefaultMusicApiModels.contains(hardware);
}

/// 剥掉 account.xiaomi.com 响应体的 `&&&START&&&` 前缀。
String stripXiaomiJsonPrefix(String body) =>
    body.replaceAll('&&&START&&&', '').trim();

/// 从原始 JSON 文本正则提取大整数字段（字符串形式）。
///
/// nonce 是 64 位大整数，必须绕开 JSON 数字解析以防精度丢失
/// （miot `extractBigIntField`；Dart 的 jsonDecode 对超 int64 的整数
/// 同样会退化为 double）。
String? extractBigIntField(String jsonText, String field) {
  final match = RegExp('"$field"\\s*:\\s*(\\d+)').firstMatch(jsonText);
  return match?.group(1);
}

/// clientSign = base64(SHA1("nonce={nonce}&{ssecurity}"))。
String computeXiaomiClientSign(String nonce, String ssecurity) {
  final digest = sha1.convert(utf8.encode('nonce=$nonce&$ssecurity'));
  return base64.encode(digest.bytes);
}

/// 密码 MD5 后转大写（serviceLoginAuth2 的 hash 字段）。
String xiaomiPasswordHash(String password) =>
    md5.convert(utf8.encode(password)).toString().toUpperCase();

import 'dart:convert';
import 'dart:typed_data';

import 'mina_constants.dart';

/// 一个 sid 的 serviceToken 凭据。
class XiaomiServiceToken {
  const XiaomiServiceToken({
    required this.serviceToken,
    required this.ssecurity,
    required this.expiresAtMs,
  });

  final String serviceToken;
  final String ssecurity;

  /// 假定过期时刻（登录/刷新时刻 + [kServiceTokenValidHours] 小时）。
  final int expiresAtMs;

  bool isExpiredAt(int nowMs) => nowMs >= expiresAtMs;

  /// 剩余有效期低于主动刷新阈值（含已过期）。
  bool needsRefreshAt(int nowMs) =>
      expiresAtMs - nowMs < kTokenRefreshThresholdHours * 3600 * 1000;

  Map<String, Object?> toJson() => {
    'serviceToken': serviceToken,
    'ssecurity': ssecurity,
    'expiresAtMs': expiresAtMs,
  };

  factory XiaomiServiceToken.fromJson(Map<String, Object?> json) {
    return XiaomiServiceToken(
      serviceToken: json['serviceToken'] as String? ?? '',
      ssecurity: json['ssecurity'] as String? ?? '',
      expiresAtMs: (json['expiresAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 小米账号在本地保存的全部登录产物。
///
/// 只存 passToken 与各 sid 的 serviceToken，**不存密码**
/// （miot `XiaomiTokenInfo` 的对应物）。
class XiaomiTokenInfo {
  const XiaomiTokenInfo({
    required this.userId,
    required this.deviceId,
    required this.passToken,
    required this.services,
    required this.createdAtMs,
  });

  final String userId;

  /// 客户端自生成并长期保持的设备 ID（登录一致性关键）。
  final String deviceId;

  /// 长期凭据，用于免密续期 serviceToken。
  final String passToken;

  /// sid → 凭据（micoapi / xiaomiio …）。
  final Map<String, XiaomiServiceToken> services;

  final int createdAtMs;

  bool get isLoggedIn => userId.isNotEmpty && passToken.isNotEmpty;

  XiaomiServiceToken? service(String sid) => services[sid];

  XiaomiTokenInfo copyWith({
    String? userId,
    String? passToken,
    Map<String, XiaomiServiceToken>? services,
  }) {
    return XiaomiTokenInfo(
      userId: userId ?? this.userId,
      deviceId: deviceId,
      passToken: passToken ?? this.passToken,
      services: services ?? this.services,
      createdAtMs: createdAtMs,
    );
  }

  Map<String, Object?> toJson() => {
    'userId': userId,
    'deviceId': deviceId,
    'passToken': passToken,
    'services': {
      for (final entry in services.entries) entry.key: entry.value.toJson(),
    },
    'createdAtMs': createdAtMs,
  };

  factory XiaomiTokenInfo.fromJson(Map<String, Object?> json) {
    final rawServices = json['services'] as Map<String, Object?>? ?? const {};
    return XiaomiTokenInfo(
      userId: json['userId'] as String? ?? '',
      deviceId: json['deviceId'] as String? ?? '',
      passToken: json['passToken'] as String? ?? '',
      services: {
        for (final entry in rawServices.entries)
          entry.key: XiaomiServiceToken.fromJson(
            (entry.value as Map).cast<String, Object?>(),
          ),
      },
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  String encode() => jsonEncode(toJson());

  static XiaomiTokenInfo? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return XiaomiTokenInfo.fromJson(decoded.cast<String, Object?>());
      }
    } catch (_) {
      // 落盘数据损坏时按未登录处理。
    }
    return null;
  }
}

/// MiNA 设备（device_list 的一行）。
class MinaDevice {
  const MinaDevice({
    required this.deviceId,
    required this.miotDid,
    required this.name,
    required this.alias,
    required this.model,
    required this.hardware,
    required this.presence,
    this.serialNumber,
    this.mac,
    this.ssid,
    this.ip,
    this.rom,
  });

  /// MiNA 设备 ID，ubus 请求用它（API 字段 `deviceID`）。
  final String deviceId;

  /// MIoT 的 did，走 MIoT 签名通道时用它（API 字段 `miotDID`），
  /// 与 [deviceId] 不是一回事。
  final String miotDid;

  final String name;
  final String alias;
  final String model;

  /// 型号代码（如 LX06），所有按型号分支的依据。
  final String hardware;

  /// 在线状态（服务端原样字符串）。
  final String presence;

  final String? serialNumber;
  final String? mac;
  final String? ssid;
  final String? ip;
  final String? rom;

  bool get isOnline => presence.toLowerCase() == 'online';

  factory MinaDevice.fromJson(Map<String, Object?> json) {
    String str(String key) => json[key]?.toString() ?? '';
    String? optStr(String key) {
      final v = json[key]?.toString();
      return v == null || v.isEmpty ? null : v;
    }

    return MinaDevice(
      deviceId: str('deviceID'),
      miotDid: str('miotDID'),
      name: str('name'),
      alias: str('alias'),
      model: str('model'),
      hardware: str('hardware'),
      presence: str('presence'),
      serialNumber: optStr('serialNumber'),
      mac: optStr('mac'),
      ssid: optStr('ssid'),
      ip: optStr('ip'),
      rom: optStr('rom'),
    );
  }
}

/// ubus 响应：外层是云端受理结果，`data.code` 才是设备侧结果，
/// 两层必须分开判定（miot `UbusResponse` + `isDeviceResultOK`）。
class UbusResult {
  const UbusResult({required this.code, this.message, this.data});

  /// 外层 code：0 = 云端受理。
  final int code;
  final String? message;

  /// 解码后的 data（Map / List / 标量 / null）。
  final Object? data;

  /// 设备侧 code（data 为 Map 且含 code 时）。
  int? get deviceCode {
    final d = data;
    if (d is Map && d['code'] is num) return (d['code'] as num).toInt();
    return null;
  }

  /// `data.device_data` 里的 code（device_data 可能是 Map 或 JSON 字符串）。
  int? get deviceDataCode {
    final d = data;
    if (d is! Map) return null;
    Object? dd = d['device_data'];
    if (dd is String) {
      try {
        dd = jsonDecode(dd);
      } catch (_) {
        return null;
      }
    }
    if (dd is Map && dd['code'] is num) return (dd['code'] as num).toInt();
    return null;
  }

  bool get isCloudAccepted => code == 0;

  /// 云端受理且设备侧未拒绝。
  bool get isDeviceOk {
    if (!isCloudAccepted) return false;
    final dc = deviceCode;
    return dc == null || dc == 0;
  }

  /// 外层 101 + device_data 3012：云端没等到设备回执，
  /// 指令往往已经生效，**绝不能当失败重发**（miot ttsAcceptance）。
  bool get isAmbiguousTimeout => code == 101 && deviceDataCode == 3012;

  factory UbusResult.fromJson(Map<String, Object?> json) {
    return UbusResult(
      code: (json['code'] as num?)?.toInt() ?? -1,
      message: json['message']?.toString(),
      data: json['data'],
    );
  }
}

/// 播放状态（player_get_play_status 的 data.info 解析结果）。
class MinaPlayerStatus {
  const MinaPlayerStatus({
    required this.statusCode,
    this.volume,
    this.positionMs,
    this.durationMs,
    this.audioId,
  });

  /// 原始 status：1=播放中，2=暂停，0=停止（个别型号播完返回 3）。
  final int statusCode;
  final int? volume;

  /// 流内位置 / 流总长，单位毫秒（带 seek 的流只是流内偏移）。
  final int? positionMs;
  final int? durationMs;

  /// 当前媒体的 audio_id（play_song_detail.audio_id）；没有该字段
  /// 或为空时为 null（归属未知，不能据此判外来）。
  final String? audioId;

  bool get isPlaying => statusCode == 1;
  bool get isPaused => statusCode == 2;

  /// 0/2/3 都视为未在播放（miot device_state 的 idle 判定）。
  bool get isIdle => statusCode != 1;

  /// 在播的确定不是我们推播的媒体（TrackFerry `foreign` 判定：
  /// Playing && AudioID 非空 && AudioID != OurAudioID）。
  /// 归属只认 audio_id：position/status 本身区分不了是谁在播，
  /// 原生小爱的播放曾因此被误记为接管成功。
  bool get isForeignPlayback =>
      isPlaying &&
      audioId != null &&
      audioId!.isNotEmpty &&
      audioId != kDefaultMusicAudioId;

  static MinaPlayerStatus? tryParseInfo(Object? data) {
    if (data is! Map) return null;
    final info = data['info'];
    if (info is! String || info.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(info);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final status = decoded['status'];
    if (status is! num) return null;
    final detail = decoded['play_song_detail'];
    int? position;
    int? duration;
    String? audioId;
    if (detail is Map) {
      position = (detail['position'] as num?)?.toInt();
      duration = (detail['duration'] as num?)?.toInt();
      // audio_id 在蓝本里以 JSON 数字到达（json.Number），也可能是
      // 字符串；统一 toString，空串归一为 null（归属未知）。
      final rawAudioId = detail['audio_id']?.toString();
      if (rawAudioId != null && rawAudioId.isNotEmpty) audioId = rawAudioId;
    }
    return MinaPlayerStatus(
      statusCode: status.toInt(),
      volume: (decoded['volume'] as num?)?.toInt(),
      positionMs: position,
      durationMs: duration,
      audioId: audioId,
    );
  }
}

/// 一条对话记录里的一个回答。
class ConversationAnswer {
  const ConversationAnswer({required this.type, this.ttsText});

  /// 如 TTS / LLM / AUDIO。
  final String type;

  /// type=TTS 时的回答文本。
  final String? ttsText;
}

/// 一条小爱对话记录（userprofile conversation 接口）。
class ConversationRecord {
  const ConversationRecord({
    required this.timeMs,
    required this.query,
    required this.answers,
    this.requestId,
  });

  /// 上游请求 id（蓝本 internal/xiaomi/client.go Record.RequestID，
  /// JSON 字段 `requestId`）；某些固件为空，此时为 null。
  /// 有值时是首选去重键（蓝本 observe.handle 的 RequestKey）。
  final String? requestId;

  /// 服务端毫秒时间戳，去重基线必须用它，不能用本地时钟。
  final int timeMs;

  /// 用户原话。
  final String query;

  final List<ConversationAnswer> answers;

  /// 第一个 TTS 回答的文本，没有时为空串（miot 的 AskMessage 转换）。
  String get ttsAnswerText {
    for (final answer in answers) {
      if (answer.type == 'TTS' && answer.ttsText != null) {
        return answer.ttsText!;
      }
    }
    return '';
  }

  factory ConversationRecord.fromJson(Map<String, Object?> json) {
    final rawAnswers = json['answers'];
    final answers = <ConversationAnswer>[];
    if (rawAnswers is List) {
      for (final raw in rawAnswers) {
        if (raw is! Map) continue;
        final map = raw.cast<String, Object?>();
        String? ttsText;
        final tts = map['tts'];
        if (tts is Map) ttsText = tts['text']?.toString();
        answers.add(
          ConversationAnswer(
            type: map['type']?.toString() ?? '',
            ttsText: ttsText,
          ),
        );
      }
    }
    // requestId 归一：toString 后空串视为没有（蓝本：empty on some firmware）。
    final rawRequestId = json['requestId']?.toString();
    return ConversationRecord(
      timeMs: (json['time'] as num?)?.toInt() ?? 0,
      query: json['query']?.toString() ?? '',
      answers: answers,
      requestId: (rawRequestId == null || rawRequestId.isEmpty)
          ? null
          : rawRequestId,
    );
  }
}

/// 对话记录拉取结果：必须区分「拉取失败」与「成功但无记录」
/// （miot 的 null vs [] 语义）。
sealed class ConversationFetchResult {
  const ConversationFetchResult();
}

class ConversationFetchSuccess extends ConversationFetchResult {
  const ConversationFetchSuccess(this.records);

  /// 可能为空列表（确实没有记录）。
  final List<ConversationRecord> records;
}

class ConversationFetchFailure extends ConversationFetchResult {
  const ConversationFetchFailure(this.reason);

  final String reason;
}

/// 二次验证方式。
enum XiaomiVerifyKind { phone, email }

/// 账密登录的分步结果：验证码 / 短信验证以类型化状态返回给调用方，
/// 调用方提交答案后续跑同一次登录（客户端不弹任何 UI）。
sealed class MinaLoginResult {
  const MinaLoginResult();
}

class MinaLoginSuccess extends MinaLoginResult {
  const MinaLoginSuccess(this.tokens);

  final XiaomiTokenInfo tokens;
}

class MinaLoginNeedCaptcha extends MinaLoginResult {
  const MinaLoginNeedCaptcha({this.imageBytes, this.error});

  /// 验证码图片字节；取图失败时为 null（[error] 说明原因）。
  final Uint8List? imageBytes;
  final String? error;
}

class MinaLoginNeedVerify extends MinaLoginResult {
  const MinaLoginNeedVerify(this.kind);

  final XiaomiVerifyKind kind;
}

class MinaLoginFailure extends MinaLoginResult {
  const MinaLoginFailure(this.message, {this.code});

  final String message;
  final int? code;
}

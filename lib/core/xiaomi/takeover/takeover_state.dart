/// 接管状态模型（纯 Dart，UI 层经 Riverpod 适配消费）。
library;

/// 接管服务的总体状态。
enum TakeoverPhase {
  /// 未启用（未登录 / 未选设备 / 开关关）。
  disabled,

  /// 监听中。
  listening,

  /// 异常（如登录态失效），等待用户处理。
  error,
}

/// 一次点歌接管的记录（供 UI「最近接管」展示）。
class TakeoverRecord {
  const TakeoverRecord({
    required this.query,
    required this.title,
    required this.artist,
    required this.atMs,
    required this.success,
    this.detail,
    this.sourceName,
    this.qualityLabel,
    this.upstreamHostPath,
    this.viaProxy = false,
    this.fetched = false,
    this.stageMs = const {},
  });

  /// 触发这次接管的语音原话。
  final String query;

  /// 实际推给音箱的歌（未命中时为用户所点歌名）。
  final String title;
  final String artist;

  /// 发生时刻（服务端对话时间戳口径的墙钟毫秒，取本地记录时刻）。
  final int atMs;

  final bool success;

  /// 失败原因等补充说明（如「未找到可播版本」）。
  final String? detail;

  /// 命中的音源名（供记录展示）。
  final String? sourceName;

  /// 命中的音质（供记录展示）。
  final String? qualityLabel;

  /// 上游 URL 的 host+path，不含签名参数（供记录展示 / 排查）。
  final String? upstreamHostPath;

  /// 是否经局域网代理推播。
  final bool viaProxy;

  /// 音箱是否已从代理取流。
  final bool fetched;

  /// 阶段耗时（毫秒）：mute / resolve / push / confirm，
  /// 供排查接管时序（内部字段，UI 不强制展示）。
  final Map<String, int> stageMs;
}

/// 接管记录最多保留条数。
const int kMaxTakeoverRecords = 10;

/// 把 [record] 插到 [current] 最前（新→旧），截断到 [kMaxTakeoverRecords]
/// 条，返回不可变新列表（不改入参）。
List<TakeoverRecord> prependTakeoverRecord(
  List<TakeoverRecord> current,
  TakeoverRecord record,
) {
  return List<TakeoverRecord>.unmodifiable(
    [record, ...current].take(kMaxTakeoverRecords),
  );
}

/// 音箱当前在播（由接管推播）的一首。
class SpeakerNowPlaying {
  const SpeakerNowPlaying({
    required this.title,
    required this.artist,
    required this.queueIndex,
    required this.queueLength,
  });

  final String title;
  final String artist;

  /// 在音箱队列中的序号（0 起）。
  final int queueIndex;

  /// 音箱队列总长（含当前这首）。
  final int queueLength;
}

/// 接管状态快照（Riverpod 层据此渲染设置页）。
class XiaoaiTakeoverState {
  const XiaoaiTakeoverState({
    this.phase = TakeoverPhase.disabled,
    this.deviceName,
    this.nowPlaying,
    this.lastRecord,
    this.records = const [],
    this.errorMessage,
    this.diagnosticLog = const [],
  });

  final TakeoverPhase phase;

  /// 目标音箱名（已选设备时）。
  final String? deviceName;

  final SpeakerNowPlaying? nowPlaying;
  final TakeoverRecord? lastRecord;

  /// 接管记录（新→旧，最多 [kMaxTakeoverRecords] 条）。
  final List<TakeoverRecord> records;
  final String? errorMessage;

  /// 诊断日志（旧→新，带时间戳；落盘环形缓冲的快照）。
  final List<String> diagnosticLog;

  XiaoaiTakeoverState copyWith({
    TakeoverPhase? phase,
    String? deviceName,
    SpeakerNowPlaying? nowPlaying,
    bool clearNowPlaying = false,
    TakeoverRecord? lastRecord,
    List<TakeoverRecord>? records,
    String? errorMessage,
    bool clearError = false,
    List<String>? diagnosticLog,
  }) {
    return XiaoaiTakeoverState(
      phase: phase ?? this.phase,
      deviceName: deviceName ?? this.deviceName,
      nowPlaying: clearNowPlaying ? null : (nowPlaying ?? this.nowPlaying),
      lastRecord: lastRecord ?? this.lastRecord,
      records: records ?? this.records,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      diagnosticLog: diagnosticLog ?? this.diagnosticLog,
    );
  }
}

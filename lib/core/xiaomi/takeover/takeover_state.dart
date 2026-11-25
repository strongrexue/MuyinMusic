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
    this.errorMessage,
  });

  final TakeoverPhase phase;

  /// 目标音箱名（已选设备时）。
  final String? deviceName;

  final SpeakerNowPlaying? nowPlaying;
  final TakeoverRecord? lastRecord;
  final String? errorMessage;

  XiaoaiTakeoverState copyWith({
    TakeoverPhase? phase,
    String? deviceName,
    SpeakerNowPlaying? nowPlaying,
    bool clearNowPlaying = false,
    TakeoverRecord? lastRecord,
    String? errorMessage,
    bool clearError = false,
  }) {
    return XiaoaiTakeoverState(
      phase: phase ?? this.phase,
      deviceName: deviceName ?? this.deviceName,
      nowPlaying: clearNowPlaying ? null : (nowPlaying ?? this.nowPlaying),
      lastRecord: lastRecord ?? this.lastRecord,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

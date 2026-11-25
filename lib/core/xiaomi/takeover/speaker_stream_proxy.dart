/// 音箱推播的局域网流接缝（TrackFerry `internal/stream` 的结构移植）。
///
/// 每个被推播的流都注册成一个带不可猜 token 的局域网 URL，音箱
/// 来取流本身就是接管落地的第一硬证据（推播回执与播放状态都不
/// 足以证明）。核心只认 [StreamHandle] 上的信号：取流、重取
/// （播完从头再来）、取流中断、从中续播——与蓝本 Handle 的
/// Fetched / Restarted / Lost / Resume 一一对应。
///
/// 蓝本没有「代理不可用就直推」的回退：流服务是硬前置，
/// [SpeakerStreamProxy.publish] 返回 null 即备歌失败，交给原生。
library;

/// 局域网流服务接口。
abstract interface class SpeakerStreamProxy {
  /// 把上游直链注册为局域网流，返回句柄；服务不可用（未启动 /
  /// 取不到局域网 IP）返回 null。
  ///
  /// [durationMs] 是歌曲时长（已知时传，用于重取间隔判定与
  /// watch 时钟），未知传 null。
  Future<StreamHandle?> publish(
    String upstreamUrl, {
    int? durationMs,
    String? label,
  });
}

/// 一个已注册的流（蓝本 `stream.Handle`）。
abstract interface class StreamHandle {
  /// 推给音箱的局域网 URL（`/stream/<32位hex>.mp3`）。
  String get url;

  /// 展示名（日志用）。
  String get label;

  /// 歌曲时长（毫秒），未知为 0。
  int get lengthMs;

  /// 音箱是否已来取过流（第一次请求即为真）。
  bool get fetched;

  /// 第一次取流的时刻（毫秒），未取为 null。
  int? get fetchedAtMs;

  /// 取流次数。
  int get fetchCount;

  /// 音箱是否在播完后又从头取了一遍（单曲循环的信号）：
  /// 首次取流后隔 [restartGap] 再来一次从头请求即为真。
  bool get restarted;

  /// 音箱是否没取完就断了：有过请求、当前无请求在途、
  /// 已取字节少于总字节（蓝本 `Handle.Lost`）。
  bool get lost;

  /// 从 [atMs] 处续播：返回新句柄与实际起始位置（毫秒）；
  /// 无法从中起播（蓝本 `ErrNoSeek`）返回 null，调用方从头重推。
  Future<({StreamHandle handle, int startMs})?> resume(int atMs);
}

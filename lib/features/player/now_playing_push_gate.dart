/// iOS 系统卡（MPNowPlayingInfoCenter）推送的纯决策逻辑。
///
/// 从 LiveActivityService 里拆出来单测：去重 key 的构成、key 落盘时机
/// （invoke 成功后才 commit）、seek 跳变检测、心跳开关判定都不依赖
/// 平台通道和 Riverpod，只在这里做决定，服务层负责执行。
class NowPlayingPushGate {
  NowPlayingPushGate({this.seekJumpThresholdMs = 2000});

  /// 位置与墙钟预期偏差超过这个值（毫秒）就判定为 seek 跳转，强制重推。
  final int seekJumpThresholdMs;

  String? _committedKey;
  String? _anchorTrackId;
  int _anchorPositionMs = 0;
  bool _anchorPlaying = false;
  DateTime? _anchorTime;

  /// 去重 key：artist 位是当前歌词行（歌词滚动靠它触发），liked 保证
  /// 五角星即时刷新，coverIdentity 保证封面就绪/更换后能补推。
  static String keyFor({
    required String trackId,
    required String artist,
    required bool playing,
    required bool liked,
    required String coverIdentity,
  }) {
    return [trackId, artist, playing, liked, coverIdentity].join('|');
  }

  /// 封面身份：本地文件路径优先（就绪即唯一），未就绪时用封面 URL 占位，
  /// 文件下好后身份从 URL 变路径，key 随之变化、补推自然放行。
  static String coverIdentity({
    required String artPath,
    required String coverUrl,
  }) {
    return artPath.isNotEmpty ? artPath : coverUrl;
  }

  /// 播放中心跳兜底重推的开关条件：功能开着、有曲目、正在播放。
  static bool heartbeatWanted({
    required bool enabled,
    required bool hasTrack,
    required bool playing,
  }) {
    return enabled && hasTrack && playing;
  }

  /// 这次推送尝试是否需要真正执行。纯判定，不记录任何状态：
  /// 返回 true 后由调用方执行 invoke，成功了再调 [commit] 落盘，
  /// 失败则下次同样的内容照样放行重试。
  bool decide({
    required String key,
    required String trackId,
    required int positionMs,
    required bool playing,
    bool force = false,
    DateTime? now,
  }) {
    if (force || key != _committedKey) return true;
    // key 没变也要防 seek：位置与「上次落盘位置 + 墙钟推进」对不上
    // 就是跳转，系统卡的 elapsed 还停在旧锚点，必须重推校正。
    final anchorTime = _anchorTime;
    if (_anchorTrackId != trackId || anchorTime == null) return false;
    var expected = _anchorPositionMs;
    if (_anchorPlaying) {
      expected += (now ?? DateTime.now()).difference(anchorTime).inMilliseconds;
    }
    return (positionMs - expected).abs() > seekJumpThresholdMs;
  }

  /// invoke 成功后落盘去重 key 与位置锚点。
  void commit({
    required String key,
    required String trackId,
    required int positionMs,
    required bool playing,
    DateTime? now,
  }) {
    _committedKey = key;
    _anchorTrackId = trackId;
    _anchorPositionMs = positionMs;
    _anchorPlaying = playing;
    _anchorTime = now ?? DateTime.now();
  }

  /// 开关切换/清卡后重置，下一次推送无条件放行。
  void reset() {
    _committedKey = null;
    _anchorTrackId = null;
    _anchorTime = null;
  }
}

/// 40ms 位置 tick 是否值得进系统卡推送队列的纯判定。
///
/// 播放器每 40ms 推一次位置，之前每次都无条件进队：队列里常年排着
/// 25 个/秒的无操作项，每项还要先查一次 SQLite 才轮到去重丢弃，
/// 真正的歌词行推送被堵在后面，锁屏/车机换行总慢半拍。
/// 只有歌词行、播放态（播/停/seek/换歌）、喜欢变化才进队；
/// 纯位置推进由 2 秒心跳兜底（心跳直接 force 进队，不走这里）。
class NowPlayingTickGate {
  NowPlayingTickGate({this.seekJumpThresholdMs = 2000});

  /// 位置与墙钟预期偏差超过这个值（毫秒）就判定为 seek 跳转，强制进队。
  final int seekJumpThresholdMs;

  String? _trackId;
  String? _artist;
  bool? _playing;
  bool? _liked;
  int _positionMs = 0;
  DateTime? _time;
  bool _wasPlaying = false;

  /// 这次 tick 是否需要进队。每次调用都会刷新位置锚点（即使返回 false），
  /// 这样两次 tick 之间的 seek 仍能靠「位置与墙钟预期偏差」检出。
  bool shouldEnqueue({
    required String trackId,
    required String artist,
    required bool playing,
    required bool liked,
    required int positionMs,
    DateTime? now,
  }) {
    final t = now ?? DateTime.now();
    final changed = _trackId != trackId ||
        _artist != artist ||
        _playing != playing ||
        _liked != liked;
    var seek = false;
    if (!changed && _time != null) {
      var expected = _positionMs;
      if (_wasPlaying) {
        expected += t.difference(_time!).inMilliseconds;
      }
      seek = (positionMs - expected).abs() > seekJumpThresholdMs;
    }
    _trackId = trackId;
    _artist = artist;
    _playing = playing;
    _liked = liked;
    _positionMs = positionMs;
    _time = t;
    _wasPlaying = playing;
    return changed || seek;
  }

  /// 开关切换/清卡后重置，下一次 tick 无条件进队。
  void reset() {
    _trackId = null;
    _artist = null;
    _playing = null;
    _liked = null;
    _time = null;
    _wasPlaying = false;
  }
}

/// 每曲目已解析的封面本地路径（纯内存）：去重 key 的封面身份先用它算，
/// 命中就不必查 SQLite；解析到新路径后回填，下一次 key 随之变化补推。
/// 与 audio_service 的 ArtworkFileMemo 同构，只是 key 是曲目 id + 封面 URL。
class NowPlayingArtMemo {
  final _entries = <String, _NowPlayingArtMemoEntry>{};

  /// [trackId] 的封面已解析为 [artUri] 对应的本地文件时返回路径，否则 null。
  String? lookup(String trackId, String artUri) {
    final entry = _entries[trackId];
    if (entry == null || entry.artUri != artUri) return null;
    return entry.filePath;
  }

  /// 记录 [trackId] 的封面文件路径（只留当前曲目，换歌即清）。
  void store(String trackId, String artUri, String filePath) {
    _entries
      ..clear()
      ..[trackId] = _NowPlayingArtMemoEntry(artUri, filePath);
  }
}

class _NowPlayingArtMemoEntry {
  const _NowPlayingArtMemoEntry(this.artUri, this.filePath);

  final String artUri;
  final String filePath;
}

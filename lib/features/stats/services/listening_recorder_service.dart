import 'package:flutter/foundation.dart';

import '../data/stats_db_constants.dart';
import '../data/stats_db_helper.dart';
import '../models/stats_models.dart';

/// 听歌报告埋点（单例），移植自飞牛音乐 ListeningRecorderService。
///
/// 与 [StatsService] 的分工：
/// - StatsService 维护聚合（song_stats/listening_days…，永久保留、容量有界）；
/// - 本服务维护原始事件（report_events），每次「单曲播放 session」一条记录，
///   用于时段/连续/深夜等聚合表覆盖不了的洞察，按 90 天滚动窗口保留。
///
/// 累计在播放回调中完成，写库通过独立 [_drain] 队列事务批量进行，避免阻塞播放。
/// 不依赖 GetX：直接以 Dart 单例 [instance] 暴露（与飞牛语义一致）。
class ListeningRecorderService {
  ListeningRecorderService._internal();

  static final ListeningRecorderService instance =
      ListeningRecorderService._internal();

  /// 原始事件保留窗口：只保留最近 90 天。
  static const Duration retentionWindow = Duration(days: 90);

  /// 连续播放累计窗口：距上次 tick 超过该时长按上限截断（与 StatsService 的
  /// 10s 上限一致，避免 App 休眠/切后台产生超大 delta）。
  static const Duration maxTickGap = Duration(seconds: 10);

  String? _currentSongId;
  StatsSong? _currentSong;
  int _sessionStartMs = 0;
  int _sessionEndMs = 0;
  int _playMs = 0;
  int _durationMs = 0;
  DateTime? _lastTickAt;

  bool _flushRunning = false;

  /// 收到播放快照，累计当前歌曲的播放时长。
  void onSnapshot(PlaybackSnapshot snapshot) {
    final song = snapshot.song;
    final now = DateTime.now();

    // 歌曲变化：结束上一个 session（若有）并切换到新歌。
    if (_currentSongId != song?.id) {
      if (_currentSongId != null) {
        _finalizeCurrent();
      }
      _currentSongId = song?.id;
      _currentSong = song;
      _sessionStartMs = now.millisecondsSinceEpoch;
      _sessionEndMs = _sessionStartMs;
      _playMs = 0;
      _durationMs = snapshot.durationMs ?? 0;
      _lastTickAt = now;
      if (song == null) return;
    }

    if (!snapshot.isPlaying || song == null) {
      _finalizeCurrent();
      _lastTickAt = null;
      return;
    }

    // 播放中刷新时长（播放器可能在切歌后补发 duration）。
    _durationMs = snapshot.durationMs ?? _durationMs;
    final last = _lastTickAt;
    _lastTickAt = now;
    if (last == null) return;
    var deltaMs = now.difference(last).inMilliseconds;
    if (deltaMs <= 0) return;
    if (deltaMs > maxTickGap.inMilliseconds) {
      deltaMs = maxTickGap.inMilliseconds;
    }
    _playMs += deltaMs;
    _sessionEndMs = now.millisecondsSinceEpoch;
  }

  /// 标记当前 session 为「完整播完」。
  void markCompleted() {
    if (_currentSongId == null) return;
    _finalizeCurrent(completed: true);
  }

  /// 把当前 session 落库（完整播完或离开歌曲/暂停时）。
  void flush() {
    _finalizeCurrent();
    _pruneIfNeeded();
  }

  /// 生命周期兜底：App 切后台/被杀时调用。
  void onLifecyclePause() {
    flush();
  }

  void _finalizeCurrent({bool completed = false}) {
    final songId = _currentSongId;
    final song = _currentSong;
    if (songId == null || song == null) return;
    final startMs = _sessionStartMs;
    final endMs = _sessionEndMs;
    final playMs = _playMs;
    final durationMs = _durationMs;
    _currentSongId = null;
    _currentSong = null;
    _playMs = 0;
    if (playMs <= 0) return;
    _enqueueInsert(
      dayKey: _dayKey(DateTime.fromMillisecondsSinceEpoch(endMs)),
      hour: DateTime.fromMillisecondsSinceEpoch(endMs).hour,
      songId: songId,
      songTitle: song.title,
      artistsJson: song.artist,
      albumJson: song.album,
      coverId: song.coverUrl ?? '',
      durationMs: durationMs,
      playMs: playMs,
      completed: completed,
      sessionStartMs: startMs,
      sessionEndMs: endMs,
    );
  }

  /// 逐条入队写库。写库与累计分离：累计在播放线程高频调用，写库用独立队列
  /// 合并，避免 DB 竞争阻塞播放。
  final List<Map<String, dynamic>> _pending = [];

  void _enqueueInsert({
    required String dayKey,
    required int hour,
    required String songId,
    required String songTitle,
    required String artistsJson,
    required String albumJson,
    required String coverId,
    required int durationMs,
    required int playMs,
    required bool completed,
    required int sessionStartMs,
    required int sessionEndMs,
  }) {
    _pending.add({
      'dayKey': dayKey,
      'hour': hour,
      'songId': songId,
      'songTitle': songTitle,
      'artistsJson': artistsJson,
      'albumJson': albumJson,
      'coverId': coverId,
      'durationMs': durationMs,
      'playMs': playMs,
      'completed': completed ? 1 : 0,
      'sessionStartMs': sessionStartMs,
      'sessionEndMs': sessionEndMs,
    });
    _drain();
  }

  Future<void> _drain() async {
    if (_flushRunning) return;
    final batch = List<Map<String, dynamic>>.from(_pending);
    if (batch.isEmpty) return;
    _pending.clear();
    _flushRunning = true;
    try {
      final db = await StatsDbHelper.instance.database;
      await db.transaction((txn) async {
        for (final row in batch) {
          await txn.insert(StatsDbConstants.tableReportEvents, row);
        }
      });
      // 写入后检查滚动清理（惰性，不必每次执行）
      _pruneIfNeeded();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ListeningRecorderService drain failed: $e');
      }
    } finally {
      _flushRunning = false;
    }
  }

  String _dayKey(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// 惰性滚动清理：距上次清理超过 retentionWindow 才执行一次，避免每次写都
  /// 全表扫描。
  DateTime? _lastPruneAt;
  bool _pruneRunning = false;

  void _pruneIfNeeded() {
    if (_pruneRunning) return;
    final now = DateTime.now();
    final last = _lastPruneAt;
    if (last != null && now.difference(last) < retentionWindow) return;
    _lastPruneAt = now;
    _pruneRunning = true;
    _prune();
  }

  Future<void> _prune() async {
    try {
      final db = await StatsDbHelper.instance.database;
      final cutoff =
          DateTime.now().subtract(retentionWindow).millisecondsSinceEpoch;
      await db.delete(
        StatsDbConstants.tableReportEvents,
        where: 'sessionEndMs < ?',
        whereArgs: [cutoff],
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ListeningRecorderService prune failed: $e');
      }
    } finally {
      _pruneRunning = false;
    }
  }
}

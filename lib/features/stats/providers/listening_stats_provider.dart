import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/stats_models.dart';
import '../services/stats_service.dart';

/// 首页听歌统计卡片的聚合数据。
class ListeningStatsSummary {
  const ListeningStatsSummary({
    required this.totalListenMs,
    required this.totalPlayCount,
    required this.monthListenMs,
    required this.monthActiveDays,
    required this.topSong,
    required this.topSongStat,
    required this.recentSongs,
  });

  /// 累计收听时长（毫秒）。
  final int totalListenMs;

  /// 累计播放次数（单曲 >=30s 记一次）。
  final int totalPlayCount;

  /// 本月收听时长（毫秒）。
  final int monthListenMs;

  /// 本月有收听记录的天数。
  final int monthActiveDays;

  /// Top1 歌曲元数据（可能为 null）。
  final StatsSong? topSong;

  /// Top1 歌曲的统计数据（可能为 null）。
  final SongListeningStat? topSongStat;

  /// 最近播放的前若干首（含元数据与统计）。
  final List<({StatsSong song, SongListeningStat stat})> recentSongs;

  static const empty = ListeningStatsSummary(
    totalListenMs: 0,
    totalPlayCount: 0,
    monthListenMs: 0,
    monthActiveDays: 0,
    topSong: null,
    topSongStat: null,
    recentSongs: [],
  );
}

/// 首页听歌统计摘要 Provider。
///
/// 一次性并发查询总体/本月/Top/最近数据并拼接歌曲元数据。
/// 埋点写入后可用 `ref.invalidate(listeningStatsProvider)` 刷新。
final listeningStatsProvider = FutureProvider<ListeningStatsSummary>((
  ref,
) async {
  final service = StatsService.instance;
  final now = DateTime.now();

  final results = await Future.wait([
    service.fetchTotalStats(),
    service.fetchMonthStats(year: now.year, month: now.month),
    service.fetchTopSongs(limit: 1),
    service.fetchRecentSongs(limit: 5),
    service.fetchSongMetadata(),
  ]);

  final totals = results[0] as StatsTotals;
  final monthDays = results[1] as List<DayListeningStat>;
  final topSongs = results[2] as List<SongListeningStat>;
  final recent = results[3] as List<SongListeningStat>;
  final metadata = results[4] as Map<String, StatsSong>;

  final monthListenMs = monthDays.fold<int>(0, (sum, d) => sum + d.listenMs);
  final activeDays = monthDays.where((d) => d.listenMs > 0).length;

  SongListeningStat? topStat;
  StatsSong? topSong;
  if (topSongs.isNotEmpty) {
    topStat = topSongs.first;
    topSong = metadata[topStat.songId];
  }

  final recentWithMeta = <({StatsSong song, SongListeningStat stat})>[];
  for (final stat in recent) {
    final song = metadata[stat.songId];
    if (song != null) {
      recentWithMeta.add((song: song, stat: stat));
    }
  }

  return ListeningStatsSummary(
    totalListenMs: totals.listenMs,
    totalPlayCount: totals.playCount,
    monthListenMs: monthListenMs,
    monthActiveDays: activeDays,
    topSong: topSong,
    topSongStat: topStat,
    recentSongs: recentWithMeta,
  );
});

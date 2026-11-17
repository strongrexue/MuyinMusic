import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/ui/app_sheet.dart';
import '../../../core/ui/cover_image_source.dart';
import '../../../core/ui/cover_placeholder.dart';
import '../models/stats_models.dart';
import '../providers/listening_stats_provider.dart';
import '../services/stats_service.dart';

/// 打开「完整听歌统计」弹窗。
Future<void> showListeningStatsSheet(BuildContext context) {
  return showAppSheet<void>(
    context: context,
    detents: prism.snapSheetDetents,
    maxHeight: 900,
    glass: true, // 玻璃底板，与正例弹窗保持一致（关闭时由入口降级）。
    builder: (_) => const ListeningStatsSheet(),
  );
}

/// 排行榜中的一条记录（歌曲 / 歌手 / 专辑通用）。
class _RankItem {
  const _RankItem({
    required this.name,
    required this.playCount,
    required this.listenMs,
    this.coverUrl,
  });

  final String name;
  final int playCount;
  final int listenMs;
  final String? coverUrl;
}

/// 趋势柱状图的一根柱子。
typedef _TrendBarData = ({
  DateTime date,
  String label,
  int listenMs,
  bool isToday,
});

/// 完整统计聚合数据。
class _StatsDetail {
  const _StatsDetail({
    required this.summary,
    required this.dayStats,
    required this.topSongs,
    required this.topArtists,
    required this.topAlbums,
  });

  final ListeningStatsSummary summary;
  final List<DayListeningStat> dayStats;
  final List<_RankItem> topSongs;
  final List<_RankItem> topArtists;
  final List<_RankItem> topAlbums;

  bool get isEmpty =>
      summary.totalListenMs <= 0 &&
      summary.totalPlayCount <= 0 &&
      dayStats.isEmpty &&
      topSongs.isEmpty &&
      topArtists.isEmpty &&
      topAlbums.isEmpty;
}

/// 一次性查询概览 / 每日趋势 / 三类排行榜所需的全部数据。
///
/// 歌手榜没有独立数据表，按歌曲元数据里的 artist 聚合；专辑优先取专用表
/// 的播放次数，再用歌曲元数据补齐时长。
final _statsDetailProvider = FutureProvider<_StatsDetail>((ref) async {
  final summary = await ref.watch(listeningStatsProvider.future);
  final service = StatsService.instance;
  final now = DateTime.now();

  final results = await Future.wait([
    service.fetchMonthStats(year: now.year, month: now.month),
    service.fetchTopSongs(limit: 50),
    service.fetchSongMetadata(),
    service.fetchRecentAlbums(limit: 50),
  ]);
  final dayStats = results[0] as List<DayListeningStat>;
  final songStats = results[1] as List<SongListeningStat>;
  final metadata = results[2] as Map<String, StatsSong>;
  final albumStats = results[3] as List<AlbumPlaybackStat>;

  // 歌曲榜：用元数据里的标题展示。
  final topSongs = <_RankItem>[];
  for (final stat in songStats) {
    final song = metadata[stat.songId];
    final title = song?.title.trim() ?? '';
    if (title.isEmpty) continue;
    topSongs.add(
      _RankItem(
        name: title,
        playCount: stat.playCount,
        listenMs: stat.listenMs,
        coverUrl: song?.coverUrl,
      ),
    );
  }

  // 专辑封面兜底：按专辑名从全部元数据里取一首歌的封面。
  final albumCoverMap = <String, String>{};
  for (final song in metadata.values) {
    final album = song.album.trim();
    final cover = song.coverUrl;
    if (album.isEmpty || cover == null || cover.isEmpty) continue;
    albumCoverMap.putIfAbsent(album, () => cover);
  }

  // 歌手榜：按 artist 聚合歌曲统计，同时记下该歌手一首歌的封面作头像。
  final artistMap =
      <String, ({int playCount, int listenMs, String? coverUrl})>{};
  final albumMap = <String, ({int playCount, int listenMs})>{};
  for (final stat in songStats) {
    final song = metadata[stat.songId];
    final artist = song?.artist.trim() ?? '';
    if (artist.isNotEmpty) {
      final cur = artistMap[artist];
      artistMap[artist] = (
        playCount: (cur?.playCount ?? 0) + stat.playCount,
        listenMs: (cur?.listenMs ?? 0) + stat.listenMs,
        coverUrl: cur?.coverUrl ?? song?.coverUrl,
      );
    }
    final album = song?.album.trim() ?? '';
    if (album.isNotEmpty) {
      final cur = albumMap[album] ?? (playCount: 0, listenMs: 0);
      albumMap[album] = (
        playCount: cur.playCount + stat.playCount,
        listenMs: cur.listenMs + stat.listenMs,
      );
    }
  }
  final topArtists = artistMap.entries
      .map(
        (e) => _RankItem(
          name: e.key,
          playCount: e.value.playCount,
          listenMs: e.value.listenMs,
          coverUrl: e.value.coverUrl,
        ),
      )
      .toList()
    ..sort(_compareRank);

  // 专辑榜：优先用专用表的播放次数，并从歌曲元数据补齐时长；
  // 若专用表为空，退化为按专辑聚合歌曲统计，避免留下空壳。
  final topAlbums = <_RankItem>[];
  for (final album in albumStats) {
    topAlbums.add(
      _RankItem(
        name: album.albumName,
        playCount: album.playCount,
        listenMs: albumMap[album.albumName]?.listenMs ?? 0,
        coverUrl: albumCoverMap[album.albumName],
      ),
    );
  }
  if (topAlbums.isEmpty) {
    topAlbums.addAll(
      albumMap.entries.map(
        (e) => _RankItem(
          name: e.key,
          playCount: e.value.playCount,
          listenMs: e.value.listenMs,
          coverUrl: albumCoverMap[e.key],
        ),
      ),
    );
    topAlbums.sort(_compareRank);
  }

  return _StatsDetail(
    summary: summary,
    dayStats: dayStats,
    topSongs: topSongs,
    topArtists: topArtists,
    topAlbums: topAlbums,
  );
});

int _compareRank(_RankItem a, _RankItem b) {
  final byCount = b.playCount.compareTo(a.playCount);
  return byCount != 0 ? byCount : b.listenMs.compareTo(a.listenMs);
}

/// 完整听歌统计弹窗。
class ListeningStatsSheet extends ConsumerStatefulWidget {
  const ListeningStatsSheet({super.key});

  @override
  ConsumerState<ListeningStatsSheet> createState() =>
      _ListeningStatsSheetState();
}

class _ListeningStatsSheetState extends ConsumerState<ListeningStatsSheet> {
  /// 趋势维度：0 = 最近 7 天，1 = 本月。
  int _trendMode = 0;

  /// 排行榜维度：0 = 歌曲，1 = 歌手，2 = 专辑。
  int _rankTab = 0;

  /// 趋势图当前选中的柱子下标（在 [trendBars] 中），null = 聚焦今天。
  int? _selectedTrend;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_statsDetailProvider);
    return AppSheetLayout(
      title: '听歌统计',
      subtitle: '你的专属音乐足迹',
      onClose: () => Navigator.of(context).maybePop(),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _emptyHint(context, '统计信息暂时无法显示'),
        data: (detail) {
          if (detail.isEmpty) {
            return _emptyHint(context, '还没有听歌记录，去听几首歌吧～');
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _overview(context, detail.summary),
                const SizedBox(height: 22),
                _sectionTitle(context, Icons.trending_up_rounded, '听歌趋势'),
                const SizedBox(height: 10),
                _trendSwitcher(context),
                const SizedBox(height: 12),
                _trendChart(context, detail.dayStats),
                const SizedBox(height: 22),
                _sectionTitle(context, Icons.leaderboard_rounded, '排行榜'),
                const SizedBox(height: 10),
                _rankSwitcher(context),
                const SizedBox(height: 8),
                _rankList(context, _currentRank(detail)),
              ],
            ),
          );
        },
      ),
    );
  }

  List<_RankItem> _currentRank(_StatsDetail detail) {
    switch (_rankTab) {
      case 1:
        return detail.topArtists;
      case 2:
        return detail.topAlbums;
      default:
        return detail.topSongs;
    }
  }

  Widget _emptyHint(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bar_chart_rounded, size: 40, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _overview(BuildContext context, ListeningStatsSummary summary) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          _metric(
            context,
            '累计收听',
            _durationText(summary.totalListenMs),
          ),
          _divider(context),
          _metric(context, '播放次数', '${summary.totalPlayCount} 次'),
          _divider(context),
          _metric(context, '本月活跃', '${summary.monthActiveDays} 天'),
        ],
      ),
    );
  }

  Widget _divider(BuildContext context) {
    return Container(
      width: 1,
      height: 34,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }

  Widget _metric(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, IconData icon, String title) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }

  Widget _trendSwitcher(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _segment(context, '最近 7 天', 0),
          _segment(context, '本月', 1),
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, String label, int mode) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _trendMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() {
          _trendMode = mode;
          _selectedTrend = null;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: selected ? scheme.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.08),
                      blurRadius: 4,
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// 把每日统计转换成趋势柱状图所需的数据。
  ///
  /// 7 天模式取最近 7 个自然日（含今天），用周几作标签；本月模式补满整月，
  /// 只在每月 1 号、每 5 天和今天给出数字标签，避免柱子过密时文字重叠。
  List<_TrendBarData> _trendBars(List<DayListeningStat> dayStats) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final byDay = <DateTime, int>{};
    for (final stat in dayStats) {
      final date = _parseDayKey(stat.dayKey);
      if (date == null) continue;
      byDay[date] = (byDay[date] ?? 0) + stat.listenMs;
    }

    const weekLabels = ['一', '二', '三', '四', '五', '六', '日'];
    final bars = <_TrendBarData>[];
    if (_trendMode == 0) {
      for (var i = 6; i >= 0; i--) {
        final date = today.subtract(Duration(days: i));
        bars.add(
          (
            date: date,
            label: weekLabels[date.weekday - 1],
            listenMs: byDay[date] ?? 0,
            isToday: i == 0,
          ),
        );
      }
    } else {
      final daysInMonth = DateUtils.getDaysInMonth(now.year, now.month);
      for (var day = 1; day <= daysInMonth; day++) {
        final date = DateTime(now.year, now.month, day);
        final isToday = day == now.day;
        final label = (day == 1 || day % 5 == 0 || isToday) ? '$day' : '';
        bars.add(
          (
            date: date,
            label: label,
            listenMs: byDay[date] ?? 0,
            isToday: isToday,
          ),
        );
      }
    }
    return bars;
  }

  Widget _trendChart(BuildContext context, List<DayListeningStat> dayStats) {
    final scheme = Theme.of(context).colorScheme;
    final bars = _trendBars(dayStats);
    final maxMs = bars.fold<int>(
      0,
      (max, bar) => bar.listenMs > max ? bar.listenMs : max,
    );
    if (bars.isEmpty || maxMs <= 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          '还没有这段时间的收听记录',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
      );
    }

    var selected = _selectedTrend ?? -1;
    if (selected < 0 || selected >= bars.length) {
      selected = bars.indexWhere((bar) => bar.isToday);
      if (selected < 0) selected = bars.length - 1;
    }
    final selectedBar = bars[selected];
    final hPad = bars.length <= 7 ? 10.0 : 1.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: RichText(
            text: TextSpan(
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              children: [
                TextSpan(text: '${_fullDateLabel(selectedBar.date)} · '),
                TextSpan(
                  text: _durationText(selectedBar.listenMs),
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < bars.length; i++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: hPad),
                  child: _trendBar(context, bars[i], i, i == selected, maxMs),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _trendBar(
    BuildContext context,
    _TrendBarData bar,
    int index,
    bool isSelected,
    int maxMs,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final frac = maxMs > 0 ? (bar.listenMs / maxMs).clamp(0.0, 1.0) : 0.0;
    final barHeight = 4.0 + frac * (120 - 8);
    final colors = isSelected
        ? [scheme.primary, scheme.primary.withValues(alpha: 0.7)]
        : [
            scheme.primary.withValues(alpha: 0.5),
            scheme.primary.withValues(alpha: 0.25),
          ];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _selectedTrend = index),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 120,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Spacer(),
                Container(
                  width: double.infinity,
                  height: barHeight,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: colors,
                    ),
                    borderRadius: BorderRadius.circular(6),
                    border: isSelected
                        ? Border.all(color: scheme.primary, width: 1.5)
                        : null,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 16,
            child: Text(
              bar.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: bar.isToday ? FontWeight.w700 : FontWeight.w400,
                color: bar.isToday ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rankSwitcher(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const labels = ['歌曲', '歌手', '专辑'];
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == labels.length - 1 ? 0 : 8),
              child: GestureDetector(
                onTap: () => setState(() => _rankTab = i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: _rankTab == i
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          _rankTab == i ? FontWeight.w600 : FontWeight.w400,
                      color: _rankTab == i
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _rankList(BuildContext context, List<_RankItem> items) {
    final scheme = Theme.of(context).colorScheme;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          '暂无此类排行榜数据',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
      );
    }
    final isArtist = _rankTab == 1;
    final shown = items.length > 10 ? items.sublist(0, 10) : items;
    return Column(
      children: [
        for (var i = 0; i < shown.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              children: [
                _rankCover(context, shown[i], i + 1, isArtist),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        shown[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '播放 ${shown[i].playCount} 次 · ${_durationText(shown[i].listenMs)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 44×44 排行榜封面，左上角叠名次圆标；歌手榜为圆形，其余为圆角方形。
  Widget _rankCover(BuildContext context, _RankItem item, int rank, bool isArtist) {
    final scheme = Theme.of(context).colorScheme;
    final radius = isArtist ? 22.0 : 8.0;
    final normalized = CoverImageSource.normalizeUrl(item.coverUrl, size: 96);
    final placeholder = _rankCoverPlaceholder(context, item.name, radius);

    final Widget cover;
    if (normalized == null || normalized.isEmpty) {
      cover = placeholder;
    } else {
      cover = CachedNetworkImage(
        imageUrl: normalized,
        httpHeaders: CoverImageSource.headersFor(normalized),
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        placeholder: (_, _) => CoverLoadingSkeleton(),
        errorWidget: (_, _, _) => placeholder,
      );
    }
    final clipped = isArtist
        ? ClipOval(child: cover)
        : ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: cover,
          );

    final badgeColor = rank <= 3 ? scheme.primary : scheme.surfaceContainerHighest;
    final badgeTextColor =
        rank <= 3 ? scheme.onPrimary : scheme.onSurfaceVariant;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        clipped,
        Positioned(
          top: -2,
          left: -2,
          child: Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: badgeColor,
              border: Border.all(color: scheme.surface, width: 1.5),
            ),
            child: Text(
              '$rank',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                height: 1,
                fontWeight: FontWeight.w700,
                color: badgeTextColor,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 封面占位：底色 + 名称首字母（空名显示 '?'）。
  Widget _rankCoverPlaceholder(BuildContext context, String name, double radius) {
    final scheme = Theme.of(context).colorScheme;
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed.substring(0, 1).toUpperCase();
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: scheme.primary.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  /// 毫秒转「X 小时 X 分」中文文案。
  static String _durationText(int ms) {
    if (ms <= 0) return '0 分钟';
    final minutes = ms ~/ 60000;
    final hours = minutes ~/ 60;
    final restMinutes = minutes % 60;
    if (hours > 0) {
      return restMinutes > 0 ? '$hours 小时 $restMinutes 分' : '$hours 小时';
    }
    return '$minutes 分钟';
  }

  /// 解析形如 yyyy-MM-dd 的日期键，失败返回 null。
  static DateTime? _parseDayKey(String dayKey) {
    final parts = dayKey.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  /// 趋势图顶部的完整日期标签：形如「11月17日 周一」。
  static String _fullDateLabel(DateTime date) {
    const weekLabels = ['一', '二', '三', '四', '五', '六', '日'];
    return '${date.month}月${date.day}日 周${weekLabels[date.weekday - 1]}';
  }
}

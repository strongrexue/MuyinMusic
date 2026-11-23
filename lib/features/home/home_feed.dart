import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/music_api.dart';
import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/models/online_collection_kind.dart';
import '../../core/models/search_category.dart';
import '../../core/sdk/catalog_sdk.dart';
import '../../core/storage/settings_store.dart';
import '../../core/ui/app_breakpoints.dart';
import '../downloads/download_history_store.dart';
import '../playlists/playlist_models.dart';
import '../songs/liked_songs_store.dart';
import 'home_feed_logic.dart';
import 'recent_plays_store.dart';

/// 首页货架条数按内容可用宽度决定：Expanded 起 36 首，其余 12 首，全平台一致。
int homeShelfCountForWidth(double width) =>
    AppBreakpoints.isExpanded(width) ? 36 : 12;

/// Day number used to rotate the daily mix; the shelf only changes at midnight.
int homeDayIndex(DateTime now) =>
    DateTime(now.year, now.month, now.day).difference(DateTime(2024)).inDays;

/// 缓存键按条数分桶：窗口跨断点时不会读到另一档的缓存。
String homeDailyCacheKey(MusicSource source, int count) =>
    'home_daily_picks_${source.code}_v2_c$count';

String homeGuessCacheKey(MusicSource source, String fingerprint, int count) =>
    'home_guess_${source.code}_${fingerprint}_c$count';

String homeGuessLastKey(MusicSource source, int count) =>
    'home_guess_last_${source.code}_c$count';

/// The home shelves use the first enabled source in the user's discovery
/// order instead of following whatever source the discovery tab last had
/// selected, so browsing around never reshuffles the home page.
MusicSource _homeFeedSource(Ref ref) {
  final settings = ref.watch(settingsProvider);
  for (final source in settings.discoverySourceOrder) {
    if (source != MusicSource.all &&
        settings.enabledSearchSources.contains(source)) {
      return source;
    }
  }
  return kDefaultDiscoverySourceOrder.first;
}

DownloadHistoryEntry? _entryFor(MusicInfo music, String queueId) {
  final entry = PlaylistTrack.fromMusicInfo(
    music,
  ).toQueueEntry(playlistId: queueId);
  if (entry == null) return null;
  return entry;
}

List<DownloadHistoryEntry> _entriesFor(List<MusicInfo> tracks, String queueId) {
  final seen = <String>{};
  final entries = <DownloadHistoryEntry>[];
  for (final track in tracks) {
    final entry = _entryFor(track, queueId);
    if (entry == null) continue;
    if (!seen.add(songIdentityKey(entry))) continue;
    entries.add(entry);
  }
  return entries;
}

List<DownloadHistoryEntry> _decodeEntries(Object? rows) {
  if (rows is! List) return const [];
  return [
    for (final row in rows)
      if (row is Map)
        DownloadHistoryEntry.fromJson(Map<String, dynamic>.from(row)),
  ];
}

/// 「每日推荐」：每天从当前音源的多个榜单混采，再按本地口味（喜欢+最近播放的
/// 歌手权重）重排，剔除已经喜欢/听过的歌；结果按天缓存。
final dailyPicksProvider = FutureProvider.autoDispose
    .family<List<DownloadHistoryEntry>, int>((ref, count) async {
      final api = ref.watch(musicApiProvider);
      final source = _homeFeedSource(ref);
      final prefs = ref.watch(sharedPreferencesProvider);
      final liked = ref.watch(likedSongsProvider);
      final recent = ref.watch(recentPlaysProvider);
      final day = homeDayIndex(DateTime.now());
      final cacheKey = homeDailyCacheKey(source, count);

      final cached = prefs.getString(cacheKey);
      if (cached != null && cached.isNotEmpty) {
        try {
          final decoded = jsonDecode(cached);
          if (decoded is Map && decoded['day'] == day) {
            final entries = _decodeEntries(decoded['entries']);
            if (entries.isNotEmpty) {
              return List<DownloadHistoryEntry>.unmodifiable(entries);
            }
          }
        } catch (_) {
          // A stale or corrupt cache just falls through to the network.
        }
      }

      final boards = await api.getLeaderboards(source);
      if (boards.isEmpty) return const [];
      // Rotate the starting board by day so the mix drifts over the week,
      // but always draw from several boards instead of a single chart.
      final start = day % boards.length;
      final rotated = [
        for (var index = 0; index < boards.length; index++)
          boards[(start + index) % boards.length],
      ];
      final seen = <String>{
        for (final entry in [...liked, ...recent]) songIdentityKey(entry),
      };
      final pool = <DailyCandidate>[];
      var fetchedBoards = 0;
      for (final board in rotated) {
        if (fetchedBoards >= 6) break;
        fetchedBoards++;
        try {
          final detail = await api.getLeaderboard(
            source: source,
            boardId: board.boardId,
            maxTracks: 20,
          );
          final entries = _entriesFor(detail.tracks, 'home-daily');
          for (var index = 0; index < entries.length; index++) {
            final entry = entries[index];
            if (!seen.add(songIdentityKey(entry))) continue;
            pool.add(
              DailyCandidate(
                entry: entry,
                boardKey: board.key,
                rank: index,
                boardSize: entries.length,
              ),
            );
          }
        } catch (_) {
          // Skipping a broken board keeps the mix alive with the others.
        }
      }
      if (pool.isEmpty) return const [];
      final weights = buildArtistWeights(recent: recent, liked: liked);
      final picks = selectDailyPicks(
        pool: pool,
        weights: weights,
        count: count,
      );
      if (picks.isEmpty) return const [];
      // A clearly partial result (some boards failed) is shown but not
      // locked into the day cache, so the next visit can retry for a full one.
      if (picks.length * 2 >= count) {
        await prefs.setString(
          cacheKey,
          jsonEncode({
            'day': day,
            'entries': [for (final entry in picks) entry.toJson()],
          }),
        );
      }
      return List<DownloadHistoryEntry>.unmodifiable(picks);
    });

/// 「猜你喜欢」：用最近播放（全量）和喜欢（全量）里的歌手权重取歌——优先走
/// 歌手维度接口，否则用搜索并按歌手字段硬过滤；排除已听/已喜欢的歌，名额按
/// 权重配额分配，结果按口味指纹缓存。没有任何听歌信号时回退到热门榜单切片。
final guessYouLikeProvider = FutureProvider.autoDispose
    .family<List<DownloadHistoryEntry>, int>((ref, count) async {
      final api = ref.watch(musicApiProvider);
      final source = _homeFeedSource(ref);
      final prefs = ref.watch(sharedPreferencesProvider);
      final liked = ref.watch(likedSongsProvider);
      final recent = ref.watch(recentPlaysProvider);
      final weights = buildArtistWeights(recent: recent, liked: liked);
      // count 与三个缓存键在加载开始时一并捕获，await 之后只写回捕获的键。
      final lastKey = homeGuessLastKey(source, count);

      List<DownloadHistoryEntry> lastResort() {
        final raw = prefs.getString(lastKey);
        if (raw == null || raw.isEmpty) return const [];
        try {
          final entries = _decodeEntries(jsonDecode(raw));
          if (entries.isNotEmpty) {
            return List<DownloadHistoryEntry>.unmodifiable(entries);
          }
        } catch (_) {
          // A corrupt fallback cache is the same as no cache.
        }
        return const [];
      }

      if (weights.isEmpty) {
        try {
          final boards = await api.getLeaderboards(source);
          if (boards.isEmpty) return lastResort();
          final hot = boards.firstWhere(
            (board) => board.name.contains('热歌') || board.name.contains('热门'),
            orElse: () => boards.first,
          );
          final detail = await api.getLeaderboard(
            source: source,
            boardId: hot.boardId,
            maxTracks: count,
          );
          final entries = _entriesFor(
            detail.tracks,
            'home-guess',
          ).take(count).toList(growable: false);
          if (entries.isEmpty) return lastResort();
          return List<DownloadHistoryEntry>.unmodifiable(entries);
        } catch (_) {
          return lastResort();
        }
      }

      final fingerprint = artistFingerprint(weights);
      final cacheKey = homeGuessCacheKey(source, fingerprint, count);
      final cached = prefs.getString(cacheKey);
      if (cached != null && cached.isNotEmpty) {
        try {
          final entries = _decodeEntries(jsonDecode(cached));
          if (entries.isNotEmpty) {
            return List<DownloadHistoryEntry>.unmodifiable(entries);
          }
        } catch (_) {
          // A corrupt cache just falls through to a fresh computation.
        }
      }

      try {
        final ranked = rankArtists(weights);
        final quotas = allocateArtistQuotas(ranked: ranked, total: count);
        final seen = <String>{
          for (final entry in [...liked, ...recent]) songIdentityKey(entry),
        };
        final picks = <DownloadHistoryEntry>[];
        final loaded = <String, List<DownloadHistoryEntry>>{};

        Future<List<DownloadHistoryEntry>> loadArtist(String artist) async {
          final existing = loaded[artist];
          if (existing != null) return existing;
          var tracks = const <MusicInfo>[];
          // Prefer the source's artist catalogue (the artist's own songs);
          // only an exact name match counts, anything fuzzier falls through
          // to keyword search plus the singer-field hard filter below.
          if (CatalogSdk.supports(source, SearchCategory.artists)) {
            try {
              final response = await api.searchContent(
                keyword: artist,
                source: source,
                category: SearchCategory.artists,
                limit: 8,
              );
              final items =
                  response.catalog[SearchCategory.artists] ?? const [];
              for (final item in items) {
                if (item.summary.name.trim() != artist) continue;
                final detail = await api.getCollection(
                  source: source,
                  id: item.summary.id,
                  kind: OnlineCollectionKind.artist,
                  maxTracks: 30,
                );
                if (detail.tracks.isNotEmpty) {
                  tracks = detail.tracks;
                }
                break;
              }
            } catch (_) {
              // Fall through to keyword search.
            }
          }
          if (tracks.isEmpty) {
            try {
              final response = await api.searchMusic(
                keyword: artist,
                source: source,
                limit: 30,
              );
              tracks = response.list;
            } catch (_) {
              tracks = const [];
            }
          }
          final filtered = _entriesFor(
            filterArtistTracks(tracks, artist),
            'home-guess',
          );
          loaded[artist] = filtered;
          return filtered;
        }

        void takeFrom(List<DownloadHistoryEntry> entries, int quota) {
          var taken = 0;
          for (final entry in entries) {
            if (taken >= quota || picks.length >= count) return;
            if (!seen.add(songIdentityKey(entry))) continue;
            picks.add(entry);
            taken++;
          }
        }

        for (final artist in ranked) {
          if (picks.length >= count) break;
          final quota = quotas[artist.key];
          if (quota == null) continue;
          takeFrom(await loadArtist(artist.key), quota);
        }
        // Fill any leftover slots from the remaining filtered results,
        // walking further down the artist ranking if needed.
        for (final artist in ranked) {
          if (picks.length >= count) break;
          takeFrom(await loadArtist(artist.key), count);
        }

        if (picks.isEmpty) return lastResort();
        final result = picks.take(count).toList(growable: false);
        final encoded = jsonEncode([
          for (final entry in result) entry.toJson(),
        ]);
        await prefs.setString(cacheKey, encoded);
        await prefs.setString(lastKey, encoded);
        return List<DownloadHistoryEntry>.unmodifiable(result);
      } catch (_) {
        return lastResort();
      }
    });

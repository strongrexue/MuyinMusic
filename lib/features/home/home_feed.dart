import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/music_api.dart';
import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/models/leaderboard_info.dart';
import '../../core/storage/settings_store.dart';
import '../discovery/discovery_controller.dart';
import '../downloads/download_history_store.dart';
import '../playlists/playlist_models.dart';
import '../songs/liked_songs_store.dart';
import 'recent_plays_store.dart';

const int _dailyPickCount = 12;
const int _guessCount = 12;

/// Day number used to rotate the daily mix; the shelf only changes at midnight.
int homeDayIndex(DateTime now) =>
    DateTime(now.year, now.month, now.day)
        .difference(DateTime(2024))
        .inDays;

String _dailyCacheKey(MusicSource source) =>
    'home_daily_picks_${source.code}_v1';

DownloadHistoryEntry? _entryFor(MusicInfo music, String queueId) {
  final entry = PlaylistTrack.fromMusicInfo(music).toQueueEntry(playlistId: queueId);
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

/// 「每日推荐」：每天从当前音源的几个榜单里挑一组歌，结果按天缓存。
final dailyPicksProvider =
    FutureProvider.autoDispose<List<DownloadHistoryEntry>>((ref) async {
      final api = ref.watch(musicApiProvider);
      final source = ref.watch(selectedDiscoverySourceProvider);
      final prefs = ref.watch(sharedPreferencesProvider);
      final day = homeDayIndex(DateTime.now());
      final cacheKey = _dailyCacheKey(source);

      final cached = prefs.getString(cacheKey);
      if (cached != null && cached.isNotEmpty) {
        try {
          final decoded = jsonDecode(cached);
          if (decoded is Map && decoded['day'] == day) {
            final rows = decoded['entries'];
            if (rows is List) {
              final entries = [
                for (final row in rows)
                  if (row is Map)
                    DownloadHistoryEntry.fromJson(Map<String, dynamic>.from(row)),
              ];
              if (entries.isNotEmpty) {
                return List<DownloadHistoryEntry>.unmodifiable(entries);
              }
            }
          }
        } catch (_) {
          // A stale or corrupt cache just falls through to the network.
        }
      }

      final boards = await api.getLeaderboards(source);
      if (boards.isEmpty) return const [];
      final ordered = List<LeaderboardSummary>.of(boards);
      final pool = <MusicInfo>[];
      for (var offset = 0; offset < ordered.length && pool.length < 40; offset += 2) {
        final board = ordered[(day + offset) % ordered.length];
        try {
          final detail = await api.getLeaderboard(
            source: source,
            boardId: board.boardId,
            maxTracks: 40,
          );
          pool.addAll(detail.tracks);
        } catch (_) {
          // Skipping a broken board keeps the mix alive with the others.
        }
      }
      if (pool.isEmpty) return const [];
      final entries = _entriesFor(pool, 'home-daily');
      if (entries.isEmpty) return const [];
      final seed = math.Random(day);
      final shuffled = List<DownloadHistoryEntry>.of(entries)..shuffle(seed);
      final picks = shuffled.take(_dailyPickCount).toList(growable: false);
      await prefs.setString(
        cacheKey,
        jsonEncode({
          'day': day,
          'entries': [for (final entry in picks) entry.toJson()],
        }),
      );
      return List<DownloadHistoryEntry>.unmodifiable(picks);
    });

/// 「猜你喜欢」：用最近播放和喜欢里的歌手去搜索同风格歌曲。
final guessYouLikeProvider =
    FutureProvider.autoDispose<List<DownloadHistoryEntry>>((ref) async {
      final api = ref.watch(musicApiProvider);
      final source = ref.watch(selectedDiscoverySourceProvider);
      final liked = ref.watch(likedSongsProvider);
      final recent = ref.watch(recentPlaysProvider);

      final weights = <String, int>{};
      for (final entry in [...recent.take(12), ...liked.take(12)]) {
        final artist = entry.singer.split(RegExp(r'[、,，/&·]')).first.trim();
        if (artist.isEmpty) continue;
        weights.update(artist, (value) => value + 1, ifAbsent: () => 1);
      }
      if (weights.isEmpty) return const [];
      final artists = weights.keys.toList()
        ..sort((a, b) => weights[b]!.compareTo(weights[a]!));

      final picks = <MusicInfo>[];
      for (final artist in artists.take(3)) {
        if (picks.length >= _guessCount) break;
        try {
          final response = await api.searchMusic(
            keyword: artist,
            source: source,
            limit: 12,
          );
          picks.addAll(response.list.take(_guessCount - picks.length));
        } catch (_) {
          // One failing artist should not blank the whole shelf.
        }
      }
      if (picks.isEmpty) return const [];
      final entries = _entriesFor(picks, 'home-guess');
      return List<DownloadHistoryEntry>.unmodifiable(
        entries.take(_guessCount).toList(growable: false),
      );
    });

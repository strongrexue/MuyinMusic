import 'dart:math' as math;

import '../../core/models/music_info.dart';
import '../downloads/download_history_entry.dart';

/// Pure selection logic for the home shelves （每日推荐 / 猜你喜欢）, split out
/// of home_feed.dart so it can be unit-tested without providers or network.

final RegExp _artistSplitPattern = RegExp(r'[、,，/&·]');

/// Splits a singer field into individual artist names, in credit order.
List<String> splitArtistNames(String singer) => [
  for (final part in singer.split(_artistSplitPattern))
    if (part.trim().isNotEmpty) part.trim(),
];

/// Builds the local taste profile: every recent play and every liked song
/// counts once for its main artist; featured/collaborating artists count half.
Map<String, double> buildArtistWeights({
  required Iterable<DownloadHistoryEntry> recent,
  required Iterable<DownloadHistoryEntry> liked,
}) {
  final weights = <String, double>{};
  void add(String singer) {
    final names = splitArtistNames(singer);
    for (var index = 0; index < names.length; index++) {
      final value = index == 0 ? 1.0 : 0.5;
      weights.update(names[index], (old) => old + value, ifAbsent: () => value);
    }
  }

  for (final entry in recent) {
    add(entry.singer);
  }
  for (final entry in liked) {
    add(entry.singer);
  }
  return weights;
}

/// Artists sorted by weight, highest first; ties keep first-seen order.
List<MapEntry<String, double>> rankArtists(Map<String, double> weights) {
  final entries = weights.entries.toList();
  final order = List<int>.generate(entries.length, (index) => index);
  order.sort((a, b) {
    final byWeight = entries[b].value.compareTo(entries[a].value);
    return byWeight != 0 ? byWeight : a.compareTo(b);
  });
  return [for (final index in order) entries[index]];
}

/// Stable fingerprint of the taste profile, used as the 猜你喜欢 cache key:
/// the same listening history always maps to the same cached shelf.
String artistFingerprint(Map<String, double> weights) {
  final raw = rankArtists(
    weights,
  ).take(8).map((entry) => '${entry.key}=${entry.value.toStringAsFixed(1)}').join('|');
  // FNV-1a, so the fingerprint does not depend on Dart's per-run hash seed.
  var hash = 0x811c9dc5;
  for (final unit in raw.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// Whether [artist] is actually credited in a track's singer field.
bool isTrackByArtist(String singerField, String artist) {
  final target = artist.trim().toLowerCase();
  if (target.isEmpty) return false;
  return splitArtistNames(
    singerField,
  ).any((name) => name.toLowerCase() == target);
}

const List<String> _nonOriginalMarkers = ['伴奏', '翻唱', '铃声'];

/// Titles that are clearly not the artist's original recording.
bool hasNonOriginalMarker(String title) =>
    _nonOriginalMarkers.any(title.contains);

/// One leaderboard track with the board it came from and its rank inside it.
class DailyCandidate {
  const DailyCandidate({
    required this.entry,
    required this.boardKey,
    required this.rank,
    required this.boardSize,
  });

  final DownloadHistoryEntry entry;
  final String boardKey;
  final int rank;
  final int boardSize;
}

/// Ranks the cross-board pool by local taste and takes [count] picks.
///
/// A track by a high-weight artist scores above chart position; with no
/// taste profile (or on ties) the original board rank decides, so the shelf
/// degrades to a plain multi-board mix in board order. No board may take
/// more than a third of the shelf while other boards still have tracks to
/// give; the cap is only relaxed to fill the shelf when supply runs out.
List<DownloadHistoryEntry> selectDailyPicks({
  required List<DailyCandidate> pool,
  required Map<String, double> weights,
  required int count,
}) {
  if (pool.isEmpty || count <= 0) return const [];
  final maxWeight = weights.values.fold<double>(
    0,
    (best, value) => value > best ? value : best,
  );

  double score(DailyCandidate candidate) {
    final names = splitArtistNames(candidate.entry.singer);
    final weight = names.isEmpty ? 0.0 : (weights[names.first] ?? 0.0);
    final taste = maxWeight > 0 ? weight / maxWeight : 0.0;
    final rankBonus = candidate.boardSize > 0
        ? (candidate.boardSize - candidate.rank) / candidate.boardSize
        : 0.0;
    return taste * 100 + rankBonus;
  }

  final indexed = [
    for (var index = 0; index < pool.length; index++) (index, pool[index]),
  ];
  indexed.sort((a, b) {
    final byScore = score(b.$2).compareTo(score(a.$2));
    return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
  });

  final cap = (count / 3).ceil();
  final perBoard = <String, int>{};
  final picks = <DownloadHistoryEntry>[];
  final capped = <DailyCandidate>[];
  for (final (_, candidate) in indexed) {
    if (picks.length >= count) break;
    final taken = perBoard[candidate.boardKey] ?? 0;
    if (taken >= cap) {
      capped.add(candidate);
      continue;
    }
    perBoard[candidate.boardKey] = taken + 1;
    picks.add(candidate.entry);
  }
  for (final candidate in capped) {
    if (picks.length >= count) break;
    picks.add(candidate.entry);
  }
  return picks;
}

/// Splits [total] shelf slots across the top artists in proportion to their
/// weights: every considered artist gets at least one slot, nobody gets more
/// than the single-artist cap, and the quotas always add up to [total] when
/// the artists can absorb it.
Map<String, int> allocateArtistQuotas({
  required List<MapEntry<String, double>> ranked,
  required int total,
  int maxArtists = 8,
}) {
  if (total <= 0 || ranked.isEmpty) return const {};
  final artists = ranked.take(maxArtists).toList();
  final cap = math.max(6, (total / 2).ceil());
  final totalWeight = artists.fold<double>(
    0,
    (sum, entry) => sum + entry.value,
  );
  final quotas = <String, int>{};
  for (final entry in artists) {
    var quota = totalWeight > 0
        ? (total * entry.value / totalWeight).floor()
        : 0;
    if (quota < 1) quota = 1;
    if (quota > cap) quota = cap;
    quotas[entry.key] = quota;
  }
  var sum = quotas.values.fold(0, (a, b) => a + b);
  while (sum > total) {
    var changed = false;
    for (final entry in artists.reversed) {
      if (sum <= total) break;
      if ((quotas[entry.key] ?? 0) > 1) {
        quotas[entry.key] = quotas[entry.key]! - 1;
        sum--;
        changed = true;
      }
    }
    if (!changed) break;
  }
  while (sum < total) {
    var changed = false;
    for (final entry in artists) {
      if (sum >= total) break;
      if ((quotas[entry.key] ?? 0) < cap) {
        quotas[entry.key] = quotas[entry.key]! + 1;
        sum++;
        changed = true;
      }
    }
    if (!changed) break;
  }
  return quotas;
}

/// Keeps only tracks genuinely credited to [artist] and drops obvious
/// non-original versions (instrumentals, covers, ringtones).
List<MusicInfo> filterArtistTracks(List<MusicInfo> tracks, String artist) => [
  for (final track in tracks)
    if (isTrackByArtist(track.singer, artist) &&
        !hasNonOriginalMarker(track.name))
      track,
];

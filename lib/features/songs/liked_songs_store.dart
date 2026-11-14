import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/settings_store.dart';
import '../downloads/download_history_store.dart';

const String likedSongsStorageKey = 'liked_songs_v2';

/// Identity a liked flag is stored under. It matches the queue de-duplication
/// key: the file path wins, then the source music id, then the entry id.
String songIdentityKey(DownloadHistoryEntry entry) {
  final path = entry.savedPath?.trim();
  if (path != null && path.isNotEmpty) return 'file:$path';
  final musicId = entry.musicId.trim();
  if (musicId.isNotEmpty) return 'music:${entry.sourceCode}:$musicId';
  return 'entry:${entry.id}';
}

/// The songs the user marked with 喜欢, persisted across restarts.
///
/// Entries are stored whole so that online songs keep their metadata and stay
/// playable from the 我的喜欢 tab even before they are downloaded.
class LikedSongsNotifier extends Notifier<List<DownloadHistoryEntry>> {
  late final _prefs = ref.read(sharedPreferencesProvider);

  @override
  List<DownloadHistoryEntry> build() {
    final raw = _prefs.getString(likedSongsStorageKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return List<DownloadHistoryEntry>.unmodifiable(
        [
          for (final row in decoded)
            if (row is Map)
              DownloadHistoryEntry.fromJson(Map<String, dynamic>.from(row)),
        ].where((entry) => entry.name.isNotEmpty || entry.musicId.isNotEmpty),
      );
    } catch (_) {
      return const [];
    }
  }

  bool isLiked(DownloadHistoryEntry entry) {
    final key = songIdentityKey(entry);
    return state.any((item) => songIdentityKey(item) == key);
  }

  /// Flips the liked flag of [entry] and returns whether it is liked after.
  bool toggle(DownloadHistoryEntry entry) {
    final key = songIdentityKey(entry);
    final next = state
        .where((item) => songIdentityKey(item) != key)
        .toList(growable: true);
    final liked = next.length == state.length;
    if (liked) next.insert(0, entry);
    state = List<DownloadHistoryEntry>.unmodifiable(next);
    unawaited(_persist(next));
    return liked;
  }

  Future<void> _persist(List<DownloadHistoryEntry> entries) => _prefs
      .setString(
        likedSongsStorageKey,
        jsonEncode([for (final entry in entries) entry.toJson()]),
      )
      .then((_) {});
}

final likedSongsProvider =
    NotifierProvider<LikedSongsNotifier, List<DownloadHistoryEntry>>(
      LikedSongsNotifier.new,
    );

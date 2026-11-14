import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/settings_store.dart';
import '../downloads/download_history_store.dart';
import '../songs/liked_songs_store.dart';

const String recentPlaysStorageKey = 'recent_plays_v1';
const int recentPlaysLimit = 40;

/// The songs the user actually started playing, newest first.
///
/// The home tab reads this for its 最近播放 rail. Entries are stored whole so
/// online songs stay playable without being downloaded first.
class RecentPlaysNotifier extends Notifier<List<DownloadHistoryEntry>> {
  late final _prefs = ref.read(sharedPreferencesProvider);

  @override
  List<DownloadHistoryEntry> build() {
    final raw = _prefs.getString(recentPlaysStorageKey);
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

  /// Moves [entry] to the front of the list, keeping one row per song.
  void record(DownloadHistoryEntry entry) {
    if (entry.name.isEmpty && entry.musicId.isEmpty) return;
    final key = songIdentityKey(entry);
    final next = state
        .where((item) => songIdentityKey(item) != key)
        .toList(growable: true)
      ..insert(0, entry);
    if (next.length > recentPlaysLimit) next.removeRange(recentPlaysLimit, next.length);
    state = List<DownloadHistoryEntry>.unmodifiable(next);
    unawaited(_persist(next));
  }

  Future<void> clear() {
    state = const [];
    return _persist(const []);
  }

  Future<void> _persist(List<DownloadHistoryEntry> entries) => _prefs
      .setString(
        recentPlaysStorageKey,
        jsonEncode([for (final entry in entries) entry.toJson()]),
      )
      .then((_) {});
}

final recentPlaysProvider =
    NotifierProvider<RecentPlaysNotifier, List<DownloadHistoryEntry>>(
      RecentPlaysNotifier.new,
    );

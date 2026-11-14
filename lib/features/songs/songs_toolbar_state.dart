import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/settings_store.dart';

const String songsLibraryTabStorageKey = 'songs_library_tab_v1';

/// The three collections the Songs page hosts as independent tabs.
enum SongsLibraryTab {
  liked('liked', '喜欢', Icons.favorite_rounded),
  local('local', '本地音乐', Icons.smartphone_rounded),
  playlists('playlists', '歌单', Icons.queue_music_rounded);

  const SongsLibraryTab(this.code, this.label, this.icon);

  final String code;
  final String label;
  final IconData icon;

  static SongsLibraryTab fromCode(String? code) {
    return switch (code) {
      'local' => SongsLibraryTab.local,
      'playlists' => SongsLibraryTab.playlists,
      _ => SongsLibraryTab.liked,
    };
  }
}

enum SongSortMode {
  title('title', '标题', Icons.sort_by_alpha_rounded),
  artist('artist', '歌手', Icons.person_outline_rounded),
  added('added', '添加时间', Icons.schedule_rounded);

  const SongSortMode(this.code, this.label, this.icon);

  final String code;
  final String label;
  final IconData icon;

  static SongSortMode fromCode(String? code) {
    return switch (code) {
      'artist' => SongSortMode.artist,
      'added' => SongSortMode.added,
      _ => SongSortMode.title,
    };
  }
}

@immutable
class SongsToolbarState {
  const SongsToolbarState({
    this.owner,
    this.libraryTitle = '歌曲',
    this.tab = SongsLibraryTab.local,
    this.songCount = 0,
    this.selectedCount = 0,
    this.allSelected = false,
    this.batchMode = false,
    this.searchMode = false,
    this.searchAutoFocus = true,
    this.searchController,
    this.searchFocusNode,
    this.onCloseSearch,
    this.onSearchChanged,
    this.onSearch,
    this.onShuffle,
    this.onOpenHistory,
    this.onSelectTab,
    this.onToggleBatch,
    this.onToggleSelectAll,
  });

  final Object? owner;
  final String libraryTitle;
  final SongsLibraryTab tab;
  final int songCount;
  final int selectedCount;
  final bool allSelected;
  final bool batchMode;
  final bool searchMode;
  final bool searchAutoFocus;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final VoidCallback? onCloseSearch;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onSearch;
  final VoidCallback? onShuffle;
  final VoidCallback? onOpenHistory;
  final ValueChanged<SongsLibraryTab>? onSelectTab;
  final VoidCallback? onToggleBatch;
  final VoidCallback? onToggleSelectAll;

  bool get attached => owner != null;
  bool get hasSongs => songCount > 0;

  /// The playlist tab lists collections, so the song search does not apply.
  bool get searchEnabled => tab != SongsLibraryTab.playlists;

  String get searchLabel => switch (tab) {
    SongsLibraryTab.local => '搜索本地音乐',
    SongsLibraryTab.liked => '搜索喜欢的歌曲',
    SongsLibraryTab.playlists => '搜索歌单',
  };

  bool matchesView({
    required Object owner,
    required String libraryTitle,
    required SongsLibraryTab tab,
    required int songCount,
    required int selectedCount,
    required bool allSelected,
    required bool batchMode,
    required bool searchMode,
    required bool searchAutoFocus,
  }) {
    return identical(this.owner, owner) &&
        this.libraryTitle == libraryTitle &&
        this.tab == tab &&
        this.songCount == songCount &&
        this.selectedCount == selectedCount &&
        this.allSelected == allSelected &&
        this.batchMode == batchMode &&
        this.searchMode == searchMode &&
        this.searchAutoFocus == searchAutoFocus;
  }
}

/// The tab selected in the Songs page. An app restart restores the last tab.
class SongsLibraryTabNotifier extends Notifier<SongsLibraryTab> {
  late final _prefs = ref.read(sharedPreferencesProvider);

  @override
  SongsLibraryTab build() =>
      SongsLibraryTab.fromCode(_prefs.getString(songsLibraryTabStorageKey));

  void select(SongsLibraryTab tab) {
    if (state == tab) return;
    state = tab;
    unawaited(_prefs.setString(songsLibraryTabStorageKey, tab.code));
  }
}

final songsLibraryTabProvider =
    NotifierProvider<SongsLibraryTabNotifier, SongsLibraryTab>(
      SongsLibraryTabNotifier.new,
    );

final songsToolbarStateProvider = StateProvider<SongsToolbarState>(
  (ref) => const SongsToolbarState(),
);

/// Opening search focuses the header after its animation. Playing a result
/// releases focus; restored search routes must not focus again when the player
/// returns, so the persistent bottom toolbar remains visible.
final songsSearchAutoFocusProvider = StateProvider<bool>((ref) => true);

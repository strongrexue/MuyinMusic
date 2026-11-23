import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../core/services/batch_download_controller.dart';
import '../../core/services/saf_storage.dart';
import '../../core/services/local_audio_source.dart';
import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/services/embedded_artwork_cache.dart';
import '../../core/services/embedded_audio_tags.dart';
import '../../core/storage/settings_store.dart';
import '../../core/ui/app_breakpoints.dart';
import '../../core/ui/app_scrollbar.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/app_refresh_indicator.dart';
import '../../theme/app_motion.dart';
import '../downloads/download_history_store.dart';
import '../downloads/download_progress.dart';
import '../music_sources/music_source_action_guard.dart';
import '../player/player_controller.dart';
import '../search/widgets/quality_picker_sheet.dart';
import '../playlists/widgets/add_music_to_playlist.dart';
import '../playlists/playlist_models.dart';
import '../playlists/online_playlist_updater.dart';
import '../playlists/playlist_import_actions.dart';
import '../playlists/playlist_name_dialog.dart';
import '../playlists/playlist_store.dart';
import '../playlists/widgets/playlist_library_tile.dart';
import '../playlists/widgets/playlists_batch_action_bar.dart';
import '../shell/shell_toolbar_visibility.dart';
import '../shell/shell_bottom_area.dart';
import '../shell/widgets/scrolling_page_header.dart';
import 'liked_songs_store.dart';
import 'local_song_scan_cache.dart';
import 'scanned_song_file.dart';
import 'song_search.dart';
import 'songs_toolbar_state.dart';
import 'songs_playback_location.dart';
import 'widgets/song_row.dart';
import 'widgets/windows_playlist_cover_card.dart';
import 'widgets/songs_batch_action_bar.dart';
import 'widgets/songs_placeholders.dart';
import 'widgets/songs_sort_sheet.dart';

const _songSortModeKey = 'songs_sort_mode_v1';
const _songSortAscendingKey = 'songs_sort_ascending_v1';

/// 歌单封面网格列数：按可用宽以目标格宽 240 动态加列，钳制在 2–10 列。
int songsPlaylistGridColumnCount(double gridWidth) =>
    (gridWidth / 240).floor().clamp(2, 10);

/// Footprint the floating tab capsule needs above the list: the capsule plus
/// its top and bottom breathing room.
const double kSongsTabBarSlot = prism.kGlassPillBarHeight + 14;

class SongsPage extends ConsumerStatefulWidget {
  const SongsPage({super.key, this.searchMode = false});

  /// Initial state for restored /songs/search routes. Header searches open in place.
  final bool searchMode;

  @override
  ConsumerState<SongsPage> createState() => _SongsPageState();
}

class _SongsPageState extends ConsumerState<SongsPage> {
  SongSortMode _sortMode = SongSortMode.title;
  bool _ascending = true;
  bool _batchMode = false;
  bool _playlistSortMode = false;
  String _searchQuery = '';
  bool _searchMode = false;
  double? _preSearchScrollOffset;
  final Object _toolbarOwner = Object();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _songsListKey = GlobalKey(debugLabel: 'songs-list');
  int _locateGeneration = 0;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'songs-search');
  bool? _toolbarVisibilityBeforeSearchFocus;
  List<DownloadHistoryEntry> _visibleSongs = const [];
  List<String> _visiblePlaylistIds = const [];
  final Set<String> _selectedIds = <String>{};
  final Set<String> _updatingPlaylistIds = <String>{};
  bool _importingLx = false;
  String? _lxImportProgress;
  List<ScannedSongFile>? _scannedFiles;
  String? _scanError;
  ProviderSubscription<List<String>>? _localMusicDirSubscription;
  late final StateController<SongsToolbarState> _toolbarStateController;
  late final StateController<bool> _shellToolbarController;
  late final LocalSongScanCache _scanCache;

  @override
  void initState() {
    super.initState();
    _searchMode = widget.searchMode;
    final prefs = ref.read(sharedPreferencesProvider);
    _sortMode = SongSortMode.fromCode(prefs.getString(_songSortModeKey));
    _ascending = prefs.getBool(_songSortAscendingKey) ?? true;
    _toolbarStateController = ref.read(songsToolbarStateProvider.notifier);
    _shellToolbarController = ref.read(shellToolbarVisibleProvider.notifier);
    _scanCache = ref.read(localSongScanCacheProvider);
    _seedFromScanCache();
    _scanCache.addListener(_handleScanCacheChanged);
    if (_searchMode) _enableSearchFocusHandling();
    _localMusicDirSubscription = ref.listenManual(
      settingsProvider.select((settings) => settings.localMusicDirs),
      (previous, next) {
        if (previous == null || previous == next) return;
        // Keep the currently rendered library in place while the new folders are
        // scanned, then swap the result in one frame. This avoids a loading
        // flash when the local music folder changes from Settings.
        unawaited(_scanCache.ensureScan(directories: next));
      },
    );
    unawaited(_initializeScan());
  }

  void _seedFromScanCache() {
    // Restore against the real list on the first frame; an empty loading frame
    // would clamp PageStorage's saved scroll offset back to zero.
    final snapshot = _scanCache.snapshot;
    if (snapshot == null ||
        !snapshot.matchesDirectories(
          ref.read(settingsProvider).localMusicDirs,
        )) {
      return;
    }
    _scannedFiles = [
      for (final file in snapshot.files) ScannedSongFile.fromSnapshot(file),
    ];
    _scanError = snapshot.error;
  }

  @override
  void didUpdateWidget(covariant SongsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchMode == widget.searchMode) return;
    _searchMode = widget.searchMode;
    if (_searchMode) {
      _enableSearchFocusHandling();
    } else {
      _disableSearchFocusHandling();
    }
  }

  Future<void> _initializeScan() async {
    await _scanCache.ensureScan(
      directories: ref.read(settingsProvider).localMusicDirs,
    );
    if (mounted) _handleScanCacheChanged();
  }

  @override
  void dispose() {
    _disableSearchFocusHandling(deferRestore: true);
    _scanCache.removeListener(_handleScanCacheChanged);
    _localMusicDirSubscription?.close();
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    final toolbarStateController = _toolbarStateController;
    final toolbarOwner = _toolbarOwner;
    scheduleMicrotask(() {
      if (!toolbarStateController.mounted) return;
      final toolbarState = toolbarStateController.state;
      if (identical(toolbarState.owner, toolbarOwner)) {
        toolbarStateController.state = const SongsToolbarState();
      }
    });
    super.dispose();
  }

  void _enableSearchFocusHandling() {
    _searchFocusNode.addListener(_handleSearchFocusChanged);
    // The shared header requests focus after its opening animation completes.
  }

  void _disableSearchFocusHandling({bool deferRestore = false}) {
    _searchFocusNode.removeListener(_handleSearchFocusChanged);
    _restoreToolbarAfterSearchFocus(deferRestore: deferRestore);
  }

  void _handleSearchFocusChanged() {
    if (!mounted || !_searchMode) return;
    if (!_searchFocusNode.hasFocus) {
      _restoreToolbarAfterSearchFocus();
      return;
    }

    _toolbarVisibilityBeforeSearchFocus ??= ref.read(
      shellToolbarVisibleProvider,
    );
    final toolbar = ref.read(shellToolbarVisibleProvider.notifier);
    if (toolbar.mounted) toolbar.state = false;
  }

  void _restoreToolbarAfterSearchFocus({bool deferRestore = false}) {
    final previous = _toolbarVisibilityBeforeSearchFocus;
    if (previous == null) return;
    _toolbarVisibilityBeforeSearchFocus = null;
    final toolbar = _shellToolbarController;
    void restore() {
      if (toolbar.mounted) toolbar.state = previous;
    }

    if (deferRestore) {
      // Disposal cannot read WidgetRef or update other widgets during unmount.
      scheduleMicrotask(restore);
    } else {
      restore();
    }
  }

  void _handleScanCacheChanged() {
    if (!mounted) return;
    final snapshot = _scanCache.snapshot;
    if (snapshot == null) return;
    final currentDirectories = ref.read(settingsProvider).localMusicDirs;
    if (!snapshot.matchesDirectories(currentDirectories)) return;

    final files = [
      for (final file in snapshot.files) ScannedSongFile.fromSnapshot(file),
    ];
    setState(() {
      _scannedFiles = files;
      _scanError = snapshot.error;
    });
  }

  Future<void> _scanLocalMusicFolder() {
    return _scanCache.refresh(
      directories: ref.read(settingsProvider).localMusicDirs,
    );
  }

  List<DownloadHistoryEntry> _songs(List<DownloadHistoryEntry> history) {
    final scannedFiles = _scannedFiles;
    if (scannedFiles == null) return const [];
    final historyByPath = <String, DownloadHistoryEntry>{};
    for (final entry in history) {
      final path = entry.savedPath;
      if (path == null || path.isEmpty) continue;
      historyByPath[_pathKey(path)] = entry;
    }

    final out = <DownloadHistoryEntry>[];
    final seen = <String>{};
    for (final file in scannedFiles) {
      final key = _pathKey(file.path);
      final tags = file.tags;
      final historyEntry = historyByPath[key];
      final entry = historyEntry == null
          ? _syntheticEntryFor(file, tags)
          : _entryWithScannedFile(historyEntry, file, tags);
      if (seen.add(key)) out.add(entry);
    }

    int compare(DownloadHistoryEntry a, DownloadHistoryEntry b) {
      switch (_sortMode) {
        case SongSortMode.title:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case SongSortMode.artist:
          return a.singer.toLowerCase().compareTo(b.singer.toLowerCase());
        case SongSortMode.added:
          return a.createdAt.compareTo(b.createdAt);
      }
    }

    out.sort(_ascending ? compare : (a, b) => compare(b, a));
    return out;
  }

  DownloadHistoryEntry _entryWithScannedFile(
    DownloadHistoryEntry entry,
    ScannedSongFile file,
    EmbeddedAudioTags? tags,
  ) {
    return DownloadHistoryEntry(
      id: entry.id,
      musicId: entry.musicId,
      name: _preferTag(
        tags?.title,
        entry.name.isEmpty ? file.title : entry.name,
      ),
      singer: _preferTag(tags?.artist, entry.singer),
      albumName: _preferTag(tags?.album, entry.albumName),
      sourceCode: entry.sourceCode,
      qualityCode: entry.qualityCode,
      status: entry.status,
      createdAt: file.createdAt,
      savedPath: file.path,
      message: entry.message,
      picUrl: entry.picUrl,
      sizeBytes: file.sizeBytes,
      musicJson: entry.musicJson,
    );
  }

  DownloadHistoryEntry _syntheticEntryFor(
    ScannedSongFile file,
    EmbeddedAudioTags? tags,
  ) {
    return DownloadHistoryEntry(
      id: 'file:${file.identityPath}',
      musicId: file.identityPath,
      name: _preferTag(tags?.title, file.title),
      singer: _preferTag(tags?.artist, file.artist),
      albumName: _preferTag(tags?.album, ''),
      sourceCode: MusicSource.all.code,
      qualityCode: file.extension.toLowerCase(),
      status: DownloadHistoryStatus.completed,
      createdAt: file.createdAt,
      savedPath: file.path,
      sizeBytes: file.sizeBytes,
    );
  }

  Future<void> _play(
    DownloadHistoryEntry entry,
    List<DownloadHistoryEntry> queue, {
    bool replaceQueue = true,
  }) async {
    final path = entry.savedPath;
    final hasLocalFile =
        path != null && path.isNotEmpty && isLocalAudioSourceAvailable(path);
    if (!hasLocalFile && entry.musicInfo == null) {
      showAppToast(context, '文件不存在，可能已被移动或删除', type: AppToastType.warning);
      return;
    }
    final available = await ensureQueueEntryMusicSourceAvailable(
      context,
      entry,
    );
    if (!available || !mounted) return;
    if (_searchMode) {
      ref.read(songsSearchAutoFocusProvider.notifier).state = false;
      _searchFocusNode.unfocus();
      _restoreToolbarAfterSearchFocus();
    }
    final player = ref.read(playerControllerProvider.notifier);
    if (!replaceQueue) {
      await player.playSingleQueueEntry(entry);
    } else {
      await player.playFromHistoryQueue(entry, queue);
    }
  }

  Future<void> _locateCurrentSong() async {
    final generation = ++_locateGeneration;
    final initialPlayer = ref.read(playerControllerProvider);
    final trackId = initialPlayer.track?.id;
    if (trackId == null) return;
    if (_searchMode) _clearSearch();
    // Clearing the search rebuilds the list; wait until its rows and scroll
    // dimensions are ready before finding the playing song.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _locateGeneration) return;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppMotion.medium;

    // SliverList only builds nearby rows. Use a measured row to reach the
    // target's neighborhood, then align the actual target after layout.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!mounted || generation != _locateGeneration) return;
      final player = ref.read(playerControllerProvider);
      if (player.track?.id != trackId || !_scrollController.hasClients) {
        return;
      }
      final queueEntry =
          player.queueIndex >= 0 && player.queueIndex < player.queue.length
          ? player.queue[player.queueIndex]
          : null;
      final index = _visibleSongs.indexWhere(
        (entry) => matchesPlayingEntry(
          entry,
          queueEntry,
          player.track?.localPath,
          trackId,
        ),
      );
      if (index < 0) {
        showAppToast(context, '当前歌曲不在这个列表中');
        return;
      }
      final sliver = _songsListKey.currentContext?.findRenderObject();
      if (sliver is! RenderSliverMultiBoxAdaptor) return;
      RenderBox? anchor;
      RenderBox? target;
      var child = sliver.firstChild;
      while (child != null) {
        final data = child.parentData! as SliverMultiBoxAdaptorParentData;
        // The separated list alternates song rows and 1dp dividers.
        if (data.index!.isEven) anchor ??= child;
        if (data.index == index * 2) {
          target = child;
          break;
        }
        child = sliver.childAfter(child);
      }
      final position = _scrollController.position;
      if (target != null) {
        await position.ensureVisible(
          target,
          alignment: 0.45,
          duration: duration,
          curve: AppMotion.emphasized,
        );
        return;
      }
      if (anchor == null) return;
      final data = anchor.parentData! as SliverMultiBoxAdaptorParentData;
      final anchorOffset = RenderAbstractViewport.of(
        anchor,
      ).getOffsetToReveal(anchor, 0.45).offset;
      final offset =
          (anchorOffset + (index - data.index! ~/ 2) * (anchor.size.height + 1))
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();
      // Skip a long scroll animation when the target is far away.
      if (duration == Duration.zero ||
          (offset - position.pixels).abs() > position.viewportDimension * 2) {
        _scrollController.jumpTo(offset);
      } else {
        await _scrollController.animateTo(
          offset,
          duration: duration,
          curve: AppMotion.emphasized,
        );
      }
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Future<void> _playRandom(List<DownloadHistoryEntry> songs) async {
    final playable = songs
        .where((entry) {
          final path = entry.savedPath;
          return (path != null &&
                  path.isNotEmpty &&
                  isLocalAudioSourceAvailable(path)) ||
              entry.musicInfo != null;
        })
        .toList(growable: false);
    if (playable.isEmpty) {
      showAppToast(context, '没有可播放的本地歌曲', type: AppToastType.warning);
      return;
    }
    final shuffled = [...playable]..shuffle(math.Random());
    await _play(shuffled.first, shuffled);
  }

  void _shuffleVisibleSongs() {
    unawaited(_playRandom(_visibleSongs));
  }

  Future<void> _playSelected(List<DownloadHistoryEntry> songs) async {
    final selected = songs
        .where((entry) => _selectedIds.contains(entry.id))
        .where((entry) {
          final path = entry.savedPath;
          return (path != null &&
                  path.isNotEmpty &&
                  isLocalAudioSourceAvailable(path)) ||
              entry.musicInfo != null;
        })
        .toList(growable: false);
    if (selected.isEmpty) {
      showAppToast(context, '请先选择可播放的歌曲', type: AppToastType.warning);
      return;
    }
    setState(() {
      _selectedIds.clear();
      _batchMode = false;
    });
    await _play(selected.first, selected);
  }

  Future<void> _addNext(DownloadHistoryEntry entry) async {
    final path = entry.savedPath;
    final hasLocalFile =
        path != null && path.isNotEmpty && isLocalAudioSourceAvailable(path);
    if (!hasLocalFile && entry.musicInfo == null) {
      showAppToast(context, '文件不存在，无法加入队列', type: AppToastType.warning);
      return;
    }
    final available = await ensureQueueEntryMusicSourceAvailable(
      context,
      entry,
    );
    if (!available || !mounted) return;
    await ref.read(playerControllerProvider.notifier).enqueueNext(entry);
    if (!mounted) return;
    showAppToast(context, '已添加到下一首播放', type: AppToastType.success);
  }

  Future<void> _addSongToPlaylist(
    DownloadHistoryEntry entry,
    LocalPlaylist playlist,
  ) async {
    try {
      final added = await ref.read(localPlaylistsProvider.notifier).addEntries(
        playlist.id,
        [entry],
      );
      if (!mounted) return;
      if (added == 0) {
        showAppToast(
          context,
          '歌曲已在「${playlist.name}」中',
          type: AppToastType.info,
        );
        return;
      }
      showAppToast(
        context,
        '已添加到「${playlist.name}」',
        type: AppToastType.success,
      );
    } catch (error) {
      if (!mounted) return;
      showAppToast(context, '添加到歌单失败：$error', type: AppToastType.error);
    }
  }

  Future<void> _selectPlaylistForSong(DownloadHistoryEntry entry) async {
    final playlist = await showPlaylistAddCard(context);
    if (!mounted || playlist == null) return;
    await _addSongToPlaylist(entry, playlist);
  }

  bool _deletingFiles = false;

  Future<void> _deleteSong(DownloadHistoryEntry entry) => _deleteSongs([entry]);

  Future<void> _deleteSongs(List<DownloadHistoryEntry> entries) async {
    if (_deletingFiles) return;
    final paths = entries
        .map((e) => e.savedPath)
        .whereType<String>()
        .where((p) => p.isNotEmpty)
        .toSet();
    if (paths.isEmpty) return;
    // Android 由系统 MediaStore 删除确认弹窗兜底；iOS/桌面 直接物理删除，
    // 这里补应用内二次确认，避免误触即删。
    if (!Platform.isAndroid) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => prism.AlertDialog(
          title: entries.length == 1 ? '删除本地歌曲' : '删除本地歌曲',
          actions: [
            prism.TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            prism.FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ],
          child: Text(
            entries.length == 1
                ? '确定删除这首本地歌曲吗？文件会从设备中移除，且无法恢复。'
                : '确定删除选中的 ${entries.length} 首本地歌曲吗？文件会从设备中移除，且无法恢复。',
          ),
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    _deletingFiles = true;
    final history = ref.read(downloadHistoryProvider);
    final historyNotifier = ref.read(downloadHistoryProvider.notifier);
    final playlists = ref.read(localPlaylistsProvider.notifier);
    final scanCache = _scanCache;
    final wasBatch = _batchMode;
    try {
      final result = await SafStorage.deleteFiles(paths);
      final deletedKeys = result.deletedPaths.map(_pathKey).toSet();
      final removedKeys = result.removedFromListOnly.map(_pathKey).toSet();
      final physicalDeletedCount = deletedKeys.difference(removedKeys).length;
      if (deletedKeys.isNotEmpty) {
        for (final path in result.deletedPaths) {
          await playlists.removeLocalPathFromAll(
            path,
            pathKey: scanCache.pathKey,
          );
          _forgetTagCache(path);
        }
        await historyNotifier.removeMany([
          for (final item in history)
            if (item.savedPath != null &&
                deletedKeys.contains(_pathKey(item.savedPath!)))
              item.id,
        ]);
        await scanCache.flush();
        if (mounted && wasBatch) {
          setState(() {
            _selectedIds
              ..clear()
              ..addAll(
                entries
                    .where(
                      (entry) =>
                          entry.savedPath != null &&
                          !deletedKeys.contains(_pathKey(entry.savedPath!)),
                    )
                    .map((e) => e.id),
              );
            _batchMode = _selectedIds.isNotEmpty;
          });
        }
      }
      if (!mounted) return;
      final removedCount = removedKeys.length;
      if (result.failed.isNotEmpty) {
        showAppToast(
          context,
          '已删除 $physicalDeletedCount 个文件'
          '${removedCount > 0 ? '，$removedCount 首仅从列表移除' : ''}'
          '，${result.failed.length} 个失败：${result.failed.values.first}',
          type: physicalDeletedCount == 0 && removedCount == 0
              ? AppToastType.error
              : AppToastType.warning,
        );
      } else if (result.cancelled) {
        showAppToast(
          context,
          physicalDeletedCount == 0 && removedCount == 0
              ? '已取消删除'
              : '已删除 $physicalDeletedCount 个文件'
                    '${removedCount > 0 ? '，$removedCount 首仅从列表移除' : ''}，其余已取消',
        );
      } else if (removedCount > 0) {
        showAppToast(
          context,
          physicalDeletedCount > 0
              ? '已删除 $physicalDeletedCount 个文件，$removedCount 首仅从列表移除'
              : '$removedCount 首本地文件已不在设备中，仅从列表移除',
          type: physicalDeletedCount > 0
              ? AppToastType.warning
              : AppToastType.success,
        );
      } else {
        showAppToast(
          context,
          '已删除 $physicalDeletedCount 个文件',
          type: AppToastType.success,
        );
      }
    } catch (error) {
      if (mounted) {
        showAppToast(context, '删除失败：$error', type: AppToastType.error);
      }
    } finally {
      _deletingFiles = false;
    }
  }

  Future<void> _openPlaylist(LocalPlaylist playlist) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await context.push('/playlists/${playlist.id}');
  }

  Future<void> _createPlaylist() async {
    final name = await showPlaylistNameDialog(
      context,
      title: '新建歌单',
      actionLabel: '创建',
    );
    if (name == null || !mounted) return;
    try {
      final playlist = await ref
          .read(localPlaylistsProvider.notifier)
          .create(name);
      if (!mounted) return;
      showAppToast(
        context,
        '歌单“${playlist.name}”已创建',
        type: AppToastType.success,
      );
      await _openPlaylist(playlist);
    } on PlaylistStoreException catch (error) {
      if (mounted) {
        showAppToast(context, error.message, type: AppToastType.warning);
      }
    }
  }

  Future<void> _importOnlinePlaylist() async {
    await context.push('/playlists/import');
  }

  Future<void> _importLxPlaylist() async {
    if (_importingLx) return;
    setState(() => _importingLx = true);
    try {
      await importLxPlaylistFile(
        context,
        ref,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _lxImportProgress = progress);
        },
      );
    } finally {
      if (mounted) {
        setState(() {
          _importingLx = false;
          _lxImportProgress = null;
        });
      }
    }
  }

  /// Drops a playlist out of the library — the filled heart on its row.
  Future<void> _unfavoritePlaylist(LocalPlaylist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => prism.AlertDialog(
        title: '取消收藏这个歌单？',
        // 玻璃确认框：描述移入 child，去掉 Material icon，按钮换成 prism。
        actions: [
          prism.TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          prism.FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('取消收藏'),
          ),
        ],
        child: Text('「${playlist.name}」将从我的歌单中移除，下载的歌曲不会被删除。'),
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(localPlaylistsProvider.notifier).delete(playlist.id);
    if (!mounted) return;
    showAppToast(context, '已取消收藏', type: AppToastType.success);
  }

  /// Liked entries newest first, preferring the freshly scanned local row when
  /// the same song is also in the local library.
  List<DownloadHistoryEntry> _likedSongs(
    List<DownloadHistoryEntry> liked,
    List<DownloadHistoryEntry> librarySongs,
  ) {
    final byKey = {
      for (final entry in librarySongs) songIdentityKey(entry): entry,
    };
    return [for (final entry in liked) byKey[songIdentityKey(entry)] ?? entry];
  }

  void _toggleLike(DownloadHistoryEntry entry) {
    final liked = ref.read(likedSongsProvider.notifier).toggle(entry);
    showAppToast(
      context,
      liked ? '已加入我的喜欢' : '已取消喜欢',
      type: AppToastType.success,
    );
  }

  void _openHistory() {
    context.go('/downloads');
  }

  void _openSearch() {
    if (_searchMode) return;
    _preSearchScrollOffset = _scrollController.hasClients
        ? _scrollController.offset
        : null;
    ref.read(songsSearchAutoFocusProvider.notifier).state = true;
    _enableSearchFocusHandling();
    setState(() {
      _searchMode = true;
      _batchMode = false;
      _selectedIds.clear();
    });
  }

  void _closeSearch() {
    if (!_searchMode) return;
    _disableSearchFocusHandling();
    _searchFocusNode.unfocus();
    _searchController.clear();
    setState(() {
      _searchMode = false;
      _searchQuery = '';
      _selectedIds.clear();
    });
    final previousOffset = _preSearchScrollOffset;
    _preSearchScrollOffset = null;
    if (previousOffset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_searchMode && _scrollController.hasClients) {
          _scrollController.jumpTo(
            previousOffset.clamp(0, _scrollController.position.maxScrollExtent),
          );
        }
      });
    }
    // Keep old links/restored search routes working; new searches stay in place.
    if (widget.searchMode) context.go('/songs');
  }

  Future<void> _updatePlaylist(LocalPlaylist playlist) async {
    if (_updatingPlaylistIds.contains(playlist.id)) return;
    setState(() => _updatingPlaylistIds.add(playlist.id));
    try {
      final result = await ref
          .read(onlinePlaylistUpdaterProvider)
          .update(
            playlist: playlist,
            store: ref.read(localPlaylistsProvider.notifier),
          );
      if (!mounted) return;
      showAppToast(
        context,
        onlinePlaylistUpdateMessage(result),
        type: AppToastType.success,
      );
    } catch (error) {
      if (!mounted) return;
      showAppToast(context, '更新歌单失败：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _updatingPlaylistIds.remove(playlist.id));
    }
  }

  void _selectTab(SongsLibraryTab tab) {
    if (ref.read(songsLibraryTabProvider) == tab) return;
    ref.read(songsLibraryTabProvider.notifier).select(tab);
    ref.read(songsSearchAutoFocusProvider.notifier).state = false;
    _searchFocusNode.unfocus();
    setState(() {
      if (_searchMode) {
        _searchMode = false;
        _searchQuery = '';
        _searchController.clear();
      }
      _selectedIds.clear();
      _batchMode = false;
    });
  }

  void _setSort(SongSortMode mode, bool ascending) {
    if (!mounted || (_sortMode == mode && _ascending == ascending)) return;
    setState(() {
      _sortMode = mode;
      _ascending = ascending;
    });
    unawaited(_persistSongSortPreferences());
  }

  Future<void> _openSortSheet() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final toolbar = ref.read(shellToolbarVisibleProvider.notifier);
    final wasToolbarVisible = ref.read(shellToolbarVisibleProvider);
    toolbar.state = false;
    try {
      await showSongsSortSheet(
        context: context,
        initialMode: _sortMode,
        initialAscending: _ascending,
        onChanged: _setSort,
      );
    } finally {
      if (toolbar.mounted) toolbar.state = wasToolbarVisible;
    }
  }

  void _updateSearchQuery(String query) {
    if (_searchQuery == query) return;
    setState(() {
      _searchQuery = query;
      if (_batchMode) _selectedIds.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchMode && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _updateSearchQuery('');
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _persistSongSortPreferences() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await Future.wait([
      prefs.setString(_songSortModeKey, _sortMode.code),
      prefs.setBool(_songSortAscendingKey, _ascending),
    ]);
  }

  void _toggleVisibleSelection() {
    if (ref.read(songsLibraryTabProvider) == SongsLibraryTab.playlists) {
      _toggleSelectAllPlaylists(_visiblePlaylistIds);
      return;
    }
    _toggleSelectAll(_visibleSongs);
  }

  void _togglePlaylistSelection(String id) {
    setState(() {
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  void _toggleSelectAllPlaylists(List<String> ids) {
    if (ids.isEmpty) return;
    final targets = ids.toSet();
    setState(() {
      final selectedCount = _selectedIds.where(targets.contains).length;
      if (selectedCount == targets.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(targets);
      }
    });
  }

  Future<void> _reorderPlaylists(int oldIndex, int newIndex) async {
    await ref.read(localPlaylistsProvider.notifier).reorder(oldIndex, newIndex);
  }

  Future<void> _confirmRemoveSelectedPlaylists(
    List<LocalPlaylist> playlists,
  ) async {
    final selected = [
      for (final playlist in playlists)
        if (_selectedIds.contains(playlist.id)) playlist,
    ];
    if (selected.isEmpty) {
      showAppToast(context, '请先选择要移除的歌单', type: AppToastType.warning);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => prism.AlertDialog(
        title: '移除已选歌单？',
        // 玻璃确认框：描述移入 child，去掉 Material icon，按钮换成 prism。
        actions: [
          prism.TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          prism.FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
        child: Text('将移除 ${selected.length} 个歌单，本地下载的歌曲不会被删除。'),
      ),
    );
    if (confirmed != true || !mounted) return;
    final removed = await ref
        .read(localPlaylistsProvider.notifier)
        .deleteMany(selected.map((playlist) => playlist.id));
    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
      _batchMode = false;
    });
    showAppToast(
      context,
      removed == 0 ? '没有歌单被移除' : '已移除 $removed 个歌单',
      type: removed == 0 ? AppToastType.info : AppToastType.success,
    );
  }

  Future<void> _addSelectedToPlaylist(List<DownloadHistoryEntry> songs) async {
    final selected = songs
        .where((entry) => _selectedIds.contains(entry.id))
        .toList(growable: false);
    if (selected.isEmpty) {
      showAppToast(context, '请先选择歌曲', type: AppToastType.warning);
      return;
    }
    final playlist = await showPlaylistAddCard(context);
    if (!mounted || playlist == null) return;
    final added = await ref
        .read(localPlaylistsProvider.notifier)
        .addEntries(playlist.id, selected);
    if (!mounted) return;
    if (added == 0) {
      showAppToast(context, '所选歌曲已在这个歌单中', type: AppToastType.info);
      return;
    }
    setState(() {
      _selectedIds.clear();
      _batchMode = false;
    });
    showAppToast(context, '已加入 $added 首歌曲', type: AppToastType.success);
  }

  Future<void> _downloadSelected(List<DownloadHistoryEntry> songs) async {
    final selected = songs
        .where((entry) => _selectedIds.contains(entry.id))
        .toList(growable: false);
    if (selected.isEmpty) {
      showAppToast(context, '请先选择歌曲', type: AppToastType.warning);
      return;
    }
    final progress = ref.read(downloadProgressProvider);
    final musics = <MusicInfo>[];
    var skipped = 0;
    for (final entry in selected) {
      final music = entry.musicInfo;
      if (music == null ||
          (entry.savedPath?.isNotEmpty ?? false) ||
          progress.isMusicActive(music.id)) {
        skipped++;
        continue;
      }
      musics.add(music);
    }
    if (musics.isEmpty) {
      showAppToast(context, '所选歌曲都已在本地或正在下载', type: AppToastType.warning);
      return;
    }
    final available = await ensureOnlineMusicSourcesAvailable(
      context,
      musics.map((music) => music.source),
    );
    if (!available || !mounted) return;
    final tab = ref.read(songsLibraryTabProvider);
    try {
      final task = ref
          .read(batchDownloadProvider.notifier)
          .create(
            musics: musics,
            title: switch (tab) {
              SongsLibraryTab.liked => '我的喜欢',
              SongsLibraryTab.playlists => '歌单',
              SongsLibraryTab.local => '本地音乐',
            },
            quality: ref.read(settingsProvider).batchDownloadQuality,
            skippedCount: skipped,
          );
      setState(() {
        _selectedIds.clear();
        _batchMode = false;
      });
      showAppToast(
        context,
        '已创建任务 ${task.id}：${task.items.length} 首'
        '${task.skippedCount > 0 ? '，跳过 ${task.skippedCount} 首' : ''}'
        '，可在下载页管理',
        type: task.items.isEmpty ? AppToastType.warning : AppToastType.info,
        duration: const Duration(seconds: 4),
      );
    } catch (error) {
      if (mounted) {
        showAppToast(
          context,
          '批量下载失败：$error',
          type: AppToastType.error,
          duration: const Duration(seconds: 4),
        );
      }
    }
  }

  String _pathKey(String path) => _scanCache.pathKey(path);

  void _forgetTagCache(String path) {
    EmbeddedArtworkCache.evictPath(path);
  }

  void _toggleBatchMode() {
    _setBatchMode(!_batchMode);
  }

  void _setBatchMode(bool enabled) {
    if (_batchMode == enabled) return;
    _searchFocusNode.unfocus();
    setState(() {
      _batchMode = enabled;
      if (!enabled) _selectedIds.clear();
    });
  }

  void _toggleSelection(DownloadHistoryEntry entry) {
    setState(() {
      if (!_selectedIds.add(entry.id)) _selectedIds.remove(entry.id);
    });
  }

  void _toggleSelectAll(List<DownloadHistoryEntry> songs) {
    if (songs.isEmpty) return;
    final ids = {for (final entry in songs) entry.id};
    setState(() {
      final selectedCount = _selectedIds.where(ids.contains).length;
      if (selectedCount == ids.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(ids);
      }
    });
  }

  Future<void> _confirmDeleteSelected(List<DownloadHistoryEntry> songs) async {
    final selected = songs
        .where((entry) => _selectedIds.contains(entry.id))
        .toList(growable: false);
    if (selected.isEmpty) {
      showAppToast(context, '请先选择要删除的歌曲', type: AppToastType.warning);
      return;
    }

    await _deleteSongs(selected);
  }

  Future<void> _unlikeSelected(List<DownloadHistoryEntry> songs) async {
    final selected = songs
        .where((entry) => _selectedIds.contains(entry.id))
        .toList(growable: false);
    if (selected.isEmpty) {
      showAppToast(context, '请先选择歌曲', type: AppToastType.warning);
      return;
    }
    ref.read(likedSongsProvider.notifier).removeMany(selected);
    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
      _batchMode = false;
    });
    showAppToast(
      context,
      '已取消喜欢 ${selected.length} 首',
      type: AppToastType.success,
    );
  }

  void _syncToolbarState({
    required SongsLibraryTab tab,
    required String libraryTitle,
    required int songCount,
    required int selectedCount,
    required bool searchAutoFocus,
  }) {
    if (!TickerMode.valuesOf(context).enabled ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final allSelected = songCount > 0 && selectedCount == songCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !TickerMode.valuesOf(context).enabled ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      final current = ref.read(songsToolbarStateProvider);
      if (current.matchesView(
        owner: _toolbarOwner,
        libraryTitle: libraryTitle,
        tab: tab,
        songCount: songCount,
        selectedCount: selectedCount,
        allSelected: allSelected,
        batchMode: _batchMode,
        searchMode: _searchMode,
        searchAutoFocus: searchAutoFocus,
      )) {
        return;
      }
      ref.read(songsToolbarStateProvider.notifier).state = SongsToolbarState(
        owner: _toolbarOwner,
        libraryTitle: libraryTitle,
        tab: tab,
        songCount: songCount,
        selectedCount: selectedCount,
        allSelected: allSelected,
        batchMode: _batchMode,
        searchMode: _searchMode,
        searchAutoFocus: searchAutoFocus,
        onSelectTab: _selectTab,
        onSearch: _openSearch,
        onCloseSearch: _closeSearch,
        onSearchChanged: _updateSearchQuery,
        searchController: _searchController,
        searchFocusNode: _searchFocusNode,
        onShuffle: _shuffleVisibleSongs,
        onOpenHistory: _openHistory,
        onToggleBatch: _toggleBatchMode,
        onToggleSelectAll: _toggleVisibleSelection,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(songsLibraryTabProvider);
    final playlists = ref.watch(localPlaylistsProvider);
    final history = ref.watch(downloadHistoryProvider);
    final likedSongs = ref.watch(likedSongsProvider);
    final likedKeys = {for (final entry in likedSongs) songIdentityKey(entry)};
    final query = _searchQuery.trim();
    final searching = _searchMode && query.isNotEmpty;
    final librarySongs = _songs(history);
    final localSongs = tab == SongsLibraryTab.liked
        ? _likedSongs(likedSongs, librarySongs)
        : librarySongs;
    final songs = _searchMode
        ? filterSongsByQuery(localSongs, _searchQuery)
        : localSongs;
    final visiblePlaylists = !searching
        ? playlists
        : [
            for (final playlist in playlists)
              if (playlist.name.toLowerCase().contains(query.toLowerCase()))
                playlist,
          ];
    final playlistTab = tab == SongsLibraryTab.playlists;
    final scanning = !playlistTab && _scannedFiles == null;
    final playbackIdentity = ref.watch(
      playerControllerProvider.select((state) {
        final queueIndex = state.queueIndex;
        final queueEntry = queueIndex >= 0 && queueIndex < state.queue.length
            ? state.queue[queueIndex]
            : null;
        return (
          queueEntry: queueEntry,
          localPath: state.track?.localPath,
          trackId: state.track?.id,
          playing: state.playing,
        );
      }),
    );
    final artworkVersionByPath = <String, String>{
      for (final file in _scannedFiles ?? const <ScannedSongFile>[])
        _pathKey(file.path): file.fingerprint,
    };
    final selectedCount = playlistTab
        ? visiblePlaylists.where((p) => _selectedIds.contains(p.id)).length
        : songs.where((entry) => _selectedIds.contains(entry.id)).length;
    _visibleSongs = playlistTab ? const [] : songs;
    _visiblePlaylistIds = [
      for (final playlist in visiblePlaylists) playlist.id,
    ];
    _syncToolbarState(
      tab: tab,
      libraryTitle: '歌曲',
      songCount: playlistTab ? visiblePlaylists.length : songs.length,
      selectedCount: selectedCount,
      searchAutoFocus: ref.watch(songsSearchAutoFocusProvider),
    );

    final libraryView = AppScrollbar(
      controller: _scrollController,
      child: CustomScrollView(
        controller: _scrollController,
        key: PageStorageKey(
          '${widget.searchMode ? 'songs-search' : 'songs'}-${tab.name}-scroll',
        ),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          const SliverToBoxAdapter(child: ScrollHeaderSpacer()),
          // The tab capsule floats over the list, so the list only needs its
          // footprint kept clear here.
          const SliverToBoxAdapter(child: SizedBox(height: kSongsTabBarSlot)),
          if (playlistTab) ...[
            if (!searching && !_batchMode)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Expanded(
                        child: _LibraryQuickAction(
                          key: const ValueKey('playlists-quick-create'),
                          icon: Icons.create_new_folder_rounded,
                          label: '新建歌单',
                          onPressed: () => unawaited(_createPlaylist()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _LibraryQuickAction(
                          key: const ValueKey('playlists-quick-online'),
                          icon: Icons.cloud_download_outlined,
                          label: '在线导入',
                          onPressed: () => unawaited(_importOnlinePlaylist()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _LibraryQuickAction(
                          key: const ValueKey('playlists-quick-lx'),
                          icon: Icons.upload_file_rounded,
                          label:
                              _lxImportProgress ??
                              (_importingLx ? '正在导入' : '洛雪导入'),
                          onPressed: _importingLx
                              ? null
                              : () => unawaited(_importLxPlaylist()),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (visiblePlaylists.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 2),
                sliver: SliverToBoxAdapter(
                  child: SongsListSummary(
                    count: visiblePlaylists.length,
                    totalCount: playlists.length,
                    searching: searching,
                    sortMode: _sortMode,
                    ascending: _ascending,
                    batchMode: _batchMode,
                    onOpenSort: () => unawaited(_openSortSheet()),
                    onToggleBatch: visiblePlaylists.isEmpty
                        ? null
                        : _toggleBatchMode,
                    showSort: false,
                    collectionLabel: '歌单',
                  ),
                ),
              ),
            if (visiblePlaylists.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    // 与内容区同一测量口径：Expanded 且非搜索/批量态才给排序入口。
                    final wide = AppBreakpoints.isExpanded(
                      constraints.crossAxisExtent,
                    );
                    if (!wide || searching || _batchMode) {
                      return const SliverToBoxAdapter(child: SizedBox.shrink());
                    }
                    return SliverToBoxAdapter(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          key: const ValueKey('playlists-sort-mode-toggle'),
                          onPressed: () => setState(
                            () => _playlistSortMode = !_playlistSortMode,
                          ),
                          icon: Icon(
                            _playlistSortMode
                                ? Icons.check_rounded
                                : Icons.swap_vert_rounded,
                            size: 18,
                          ),
                          label: Text(_playlistSortMode ? '完成排序' : '排序'),
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (visiblePlaylists.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptySongs(
                  playlistMode: true,
                  title: searching ? '没有匹配的歌单' : '还没有歌单',
                  message: searching ? '换一个歌单名试试' : '从酷我、酷狗、QQ、网易云或咪咕导入公开歌单',
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  0,
                  12,
                  _batchMode
                      ? 12
                      : ShellBottomArea.contentPadding(context, 104),
                ),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    // 外层 SliverPadding 已保留左右各 12 的对称留白，这里按可用宽决定形态：
                    // Expanded 起用封面网格，排序模式下切回可拖拽列表。
                    final gridWidth = constraints.crossAxisExtent;
                    if (!AppBreakpoints.isExpanded(gridWidth) ||
                        _playlistSortMode) {
                      return SliverReorderableList(
                        itemCount: visiblePlaylists.length,
                        onReorderItem: (oldIndex, newIndex) {
                          unawaited(_reorderPlaylists(oldIndex, newIndex));
                        },
                        itemBuilder: (context, index) {
                          final playlist = visiblePlaylists[index];
                          return Padding(
                            key: ValueKey('songs-playlist-${playlist.id}'),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ReorderableDelayedDragStartListener(
                              index: index,
                              enabled: !_batchMode && !searching,
                              child: PlaylistLibraryTile(
                                playlist: playlist,
                                batchMode: _batchMode,
                                selected: _selectedIds.contains(playlist.id),
                                onToggleSelected: () =>
                                    _togglePlaylistSelection(playlist.id),
                                onOpen: () =>
                                    unawaited(_openPlaylist(playlist)),
                                onUpdate: playlist.isOnlineImport
                                    ? () => unawaited(_updatePlaylist(playlist))
                                    : null,
                                updating: _updatingPlaylistIds.contains(
                                  playlist.id,
                                ),
                                onUnfavorite: () =>
                                    unawaited(_unfavoritePlaylist(playlist)),
                              ),
                            ),
                          );
                        },
                      );
                    }
                    // 与发现页封面网格一致：目标格宽 240，窗口越宽列数越多，
                    // 避免大窗口下顶死少量列导致封面被撑得过大。
                    final columnCount = songsPlaylistGridColumnCount(gridWidth);
                    const gap = 10.0;
                    final cellWidth =
                        (gridWidth - gap * (columnCount - 1)) / columnCount;
                    // 卡片 = 正方形封面 + 底部元信息（padding 22 + 标题 20 + 间距 4 + meta 16）。
                    const metaHeight = 62.0;
                    final childAspectRatio =
                        cellWidth / (cellWidth + metaHeight);
                    final canReorder = !_batchMode && !searching;
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columnCount,
                        mainAxisSpacing: gap,
                        crossAxisSpacing: gap,
                        childAspectRatio: childAspectRatio,
                      ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final playlist = visiblePlaylists[index];
                        return WindowsPlaylistCoverCard(
                          playlist: playlist,
                          index: index,
                          total: visiblePlaylists.length,
                          batchMode: _batchMode,
                          selected: _selectedIds.contains(playlist.id),
                          canMoveUp: index > 0,
                          canMoveDown: index < visiblePlaylists.length - 1,
                          onOpen: () => unawaited(_openPlaylist(playlist)),
                          onUnfavorite: () =>
                              unawaited(_unfavoritePlaylist(playlist)),
                          onUpdate: playlist.isOnlineImport
                              ? () => unawaited(_updatePlaylist(playlist))
                              : null,
                          updating: _updatingPlaylistIds.contains(playlist.id),
                          onToggleSelected: () =>
                              _togglePlaylistSelection(playlist.id),
                          // 批量/搜索态不显示排序菜单（与手机端 enabled 条件一致）。
                          onMoveUp: canReorder && index > 0
                              ? () => unawaited(
                                  _reorderPlaylists(index, index - 1),
                                )
                              : null,
                          onMoveDown:
                              canReorder && index < visiblePlaylists.length - 1
                              ? () => unawaited(
                                  _reorderPlaylists(index, index + 1),
                                )
                              : null,
                        );
                      }, childCount: visiblePlaylists.length),
                    );
                  },
                ),
              ),
          ] else ...[
            if (localSongs.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 2),
                sliver: SliverToBoxAdapter(
                  child: SongsListSummary(
                    count: songs.length,
                    totalCount: localSongs.length,
                    searching: searching,
                    sortMode: _sortMode,
                    ascending: _ascending,
                    batchMode: _batchMode,
                    onOpenSort: () => unawaited(_openSortSheet()),
                    onToggleBatch: songs.isEmpty ? null : _toggleBatchMode,
                    collectionLabel: tab == SongsLibraryTab.liked
                        ? '喜欢的歌曲'
                        : '本地音乐',
                  ),
                ),
              ),
            if (localSongs.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child:
                    scanning &&
                        !(tab == SongsLibraryTab.liked && likedKeys.isEmpty)
                    ? const SongsLoading()
                    : tab == SongsLibraryTab.liked
                    ? const EmptySongs(
                        liked: true,
                        title: '还没有喜欢的歌曲',
                        message: '在歌曲列表点击右侧 ❤️ 即可收藏到这里',
                      )
                    : EmptySongs(error: _scanError),
              )
            else if (songs.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptySongSearch(),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  0,
                  12,
                  _batchMode
                      ? 12
                      : ShellBottomArea.contentPadding(context, 104),
                ),
                sliver: SliverList.separated(
                  key: _songsListKey,
                  itemCount: songs.length,
                  separatorBuilder: (_, _) => const SongListDivider(),
                  itemBuilder: (context, index) {
                    final entry = songs[index];
                    final path = entry.savedPath;
                    final playing = matchesPlayingEntry(
                      entry,
                      playbackIdentity.queueEntry,
                      playbackIdentity.localPath,
                      playbackIdentity.trackId,
                    );
                    return SongRow(
                      key: ValueKey(entry.id),
                      entry: entry,
                      artworkVersion: path == null
                          ? null
                          : artworkVersionByPath[_pathKey(path)],
                      playing: playing,
                      playingActive: playing && playbackIdentity.playing,
                      batchMode: _batchMode,
                      selected: _selectedIds.contains(entry.id),
                      liked: likedKeys.contains(songIdentityKey(entry)),
                      onToggleLike: () => _toggleLike(entry),
                      onToggleSelected: () => _toggleSelection(entry),
                      onAddNext: () => _addNext(entry),
                      onAddToPlaylist: () =>
                          unawaited(_selectPlaylistForSong(entry)),
                      onDownload: entry.musicInfo == null
                          ? null
                          : () => showQualityPickerSheet(
                              context,
                              entry.musicInfo!,
                            ),
                      onPlay: () => _play(entry, songs, replaceQueue: false),
                      onDelete: () => _deleteSong(entry),
                    );
                  },
                ),
              ),
          ],
        ],
      ),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      bottomNavigationBar: _batchMode
          ? (playlistTab
                ? PlaylistsBatchActionBar(
                    selectedCount: selectedCount,
                    onRemove: selectedCount == 0
                        ? null
                        : () => unawaited(
                            _confirmRemoveSelectedPlaylists(visiblePlaylists),
                          ),
                  )
                : SongsBatchActionBar(
                    selectedCount: selectedCount,
                    likedMode: tab == SongsLibraryTab.liked,
                    onDelete: selectedCount == 0
                        ? null
                        : (tab == SongsLibraryTab.liked
                              ? () => unawaited(_unlikeSelected(songs))
                              : () => unawaited(_confirmDeleteSelected(songs))),
                    onAddToPlaylist: selectedCount == 0
                        ? null
                        : () => unawaited(_addSelectedToPlaylist(songs)),
                    onPlaySelected: selectedCount == 0
                        ? null
                        : () => unawaited(_playSelected(songs)),
                    onDownloadSelected: selectedCount == 0
                        ? null
                        : () => unawaited(_downloadSelected(songs)),
                  ))
          : null,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_batchMode || playlistTab || tab == SongsLibraryTab.liked)
            libraryView
          else
            AppRefreshIndicator(
              onRefresh: _scanLocalMusicFolder,
              child: libraryView,
            ),
          // The capsule floats over the list, exactly like the dock: rows keep
          // scrolling underneath the glass instead of pushing it along.
          Positioned(
            top: ScrollHeaderInset.of(context),
            left: 14,
            right: 14,
            child: prism.SegmentedControl<SongsLibraryTab>(
              key: const ValueKey('songs-library-tabs'),
              segments: const [
                (SongsLibraryTab.liked, '喜欢'),
                (SongsLibraryTab.local, '本地音乐'),
                (SongsLibraryTab.playlists, '歌单'),
              ],
              value: tab,
              onChanged: _selectTab,
              iconBuilder: (option, selected) => Icon(
                option.icon,
                size: 17,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (!_batchMode && !playlistTab && playbackIdentity.trackId != null)
            Positioned(
              right: 18,
              bottom: ShellBottomArea.contentPadding(context, 88),
              child: FloatingActionButton.small(
                key: const ValueKey('songs-locate-current'),
                heroTag: null,
                tooltip: '定位当前歌曲',
                elevation: 3,
                onPressed: () => unawaited(_locateCurrentSong()),
                child: const Icon(Icons.my_location_rounded, size: 22),
              ),
            ),
        ],
      ),
    );
  }
}

/// One of the three shortcuts above the playlist list: 新建歌单 / 在线导入 /
/// 洛雪导入.
class _LibraryQuickAction extends StatelessWidget {
  const _LibraryQuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final content = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 17,
                color: enabled
                    ? scheme.onSurface
                    : scheme.onSurface.withValues(alpha: 0.38),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: enabled
                        ? scheme.onSurface
                        : scheme.onSurface.withValues(alpha: 0.38),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // Same material as the floating tab capsule above: real glass when the
    // scope allows it, the dock's flat fallback otherwise.
    final prismScheme = prism.Theme.of(context).colorScheme;
    if (prism.LiquidGlassScope.of(context)) {
      return prism.LiquidGlass(
        style: prism.LiquidGlassStyle.pill(prismScheme),
        shadows: prism.dockShadows(prismScheme),
        child: content,
      );
    }
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.62),
        shape: prism.AppShape.full,
        shadows: prism.dockShadows(prismScheme),
      ),
      child: content,
    );
  }
}

String _preferTag(String? value, String fallback) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? fallback : trimmed;
}

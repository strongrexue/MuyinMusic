import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter/material.dart' as material show SearchController;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/music_api.dart';
import '../../core/debug/debug_paint_guard.dart';
import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/models/search_category.dart';
import '../../core/storage/settings_store.dart';
import '../../core/ui/app_toast.dart';
import '../music_sources/music_source_action_guard.dart';
import '../player/player_controller.dart';
import '../playlists/playlist_models.dart';
import '../playlists/widgets/add_music_to_playlist.dart';
import 'search_controller.dart';
import 'search_history_store.dart';
import 'search_toolbar_state.dart';
import 'widgets/catalog_results.dart';
import 'widgets/quality_picker_sheet.dart';
import 'widgets/search_field.dart';
import 'widgets/search_filters.dart';
import 'widgets/search_history_suggestions.dart';

/// The complete online search surface: input, history/suggestions, category
/// tabs, the paged result list and the shell paging toolbar wiring.
///
/// It owns every piece of search state, so whichever page hosts it (the home
/// tab) is the only page that talks to [searchControllerProvider].
class OnlineSearchBody extends ConsumerStatefulWidget {
  const OnlineSearchBody({
    super.key,
    this.onClosed,
    this.openEntryOnMount = false,
  });

  /// Called when the user clears/leaves the search, so the host can pop back.
  final VoidCallback? onClosed;

  /// Opens the suggestion view (and the keyboard) as soon as this mounts.
  final bool openEntryOnMount;

  @override
  ConsumerState<OnlineSearchBody> createState() => _OnlineSearchBodyState();
}

class _OnlineSearchBodyState extends ConsumerState<OnlineSearchBody> {
  late final material.SearchController _controller;
  late final ScrollController _resultsScrollController;
  Object? _tipRequest;
  Iterable<Widget> _lastSuggestionWidgets = const <Widget>[];
  AppToastHandle? _searchErrorToast;
  StateController<SearchToolbarState>? _toolbarState;

  @override
  void initState() {
    super.initState();
    _controller = material.SearchController();
    // Loading replaces the list. Each new result starts at the top instead of
    // restoring the previous list's PageStorage offset when it reattaches.
    _resultsScrollController = ScrollController(keepScrollOffset: false);
    _controller.text = ref.read(searchControllerProvider).keyword;
    if (widget.openEntryOnMount) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openEntry());
    }
  }

  @override
  void dispose() {
    _tipRequest = null;
    _dismissSearchErrorToast();
    // The paging capsule is driven by this page, so it must not outlive it:
    // leaving the search surface with visible still true used to keep a stale
    // "第 N 页" pill (and hid the discovery category FAB) on the next route.
    final toolbarState = _toolbarState;
    _toolbarState = null;
    if (toolbarState != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          toolbarState.state = const SearchToolbarState();
        } catch (_) {
          // The provider container is already gone during app teardown.
        }
      });
    }
    _controller.dispose();
    _resultsScrollController.dispose();
    super.dispose();
  }

  Future<Iterable<Widget>> _buildSuggestionTiles(
    BuildContext context,
    material.SearchController controller,
  ) async {
    final query = controller.text.trim();
    if (query.isEmpty) {
      _tipRequest = null;
      _lastSuggestionWidgets = [
        SearchHistorySuggestions(
          onSelected: (keyword) => _runSearch(keyword: keyword),
        ),
      ];
      return _lastSuggestionWidgets;
    }

    // Identity-only marker — the SDK fan-out can't really cancel, so we just
    // ignore the result if a newer keystroke has started another tip lookup.
    final request = Object();
    _tipRequest = request;
    try {
      final api = ref.read(musicApiProvider);
      final tips = await api.searchTip(
        keyword: query,
        source: _sourceForSearchRequest(ref.read(searchControllerProvider)),
      );
      if (!identical(request, _tipRequest) || query != controller.text.trim()) {
        return _lastSuggestionWidgets;
      }
      final seen = <String>{};
      final items = tips
          .map((tip) => tip.trim())
          .where((tip) => tip.isNotEmpty && seen.add(tip))
          .take(8)
          .map(
            (tip) => SearchSuggestionTile(
              text: tip,
              onTap: () {
                controller.closeView(tip);
                _runSearch(keyword: tip);
              },
              onComplete: () {
                controller.text = tip;
                controller.selection = TextSelection.collapsed(
                  offset: controller.text.length,
                );
              },
            ),
          )
          .toList(growable: false);
      _lastSuggestionWidgets = items;
      return items;
    } on DioException {
      return _lastSuggestionWidgets;
    }
  }

  Future<void> _runSearch({
    String? keyword,
    int page = 1,
    bool scrollToTopOnSuccess = true,
    bool recordHistory = true,
  }) async {
    DebugPaintGuard.disableNow();
    final query = (keyword ?? _controller.text).trim();
    if (query.isEmpty) {
      showAppToast(context, '请输入歌曲、艺人、歌单或专辑', type: AppToastType.warning);
      return;
    }
    _controller.text = query;
    _controller.selection = TextSelection.collapsed(offset: query.length);
    if (_controller.isAttached && _controller.isOpen) {
      _controller.closeView(query);
    }
    _dismissTransientRoutes();
    _releaseSearchFocus();

    if (recordHistory) {
      ref.read(searchHistoryProvider.notifier).add(query);
    }

    final requestedSource = _sourceForSearchRequest(
      ref.read(searchControllerProvider),
    );
    await ref
        .read(searchControllerProvider.notifier)
        .search(keyword: query, source: requestedSource, page: page);
    if (!scrollToTopOnSuccess || !mounted) return;

    final completedState = ref.read(searchControllerProvider);
    final response = completedState.response;
    final requestStillMatches =
        !completedState.loading &&
        completedState.error == null &&
        completedState.keyword == query &&
        completedState.source == requestedSource &&
        completedState.page == page &&
        response?.page == page;
    if (!requestStillMatches) return;

    _resetResultsScroll();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchControllerProvider);
    final platformButtonOnLeft = ref.watch(
      settingsProvider.select((settings) => settings.platformButtonOnLeft),
    );

    ref.listen<Set<MusicSource>>(
      settingsProvider.select((settings) => settings.enabledSearchSources),
      (previous, next) {
        _tipRequest = null;
        _lastSuggestionWidgets = const <Widget>[];
      },
    );

    ref.listen<SearchState>(
      searchControllerProvider,
      _handleSearchStateChanged,
    );

    _syncToolbarState(state);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
          child: Row(
            children: [
              if (platformButtonOnLeft) ...[
                const SearchPlatformMenu(
                  key: ValueKey('search-platform-menu-slot'),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                key: const ValueKey('search-input-slot'),
                child: NativeSearchField(
                  controller: _controller,
                  onSubmitted: (v) => _runSearch(keyword: v),
                  loading: state.loading,
                  suggestionsBuilder: _buildSuggestionTiles,
                  onClear: _closeSearch,
                ),
              ),
              if (!platformButtonOnLeft) ...[
                const SizedBox(width: 10),
                const SearchPlatformMenu(
                  key: ValueKey('search-platform-menu-slot'),
                ),
              ],
            ],
          ),
        ),
        if (state.isSearchActive) ...[
          const SearchCategoryTabs(),
          const SizedBox(height: 4),
          Expanded(
            child: CatalogResults(
              state: state,
              scrollController: _resultsScrollController,
              onDownload: _openPicker,
              onPlay: _play,
              onAddToPlaylist: _selectPlaylistForMusic,
            ),
          ),
        ] else
          const Expanded(child: SearchIdleHint()),
      ],
    );
  }

  Future<void> _openPicker(MusicInfo music) async {
    await showQualityPickerSheet(context, music);
  }

  Future<void> _play(MusicInfo music) async {
    final available = await ensureOnlineMusicSourcesAvailable(context, [
      music.source,
    ]);
    if (!available || !mounted) return;
    final entry = PlaylistTrack.fromMusicInfo(
      music,
    ).toQueueEntry(playlistId: 'search');
    if (entry == null) return;
    // 点一首歌只把它插到当前曲后面播放，不再用整页结果替换队列。
    await ref.read(playerControllerProvider.notifier).playSingleQueueEntry(entry);
  }

  Future<void> _selectPlaylistForMusic(MusicInfo music) =>
      showAddMusicToPlaylist(context, ref, music);

  void _openEntry() {
    if (!mounted || _controller.isOpen) return;
    _controller.openView();
  }

  /// Clears the query and leaves the search surface entirely.
  void _closeSearch() {
    _controller.clear();
    if (_controller.isAttached && _controller.isOpen) {
      _controller.closeView('');
    }
    _tipRequest = null;
    _lastSuggestionWidgets = const <Widget>[];
    _dismissSearchErrorToast();
    ref.read(searchControllerProvider.notifier).resetToDiscovery();
    _releaseSearchFocus();
    widget.onClosed?.call();
  }

  /// Whether this search surface is the page the user is looking at.
  ///
  /// The search route is a nested page of the home branch, so it is `isActive`
  /// while the shell itself keeps another route on top of the branch stack —
  /// `isCurrent` is therefore too strict here.
  bool get _pageVisible {
    if (!TickerMode.valuesOf(context).enabled) return false;
    final route = ModalRoute.of(context);
    return route == null || route.isActive;
  }

  void _syncToolbarState(SearchState state) {
    if (!_pageVisible) {
      return;
    }
    _toolbarState = ref.read(searchToolbarStateProvider.notifier);
    final response = state.response;
    final hasResults =
        state.category != SearchCategory.all &&
        response != null &&
        response.hasResults;
    final allPage = response?.allPage ?? state.page;
    final canNext =
        hasResults && state.page < (allPage > 0 ? allPage : state.page + 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageVisible) {
        return;
      }
      final next = SearchToolbarState(
        visible: state.category != SearchCategory.all && (hasResults || state.page > 1),
        page: state.page,
        loading: state.loading,
        canPrev: state.page > 1,
        canNext: canNext,
        onPrev: () => _runSearch(
          page: state.page - 1,
          scrollToTopOnSuccess: true,
          recordHistory: false,
        ),
        onNext: () => _runSearch(
          page: state.page + 1,
          scrollToTopOnSuccess: true,
          recordHistory: false,
        ),
        onCloseSearch: state.isSearchActive ? _closeSearch : null,
      );
      // Always refresh the callbacks as well as the visible paging values.
      // They close over the current SearchState page; keeping an older state
      // object here makes the FAB look correct while invoking a stale page.
      ref.read(searchToolbarStateProvider.notifier).state = next;
    });
  }

  void _dismissTransientRoutes() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(
      context,
      rootNavigator: true,
    ).popUntil((route) => route.isFirst);
  }

  void _releaseSearchFocus() {
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  void _handleSearchStateChanged(SearchState? previous, SearchState next) {
    if (!mounted) return;
    if (previous != null &&
        (previous.category != next.category ||
            previous.source != next.source ||
            previous.keyword != next.keyword ||
            previous.page != next.page ||
            (next.response != null &&
                !identical(previous.response, next.response)))) {
      _resetResultsScroll();
    }
    if (next.error != null && next.error != previous?.error) {
      _dismissSearchErrorToast();
      _searchErrorToast = showAppToast(
        context,
        next.error!,
        type: AppToastType.error,
      );
    } else if (next.error == null && previous?.error != null) {
      _dismissSearchErrorToast();
    }
  }

  void _resetResultsScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_resultsScrollController.hasClients) return;
      _resultsScrollController.jumpTo(
        _resultsScrollController.position.minScrollExtent,
      );
    });
  }

  void _dismissSearchErrorToast() {
    final toast = _searchErrorToast;
    _searchErrorToast = null;
    dismissAppToast(toast, showRemoveAnimation: false);
  }

  MusicSource _sourceForSearchRequest(SearchState state) {
    final enabled = ref.read(settingsProvider).enabledSearchSources;
    return state.source == MusicSource.all || !enabled.contains(state.source)
        ? MusicSource.all
        : state.source;
  }
}

/// Shown while no query is active — the host page keeps its own content away.
class SearchIdleHint extends StatelessWidget {
  const SearchIdleHint({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_rounded,
            size: 38,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 12),
          Text(
            '搜索歌曲、艺人、歌单或专辑',
            style: TextStyle(
              fontSize: 13.5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

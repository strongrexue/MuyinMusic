import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/music_api.dart';
import '../../core/models/enums.dart';
import '../../core/models/playlist_category.dart';
import '../../core/models/playlist_summary.dart';
import '../../core/sdk/leaderboard_catalog.dart';
import '../../core/ui/app_refresh_indicator.dart';
import '../../core/ui/car_display_layout.dart';
import '../../theme/app_motion.dart';
import '../shell/shell_bottom_area.dart';
import 'discovery_browse_cache.dart';
import 'discovery_controller.dart';
import 'widgets/discovery_helpers.dart';
import 'widgets/discovery_placeholders.dart';
import 'widgets/discovery_source_transition.dart';
import 'widgets/leaderboard_spotlight.dart';
import 'widgets/masonry_playlist_grid.dart';

class DiscoveryContent extends ConsumerWidget {
  const DiscoveryContent({super.key, this.topPadding = 2});

  /// Room at the top of the list, e.g. so the floating source tabs can hover
  /// above the content while later rows scroll underneath them.
  final double topPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(selectedDiscoverySourceProvider);
    return DiscoverySourceTransition(
      source: source,
      child: _DiscoverySourcePage(
        key: ValueKey(source),
        source: source,
        topPadding: topPadding,
      ),
    );
  }
}

class _DiscoverySourcePage extends ConsumerWidget {
  const _DiscoverySourcePage({
    super.key,
    required this.source,
    required this.topPadding,
  });

  final MusicSource source;
  final double topPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only platforms with neither a leaderboard nor a playlist catalogue are
    // search-only. 汽水音乐 has no static leaderboard table but does publish a
    // playlist shelf, so it renders the normal page.
    if (leaderboardCatalogFor(source).isEmpty &&
        playlistCatalogCategoriesFor(source).isEmpty) {
      return _DiscoveryUnsupported(source: source);
    }
    final categoryId = ref.watch(selectedDiscoveryCategoryProvider(source));
    final tagId = ref.watch(selectedDiscoveryTagProvider(source));
    // 分类切换只更新精选歌单，排行榜所在的页面骨架保持挂载。
    return _DiscoveryList(
      source: source,
      categoryId: categoryId,
      tagId: tagId,
      topPadding: topPadding,
      browseCache: ref.watch(discoveryBrowseCacheProvider),
      featured: ref.watch(featuredPlaylistsProvider(source)),
      onRefresh: () async {
        ref.invalidate(featuredPlaylistsProvider(source));
        ref.invalidate(leaderboardBoardsProvider(source));
        await Future.wait([
          ref.read(featuredPlaylistsProvider(source).future),
          ref.read(leaderboardBoardsProvider(source).future),
        ]);
      },
      onRetry: () => ref.invalidate(featuredPlaylistsProvider(source)),
      onLoadMore: (page) => ref
          .read(musicApiProvider)
          .featuredPlaylists(
            source: source,
            page: page,
            limit: discoveryPlaylistPageSize,
            categoryId: categoryId,
            tagId: tagId,
          ),
    );
  }
}

/// Shown for platforms that only support search (e.g. 汽水音乐).
class _DiscoveryUnsupported extends StatelessWidget {
  const _DiscoveryUnsupported({required this.source});

  final MusicSource source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.explore_off_outlined,
              size: 44,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              '${source.label}音乐暂不支持发现页',
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '可以在首页搜索里直接找 ${source.label} 的歌曲、专辑和歌手',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoveryList extends StatefulWidget {
  const _DiscoveryList({
    required this.source,
    required this.categoryId,
    required this.tagId,
    required this.topPadding,
    required this.browseCache,
    required this.featured,
    required this.onRefresh,
    required this.onRetry,
    required this.onLoadMore,
  });

  final MusicSource source;
  final String categoryId;
  final String? tagId;
  final double topPadding;
  final DiscoveryBrowseCache browseCache;

  /// 当前分类的首页数据；loading / error 只影响歌单区块。
  final AsyncValue<List<PlaylistSummary>> featured;
  final Future<void> Function() onRefresh;
  final VoidCallback onRetry;
  final Future<List<PlaylistSummary>> Function(int page) onLoadMore;

  @override
  State<_DiscoveryList> createState() => _DiscoveryListState();
}

class _DiscoveryListState extends State<_DiscoveryList> {
  late final ScrollController _scrollController;
  late List<PlaylistSummary> _items;
  double _scrollOffset = 0;
  int _requestGeneration = 0;
  bool _scrollResetPending = false;
  var _nextPage = 2;
  var _loadingMore = false;
  var _hasMore = true;
  Object? _loadMoreError;

  /// 只认已到达的数据；分类切换期间 provider 处于 loading，此时不分页。
  List<PlaylistSummary>? get _loadedItems =>
      widget.featured.isLoading ? null : widget.featured.asData?.value;

  /// 网格的标识同时带上标签，换标签时整块重建而不是复用旧滚动位置。
  String get _gridKey =>
      'featured-grid-${widget.categoryId}-${widget.tagId ?? 'all'}';

  @override
  void initState() {
    super.initState();
    _reset(_loadedItems);
    final saved = widget.browseCache.restore(
      source: widget.source,
      categoryId: widget.categoryId,
      tagId: widget.tagId,
      firstPage: _loadedItems,
    );
    if (saved != null) {
      _items = saved.items;
      _nextPage = saved.nextPage;
      _hasMore = saved.hasMore;
      _scrollOffset = saved.scrollOffset;
    }
    // The offset belongs to the cached list. PageStorage must not restore an
    // old deep offset after that list was refreshed or evicted.
    _scrollController = ScrollController(
      initialScrollOffset: _scrollOffset,
      keepScrollOffset: false,
    )..addListener(_onScroll);
    _scheduleFillViewport();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (TickerMode.valuesOf(context).enabled) _scheduleFillViewport();
  }

  @override
  void didUpdateWidget(covariant _DiscoveryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldItems = oldWidget.featured.isLoading
        ? null
        : oldWidget.featured.asData?.value;
    if (oldWidget.source != widget.source ||
        oldWidget.categoryId != widget.categoryId ||
        oldWidget.tagId != widget.tagId ||
        !identical(oldItems, _loadedItems)) {
      _reset(_loadedItems);
      _scrollResetPending = true;
      final generation = _requestGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _requestGeneration) return;
        _scrollResetPending = false;
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
        _maybeLoadMore();
      });
      _scheduleFillViewport();
    }
  }

  @override
  void dispose() {
    _requestGeneration++;
    widget.browseCache.save(
      source: widget.source,
      categoryId: widget.categoryId,
      tagId: widget.tagId,
      firstPage: _loadedItems,
      items: _items,
      nextPage: _nextPage,
      hasMore: _hasMore,
      scrollOffset: _scrollOffset,
    );
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _reset(List<PlaylistSummary>? items) {
    _requestGeneration++;
    _scrollOffset = 0;
    _items = List<PlaylistSummary>.from(items ?? const <PlaylistSummary>[]);
    _nextPage = 2;
    _loadingMore = false;
    _hasMore = items != null && items.isNotEmpty;
    _loadMoreError = null;
  }

  void _scheduleFillViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
  }

  void _onScroll() {
    if (!_scrollResetPending && _scrollController.hasClients) {
      _scrollOffset = _scrollController.offset;
    }
    _maybeLoadMore();
  }

  void _maybeLoadMore() {
    if (!mounted ||
        _scrollResetPending ||
        !TickerMode.valuesOf(context).enabled ||
        !_scrollController.hasClients ||
        _scrollController.position.extentAfter > 600) {
      return;
    }
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loadedItems == null) return;
    final generation = _requestGeneration;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final page = await widget.onLoadMore(_nextPage);
      if (!mounted || generation != _requestGeneration) return;
      final seen = _items.map((item) => item.key).toSet();
      final additions = [
        for (final item in page)
          if (seen.add(item.key)) item,
      ];
      setState(() {
        _items = [..._items, ...additions];
        _nextPage++;
        _hasMore = page.isNotEmpty && additions.isNotEmpty;
      });
      if (_hasMore) _scheduleFillViewport();
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() => _loadMoreError = error);
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() => _loadingMore = false);
      }
    }
  }

  /// 「精选歌单」区块：加载 / 错误 / 空 / 网格。只有这一块随分类切换变化。
  /// 网格是懒加载的 sliver；加载、错误、空态放在常驻的切换器里淡入淡出。
  List<Widget> _buildFeaturedSlivers(double maxWidth) {
    final loaded = _loadedItems;
    Widget status;
    Key key;
    if (loaded == null) {
      key = ValueKey(
        widget.featured.hasError ? 'featured-error' : 'featured-loading',
      );
      status = widget.featured.hasError && !widget.featured.isLoading
          ? DiscoverySectionError(
              message: discoveryFriendlyError(widget.featured.error!),
              onRetry: widget.onRetry,
            )
          : const DiscoverySectionLoading();
    } else if (_items.isEmpty) {
      key = const ValueKey('featured-empty');
      status = const DiscoverySectionEmpty();
    } else {
      key = ValueKey(_gridKey);
      status = const SizedBox.shrink();
    }
    return [
      SliverToBoxAdapter(
        key: const ValueKey('featured-status'),
        child: AnimatedSwitcher(
          duration: AppMotion.medium,
          switchInCurve: AppMotion.emphasizedDecelerate,
          switchOutCurve: AppMotion.emphasizedAccelerate,
          // 只按当前内容占位：淡出的旧状态叠在网格上，不把卡片往下推。
          layoutBuilder: (current, previous) => Stack(
            clipBehavior: Clip.none,
            children: [
              for (final child in previous)
                Positioned(top: 0, left: 0, right: 0, child: child),
              ?current,
            ],
          ),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: animation.drive(
                Tween<Offset>(begin: const Offset(0, 0.025), end: Offset.zero),
              ),
              child: child,
            ),
          ),
          child: KeyedSubtree(key: key, child: status),
        ),
      ),
      if (loaded != null && _items.isNotEmpty) ...[
        SliverMasonryPlaylistGrid(
          key: ValueKey(_gridKey),
          items: _items,
          animateInitialItems: false,
          maxWidth: maxWidth,
        ),
        if (_loadingMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 18),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (_loadMoreError != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Center(
                child: IconButton.filledTonal(
                  tooltip: '重新加载',
                  onPressed: _loadMore,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ),
            ),
          ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final constraints = CarDisplayLayout.contentConstraints(
      context,
      maxWidth: 960,
    );
    return AppRefreshIndicator(
      onRefresh: widget.onRefresh,
      child: CustomScrollView(
        key: PageStorageKey('discovery-${widget.source.code}-scroll'),
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              12,
              widget.topPadding,
              12,
              ShellBottomArea.contentPadding(context, 156),
            ),
            sliver: SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: constraints,
                      child: LeaderboardSpotlight(source: widget.source),
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 20)),
                SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: constraints,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
                          child: Text(
                            '精选歌单',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                ..._buildFeaturedSlivers(constraints.maxWidth),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/app_refresh_indicator.dart';
import '../../theme/app_motion.dart';
import '../downloads/download_history_store.dart';
import '../player/player_controller.dart';
import '../shell/shell_bottom_area.dart';
import '../shell/widgets/scrolling_page_header.dart';
import 'home_feed.dart';
import 'recent_plays_store.dart';
import 'widgets/home_quick_actions.dart';
import 'widgets/home_search_capsule.dart';
import 'widgets/home_track_rail.dart';

/// Landing tab: what to continue, the shortcuts into the library and the two
/// recommendation shelves. Public content stays on 发现.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  static const _subtitles = <String>[
    '接着上次的播放，或者从这里开始',
    '今天想听点什么？',
    '为你挑了几首，先听听看',
    '换个角度，发现新的声音',
    '心情不错的话，来点节奏',
    '挑一首，让今天有点不一样',
    '老歌新听，也别有味道',
    '戴上耳机，世界安静一点',
  ];

  final _random = Random();
  int _subtitleIndex = 0;

  @override
  void initState() {
    super.initState();
    _subtitleIndex = _random.nextInt(_subtitles.length);
  }

  void _shuffleSubtitle() {
    if (_subtitles.length < 2) return;
    var next = _random.nextInt(_subtitles.length);
    if (next == _subtitleIndex) next = (next + 1) % _subtitles.length;
    _subtitleIndex = next;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final padding = ShellBottomArea.contentPadding(context, 156);
    return LayoutBuilder(
      builder: (context, constraints) {
        final shelfCount = homeShelfCountForWidth(constraints.maxWidth);
        return AppRefreshIndicator(
          onRefresh: () async {
            ref.invalidate(dailyPicksProvider(shelfCount));
            ref.invalidate(guessYouLikeProvider(shelfCount));
            setState(_shuffleSubtitle);
            await Future.wait([
              ref
                  .read(dailyPicksProvider(shelfCount).future)
                  .catchError((_) => const <DownloadHistoryEntry>[]),
              ref
                  .read(guessYouLikeProvider(shelfCount).future)
                  .catchError((_) => const <DownloadHistoryEntry>[]),
            ]);
          },
          child: CustomScrollView(
            key: const PageStorageKey('home-scroll'),
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              const SliverToBoxAdapter(child: ScrollHeaderSpacer()),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, padding),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    Text(
                      _greeting(DateTime.now()),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _subtitles[_subtitleIndex],
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const HomeSearchCapsule(),
                    const SizedBox(height: 18),
                    const HomeQuickActions(),
                    const SizedBox(height: 20),
                    _DailyPicksSection(shelfCount: shelfCount),
                    _GuessYouLikeSection(shelfCount: shelfCount),
                    const _RecentPlaysSection(),
                  ]),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _greeting(DateTime now) {
    final hour = now.hour;
    if (hour < 6) return '夜深了';
    if (hour < 12) return '早上好';
    if (hour < 14) return '中午好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(action!, style: const TextStyle(fontSize: 12.5)),
            ),
        ],
      ),
    );
  }
}

class _DailyPicksSection extends ConsumerWidget {
  const _DailyPicksSection({required this.shelfCount});

  final int shelfCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picks = ref.watch(dailyPicksProvider(shelfCount));
    return picks.when(
      loading: () => const _ShelfLoading(title: '每日推荐'),
      error: (_, _) => const SizedBox.shrink(),
      data: (entries) {
        if (entries.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: Column(
            key: const ValueKey('home-daily-picks'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionHeader(
                title: '每日推荐',
                action: '播放全部',
                onAction: () => _play(ref, entries, 0),
              ),
              HomeTrackRail(
                entries: entries,
                onPlay: (index) => _play(ref, entries, index),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _GuessYouLikeSection extends ConsumerWidget {
  const _GuessYouLikeSection({required this.shelfCount});

  final int shelfCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final picks = ref.watch(guessYouLikeProvider(shelfCount));
    return picks.when(
      loading: () => const _ShelfLoading(title: '猜你喜欢'),
      error: (_, _) => const SizedBox.shrink(),
      data: (entries) {
        if (entries.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: Column(
            key: const ValueKey('home-guess-you-like'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionHeader(title: '猜你喜欢'),
              HomeTrackRail(
                entries: entries,
                onPlay: (index) => _play(ref, entries, index),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RecentPlaysSection extends ConsumerWidget {
  const _RecentPlaysSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(recentPlaysProvider);
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('home-recent-plays'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '最近播放'),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '播放过的歌曲会出现在这里',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          HomeTrackRail(
            entries: entries,
            onPlay: (index) => _play(ref, entries, index),
          ),
      ],
    );
  }
}

class _ShelfLoading extends StatelessWidget {
  const _ShelfLoading({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(title: title),
          SizedBox(
            height: 128,
            child: Row(
              children: [
                for (var index = 0; index < 3; index++) ...[
                  if (index > 0) const SizedBox(width: 12),
                  Expanded(
                    child: AnimatedOpacity(
                      opacity: 0.55,
                      duration: AppMotion.medium,
                      child: Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void _play(WidgetRef ref, List<DownloadHistoryEntry> queue, int index) {
  if (queue.isEmpty) return;
  final safeIndex = index.clamp(0, queue.length - 1);
  ref
      .read(playerControllerProvider.notifier)
      .playFromHistoryQueue(queue[safeIndex], queue);
}

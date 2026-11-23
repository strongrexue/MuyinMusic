import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/settings_store.dart';
import '../../theme/app_motion.dart';
import '../shell/player_transition.dart';
import 'player_controller.dart';
import 'widgets/album_cluster.dart';
import 'widgets/immersive_background.dart';
import 'widgets/immersive_chrome.dart';
import 'widgets/ktv_lyrics_view.dart';
import 'widgets/lyrics_panel.dart';
import 'widgets/player_action_row.dart';
import 'widgets/player_control_color.dart';
import 'widgets/player_layout.dart';
import 'widgets/top_chrome_row.dart';
import 'widgets/transport_bar.dart';

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({
    super.key,
    required this.returnLocation,
    required this.progress,
    required this.active,
    required this.onDismissRequested,
  });

  final String returnLocation;

  /// Shell-owned reveal progress: 0 is the capsule, 1 is the full player.
  /// Background and controls follow separate phases of this same progress.
  final Animation<double> progress;

  /// True only while `/player` is the active route. The page stays mounted
  /// below that (during a pull, or parked at progress 0), so anything with
  /// side effects outside the page — error toasts, hit testing — must be
  /// gated on this.
  final bool active;

  /// Asks the shell to slide the page away and navigate to [target], or to
  /// the remembered return location when omitted.
  final void Function([String? target]) onDismissRequested;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  bool _systemBarsHidden = false;

  /// Continuous compact-pager position (0 = cover page, 1 = lyrics page),
  /// shared with the background and the top chrome: the integrated
  /// background's artwork component fades out over it, and the chrome's
  /// adaptive foreground follows.
  final ValueNotifier<double> _compactPageProgress = ValueNotifier(0);

  /// Landscape KTV is a full-screen stage, so the system bars hide while
  /// it is on screen; every other player state keeps the app-wide
  /// edge-to-edge mode set at startup. Guarded by [_systemBarsHidden] so
  /// the platform call only fires on transitions.
  void _syncKtvSystemUi(bool hide) {
    if (hide == _systemBarsHidden) return;
    _systemBarsHidden = hide;
    SystemChrome.setEnabledSystemUIMode(
      hide ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  @override
  void dispose() {
    if (_systemBarsHidden) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _compactPageProgress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch only what decides the page skeleton. `position` ticks every few
    // frames while playing; keeping it out of this watch stops the cover,
    // title and background from rebuilding on every tick.
    final showEmpty = ref.watch(
      playerControllerProvider.select((s) => s.track == null && !s.loading),
    );
    // In landscape KTV the top chrome (title, quality / timer / equalizer)
    // stays on screen in immersive mode; only the transport bar fades.
    final ktvChromePinned =
        ref.watch(
          settingsProvider.select((settings) => settings.ktvModeEnabled),
        ) &&
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    // Hide the system bars only while landscape KTV is actually the
    // active page; the page stays mounted (inactive) under other routes.
    _syncKtvSystemUi(ktvChromePinned && widget.active);
    // Landscape without KTV drops the three-band column: the body
    // takes the full height and the top chrome floats over it, so the
    // cover and lyrics read as one plane with the chrome on top.
    final landscapeFloating =
        !ktvChromePinned &&
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    final topChromeRow = TopChromeRow(
      onOpenEqualizer: () => widget.onDismissRequested('/settings/equalizer'),
      compactPageProgress: _compactPageProgress,
    );

    ref.listen<PlayerState>(playerControllerProvider, (prev, next) {
      // The page outlives the route, so without this guard a playback error
      // would raise a snack bar over whatever page the user is actually on.
      if (!widget.active) return;
      final error = next.error;
      if (error != null && error != prev?.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), duration: const Duration(seconds: 3)),
        );
      }
    });

    // The status bar icons follow the top chrome's adaptive foreground:
    // light while they float over a dark artwork top in portrait square
    // mode, theme-appropriate otherwise. The AnnotatedRegion restores the
    // surrounding style when the player leaves the top of the stack.
    final squareCoverEnabled = ref.watch(
      settingsProvider.select((s) => s.squareAlbumCoverEnabled),
    );
    final artworkTopLuminance = ref
        .watch(playerArtworkTopLuminanceProvider)
        .valueOrNull;
    final themeDark = Theme.of(context).brightness == Brightness.dark;

    // Back handling and pop scoping live in AppShell: this subtree is a
    // sibling of the route content rather than the route itself, so a
    // PopScope here would register against the shell's own ModalRoute.
    return ValueListenableBuilder<double>(
      valueListenable: _compactPageProgress,
      builder: (context, page, child) {
        final lightStatusIcons =
            themeDark ||
            artworkChromeLightForeground(
              squareCoverEnabled: squareCoverEnabled,
              portrait:
                  MediaQuery.orientationOf(context) == Orientation.portrait,
              topLuminance: artworkTopLuminance,
              pagerPage: page,
            );
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: lightStatusIcons
                ? Brightness.light
                : Brightness.dark,
            statusBarBrightness: lightStatusIcons
                ? Brightness.dark
                : Brightness.light,
          ),
          child: child!,
        );
      },
      child: IgnorePointer(
        ignoring: !widget.active,
        child: Scaffold(
          key: PlayerTransitionScope.maybeOf(context)?.pageKey,
          backgroundColor: Colors.transparent,
          // The layer is pinned to the full screen height; letting the
          // keyboard resize it would re-run the backdrop's blur pipeline.
          resizeToAvoidBottomInset: false,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                key: const ValueKey('player-backdrop'),
                child: FadeTransition(
                  opacity: widget.progress.drive(const PlayerPhase(0, 0.12)),
                  child: RepaintBoundary(
                    child: ImmersiveBackground(
                      revealProgress: widget.progress,
                      compactPageProgress: _compactPageProgress,
                    ),
                  ),
                ),
              ),
              FadeTransition(
                opacity: widget.progress.drive(const PlayerPhase(0.33, 0.86)),
                child: ImmersiveChrome(
                  active: widget.active,
                  // Landscape KTV stretches full-bleed like mainstream KTV
                  // apps: only the top chrome keeps its safe-area insets,
                  // the body reaches every screen edge.
                  child: ktvChromePinned
                      ? Column(
                          key: const ValueKey('player-chrome'),
                          children: [
                            SafeArea(bottom: false, child: topChromeRow),
                            Expanded(
                              child: showEmpty
                                  ? const _EmptyPlayer()
                                  : _NowPlayingBody(
                                      pageProgress: _compactPageProgress,
                                    ),
                            ),
                          ],
                        )
                      : landscapeFloating
                      ? SafeArea(
                          key: const ValueKey('player-chrome'),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              showEmpty
                                  ? const _EmptyPlayer()
                                  : _NowPlayingBody(
                                      pageProgress: _compactPageProgress,
                                    ),
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                child: topChromeRow,
                              ),
                            ],
                          ),
                        )
                      : SafeArea(
                          key: const ValueKey('player-chrome'),
                          child: Column(
                            children: [
                              topChromeRow,
                              Expanded(
                                child: showEmpty
                                    ? const _EmptyPlayer()
                                    : _NowPlayingBody(
                                        pageProgress: _compactPageProgress,
                                      ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NowPlayingBody extends ConsumerStatefulWidget {
  const _NowPlayingBody({this.pageProgress});

  /// Receives the compact pager's continuous position so the page-level
  /// background and chrome can follow it.
  final ValueNotifier<double>? pageProgress;

  @override
  ConsumerState<_NowPlayingBody> createState() => _NowPlayingBodyState();
}

class _NowPlayingBodyState extends ConsumerState<_NowPlayingBody> {
  late final PageController _pageController;
  int? _compactPagerPointer;
  Offset _compactPagerPointerDelta = Offset.zero;
  bool _compactPagerHorizontalDrag = false;
  bool _compactPagerScrolling = false;

  bool get _compactPagerMoving =>
      _compactPagerHorizontalDrag || _compactPagerScrolling;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _pageController.addListener(_reportCompactPageProgress);
  }

  void _reportCompactPageProgress() {
    final progress = widget.pageProgress;
    if (progress == null || !_pageController.hasClients) return;
    final page = _pageController.page;
    if (page != null) progress.value = page;
  }

  @override
  void dispose() {
    _pageController.removeListener(_reportCompactPageProgress);
    _pageController.dispose();
    super.dispose();
  }

  void _goToPage(int page) {
    if (!_pageController.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(page);
      return;
    }
    _pageController.animateToPage(
      page,
      duration: AppMotion.long,
      curve: AppMotion.emphasized,
    );
  }

  void _openLyricsPage() => _goToPage(1);

  bool _handleCompactPagerScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      // Shared artwork lives above the pager, so return it before scrolling
      // to let the page's movement and clipping apply immediately.
      PlayerTransitionScope.maybeOf(context)?.cancelCoverFlight();
      if (notification.dragDetails == null) {
        _setCompactPagerScrolling(true);
      }
    } else if (notification is ScrollEndNotification) {
      _setCompactPagerScrolling(false);
    }
    return false;
  }

  void _handleCompactPagerPointerDown(PointerDownEvent event) {
    if (_compactPagerPointer != null) return;
    _compactPagerPointer = event.pointer;
    _compactPagerPointerDelta = Offset.zero;
  }

  void _handleCompactPagerPointerMove(PointerMoveEvent event) {
    if (_compactPagerPointer != event.pointer || _compactPagerHorizontalDrag) {
      return;
    }
    _compactPagerPointerDelta += event.delta;
    if (_compactPagerPointerDelta.dx.abs() >= 4 &&
        _compactPagerPointerDelta.dx.abs() >
            _compactPagerPointerDelta.dy.abs()) {
      _setCompactPagerHorizontalDrag(true);
    }
  }

  void _handleCompactPagerPointerEnd(PointerEvent event) {
    if (_compactPagerPointer != event.pointer) return;
    _compactPagerPointer = null;
    _compactPagerPointerDelta = Offset.zero;
    if (_compactPagerHorizontalDrag && _pageController.hasClients) {
      final page = _pageController.page;
      _compactPagerScrolling =
          page != null && (page - page.roundToDouble()).abs() > 0.001;
    }
    _setCompactPagerHorizontalDrag(false);
  }

  void _setCompactPagerHorizontalDrag(bool value) {
    if (_compactPagerHorizontalDrag == value) return;
    if (value) PlayerTransitionScope.maybeOf(context)?.cancelCoverFlight();
    final wasMoving = _compactPagerMoving;
    _compactPagerHorizontalDrag = value;
    if (wasMoving != _compactPagerMoving) setState(() {});
  }

  void _setCompactPagerScrolling(bool value) {
    if (_compactPagerScrolling == value) return;
    final wasMoving = _compactPagerMoving;
    _compactPagerScrolling = value;
    if (wasMoving != _compactPagerMoving) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ktvModeEnabled = ref.watch(
      settingsProvider.select((settings) => settings.ktvModeEnabled),
    );
    final landscapeLyricAlignMode = ref.watch(
      settingsProvider.select((settings) => settings.lyricAlignModeLandscape),
    );
    // Portrait square covers live in the integrated background, so the
    // compact body drops its outer insets in that mode (inner rows
    // compensate by the same amount, keeping their on-screen positions
    // unchanged).
    final squareCoverEnabled = ref.watch(
      settingsProvider.select((settings) => settings.squareAlbumCoverEnabled),
    );
    final mediaSize = MediaQuery.sizeOf(context);
    if (ktvModeEnabled && mediaSize.width > mediaSize.height) {
      return const KtvPlayerLayout(key: ValueKey('player-ktv-layout'));
    }

    // Landscape (not KTV): a single-plane floating layout of its
    // own — cover left and lyrics right, both spanning the full
    // height under the floating top chrome (placed by the page), and
    // a merged bottom stack (one slim progress line, then a single
    // control row holding all ten buttons as one centred group)
    // floating over the same plane with no band behind it. The
    // lyrics panel gets landscape-scoped metrics (smaller edge fade,
    // centred scroll anchor, tighter rows) plus list insets that
    // clear the floating chrome and bottom stack, and follows the
    // separate landscape lyric alignment setting.
    if (mediaSize.width > mediaSize.height) {
      return Stack(
        key: const ValueKey('player-phone-landscape-layout'),
        fit: StackFit.expand,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: playerWideOuterInset,
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 10,
                  child: KeyedSubtree(
                    key: const ValueKey('player-phone-landscape-album'),
                    // The cover centres over the band above the
                    // floating bottom stack, not the full height, so
                    // its bottom edge never slides under the progress
                    // line floating over the plane.
                    child: Padding(
                      padding: const EdgeInsets.only(
                        bottom:
                            playerLandscapeBottomInset +
                            playerLandscapeBottomStackHeight,
                      ),
                      child: AlbumPage(
                        wide: true,
                        // The cover scales with the screen instead of
                        // filling its area: half the short side, the
                        // same proportion on phones and desktops.
                        wideCoverCap: mediaSize.shortestSide * 0.5,
                        wideMinCoverSize: 80,
                        wideShowMetadata: false,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: playerWideColumnGap),
                Expanded(
                  flex: 11,
                  child: KeyedSubtree(
                    key: const ValueKey('player-phone-landscape-lyrics'),
                    child: LyricsPanel(
                      edgeFadeExtent: 10,
                      // Long asymmetric fades matched to the list
                      // insets below: a line dissolves over the full
                      // height of the floating chrome at each edge
                      // instead of sliding under it still readable.
                      edgeFadeExtentTop: playerLandscapeChromeHeight + 12,
                      edgeFadeExtentBottom:
                          playerLandscapeBottomInset +
                          playerLandscapeBottomStackHeight +
                          12,
                      scrollAnchor: 0.5,
                      lineVerticalPadding: 4,
                      listPadding: const EdgeInsets.fromLTRB(
                        0,
                        playerLandscapeChromeHeight + 12,
                        0,
                        playerLandscapeBottomInset +
                            playerLandscapeBottomStackHeight +
                            12,
                      ),
                      alignMode: landscapeLyricAlignMode,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // One centred group on a shared pitch: the action segments
          // and the transport cluster use the same button series, so
          // the row no longer reads as three split clusters.
          const Positioned(
            left: playerWideOuterInset,
            right: playerWideOuterInset,
            bottom: playerLandscapeBottomInset,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TransportBar.progressLine(
                  key: ValueKey('player-phone-landscape-progress'),
                ),
                SizedBox(height: 2),
                Row(
                  key: ValueKey('player-phone-landscape-controls'),
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    PlayerActionRow.leading(),
                    SizedBox(width: playerLandscapeControlGap),
                    TransportBar.controlsRow(),
                    SizedBox(width: playerLandscapeControlGap),
                    PlayerActionRow.trailing(),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    }

    // Keep the lyrics' horizontal inset inside each row so their blur halos
    // have room before reaching the pager clips. Text starts at the same
    // position as the progress track, including the slider's own inset.
    return Padding(
      padding: squareCoverEnabled
          ? const EdgeInsets.fromLTRB(0, 0, 0, 14)
          : const EdgeInsets.fromLTRB(
              playerCompactOuterInset,
              4,
              playerCompactOuterInset,
              14,
            ),
      child: Column(
        children: [
          Expanded(
            child: NotificationListener<OverscrollIndicatorNotification>(
              key: const ValueKey('player-compact-pager-edge-guard'),
              onNotification: (notification) {
                if (notification.depth == 0) {
                  notification.disallowIndicator();
                }
                return false;
              },
              child: Listener(
                key: const ValueKey('player-compact-pager-pointer-guard'),
                behavior: HitTestBehavior.translucent,
                onPointerDown: _handleCompactPagerPointerDown,
                onPointerMove: _handleCompactPagerPointerMove,
                onPointerUp: _handleCompactPagerPointerEnd,
                onPointerCancel: _handleCompactPagerPointerEnd,
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleCompactPagerScroll,
                  child: Stack(
                    children: [
                      PageView(
                        key: const ValueKey('player-compact-pager'),
                        controller: _pageController,
                        onPageChanged: (_) => setState(() {}),
                        clipBehavior: Clip.hardEdge,
                        children: [
                          ClipRect(
                            key: const ValueKey('player-compact-album-clip'),
                            clipBehavior: Clip.hardEdge,
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: squareCoverEnabled
                                    ? 0
                                    : playerContentInset,
                              ),
                              child: AlbumPage(onOpenLyrics: _openLyricsPage),
                            ),
                          ),
                          ClipRect(
                            key: const ValueKey('player-compact-lyrics-clip'),
                            clipBehavior: Clip.hardEdge,
                            child: LyricsPanel(
                              edgeFadeEnabled: !_compactPagerMoving,
                              horizontalPadding: squareCoverEnabled
                                  ? playerCompactOuterInset +
                                        playerContentInset +
                                        playerProgressTrackInset
                                  : playerContentInset +
                                        playerProgressTrackInset,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: squareCoverEnabled
                  ? playerCompactOuterInset + playerContentInset
                  : playerContentInset,
            ),
            child: const PlayerActionRow(),
          ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: squareCoverEnabled
                  ? playerCompactOuterInset + playerContentInset
                  : playerContentInset,
            ),
            child: const TransportBar(),
          ),
        ],
      ),
    );
  }
}

class _EmptyPlayer extends StatelessWidget {
  const _EmptyPlayer();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.music_note_rounded,
              size: 56,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(
              '没有正在播放的歌曲哦',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

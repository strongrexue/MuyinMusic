import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/car_display_layout.dart';
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
import 'widgets/player_layout.dart';
import 'widgets/player_palette.dart';
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
    final topChromeRow = TopChromeRow(
      onOpenEqualizer: () =>
          widget.onDismissRequested('/settings/equalizer'),
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

    // Back handling and pop scoping live in AppShell: this subtree is a
    // sibling of the route content rather than the route itself, so a
    // PopScope here would register against the shell's own ModalRoute.
    return IgnorePointer(
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
                  child: ImmersiveBackground(revealProgress: widget.progress),
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
                                : const _NowPlayingBody(),
                          ),
                        ],
                      )
                    : SafeArea(
                        key: const ValueKey('player-chrome'),
                        child: Column(
                          children: [
                            topChromeRow,
                            Expanded(
                              child: showEmpty
                                  ? const _EmptyPlayer()
                                  : const _NowPlayingBody(),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingBody extends ConsumerStatefulWidget {
  const _NowPlayingBody();

  @override
  ConsumerState<_NowPlayingBody> createState() => _NowPlayingBodyState();
}

class _NowPlayingBodyState extends ConsumerState<_NowPlayingBody> {
  late final PageController _pageController;
  int _currentPage = 0;
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
  }

  @override
  void dispose() {
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

  void _openAlbumPage() => _goToPage(0);

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
    final mediaSize = MediaQuery.sizeOf(context);
    if (ktvModeEnabled && mediaSize.width > mediaSize.height) {
      return const KtvPlayerLayout(key: ValueKey('player-ktv-layout'));
    }
    final carPadModeEnabled =
        ref.watch(
          settingsProvider.select((settings) => settings.carPadModeEnabled),
        ) ||
        CarDisplayLayout.wideOf(context);
    if (carPadModeEnabled) {
      return Padding(
        key: const ValueKey('player-wide-layout'),
        padding: const EdgeInsets.fromLTRB(
          playerWideOuterInset,
          8,
          playerWideOuterInset,
          18,
        ),
        child: Row(
          children: [
            Expanded(
              flex: 10,
              child: Column(
                children: [
                  const Expanded(
                    child: KeyedSubtree(
                      key: ValueKey('player-wide-album'),
                      child: AlbumPage(wide: true),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const PlayerActionRow(),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: playerWideTransportMaxWidth,
                    ),
                    child: const TransportBar(),
                  ),
                ],
              ),
            ),
            const SizedBox(width: playerWideColumnGap),
            const Expanded(
              flex: 11,
              child: KeyedSubtree(
                key: ValueKey('player-wide-lyrics'),
                child: LyricsPanel(),
              ),
            ),
          ],
        ),
      );
    }

    // Keep the lyrics' horizontal inset inside each row so their blur halos
    // have room before reaching the pager clips. Text starts at the same
    // position as the progress track, including the slider's own inset.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
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
                        onPageChanged: (page) =>
                            setState(() => _currentPage = page),
                        clipBehavior: Clip.hardEdge,
                        children: [
                          ClipRect(
                            key: const ValueKey('player-compact-album-clip'),
                            clipBehavior: Clip.hardEdge,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: playerContentInset,
                              ),
                              child: AlbumPage(onOpenLyrics: _openLyricsPage),
                            ),
                          ),
                          ClipRect(
                            key: const ValueKey('player-compact-lyrics-clip'),
                            clipBehavior: Clip.hardEdge,
                            child: LyricsPanel(
                              edgeFadeEnabled: !_compactPagerMoving,
                              horizontalPadding:
                                  playerContentInset + playerProgressTrackInset,
                            ),
                          ),
                        ],
                      ),
                      Positioned(
                        right: 8,
                        bottom: 6,
                        child: _LyricsToggleButton(
                          showLyrics: _currentPage == 0,
                          onTap: _currentPage == 0
                              ? _openLyricsPage
                              : _openAlbumPage,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: playerContentInset),
            child: PlayerActionRow(),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: playerContentInset),
            child: TransportBar(),
          ),
        ],
      ),
    );
  }
}

class _LyricsToggleButton extends StatelessWidget {
  const _LyricsToggleButton({
    required this.showLyrics,
    required this.onTap,
  });

  /// True when currently on the album page (so the button offers lyrics).
  final bool showLyrics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = showLyrics ? '查看歌词' : '返回封面';
    final icon = showLyrics ? Icons.lyrics_rounded : Icons.album_rounded;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: playerInk(context).withValues(alpha: 0.10),
          shape: const StadiumBorder(),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15, color: playerInk(context)),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      color: playerInk(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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

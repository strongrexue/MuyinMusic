import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/enums.dart';
import '../../core/storage/settings_store.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/cover_image_source.dart';
import '../../theme/app_motion.dart';
import '../player/player_page.dart';
import '../player/widgets/player_control_color.dart';
import '../player/widgets/spinning_cover_art.dart';
import '../player/player_controller.dart';
import '../playlists/playlist_detail_toolbar_state.dart';
import '../search/search_controller.dart';
import '../search/search_toolbar_state.dart';
import '../settings/settings_section.dart';
import '../songs/songs_toolbar_state.dart';
import 'player_origin_state.dart';
import 'player_pull_scope.dart';
import 'player_transition.dart';
import 'shell_bottom_area.dart';
import 'shell_route_utils.dart';
import 'shell_toolbar_visibility.dart';
import 'tab_location_memory.dart';
import 'widgets/dual_capsule_bottom_navigation.dart';
import 'widgets/player_surface_clipper.dart';
import 'widgets/search_paging_fab.dart';
import 'widgets/toolbar_capsule.dart';
import 'widgets/toolbar_metrics.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({
    super.key,
    required this.child,
    required this.location,
    required this.routeLocation,
    required this.playerReturnLocation,
    required this.playlistBackLocation,
  });

  final Widget child;
  final String location;
  final String routeLocation;
  final String playerReturnLocation;
  final String playlistBackLocation;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with TickerProviderStateMixin {
  String _playerReturnLocation = '/songs';
  late final AnimationController _toolbarRevealController;

  /// How far the bottom chrome has folded away while a list scrolls: 0 keeps
  /// it in place, 1 applies the setting's full collapse or hide.
  late final AnimationController _chromeFold;
  double _chromeFoldTravel = 0;
  double _scrollFoldAccum = 0;

  /// The scrollable of the page currently under the floating chrome, captured
  /// from its scroll notifications so the folded dock anchor can jump the page
  /// back to the top without every page registering its controller.
  ScrollPosition? _pageScrollPosition;

  /// How much of a vertical drag accumulates before the chrome reacts.
  static const double _scrollFoldThreshold = 26;

  /// Player reveal progress: 0 parks the player layer below the screen, 1
  /// seats it. This is the single source of truth for entering, leaving and
  /// dragging the player — the page itself never animates.
  late final AnimationController _pull;
  late final PlayerPullGestures _pullGestures;

  /// Mounted lazily on first pull and never torn down again, so the backdrop's
  /// async blur pipeline only ever runs its cold start once.
  bool _playerLayerMounted = false;
  bool _pullActive = false;
  late final AnimationController _coverRotation;
  late final PlayerTransition _transition;
  int _pullGeneration = 0;
  double? _settleTarget;
  bool _settledExpanded = false;
  bool _dragFromPlayer = false;
  double _dragStartProgress = 0;
  Timer? _returnToDesktopTimer;
  AppToastHandle? _returnToDesktopToast;

  @override
  void initState() {
    super.initState();
    _toolbarRevealController = AnimationController(
      vsync: this,
      value: 1,
      duration: AppMotion.medium,
    );
    _chromeFold = AnimationController(
      vsync: this,
      value: 0,
      duration: AppMotion.medium,
    );
    final startsOnPlayer = widget.location == '/player';
    _settledExpanded = startsOnPlayer;
    _pull = AnimationController(
      vsync: this,
      value: startsOnPlayer ? 1 : 0,
      duration: AppMotion.medium,
    );
    _playerLayerMounted = startsOnPlayer;
    _playerReturnLocation = normalizedPlayerReturnLocation(
      startsOnPlayer ? widget.playerReturnLocation : widget.routeLocation,
      '/songs',
    );
    _coverRotation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    _transition = PlayerTransition(progress: _pull, rotation: _coverRotation);
    _syncCoverRotation();
    // Built once: the tear-offs below are stable across builds, so dependents
    // of PlayerPullScope never rebuild.
    _pullGestures = PlayerPullGestures(
      onWarm: _handlePullWarm,
      onStart: _handlePullStart,
      onUpdate: _handlePullUpdate,
      onEnd: _handlePullEnd,
      onCancel: _handlePullCancel,
      onOpen: _handleOpenPlayer,
      onClose: _dismissPlayer,
    );
    _rememberTabLocation();
  }

  void _syncCoverRotation() {
    final rotate =
        ref.read(playerControllerProvider).playing &&
        !ref.read(settingsProvider).squareAlbumCoverEnabled;
    if (rotate) {
      if (!_coverRotation.isAnimating) _coverRotation.repeat();
    } else {
      _coverRotation.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    _resetTopLevelBack();
    _toolbarRevealController.dispose();
    _chromeFold.dispose();
    _transition.dispose();
    _coverRotation.dispose();
    _pull.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.routeLocation != widget.routeLocation) {
      _rememberTabLocation();
    }
    if (oldWidget.location != widget.location) {
      _setChromeFolded(false);
      // The "came from the player" hand-off only covers the page it opened.
      if (oldWidget.location == '/settings/equalizer') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref.read(pageOpenedFromPlayerProvider.notifier).state = null;
          }
        });
      }
      _resetTopLevelBack();
      // Keep the bottom controls fully revealed when the route shell changes.
      if (!_pullActive && _pull.value == 0) {
        _toolbarRevealController.value = 1;
      }
      if (widget.location == '/player') {
        _playerReturnLocation = normalizedPlayerReturnLocation(
          widget.playerReturnLocation,
          oldWidget.routeLocation,
        );
        _playerLayerMounted = true;
        if (_pull.value < 1 && _settleTarget != 1 && !_pullActive) {
          _commitPull();
        }
      } else {
        if (oldWidget.location == '/player') {
          _settledExpanded = false;
          // Closing releases the route immediately. Its visual tail remains
          // in this shell and must not be snapped away by the route update.
          if (_settleTarget != 0) {
            _pullGeneration++;
            _settleTarget = null;
            _pull.stop();
            _pull.value = 0;
            _animateToolbarTo(1);
          }
        } else if (_settleTarget != 0) {
          _playerReturnLocation = normalizedPlayerReturnLocation(
            widget.location,
            _playerReturnLocation,
          );
        }
      }
      if (widget.location == '/songs/search') {
        FocusManager.instance.primaryFocus?.unfocus();
      } else {
        _releaseRouteFocus();
      }
    }
  }

  double get _pullExtent => _transition.travel;

  String get _contentLocation => widget.location == '/player'
      ? Uri.parse(_playerReturnLocation).path
      : widget.location;

  void _handlePullWarm() {
    if (_settleTarget == 0) return;
    _transition.capture();
    if (!_playerLayerMounted) setState(() => _playerLayerMounted = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _transition.capture();
    });
  }

  void _handleOpenPlayer() {
    _releaseRouteFocus();
    _handlePullWarm();
    _pullActive = false;
    _commitPull();
  }

  void _handlePullStart({bool fromPlayer = false}) {
    // A released dismiss belongs to the underlying page. Only an explicit
    // new pull on the capsule may open the player again during its tail.
    if (fromPlayer && _settleTarget == 0) return;
    _pullGeneration++;
    _settleTarget = null;
    _pull.stop();
    _handlePullWarm();
    _pullActive = true;
    _dragFromPlayer = fromPlayer;
    _dragStartProgress = _pull.value;
    _toolbarRevealController.stop();
    _releaseRouteFocus();
  }

  void _handlePullUpdate(double dy) {
    if (!_pullActive || dy == 0) return;
    _pull.value = (_pull.value - dy / _pullExtent).clamp(0.0, 1.0);
  }

  void _handlePullEnd(double velocityDy) {
    if (!_pullActive) return;
    _pullActive = false;
    final reveal = PlayerMotion.shouldExpand(
      progress: _pull.value,
      travel: _pullExtent,
      velocityY: velocityDy,
      wasExpanded: _settledExpanded,
      fromPlayer: _dragFromPlayer,
      startProgress: _dragStartProgress,
    );
    if (reveal) {
      _commitPull(velocityDy: velocityDy);
    } else {
      _settleClosed(velocityDy: velocityDy);
    }
  }

  void _handlePullCancel() {
    if (!_pullActive) return;
    _pullActive = false;
    if (_settledExpanded) {
      _commitPull();
    } else {
      _settleClosed();
    }
  }

  Future<void> _commitPull({double velocityDy = 0}) async {
    final generation = ++_pullGeneration;
    _settleTarget = 1;
    if (!_playerLayerMounted) setState(() => _playerLayerMounted = true);
    // Lay out the real destination before the first visible shared-cover frame.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _pullGeneration) return;
    _transition.capture();
    // The transparent route keeps the origin alive. Activate the controls
    // immediately instead of waiting through the spring's subpixel tail.
    if (widget.location != '/player') {
      _playerReturnLocation = widget.routeLocation;
      unawaited(context.push<void>('/player', extra: _playerReturnLocation));
    }
    try {
      await _animatePullTo(1, velocityDy: velocityDy).orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || generation != _pullGeneration || _pull.value != 1) return;
    _settledExpanded = true;
    _settleTarget = null;
  }

  Future<void> _dismissPlayer([String? target]) => _settleClosed(
    destination: target,
    velocityDy: -_pull.velocity * _pullExtent,
  );

  Future<void> _settleClosed({
    String? destination,
    double velocityDy = 0,
  }) async {
    final generation = ++_pullGeneration;
    _pullActive = false;
    setState(() {
      _settleTarget = 0;
      _settledExpanded = false;
    });
    _transition.capture();
    // Remove the transparent route and its modal barrier before animating,
    // so the next pointer can scroll/click the live page immediately.
    if (widget.location == '/player') {
      if (destination == null && GoRouter.of(context).canPop()) {
        context.pop();
      } else {
        if (destination != null) {
          // Remember that the player opened this page, so its back button can
          // return here instead of the tab underneath.
          ref.read(pageOpenedFromPlayerProvider.notifier).state =
              _playerReturnLocation;
        }
        context.go(destination ?? _playerReturnLocation);
      }
    }
    try {
      await _animatePullTo(0, velocityDy: velocityDy).orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || generation != _pullGeneration || _pull.value != 0) return;
    setState(() => _settleTarget = null);
    _animateToolbarTo(1);
  }

  TickerFuture _animatePullTo(double target, {double velocityDy = 0}) {
    if ((_pull.value - target).abs() < 1e-9 ||
        MediaQuery.disableAnimationsOf(context)) {
      _pull.value = target;
      return TickerFuture.complete();
    }
    return _pull.animateWith(
      PlayerSpringSimulation(
        _pull.value,
        target,
        -velocityDy / _pullExtent,
        distanceTolerance:
            0.01 / (MediaQuery.devicePixelRatioOf(context) * _pullExtent),
      ),
    );
  }

  /// Records the current route (full URI including query) as the last visited
  /// location of its bottom-toolbar tab, so tab taps can restore it later.
  void _rememberTabLocation() {
    final location = widget.location;
    final routeLocation = widget.routeLocation;
    if (location == '/player') return;
    final index = toolbarIndexFor(location);
    if (index == 2) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final memory = ref.read(tabLocationMemoryProvider);
      if (memory[index] == routeLocation) return;
      ref.read(tabLocationMemoryProvider.notifier).state = {
        ...memory,
        index: routeLocation,
      };
    });
  }

  Future<bool> _handleBackButton() async {
    final navigator = Navigator.of(context, rootNavigator: true);
    if (navigator.canPop()) {
      await navigator.maybePop();
      return true;
    }
    final popupNavigator = _nestedPopupNavigator();
    if (popupNavigator != null) {
      _resetTopLevelBack();
      await popupNavigator.maybePop();
      return true;
    }
    if (widget.location == '/player') {
      _pullActive = false;
      unawaited(_dismissPlayer());
      return true;
    }
    // Mid-pull: put the player back where it came from instead of navigating.
    if (_pullActive ||
        (_pull.value > 0 &&
            _settleTarget != 0 &&
            widget.location != '/player')) {
      _pullActive = false;
      unawaited(_settleClosed());
      return true;
    }
    if (isSongsLibraryLocation(widget.location)) {
      final songsToolbar = ref.read(songsToolbarStateProvider);
      if (songsToolbar.batchMode && songsToolbar.onToggleBatch != null) {
        songsToolbar.onToggleBatch!();
        return true;
      }
      if (songsToolbar.searchMode && songsToolbar.onCloseSearch != null) {
        songsToolbar.onCloseSearch!();
        return true;
      }
    }
    if (isPlaylistDetailLocation(widget.location)) {
      final playlistToolbar = ref.read(playlistDetailToolbarStateProvider);
      if (playlistToolbar.batchMode && playlistToolbar.onToggleBatch != null) {
        playlistToolbar.onToggleBatch!();
        return true;
      }
      if (playlistToolbar.searchMode &&
          playlistToolbar.onToggleSearch != null) {
        playlistToolbar.onToggleSearch!();
        return true;
      }
    }
    if (widget.location == '/' &&
        ref.read(searchControllerProvider).isSearchActive) {
      final closeSearch = ref.read(searchToolbarStateProvider).onCloseSearch;
      if (closeSearch != null) {
        _resetTopLevelBack();
        closeSearch();
        return true;
      }
    }

    _releaseRouteFocus();
    final settingsParent = settingsParentLocation(widget.location);
    final playerOrigin = ref.read(pageOpenedFromPlayerProvider);
    if (_isTopLevelMenuLocation(widget.location)) {
      await _handleTopLevelBack();
    } else if (widget.location == '/downloads' ||
        widget.location == '/songs/search') {
      context.go('/songs');
    } else if (playerOrigin != null && settingsParent != null) {
      // Back out of a page the player opened into the player again.
      context.go('/player', extra: playerOrigin);
    } else if (settingsParent != null) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(settingsParent);
      }
    } else if (context.canPop()) {
      context.pop();
    } else if (isDiscoveryLocation(widget.location) && widget.location != '/') {
      context.go('/');
    } else if (isPlaylistLocation(widget.location)) {
      context.go(widget.playlistBackLocation);
    } else {
      unawaited(_moveAppTaskToBack());
    }
    return true;
  }

  NavigatorState? _nestedPopupNavigator() {
    RouteMatchBase match = GoRouter.of(
      context,
    ).routerDelegate.currentConfiguration.matches.last;
    // Sheets and menus belong to the navigator that opened them, including
    // retained tab navigators. Inspect outer overlays before inner ones.
    while (match is ShellRouteMatch) {
      final navigator = match.navigatorKey.currentState;
      if (navigator == null ||
          ModalRoute.of(navigator.context)?.isCurrent == false) {
        break;
      }
      var hasPopup = false;
      navigator.popUntil((route) {
        hasPopup = route is PopupRoute || route.willHandlePopInternally;
        return true; // Inspect the top route without popping a page.
      });
      if (hasPopup) return navigator;
      match = match.matches.last;
    }
    return null;
  }

  Future<void> _handleTopLevelBack() async {
    if (_returnToDesktopTimer?.isActive ?? false) {
      _resetTopLevelBack();
      await _moveAppTaskToBack();
      return;
    }

    _resetTopLevelBack();
    _returnToDesktopToast = showAppToast(
      context,
      '再次点击返回键切换到桌面',
      duration: _doubleBackExitWindow,
    );
    _returnToDesktopTimer = Timer(_doubleBackExitWindow, () {
      _returnToDesktopTimer = null;
      _returnToDesktopToast = null;
    });
  }

  void _resetTopLevelBack() {
    _returnToDesktopTimer?.cancel();
    _returnToDesktopTimer = null;
    dismissAppToast(_returnToDesktopToast, showRemoveAnimation: false);
    _returnToDesktopToast = null;
  }

  void _releaseRouteFocus() {
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  void _animateToolbarTo(double target) {
    if (_pullActive) return;
    if ((_toolbarRevealController.value - target).abs() < 0.001) {
      _toolbarRevealController.value = target;
      return;
    }
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _toolbarRevealController.value = target;
      return;
    }
    final remaining = (_toolbarRevealController.value - target).abs();
    _toolbarRevealController.animateTo(
      target,
      duration: Duration(milliseconds: (140 + 180 * remaining).round()),
      curve: AppMotion.emphasized,
    );
  }

  void _setChromeFolded(bool folded) {
    final target = folded ? 1.0 : 0.0;
    if ((_chromeFold.value - target).abs() < 0.001) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _chromeFold.value = target;
      return;
    }
    _chromeFold.animateTo(
      target,
      duration: AppMotion.medium,
      curve: AppMotion.emphasized,
    );
  }

  bool _handleChromeScroll(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    if (notification.depth == 0) {
      // `metrics` is a snapshot, not the live position, so ask the scrollable
      // that raised the notification for its own position.
      final context = notification.context;
      if (context != null) {
        _pageScrollPosition = Scrollable.maybeOf(context)?.position;
      }
    }
    if (ref.read(settingsProvider).bottomBarBehavior ==
        BottomBarBehavior.always) {
      _setChromeFolded(false);
      return false;
    }
    if (notification is ScrollEndNotification) {
      // Only a genuine return to the top expands the bars again; the settle at
      // the end of a downward fling must keep them folded.
      if (metrics.extentBefore <= 4) _setChromeFolded(false);
      _scrollFoldAccum = 0;
      return false;
    }
    if (notification is! ScrollUpdateNotification) return false;
    final delta = notification.scrollDelta ?? 0;
    if (delta.abs() < 0.5) return false;
    // Rubber-band overscroll reports deltas that pull against the gesture.
    if (metrics.pixels > metrics.maxScrollExtent + 0.5) return false;
    _scrollFoldAccum = _scrollFoldAccum.sign == delta.sign
        ? _scrollFoldAccum + delta
        : delta;
    if (_scrollFoldAccum > _scrollFoldThreshold &&
        metrics.pixels > metrics.minScrollExtent + 24) {
      _setChromeFolded(true);
      _scrollFoldAccum = 0;
    } else if (_scrollFoldAccum < -_scrollFoldThreshold) {
      _setChromeFolded(false);
      _scrollFoldAccum = 0;
    }
    return false;
  }

  /// Sent by the folded dock's round capsule: bring the page back to its top.
  void _scrollPageToTop() {
    final position = _pageScrollPosition;
    if (position == null || !position.hasContentDimensions) return;
    final target = position.minScrollExtent;
    if ((position.pixels - target).abs() < 0.5) return;
    unawaited(
      position.animateTo(
        target,
        duration: AppMotion.medium,
        curve: AppMotion.emphasized,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep artwork sampling tied to song selection, including before the
    // lazily mounted player is first opened. Listening also retains its result.
    ref.listen(playerArtworkColorsProvider, (_, _) {});
    final contentLocation = _contentLocation;
    final contentRoute = widget.location == '/player'
        ? _playerReturnLocation
        : widget.routeLocation;
    final viewport = MediaQuery.sizeOf(context);
    _transition.devicePixelRatio = View.of(context).devicePixelRatio;
    if (_transition.viewport != viewport) {
      _transition.viewport = viewport;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _transition.capture(refreshSource: true);
      });
    }
    _transition.bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    ref.listen(
      playerControllerProvider.select((s) => s.playing),
      (_, _) => _syncCoverRotation(),
    );
    ref.listen(
      settingsProvider.select((s) => s.squareAlbumCoverEnabled),
      (_, _) => _syncCoverRotation(),
    );
    final pageBackground = Theme.of(context).scaffoldBackgroundColor;
    final isPlayer = widget.location == '/player';
    final showPlayerBar = ref.watch(
      playerControllerProvider.select(
        (state) => state.hasTrack || state.loading,
      ),
    );
    final shellControlsVisible =
        MediaQuery.viewInsetsOf(context).bottom == 0 &&
        ref.watch(shellToolbarVisibleProvider) &&
        !(isSongsLibraryLocation(contentLocation) &&
            ref.watch(
              songsToolbarStateProvider.select((state) => state.batchMode),
            )) &&
        !(isPlaylistDetailLocation(contentLocation) &&
            ref.watch(
              playlistDetailToolbarStateProvider.select(
                (state) => state.batchMode,
              ),
            ));
    final dualBottomExtent =
        shellControlsVisible
        ? floatingCapsuleBottomAreaHeight(context, showPlayer: showPlayerBar)
        : 0.0;
    final bottomBarBehavior = ref.watch(
      settingsProvider.select((settings) => settings.bottomBarBehavior),
    );
    _chromeFoldTravel = dualBottomExtent;

    ref.listen<bool>(shellToolbarVisibleProvider, (previous, next) {
      if (next && previous == false) _animateToolbarTo(1);
    });
    ref.listen<SongsToolbarState>(songsToolbarStateProvider, (previous, next) {
      if (!isSongsLibraryLocation(contentLocation)) return;
      if (next.batchMode) {
        _toolbarRevealController.stop(canceled: false);
      } else if (previous?.batchMode == true) {
        _animateToolbarTo(1);
      }
    });
    ref.listen<PlaylistDetailToolbarState>(playlistDetailToolbarStateProvider, (
      previous,
      next,
    ) {
      if (!isPlaylistDetailLocation(contentLocation)) return;
      if (next.batchMode) {
        _toolbarRevealController.stop(canceled: false);
      } else if (previous?.batchMode == true) {
        _animateToolbarTo(1);
      }
    });

    return BackButtonListener(
      onBackButtonPressed: _handleBackButton,
      child: PlayerTransitionScope(
        transition: _transition,
        child: PlayerPullScope(
          gestures: _pullGestures,
          child: ShellBottomArea(
            extent: dualBottomExtent,
            floatingExtent: dualBottomExtent,
            child: Scaffold(
              extendBody: true,
              resizeToAvoidBottomInset: true,
              backgroundColor: pageBackground,
              body: NotificationListener<ScrollNotification>(
                onNotification: _handleChromeScroll,
                child: Stack(
                  key: _transition.rootKey,
                  // Every child carries an explicit key so element matching never
                  // falls back to list position. The player layer slot below appears
                  // and disappears, and without keys that index shift would rebuild
                  // the toolbar subtree — killing any in-flight drag recognizer.
                  children: [
                    Positioned.fill(
                      key: const ValueKey('shell-content'),
                      child: ColoredBox(
                        color: pageBackground,
                        // Keep the outer navigator mounted across tab changes;
                        // its StatefulShellRoute owns the retained branch stacks.
                        child: RepaintBoundary(
                          child: ClipRect(child: widget.child),
                        ),
                      ),
                    ),
                    // The paging FAB belongs to the search surface only: its
                    // state is written by OnlineSearchBody and is never cleared
                    // when that page goes away, so mounting it on the discovery
                    // route leaked a stale "第 1 页" capsule there.
                    if (isHomeSearchLocation(contentLocation))
                      const Positioned.fill(
                        key: ValueKey('shell-search-fab'),
                        child: SearchPagingFabLayer(),
                      ),
                    _buildPlayerLayer(isPlayer),
                    Positioned(
                      key: const ValueKey('shell-toolbar'),
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: AnimatedBuilder(
                        animation: _pull,
                        builder: (context, child) {
                          final blocked =
                              _pull.value > 0 &&
                              !(_settleTarget == 0 && _pull.value < 0.2);
                          return IgnorePointer(
                            ignoring: blocked,
                            child: ExcludeSemantics(
                              excluding: blocked,
                              child: child!,
                            ),
                          );
                        },
                        child: _FoldingBottomChrome(
                          fold: _chromeFold,
                          behavior: bottomBarBehavior,
                          travel: dualBottomExtent > 0
                              ? dualBottomExtent
                              : _chromeFoldTravel,
                          child: FloatingCapsuleBottomNavigation(
                            location: contentLocation,
                            routeLocation: contentRoute,
                            showPlayer: showPlayerBar,
                            visible: shellControlsVisible,
                            reveal: _toolbarRevealController,
                            isPlayer: isPlayer,
                            fold: bottomBarBehavior == BottomBarBehavior.leftFold
                                ? _chromeFold
                                : null,
                            onFoldedAnchorTap: _scrollPageToTop,
                            onFoldedPlayerTap: _handleOpenPlayer,
                          ),
                        ),
                      ),
                    ),
                    _buildSharedCoverLayer(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerLayer(bool isPlayer) {
    if (!_playerLayerMounted) {
      return const Positioned(
        key: ValueKey('shell-player'),
        left: 0,
        top: 0,
        width: 0,
        height: 0,
        child: SizedBox.shrink(),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      key: const ValueKey('shell-player'),
      left: 0,
      right: 0,
      top: 0,
      height: MediaQuery.sizeOf(context).height,
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: AnimatedBuilder(
          animation: _transition,
          child: PlayerPage(
            returnLocation: _playerReturnLocation,
            progress: _pull,
            active: isPlayer,
            onDismissRequested: _dismissPlayer,
          ),
          builder: (context, child) {
            final p = _pull.value;
            final visible = p > 0 || isPlayer;
            final interactive = visible && _settleTarget != 0;
            return IgnorePointer(
              ignoring: !interactive,
              child: ExcludeSemantics(
                excluding: !interactive,
                child: TickerMode(
                  enabled: visible,
                  child: Opacity(
                    opacity: visible ? 1 : 0,
                    child: PlayerPullHandle(
                      child: Stack(
                        fit: StackFit.expand,
                        clipBehavior: Clip.none,
                        children: [
                          ClipPath(
                            key: const ValueKey('player-surface-clip'),
                            clipBehavior: p == 1 ? Clip.none : Clip.antiAlias,
                            clipper: PlayerSurfaceClipper(
                              _transition.surface,
                              _transition.screenCorners.curve,
                              _transition.cornerBlend,
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ColoredBox(color: toolbarCapsuleColor(scheme)),
                                Transform.translate(
                                  key: const ValueKey('player-exit-slide'),
                                  offset: Offset(0, (1 - p) * _pullExtent),
                                  child: child,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSharedCoverLayer() {
    final square = ref.watch(
      settingsProvider.select((s) => s.squareAlbumCoverEnabled),
    );
    // Portrait square mode has no shared cover flight: the page's own
    // integrated background artwork (a full-width square at the top of the
    // screen) is the destination surface, while the flight targets the
    // cover hot-zone rect, so both covers would be on screen at once
    // during the reveal. The page slide/fade carries the transition.
    final suppressFlight =
        square &&
        MediaQuery.orientationOf(context) == Orientation.portrait;
    final track = ref.watch(playerControllerProvider.select((s) => s.track));
    final scheme = Theme.of(context).colorScheme;
    // Paint above the returning capsule background. This overlay never owns
    // input, even while the cover overlaps an interactive part of the page.
    return Positioned.fill(
      key: const ValueKey('shell-shared-cover'),
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: AnimatedBuilder(
            animation: _transition,
            child: RotationTransition(
              turns: square
                  ? const AlwaysStoppedAnimation<double>(0)
                  : _coverRotation,
              child: RepaintBoundary(
                child: PlayerArtworkImage(
                  url: CoverImageSource.normalizeUrl(
                    track?.coverUrl,
                    size: 700,
                  ),
                  bytes: track?.coverBytes,
                  placeholder: ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: const Center(child: Icon(Icons.album_rounded)),
                  ),
                ),
              ),
            ),
            builder: (context, child) {
              final flight = track == null ? null : _transition.coverRect;
              final destination = _transition.fullCover;
              final visible =
                  flight != null && destination != null && !suppressFlight;
              final artworkRect = destination ?? Rect.zero;
              return Stack(
                children: [
                  // Keep this image subscribed between flights so it retains
                  // the same ready artwork as the mini and full player covers.
                  Positioned.fromRect(
                    rect: artworkRect,
                    child: Offstage(
                      offstage: !visible,
                      child: TickerMode(
                        enabled: true,
                        child: Transform.translate(
                          offset: visible
                              ? flight.topLeft - artworkRect.topLeft
                              : Offset.zero,
                          child: Transform.scale(
                            scale: visible
                                ? flight.width / artworkRect.width
                                : 1,
                            alignment: Alignment.topLeft,
                            child: RepaintBoundary(
                              key: const ValueKey('player-shared-cover'),
                              child: square
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(
                                        artworkRect.width *
                                            kSquareCoverRadiusFactor,
                                      ),
                                      child: child,
                                    )
                                  : ClipOval(child: child),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

const _doubleBackExitWindow = Duration(seconds: 2);

/// Applies the configured scroll behaviour to the floating mini player and
/// dock: folding shrinks it towards the bottom edge, hiding slides it away.
class _FoldingBottomChrome extends StatelessWidget {
  const _FoldingBottomChrome({
    required this.fold,
    required this.behavior,
    required this.travel,
    required this.child,
  });

  final Animation<double> fold;
  final BottomBarBehavior behavior;
  final double travel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 向左折叠 is painted inside the bars themselves (each folds towards its
    // left anchor), so this wrapper only drives 滚动折叠 and 滚动隐藏.
    if (behavior == BottomBarBehavior.leftFold) return child;
    final hiding = behavior == BottomBarBehavior.hide;
    return AnimatedBuilder(
      animation: fold,
      child: child,
      builder: (context, child) {
        final amount = fold.value.clamp(0.0, 1.0);
        if (amount == 0) return child!;
        return IgnorePointer(
          ignoring: amount > 0.4,
          child: ExcludeSemantics(
            excluding: amount > 0.4,
            child: Opacity(
              opacity: hiding ? 1 - 0.35 * amount : 1 - 0.1 * amount,
              child: Transform.translate(
                offset: Offset(0, travel * (hiding ? amount : 0.42 * amount)),
                child: Transform.scale(
                  scale: hiding ? 1 : 1 - 0.08 * amount,
                  alignment: Alignment.bottomCenter,
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

bool _isTopLevelMenuLocation(String location) {
  return location == '/' || location == '/songs' || location == '/settings';
}

const _appTaskChannel = MethodChannel('panghu_music/app_task');

Future<void> _moveAppTaskToBack() async {
  try {
    await _appTaskChannel.invokeMethod<bool>('moveToBack');
  } catch (_) {
    // If the native channel is unavailable, still consume back so Android does
    // not destroy the Flutter route stack.
  }
}

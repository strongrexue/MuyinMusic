import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/icons/icons.dart' as prism_glyph;
import 'package:prism_ui/icons/prism_glyphs.dart' as prism_glyphs;

import '../../../core/ui/music_action_glyphs.dart';
import '../../player/player_controller.dart';
import '../../player/widgets/spinning_cover_art.dart';
import '../../../theme/app_motion.dart';
import '../player_transition.dart';
import '../shell_navigation.dart';
import 'floating_player_bar.dart';
import 'toolbar_metrics.dart';

// NavigationDock reserves 21dp at either side of its visible surface. Keep the
// player 16dp inside those edges so it stays secondary to the dock.
const double _navigationDockHorizontalInset = 21;
const double _playerHorizontalInset = 16;
// The dock's own shadow room supplies the visible gap above its surface.
const double _navigationDockShadowRoom = 8;
const double _floatingDockMaxWidth = 360;

// Once a bar has folded into its left anchor, nudge the whole bar further left
// so the round capsule hugs the screen edge instead of sitting a full icon
// position inside it.
const double _foldedLeftShift = 26;

double floatingCapsuleNavBarHeight(BuildContext context) =>
    _navigationDockShadowRoom + prism.NavigationDock.insetOf(context);

// Legacy helper name retained for callers outside the shell.
double dualCapsuleNavBarHeight(BuildContext context) =>
    floatingCapsuleNavBarHeight(context);

double dualCapsulePlayerHeight(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  return math.max(
    // Keep enough room for the mini player's title and artist at large text
    // scales while the dock remains visually compact.
    50,
    (scaler.scale(14) + scaler.scale(11.5)) * 1.2 + 13,
  );
}

double floatingCapsuleBottomAreaHeight(
  BuildContext context, {
  required bool showPlayer,
}) =>
    floatingCapsuleNavBarHeight(context) +
    (showPlayer ? dualCapsulePlayerHeight(context) : 0);

// Legacy helper name retained while downstream callers migrate.
double dualCapsuleBottomAreaHeight(
  BuildContext context, {
  required bool showPlayer,
}) => floatingCapsuleBottomAreaHeight(context, showPlayer: showPlayer);

class FloatingCapsuleBottomNavigation extends ConsumerWidget {
  const FloatingCapsuleBottomNavigation({
    super.key,
    required this.location,
    required this.routeLocation,
    required this.showPlayer,
    required this.visible,
    required this.reveal,
    this.isPlayer = false,
    this.fold,
    this.onFoldedAnchorTap,
    this.onFoldedPlayerTap,
  });

  final String location;
  final String routeLocation;
  final bool showPlayer;
  final bool visible;
  final Animation<double> reveal;
  final bool isPlayer;

  /// Drives the scroll "collapse" behaviour: 0 keeps the bars at full width,
  /// 1 folds each bar into its left anchor (the cover art, the home icon).
  final Animation<double>? fold;

  /// Tapped once the dock has folded into its single round capsule.
  final VoidCallback? onFoldedAnchorTap;

  /// Tapped on the folded mini player's round cover, which opens the player.
  final VoidCallback? onFoldedPlayerTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transition = PlayerTransitionScope.maybeOf(context);
    final navOpacity = transition == null
        ? AlwaysStoppedAnimation(isPlayer ? 0.0 : 1.0)
        : ReverseAnimation(
            transition.progress.drive(const PlayerPhase(0, 0.2)),
          );
    final controls = SafeArea(
      top: false,
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final dockWidth = math.min(
            constraints.maxWidth,
            _floatingDockMaxWidth,
          );
          final playerHeight = dualCapsulePlayerHeight(context);
          final navHeight = floatingCapsuleNavBarHeight(context);
          final dockBarHeight = prism.NavigationDock.heightOf(context);
          final barWidth = math.max<double>(
            0,
            dockWidth -
                (_navigationDockHorizontalInset + _playerHorizontalInset) * 2,
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showPlayer)
                Center(
                  child: _FoldedBar(
                    fold: fold,
                    label: 'player',
                    width: barWidth,
                    height: playerHeight,
                    collapsedWidth: playerHeight - 8,
                    leftInset: 4,
                    collapsedTop: 4,
                    foldShift: _foldedLeftShift,
                    // The capsule itself fades with the player transition
                    // inside ToolbarCapsule; this round cover is drawn beside
                    // it, so it needs the same fade or it stays pinned to the
                    // bottom-left corner of the open player page.
                    collapsedChild: FadeTransition(
                      opacity: navOpacity,
                      child: _FoldedPlayerAnchor(
                        key: const ValueKey('folded-player-anchor'),
                        size: playerHeight - 8,
                        onTap: onFoldedPlayerTap,
                      ),
                    ),
                    child: FloatingPlayerBar(
                      routeLocation: routeLocation,
                      width: barWidth,
                      height: playerHeight,
                    ),
                  ),
                ),
              FadeTransition(
                opacity: navOpacity,
                child: Center(
                  child: _FoldedBar(
                    fold: fold,
                    label: 'dock',
                    width: dockWidth,
                    height: navHeight,
                    collapsedWidth: playerHeight - 8,
                    // Line the circle up under the mini player's folded cover.
                    leftInset: 4 + (dockWidth - barWidth) / 2,
                    collapsedTop:
                        _navigationDockShadowRoom +
                        (dockBarHeight - (playerHeight - 8)) / 2,
                    foldShift: _foldedLeftShift,
                    collapsedChild: _FoldedDockAnchor(
                      key: const ValueKey('folded-dock-anchor'),
                      size: playerHeight - 8,
                      onTap: onFoldedAnchorTap,
                    ),
                    child: _FloatingCapsuleNavBar(
                      location: location,
                      routeLocation: routeLocation,
                      width: dockWidth,
                      height: navHeight,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );

    final travel = floatingCapsuleBottomAreaHeight(
      context,
      showPlayer: showPlayer,
    );
    return ExcludeSemantics(
      excluding: !visible,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 1),
          duration: AppMotion.medium,
          curve: AppMotion.emphasized,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: AppMotion.short,
            child: AnimatedBuilder(
              animation: reveal,
              child: controls,
              builder: (context, child) {
                final progress = reveal.value.clamp(0.0, 1.0).toDouble();
                return IgnorePointer(
                  ignoring: progress <= toolbarHitTestRevealThreshold,
                  child: Opacity(
                    opacity: toolbarOpacityFor(progress),
                    child: Transform.translate(
                      offset: Offset(0, (1 - progress) * travel),
                      child: child,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// Source compatibility for code written before the single/double capsule
// modes were consolidated into the Prism UI-style floating dock.
typedef DualCapsuleBottomNavigation = FloatingCapsuleBottomNavigation;

/// The round cover the mini player folds into.
class _FoldedPlayerAnchor extends ConsumerWidget {
  const _FoldedPlayerAnchor({super.key, required this.size, this.onTap});

  final double size;

  /// Opens the player even while the bar is folded down to this cover.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final track = ref.watch(
      playerControllerProvider.select((state) => state.track),
    );
    return Semantics(
      button: true,
      label: '打开播放页',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ClipOval(
          child: SizedBox.square(
            dimension: size,
            child: track == null
                ? ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: Center(
                      child: Icon(
                        Icons.album_rounded,
                        size: size * 0.45,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : SpinningCoverArt(
                    track: track,
                    size: size,
                    placeholder: ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Center(
                        child: Icon(
                          Icons.album_rounded,
                          size: size * 0.45,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// The round capsule the dock folds into: a single icon, no label.
class _FoldedDockAnchor extends StatelessWidget {
  const _FoldedDockAnchor({super.key, required this.size, this.onTap});

  final double size;

  /// Jumped back to the top of the page the capsule is sitting on.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: '回到顶部',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.32 : 0.06),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: prism_glyph.GlyphIcon(
              prism_glyphs.AppGlyphs.homeFilled,
              size: size * 0.54,
              color: scheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Folds a capsule bar towards its left anchor: the layout box keeps its full
/// width so the bars stay centred, while the painted part narrows to
/// [collapsedWidth] with a rounded right cap once [fold] reaches 1.
class _FoldedBar extends StatelessWidget {
  const _FoldedBar({
    required this.fold,
    required this.label,
    required this.width,
    required this.height,
    required this.collapsedWidth,
    required this.child,
    this.leftInset = 0,
    this.collapsedTop = 0,
    this.collapsedChild,
    this.foldShift = 0,
  });

  final Animation<double>? fold;
  final String label;
  final double width;
  final double height;
  final double collapsedWidth;

  /// How far the collapsed circle sits from the bar's left edge, so it can be
  /// centred on the bar's first icon rather than on the bar itself.
  final double leftInset;

  /// Vertical placement of [collapsedChild] inside the bar's box.
  final double collapsedTop;

  /// Drawn in place of the clipped bar once the fold is nearly complete.
  final Widget? collapsedChild;

  /// Extra distance the whole bar travels left as [fold] completes, so the
  /// collapsed capsule hugs the screen edge.
  final double foldShift;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final animation = fold;
    if (animation == null) return child;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final amount = animation.value.clamp(0.0, 1.0);
        if (amount == 0) return child!;
        final visible = width + (collapsedWidth - width) * amount;
        final inset = leftInset * amount;
        final swap = collapsedChild == null
            ? 0.0
            : ((amount - 0.55) / 0.45).clamp(0.0, 1.0);
        return Transform.translate(
          offset: Offset(-foldShift * amount, 0),
          child: SizedBox(
            key: ValueKey('folded-$label'),
            width: width,
            height: height,
            child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: inset,
                top: 0,
                bottom: 0,
                child: Opacity(
                  opacity: 1 - swap,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(height / 2),
                    child: SizedBox(
                      width: visible,
                      height: height,
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: width,
                        maxWidth: width,
                        minHeight: height,
                        maxHeight: height,
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
              if (collapsedChild != null && swap > 0)
                Positioned(
                  left: inset + (visible - collapsedWidth) / 2,
                  top: collapsedTop,
                  width: collapsedWidth,
                  height: collapsedWidth,
                  child: Opacity(opacity: swap, child: collapsedChild!),
                ),
            ],
          ),
          ),
        );
      },
    );
  }
}

class _FloatingCapsuleNavBar extends ConsumerWidget {
  const _FloatingCapsuleNavBar({
    required this.location,
    required this.routeLocation,
    required this.width,
    required this.height,
  });

  final String location;
  final String routeLocation;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedIndex = switch (toolbarIndexFor(location)) {
      4 => 0, // 首页
      0 => 1, // 发现
      1 => 2, // 歌曲
      _ => 3, // 设置
    };
    const destinations = [
      prism.NavigationDockDestination(
        glyph: prism_glyphs.AppGlyphs.homeFilled,
        label: '首页',
      ),
      prism.NavigationDockDestination(
        glyph: prism_glyphs.AppGlyphs.dashboard,
        label: '发现',
      ),
      prism.NavigationDockDestination(
        glyph: MusicActionGlyphs.musicLibrary,
        label: '歌曲',
      ),
      prism.NavigationDockDestination(
        glyph: prism_glyphs.AppGlyphs.settings,
        label: '设置',
      ),
    ];
    return SizedBox(
      width: width,
      height: height,
      child: prism.NavigationDock(
        key: const ValueKey('floating-navigation-dock'),
        maxWidth: width,
        destinations: destinations,
        selectedIndex: selectedIndex,
        onSelected: (index) => navigateToShellTab(
          context,
          ref,
          location,
          routeLocation,
          const ['/home', '/', '/songs', '/settings'][index],
        ),
      ),
    );
  }
}

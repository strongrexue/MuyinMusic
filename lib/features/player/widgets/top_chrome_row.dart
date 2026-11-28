import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/storage/settings_store.dart';
import '../../cast/cast_session.dart';
import '../../cast/widgets/cast_device_sheet.dart';
import '../../cast/widgets/cast_status_strip.dart';
import '../../equalizer/widgets/equalizer_popup.dart';
import '../../shell/player_pull_scope.dart';
import '../player_controller.dart';
import '../sleep_timer_controller.dart';
import 'ktv_background_panel.dart';
import 'player_control_color.dart';
import 'player_palette.dart';
import 'player_quality_sheet.dart';
import 'player_sleep_timer_sheet.dart';
import 'track_change_switcher.dart';

/// Session-only "force landscape" switch for the player page. The top-bar
/// button flips this; the player page is what calls
/// `SystemChrome.setPreferredOrientations`, and it clears the switch when
/// the page stops being the active route, so the lock never outlives the
/// player.
class LandscapeLockController extends StateNotifier<bool> {
  LandscapeLockController() : super(false);

  void toggle() => state = !state;

  void clear() {
    if (state) state = false;
  }
}

final landscapeLockProvider =
    StateNotifierProvider<LandscapeLockController, bool>(
      (ref) => LandscapeLockController(),
    );

/// Top bar: track title/artist on the left, then the source · quality entry
/// (opens the quality sheet), the force-landscape lock, and a "more" menu
/// holding the KTV mode switch, the sleep timer, the background picker, and
/// the equalizer entry.
class TopChromeRow extends ConsumerWidget {
  const TopChromeRow({
    super.key,
    required this.onOpenEqualizer,
    this.compactPageProgress,
  });

  final VoidCallback onOpenEqualizer;

  /// Continuous compact-pager position (0 = cover page, 1 = lyrics page).
  /// While the integrated background's artwork component sits behind this
  /// row (portrait square mode, cover page), the foreground adapts to the
  /// artwork's top-strip brightness.
  final ValueListenable<double>? compactPageProgress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = compactPageProgress;
    if (progress == null) {
      return _buildRow(context, ref, lightForeground: false);
    }
    final squareCoverEnabled = ref.watch(
      settingsProvider.select((s) => s.squareAlbumCoverEnabled),
    );
    final isPortrait =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    final topLuminance = ref
        .watch(playerArtworkTopLuminanceProvider)
        .valueOrNull;
    return ValueListenableBuilder<double>(
      valueListenable: progress,
      builder: (context, page, _) => _buildRow(
        context,
        ref,
        lightForeground: artworkChromeLightForeground(
          squareCoverEnabled: squareCoverEnabled,
          portrait: isPortrait,
          topLuminance: topLuminance,
          pagerPage: page,
        ),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    WidgetRef ref, {
    required bool lightForeground,
  }) {
    final trackMetadata = ref.watch(
      playerControllerProvider.select(
        (s) =>
            (id: s.track?.id, title: s.track?.title, artist: s.track?.artist),
      ),
    );
    final ktvModeEnabled = ref.watch(
      settingsProvider.select((s) => s.ktvModeEnabled),
    );
    final landscapeLocked = ref.watch(landscapeLockProvider);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    // The KTV background picker only exists on the landscape KTV page.
    final showKtvBackgroundButton = ktvModeEnabled && isLandscape;
    // The built-in KTV background is a bright photo at the top, so the
    // chrome switches to dark foreground colors while it is showing.
    final darkForeground =
        showKtvBackgroundButton &&
        ref.watch(settingsProvider.select((s) => s.ktvBackgroundStyle)) ==
            KtvBackgroundStyle.builtin;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerPullHandle(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 12, 4),
            child: Row(
          children: [
            Expanded(
              child: ClipRect(
                child: TrackChangeSwitcher(
                  transitionKey:
                      'top-title:${trackMetadata.id ?? 'loading'}:'
                      '${trackMetadata.title ?? ''}:'
                      '${trackMetadata.artist ?? ''}',
                  alignment: Alignment.centerLeft,
                  incomingOffset: const Offset(1, 0),
                  fade: false,
                  child:
                      trackMetadata.title != null &&
                          trackMetadata.title!.trim().isNotEmpty
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              key: const ValueKey('player-header-title'),
                              trackMetadata.title!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: lightForeground
                                    ? Colors.white
                                    : darkForeground
                                    ? Colors.black87
                                    : playerInk(context),
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                                height: 1.05,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              key: const ValueKey('player-header-artist'),
                              trackMetadata.artist?.trim().isNotEmpty == true
                                  ? trackMetadata.artist!.trim()
                                  : '未知歌手',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: lightForeground
                                    ? Colors.white70
                                    : darkForeground
                                    ? Colors.black54
                                    : playerMuted(
                                        context,
                                      ).withValues(alpha: 0.78),
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                height: 1.05,
                              ),
                            ),
                          ],
                        )
                      : const SizedBox(height: 36),
                ),
              ),
            ),
            const SizedBox(width: 4),
            // Capped so a long source/quality label ellipsizes instead of
            // squeezing the title on narrow phones.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 84),
              child: _QualityEntry(
                darkForeground: darkForeground,
                lightForeground: lightForeground,
              ),
            ),
            const SizedBox(width: 4),
            _LandscapeLockButton(
              locked: landscapeLocked,
              darkForeground: darkForeground,
              lightForeground: lightForeground,
              onPressed: () =>
                  ref.read(landscapeLockProvider.notifier).toggle(),
            ),
            const SizedBox(width: 4),
            _MoreMenuButton(
              darkForeground: darkForeground,
              lightForeground: lightForeground,
              showKtvBackground: showKtvBackgroundButton,
              onOpenEqualizer: onOpenEqualizer,
            ),
            ],
          ),
        ),
        ),
        const CastStatusStrip(),
      ],
    );
  }
}

/// Shows the source · quality label (e.g. `QQ 320K`) next to the title as one
/// tappable entry that opens the playback quality popup anchored to it. Local
/// tracks and tracks with a single quality have nothing to switch to, so the
/// label is shown dimmed and inert.
class _QualityEntry extends ConsumerWidget {
  const _QualityEntry({
    this.darkForeground = false,
    this.lightForeground = false,
  });

  final bool darkForeground;
  final bool lightForeground;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(
      playerControllerProvider.select(
        (s) => (track: s.track, loading: s.loading),
      ),
    );
    final track = state.track;
    final enabled =
        track != null &&
        !track.isLocal &&
        !state.loading &&
        availablePlaybackQualityOptions(track).length > 1;
    final label = track == null
        ? ''
        : '${track.sourceLabel} ${playerQualityShortLabel(track)}';
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Text(
        key: const ValueKey('player-quality-entry-label'),
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: lightForeground
              ? (enabled ? Colors.white : Colors.white.withValues(alpha: 0.45))
              : darkForeground
              ? (enabled
                    ? Colors.black87
                    : Colors.black.withValues(alpha: 0.45))
              : (enabled
                    ? playerAccent(context)
                    : playerMuted(context).withValues(alpha: 0.45)),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
    Widget target(VoidCallback? onTap) => Semantics(
      key: const ValueKey('player-quality-entry'),
      button: true,
      enabled: enabled,
      label: label.isEmpty ? null : '音源与音质 $label',
      child: prism.PressRegion(
        onTap: onTap,
        shape: prism.AppShape.all(prism.AppCorner.sm),
        child: content,
      ),
    );
    if (track == null) return target(null);
    return prism.PopupAnchor(
      targetBuilder: (open) => target(enabled ? open : null),
      popupBuilder: (_) => PlaybackQualityPopup(track: track),
    );
  }
}

/// Toggles the force-landscape lock; filled with the theme's active
/// container color while the lock is on (same treatment as the running
/// sleep timer).
class _LandscapeLockButton extends StatelessWidget {
  const _LandscapeLockButton({
    required this.locked,
    required this.onPressed,
    this.darkForeground = false,
    this.lightForeground = false,
  });

  final bool locked;
  final VoidCallback onPressed;
  final bool darkForeground;
  final bool lightForeground;

  @override
  Widget build(BuildContext context) {
    return _ChromeIconButton(
      key: const ValueKey('player-landscape-lock-button'),
      tooltip: '强制横屏',
      onPressed: onPressed,
      darkForeground: darkForeground,
      lightForeground: lightForeground,
      active: locked,
      iconBuilder: (color) => CustomPaint(
        size: const Size.square(20),
        painter: _LandscapeGlyphPainter(color),
      ),
    );
  }
}

/// The force-landscape glyph, modelled on Kugou's: a portrait phone on the
/// left (speaker dash near the top), a landscape frame sharing its bottom
/// edge on the right, and an arc arrow in the top-right gap hooking down at
/// the frame. Drawn in a 24×24 space to sit alongside the Material icons.
class _LandscapeGlyphPainter extends CustomPainter {
  const _LandscapeGlyphPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // Portrait phone.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(3.4, 2.6, 11.6, 21.4),
        const Radius.circular(2.2),
      ),
      paint,
    );
    // Speaker dash.
    canvas.drawLine(const Offset(6.1, 6.1), const Offset(8.9, 6.1), paint);
    // Landscape frame, sharing the portrait's bottom edge.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(11.6, 13.2, 21.2, 21.4),
        const Radius.circular(2.2),
      ),
      paint,
    );
    // Arc arrow sweeping over the gap, tip hooking down at the frame.
    const center = Offset(17.2, 10.6);
    const radius = 5.6;
    const start = -2.75;
    const sweep = 2.0;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep,
      false,
      paint,
    );
    final end = start + sweep;
    final tip = Offset(
      center.dx + radius * math.cos(end),
      center.dy + radius * math.sin(end),
    );
    // Direction of travel at the arc's end.
    final tangent = Offset(-math.sin(end), math.cos(end));
    for (final turn in [2.55, -2.55]) {
      final dir = Offset(
        tangent.dx * math.cos(turn) - tangent.dy * math.sin(turn),
        tangent.dx * math.sin(turn) + tangent.dy * math.cos(turn),
      );
      canvas.drawLine(tip, tip + dir * 3.4, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LandscapeGlyphPainter oldDelegate) =>
      color != oldDelegate.color;
}

/// The overflow menu at the end of the top bar: the KTV mode switch, the
/// sleep timer, the background picker, and the equalizer, moved out of the
/// row so the track title keeps its width. Picking an entry closes the menu
/// and opens that entry's usual panel as a popup anchored to this same
/// button; the KTV row is a switch and keeps the menu open.
class _MoreMenuButton extends StatefulWidget {
  const _MoreMenuButton({
    required this.darkForeground,
    required this.showKtvBackground,
    required this.onOpenEqualizer,
    this.lightForeground = false,
  });

  final bool darkForeground;
  final bool lightForeground;
  final bool showKtvBackground;
  final VoidCallback onOpenEqualizer;

  @override
  State<_MoreMenuButton> createState() => _MoreMenuButtonState();
}

class _MoreMenuButtonState extends State<_MoreMenuButton> {
  final _anchorKey = GlobalKey();

  /// The button's rect in navigator coordinates, resolved the same way
  /// [prism.PopupAnchor] resolves its own source rect.
  Rect? _anchorRect() {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    final navigatorBox =
        Navigator.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    final origin = box.localToGlobal(Offset.zero, ancestor: navigatorBox);
    return origin & box.size;
  }

  /// Opens the DLNA device picker as a modal bottom sheet on the root
  /// navigator (the player subtree is not itself a route).
  void _openCastSheet() {
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (_) => const CastDeviceSheet(),
    );
  }

  /// Opens [builder]'s panel as an anchored popup out of this button, the
  /// same route and placement the panel's own top-bar button used before.
  void _openPanel(WidgetBuilder builder) {
    if (!mounted) return;
    Navigator.of(context).push(
      prism.AnchoredPopupRoute<void>(
        barrierLabel: prism.UiLocalizations.of(context).close,
        builder: builder,
        anchorOf: _anchorRect,
        elevated: prism.ElevatedSurfaceTheme.isIn(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return prism.PopupAnchor(
      key: _anchorKey,
      targetBuilder: (open) => _ChromeIconButton(
        key: const ValueKey('player-more-button'),
        icon: Icons.more_horiz_rounded,
        tooltip: '更多',
        onPressed: open,
        darkForeground: widget.darkForeground,
        lightForeground: widget.lightForeground,
      ),
      popupBuilder: (_) => _MoreMenuItems(
        showKtvBackground: widget.showKtvBackground,
        onOpenSleepTimer: () =>
            _openPanel((_) => const PlayerSleepTimerPopup()),
        onOpenBackground: () => _openPanel((_) => const KtvBackgroundPopup()),
        onOpenEqualizer: () => _openPanel(
          (_) => PlayerEqualizerPopup(onOpenPage: widget.onOpenEqualizer),
        ),
        onOpenCast: _openCastSheet,
      ),
    );
  }
}

/// The "more" menu's entries. Watches the sleep timer itself so a running
/// timer's remaining time stays current while the menu is open.
class _MoreMenuItems extends ConsumerWidget {
  const _MoreMenuItems({
    required this.showKtvBackground,
    required this.onOpenSleepTimer,
    required this.onOpenBackground,
    required this.onOpenEqualizer,
    required this.onOpenCast,
  });

  final bool showKtvBackground;
  final VoidCallback onOpenSleepTimer;
  final VoidCallback onOpenBackground;
  final VoidCallback onOpenEqualizer;
  final VoidCallback onOpenCast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = ref.watch(sleepTimerProvider);
    final ktvModeEnabled = ref.watch(
      settingsProvider.select((s) => s.ktvModeEnabled),
    );
    final playerStyle = ref.watch(
      settingsProvider.select((s) => s.playerStyle),
    );
    final cast = ref.watch(castControllerProvider);
    // prism's menu rows have no trailing-text slot; the connection state
    // rides in the subtitle under the label instead.
    final castStateText = switch (cast.phase) {
      CastPhase.connecting => '正在连接 ${cast.device?.friendlyName ?? ''}',
      CastPhase.casting => cast.device?.friendlyName ?? '已连接',
      CastPhase.failed => '连接失败',
      CastPhase.idle => '未连接',
    };
    final scheme = Theme.of(context).colorScheme;
    Widget leading(IconData icon) =>
        Icon(icon, size: 20, color: scheme.onSurface);
    return prism.PopupMenu(
      items: [
        prism.PopupMenuItem(
          label: '横屏 KTV',
          leading: leading(Icons.mic_rounded),
          checked: ktvModeEnabled,
          keepsOpen: true,
          onPressed: () => ref
              .read(settingsProvider.notifier)
              .setKtvModeEnabled(!ktvModeEnabled),
        ),
        prism.PopupMenuItem(
          label: 'Folia 模式',
          leading: leading(Icons.auto_awesome_rounded),
          checked: playerStyle == PlayerStyle.folia,
          keepsOpen: true,
          onPressed: () => ref
              .read(settingsProvider.notifier)
              .setPlayerStyle(
                playerStyle == PlayerStyle.folia
                    ? PlayerStyle.ktv
                    : PlayerStyle.folia,
              ),
        ),
        prism.PopupMenuItem(
          label: '定时关闭',
          subtitle: remaining == null
              ? null
              : '剩余 ${formatSleepTimerRemaining(remaining)}',
          leading: leading(
            remaining == null ? Icons.timer_outlined : Icons.timer_rounded,
          ),
          executeImmediately: true,
          onPressed: onOpenSleepTimer,
        ),
        if (showKtvBackground)
          prism.PopupMenuItem(
            label: '背景',
            leading: leading(Icons.image_outlined),
            executeImmediately: true,
            onPressed: onOpenBackground,
          ),
        prism.PopupMenuItem(
          label: '均衡器',
          leading: leading(Icons.graphic_eq_rounded),
          executeImmediately: true,
          onPressed: onOpenEqualizer,
        ),
        prism.PopupMenuItem(
          label: '投播到设备',
          subtitle: castStateText,
          leading: leading(Icons.cast_rounded),
          executeImmediately: true,
          onPressed: onOpenCast,
        ),
      ],
    );
  }
}

class _ChromeIconButton extends StatelessWidget {
  const _ChromeIconButton({
    super.key,
    this.icon,
    this.iconBuilder,
    required this.tooltip,
    required this.onPressed,
    this.darkForeground = false,
    this.lightForeground = false,
    this.active = false,
  }) : assert(icon != null || iconBuilder != null);

  final IconData? icon;

  /// Builds the glyph for buttons whose icon is not a Material glyph;
  /// receives the same foreground color [icon] would have been tinted with.
  final Widget Function(Color color)? iconBuilder;
  final String tooltip;
  final VoidCallback onPressed;
  final bool darkForeground;
  final bool lightForeground;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconColor = active
        ? scheme.onPrimaryContainer
        : lightForeground
        ? Colors.white
        : (darkForeground ? Colors.black87 : playerInk(context));
    // Prism's button, not Material's: a popup can only anchor to a
    // PressSurface or PressRegion, and only the prism button is one.
    return Tooltip(
      message: tooltip,
      child: prism.IconButton(
        onPressed: onPressed,
        style: prism.ButtonStyle.from(
          fixedSize: const Size.square(36),
          shape: const CircleBorder(),
          backgroundColor: active
              ? scheme.primaryContainer
              : Colors.white.withValues(alpha: 0.28),
        ),
        icon: iconBuilder != null
            ? iconBuilder!(iconColor)
            : Icon(icon, color: iconColor, size: 20),
      ),
    );
  }
}

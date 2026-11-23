import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/storage/settings_store.dart';
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

/// Top bar: track title/artist on the left, then the source · quality entry
/// (opens the quality sheet), the KTV mode toggle, and a "more" menu holding
/// the sleep timer, the background picker, and the equalizer entry.
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
    return PlayerPullHandle(
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
            _KtvModeButton(
              enabled: ktvModeEnabled,
              darkForeground: darkForeground,
              lightForeground: lightForeground,
              onPressed: () => ref
                  .read(settingsProvider.notifier)
                  .setKtvModeEnabled(!ktvModeEnabled),
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

/// Toggles landscape KTV mode; filled with the theme's active container
/// color while the mode is on (same treatment as the running sleep timer).
class _KtvModeButton extends StatelessWidget {
  const _KtvModeButton({
    required this.enabled,
    required this.onPressed,
    this.darkForeground = false,
    this.lightForeground = false,
  });

  final bool enabled;
  final VoidCallback onPressed;
  final bool darkForeground;
  final bool lightForeground;

  @override
  Widget build(BuildContext context) {
    return _ChromeIconButton(
      key: const ValueKey('player-ktv-mode-button'),
      icon: Icons.screen_rotation_rounded,
      tooltip: '横屏 KTV 模式',
      onPressed: onPressed,
      darkForeground: darkForeground,
      lightForeground: lightForeground,
      active: enabled,
    );
  }
}

/// The overflow menu at the end of the top bar: the sleep timer, the
/// background picker, and the equalizer, moved out of the row so the track
/// title keeps its width. Picking an entry closes the menu and opens that
/// entry's usual panel as a popup anchored to this same button.
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
  });

  final bool showKtvBackground;
  final VoidCallback onOpenSleepTimer;
  final VoidCallback onOpenBackground;
  final VoidCallback onOpenEqualizer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = ref.watch(sleepTimerProvider);
    final scheme = Theme.of(context).colorScheme;
    Widget leading(IconData icon) =>
        Icon(icon, size: 20, color: scheme.onSurface);
    return prism.PopupMenu(
      items: [
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
      ],
    );
  }
}

class _ChromeIconButton extends StatelessWidget {
  const _ChromeIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.darkForeground = false,
    this.lightForeground = false,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool darkForeground;
  final bool lightForeground;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
        icon: Icon(
          icon,
          color: active
              ? scheme.onPrimaryContainer
              : lightForeground
              ? Colors.white
              : (darkForeground ? Colors.black87 : playerInk(context)),
          size: 20,
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/storage/settings_store.dart';
import '../../equalizer/widgets/equalizer_popup.dart';
import '../../shell/player_pull_scope.dart';
import '../player_controller.dart';
import '../sleep_timer_controller.dart';
import 'ktv_background_panel.dart';
import 'player_palette.dart';
import 'player_quality_sheet.dart';
import 'player_sleep_timer_sheet.dart';
import 'track_change_switcher.dart';

/// Top bar: track title/artist on the left, then the source · quality entry
/// (opens the quality sheet), the sleep timer, and the equalizer entry.
class TopChromeRow extends ConsumerWidget {
  const TopChromeRow({super.key, required this.onOpenEqualizer});

  final VoidCallback onOpenEqualizer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackMetadata = ref.watch(
      playerControllerProvider.select(
        (s) =>
            (id: s.track?.id, title: s.track?.title, artist: s.track?.artist),
      ),
    );
    final ktvModeEnabled = ref.watch(
      settingsProvider.select((s) => s.ktvModeEnabled),
    );
    // The KTV background picker only exists on the landscape KTV page.
    final showKtvBackgroundButton =
        ktvModeEnabled &&
        MediaQuery.orientationOf(context) == Orientation.landscape;
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
                                color: darkForeground
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
                                color: darkForeground
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
            const SizedBox(width: 8),
            // Capped so a long source/quality label ellipsizes instead of
            // squeezing the title on narrow phones.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 96),
              child: _QualityEntry(darkForeground: darkForeground),
            ),
            const SizedBox(width: 4),
            _SleepTimerButton(darkForeground: darkForeground),
            const SizedBox(width: 4),
            _KtvModeButton(
              enabled: ktvModeEnabled,
              darkForeground: darkForeground,
              onPressed: () => ref
                  .read(settingsProvider.notifier)
                  .setKtvModeEnabled(!ktvModeEnabled),
            ),
            if (showKtvBackgroundButton) ...[
              const SizedBox(width: 4),
              _KtvBackgroundButton(darkForeground: darkForeground),
            ],
            const SizedBox(width: 8),
            prism.PopupAnchor(
              targetBuilder: (open) => _ChromeIconButton(
                key: const ValueKey('player-equalizer-button'),
                icon: Icons.graphic_eq_rounded,
                tooltip: '均衡器',
                onPressed: open,
                darkForeground: darkForeground,
              ),
              popupBuilder: (_) =>
                  PlayerEqualizerPopup(onOpenPage: onOpenEqualizer),
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
  const _QualityEntry({this.darkForeground = false});

  final bool darkForeground;

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
          color: darkForeground
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
  });

  final bool enabled;
  final VoidCallback onPressed;
  final bool darkForeground;

  @override
  Widget build(BuildContext context) {
    return _ChromeIconButton(
      key: const ValueKey('player-ktv-mode-button'),
      icon: Icons.screen_rotation_rounded,
      tooltip: '横屏 KTV 模式',
      onPressed: onPressed,
      darkForeground: darkForeground,
      active: enabled,
    );
  }
}

/// Opens the KTV background picker (built-in image / imported images).
class _KtvBackgroundButton extends StatelessWidget {
  const _KtvBackgroundButton({this.darkForeground = false});

  final bool darkForeground;

  @override
  Widget build(BuildContext context) {
    return prism.PopupAnchor(
      targetBuilder: (open) => _ChromeIconButton(
        key: const ValueKey('player-ktv-background-button'),
        icon: Icons.image_outlined,
        tooltip: 'KTV 背景',
        onPressed: open,
        darkForeground: darkForeground,
      ),
      popupBuilder: (_) => const KtvBackgroundPopup(),
    );
  }
}

class _SleepTimerButton extends ConsumerWidget {
  const _SleepTimerButton({this.darkForeground = false});

  final bool darkForeground;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = ref.watch(sleepTimerProvider);
    if (remaining == null) {
      return prism.PopupAnchor(
        targetBuilder: (open) => _ChromeIconButton(
          key: const ValueKey('player-sleep-timer-button'),
          icon: Icons.timer_outlined,
          tooltip: '定时关闭音乐',
          onPressed: open,
          darkForeground: darkForeground,
        ),
        popupBuilder: (_) => const PlayerSleepTimerPopup(),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final label = formatSleepTimerRemaining(remaining);
    return prism.PopupAnchor(
      targetBuilder: (open) => Tooltip(
        message: '定时关闭音乐 · 剩余 $label',
        child: prism.PressRegion(
          key: const ValueKey('player-sleep-timer-button'),
          onTap: open,
          shape: const StadiumBorder(),
          fill: scheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: SizedBox(
              height: 36,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.timer_rounded,
                    color: scheme.onPrimaryContainer,
                    size: 18,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      popupBuilder: (_) => const PlayerSleepTimerPopup(),
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
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool darkForeground;
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
              : (darkForeground ? Colors.black87 : playerInk(context)),
          size: 20,
        ),
      ),
    );
  }
}

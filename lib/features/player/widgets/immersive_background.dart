import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import '../../../theme/app_theme.dart';
import '../player_controller.dart';
import '../flowing_light_background.dart';
import 'ktv_background.dart';
import 'player_palette.dart';
import 'player_control_color.dart';
import 'track_change_switcher.dart';

class ImmersiveBackground extends ConsumerWidget {
  const ImmersiveBackground({super.key, this.revealProgress, this.coverVisibility});

  /// The shell's player reveal progress, forwarded to the backdrop so its
  /// motion can hold while the page is being dragged.
  final Animation<double>? revealProgress;

  /// Compact pager cover-page visibility (1 = cover page, 0 = lyrics
  /// page). The portrait image background only belongs to the cover page,
  /// so it fades with this value; the lyrics page keeps the plain
  /// flowing-light backdrop, and artwork color extraction is untouched
  /// either way (the imported image never feeds the palette).
  final ValueListenable<double>? coverVisibility;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imageProvider = ref.watch(playerArtworkProvider);
    final artworkColors = ref.watch(playerArtworkColorsProvider);
    final hasTrack = ref.watch(
      playerControllerProvider.select((s) => s.track != null),
    );
    final playing = ref.watch(
      playerControllerProvider.select((s) => s.playing),
    );
    final flowingLightEnabled = ref.watch(
      settingsProvider.select((s) => s.flowingLightEnabled),
    );
    final ktvModeEnabled = ref.watch(
      settingsProvider.select((s) => s.ktvModeEnabled),
    );
    // 竖屏封面页选中的图片背景（与 KTV 共用图库、选中独立）：盖在流光
    // 之上完整遮住它，清掉选中即恢复流光；滑到歌词页时按
    // coverVisibility 淡出，歌词页只剩流光。
    final hasPortraitBackground = ref.watch(
      settingsProvider.select((s) => s.selectedPortraitBackgroundItem != null),
    );
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final scheme = Theme.of(context).colorScheme;
    final baseSurface = hasTrack ? playerSurface(context) : scheme.appSurface;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: baseSurface),
        if (ktvModeEnabled && isLandscape)
          const KtvBackground()
        else
          TrackChangeSwitcher(
          // Keyed on whether there is a cover at all, not on which cover. Track
          // changes are cross-faded inside FlowingLightBackground, so keying
          // per track would re-slot it, throw away its previous-frame history,
          // and leave two composite pipelines running against each other for
          // the length of the transition.
          transitionKey: imageProvider != null,
          incomingOffset: Offset.zero,
          duration:
              TickerMode.valuesOf(context).enabled &&
                  (revealProgress?.value ?? 1) >= 1
              ? const Duration(milliseconds: 500)
              : Duration.zero,
          expand: true,
          child: imageProvider == null
              ? const SizedBox.expand()
              : FlowingLightBackground(
                  imageProvider: imageProvider,
                  artworkColors: artworkColors.isLoading
                      ? null
                      : artworkColors.valueOrNull,
                  backgroundColor: baseSurface,
                  brightness: scheme.brightness,
                  running: flowingLightEnabled && playing,
                  revealProgress: revealProgress,
                ),
        ),
        if (!isLandscape && hasPortraitBackground)
          _FadedPortraitBackground(visibility: coverVisibility),
      ],
    );
  }
}

/// [PortraitBackground] faded by the compact pager's cover-page
/// visibility, so the imported image never reaches the lyrics page.
class _FadedPortraitBackground extends StatelessWidget {
  const _FadedPortraitBackground({this.visibility});

  final ValueListenable<double>? visibility;

  @override
  Widget build(BuildContext context) {
    final listenable = visibility;
    if (listenable == null) return const PortraitBackground();
    return ValueListenableBuilder<double>(
      valueListenable: listenable,
      builder: (context, value, child) =>
          Opacity(opacity: value.clamp(0.0, 1.0), child: child),
      child: const PortraitBackground(),
    );
  }
}

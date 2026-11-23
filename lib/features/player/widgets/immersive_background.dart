import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import '../../../core/ui/car_display_layout.dart';
import '../../../theme/app_theme.dart';
import '../player_controller.dart';
import '../flowing_light_background.dart';
import 'ktv_background.dart';
import 'player_control_color.dart';
import 'player_palette.dart';
import 'track_change_switcher.dart';

/// How far down the screen the integrated background's artwork component
/// reaches before it has fully dissolved into the flowing-light ambience.
const _kIntegratedArtworkHeightFactor = 0.62;

class ImmersiveBackground extends ConsumerWidget {
  const ImmersiveBackground({
    super.key,
    this.revealProgress,
    this.compactPageProgress,
  });

  /// The shell's player reveal progress, forwarded to the backdrop so its
  /// motion can hold while the page is being dragged.
  final Animation<double>? revealProgress;

  /// Continuous compact-pager position (0 = cover page, 1 = lyrics page).
  /// In portrait square mode the background's artwork component fades out
  /// with it, leaving only the cover's colour ambience behind the lyrics.
  final ValueListenable<double>? compactPageProgress;

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
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final scheme = Theme.of(context).colorScheme;
    final baseSurface = hasTrack ? playerSurface(context) : scheme.appSurface;
    // Portrait square mode folds the cover itself into the background: one
    // integrated surface from the very top of the screen, artwork first,
    // dissolving into the flowing-light ambience below. Wide and KTV
    // layouts keep the plain flowing light.
    final squareCoverEnabled = ref.watch(
      settingsProvider.select((s) => s.squareAlbumCoverEnabled),
    );
    final carPadModeEnabled =
        ref.watch(settingsProvider.select((s) => s.carPadModeEnabled)) ||
        CarDisplayLayout.wideOf(context);
    final showIntegratedArtwork =
        squareCoverEnabled &&
        !isLandscape &&
        !carPadModeEnabled &&
        imageProvider != null;
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
        if (showIntegratedArtwork)
          Positioned(
            key: const ValueKey('player-integrated-bg-artwork'),
            top: 0,
            left: 0,
            right: 0,
            height:
                MediaQuery.sizeOf(context).height *
                _kIntegratedArtworkHeightFactor,
            child: _IntegratedArtworkLayer(
              imageProvider: imageProvider,
              compactPageProgress: compactPageProgress,
            ),
          ),
      ],
    );
  }
}

/// The cover as part of the background itself: full-bleed from the top of
/// the screen (behind the status bar), dissolving into the flowing-light
/// ambience over its lower stretch via a real-alpha dstIn gradient, and
/// fading out as the compact pager moves to the lyrics page so only the
/// cover's colour ambience remains there.
class _IntegratedArtworkLayer extends StatelessWidget {
  const _IntegratedArtworkLayer({
    required this.imageProvider,
    required this.compactPageProgress,
  });

  final ImageProvider<Object> imageProvider;
  final ValueListenable<double>? compactPageProgress;

  @override
  Widget build(BuildContext context) {
    Widget artwork = TrackChangeSwitcher(
      transitionKey: imageProvider,
      incomingOffset: Offset.zero,
      duration: const Duration(milliseconds: 500),
      expand: true,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white,
            Colors.white,
            Colors.white.withValues(alpha: 0.55),
            Colors.white.withValues(alpha: 0.16),
            Colors.transparent,
          ],
          stops: const [0.0, 0.36, 0.62, 0.84, 1.0],
        ).createShader(rect),
        child: Image(
          image: imageProvider,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
        ),
      ),
    );
    final progress = compactPageProgress;
    if (progress != null) {
      artwork = ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (context, page, child) =>
            Opacity(opacity: 1 - page.clamp(0.0, 1.0), child: child),
        child: artwork,
      );
    }
    return artwork;
  }
}

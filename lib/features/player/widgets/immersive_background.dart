import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import '../../../core/ui/cover_image_source.dart';
import '../../../theme/app_theme.dart';
import '../player_controller.dart';
import '../flowing_light_background.dart';
import 'ktv_background.dart';
import 'player_control_color.dart';
import 'player_palette.dart';
import 'track_change_switcher.dart';

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
    // dissolving into the flowing-light ambience below. Landscape and KTV
    // layouts keep the plain flowing light.
    final squareCoverEnabled = ref.watch(
      settingsProvider.select((s) => s.squareAlbumCoverEnabled),
    );
    // The artwork component is sourced straight from the track, exactly
    // like the disc's cover: its presence depends only on the track
    // carrying cover bytes or a usable cover URL, never on the shared
    // backdrop provider or the chrome-luminance byte resolution.
    final cover = ref.watch(
      playerControllerProvider.select(
        (s) => (
          id: s.track?.id,
          url: s.track?.coverUrl,
          bytes: s.track?.coverBytes,
        ),
      ),
    );
    final coverUrl = CoverImageSource.normalizeUrl(cover.url, size: 700);
    final hasCoverArtwork =
        (cover.bytes != null && cover.bytes!.isNotEmpty) ||
        (coverUrl != null && coverUrl.isNotEmpty);
    final showIntegratedArtwork =
        squareCoverEnabled && !isLandscape && hasCoverArtwork;
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
            // The cover keeps its native square aspect: as wide as the
            // screen and exactly as tall, top edge at the top of the
            // screen, nothing cropped on any side.
            height: MediaQuery.sizeOf(context).width,
            child: _IntegratedArtworkLayer(
              transitionKey: cover.id ?? coverUrl ?? '',
              url: coverUrl,
              bytes: cover.bytes,
              compactPageProgress: compactPageProgress,
            ),
          ),
      ],
    );
  }
}

/// The cover as part of the background itself: the full square artwork,
/// full-bleed from the top of the screen (behind the status bar), dissolving
/// into the flowing-light ambience over its lower stretch via a real-alpha
/// dstIn gradient, and fading out as the compact pager moves to the lyrics
/// page so only the cover's colour ambience remains there.
///
/// The image loads through the same provider the disc's cover resolves —
/// the raw memory/network source decoded at 480px — so it is exactly as
/// sharp as the disc and appears whenever the track carries a cover,
/// independent of the backdrop's downsampled provider and of the
/// chrome-luminance byte resolution.
class _IntegratedArtworkLayer extends StatelessWidget {
  const _IntegratedArtworkLayer({
    required this.transitionKey,
    required this.url,
    required this.bytes,
    required this.compactPageProgress,
  });

  final Object transitionKey;
  final String? url;
  final Uint8List? bytes;
  final ValueListenable<double>? compactPageProgress;

  /// The disc's cover source at the disc's decode size: memory bytes
  /// first, then the network cover, both resized to 480px on resolve.
  ImageProvider<Object>? get _imageProvider {
    final coverBytes = bytes;
    if (coverBytes != null && coverBytes.isNotEmpty) {
      return ResizeImage(
        MemoryImage(coverBytes),
        width: 480,
        height: 480,
      );
    }
    final coverUrl = url;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      return ResizeImage(
        CachedNetworkImageProvider(
          coverUrl,
          headers: CoverImageSource.headersFor(coverUrl),
        ),
        width: 480,
        height: 480,
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final imageProvider = _imageProvider;
    Widget artwork = TrackChangeSwitcher(
      transitionKey: transitionKey,
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
          // Recalibrated for the square box: fully opaque over the top
          // 45%, then the same long eased dissolve to the box's bottom.
          stops: const [0.0, 0.45, 0.67, 0.86, 1.0],
        ).createShader(rect),
        child: imageProvider == null
            ? const SizedBox.expand()
            : Image(
                image: imageProvider,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                // Keep the current cover on screen while a replacement
                // resolves, so provider churn never blanks the layer.
                gaplessPlayback: true,
                // Transparent until the first frame arrives, then fade
                // in; a failed load stays silently transparent.
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded) return child;
                  return AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 500),
                    curve: const Cubic(0.4, 0, 0.2, 1),
                    child: child,
                  );
                },
                errorBuilder: (context, error, stackTrace) =>
                    const SizedBox.expand(),
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

import 'dart:ui' as ui;

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
    // Portrait disc mode: the backdrop is the cover itself, blurred
    // full-bleed, so the disc floats on its own artwork's tones instead
    // of the flowing light's flat field — the pale top edge of a rotated
    // cover no longer steps against an unrelated flat colour at the
    // disc's top rim. The flowing light retires in this mode only;
    // without a cover the page falls back to it as before.
    final showDiscBlurBackdrop =
        !squareCoverEnabled && !isLandscape && hasCoverArtwork;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: baseSurface),
        if (ktvModeEnabled && isLandscape)
          const KtvBackground()
        else if (showDiscBlurBackdrop)
          _DiscBlurBackdropLayer(
            key: const ValueKey('player-disc-blur-backdrop'),
            transitionKey: cover.id ?? coverUrl ?? '',
            url: coverUrl,
            bytes: cover.bytes,
            veilColor: baseSurface,
          )
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
/// the raw memory/network source decoded at 800px — so it is exactly as
/// sharp as the disc and appears whenever the track carries a cover,
/// independent of the backdrop's downsampled provider and of the
/// chrome-luminance byte resolution.
/// Stops of the integrated artwork's dstIn dissolve, as fractions of
/// the layer's height from its top edge.
const List<double> integratedArtworkDissolveStops = [
  0.0,
  0.74,
  0.766,
  0.792,
  0.818,
  0.844,
  0.87,
  0.896,
  0.922,
  0.948,
  0.974,
  1.0,
];

/// Alpha at each of [integratedArtworkDissolveStops]: fully opaque
/// down to 74% of the layer, then a smoothstep fall to zero exactly
/// at the bottom edge. The fall disperses upward from the bottom —
/// its slope grows out of zero and settles back to zero with no
/// single knee — so no row of the poster reads as a boundary line
/// against the ambience below.
const List<double> integratedArtworkDissolveAlphas = [
  1.0,
  1.0,
  0.972,
  0.896,
  0.784,
  0.648,
  0.5,
  0.352,
  0.216,
  0.104,
  0.028,
  0.0,
];

/// The dissolve's alpha at height fraction [t] of the layer,
/// interpolating the stop table linearly — the same profile the
/// layer's gradient paints.
double integratedArtworkDissolveAlphaAt(double t) {
  if (t <= 0) return integratedArtworkDissolveAlphas.first;
  if (t >= 1) return integratedArtworkDissolveAlphas.last;
  for (var i = 1; i < integratedArtworkDissolveStops.length; i++) {
    final end = integratedArtworkDissolveStops[i];
    if (t <= end) {
      final start = integratedArtworkDissolveStops[i - 1];
      final fraction = (t - start) / (end - start);
      final a = integratedArtworkDissolveAlphas[i - 1];
      final b = integratedArtworkDissolveAlphas[i];
      return a + (b - a) * fraction;
    }
  }
  return integratedArtworkDissolveAlphas.last;
}

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
  /// first, then the network cover, both resized to 800px on resolve.
  ImageProvider<Object>? get _imageProvider =>
      _playerCoverImageProvider(bytes: bytes, url: url);

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
            for (final alpha in integratedArtworkDissolveAlphas)
              Colors.white.withValues(alpha: alpha),
          ],
          stops: integratedArtworkDissolveStops,
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

/// The track cover as a full-screen backdrop source, shared by the
/// integrated artwork layer and the disc-mode blur backdrop: memory
/// bytes first, then the network cover, both decoded at 800px — the
/// same resolve the disc itself uses, so every surface drawn from it
/// stays exactly as sharp as the disc.
ImageProvider<Object>? _playerCoverImageProvider({
  required Uint8List? bytes,
  required String? url,
}) {
  if (bytes != null && bytes.isNotEmpty) {
    return ResizeImage(MemoryImage(bytes), width: 800, height: 800);
  }
  if (url != null && url.isNotEmpty) {
    return ResizeImage(
      CachedNetworkImageProvider(
        url,
        headers: CoverImageSource.headersFor(url),
      ),
      width: 800,
      height: 800,
    );
  }
  return null;
}

/// Portrait disc mode's backdrop: the current cover, Gaussian-blurred
/// across the whole screen (Panghu-style), under a veil of the player's
/// own surface colour. The disc keeps its sharp 800px artwork and its
/// contact shadow; only the field behind it changes — from the flowing
/// light's flat composite to the cover's own tones, so the disc's pale
/// top rim no longer meets an unrelated flat field along a visible
/// step. One backdrop serves both pager pages, exactly like the square
/// mode's ambience continuation.
class _DiscBlurBackdropLayer extends StatelessWidget {
  const _DiscBlurBackdropLayer({
    super.key,
    required this.transitionKey,
    required this.url,
    required this.bytes,
    required this.veilColor,
  });

  final Object transitionKey;
  final String? url;
  final Uint8List? bytes;

  /// The player surface colour, veiled over the blur so the backdrop
  /// keeps the player's established light/dark feel and the foreground
  /// chrome stays on the palette it was tuned against.
  final Color veilColor;

  @override
  Widget build(BuildContext context) {
    final imageProvider = _playerCoverImageProvider(bytes: bytes, url: url);
    return TrackChangeSwitcher(
      transitionKey: transitionKey,
      incomingOffset: Offset.zero,
      duration: const Duration(milliseconds: 500),
      expand: true,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageProvider != null)
            ImageFiltered(
              // Sigma 50 (logical px) at the cover's 800px decode fully
              // dissolves artwork detail into a smooth tonal field at
              // any phone size while keeping the cover's own colour
              // geography, so the field above the disc is the cover's
              // top region itself, only softened.
              imageFilter: ui.ImageFilter.blur(
                sigmaX: 50,
                sigmaY: 50,
                tileMode: TileMode.clamp,
              ),
              child: Image(
                image: imageProvider,
                fit: BoxFit.cover,
                // Keep the current cover on screen while a replacement
                // resolves, so provider churn never blanks the backdrop.
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
          ColoredBox(color: veilColor.withValues(alpha: 0.45)),
        ],
      ),
    );
  }
}

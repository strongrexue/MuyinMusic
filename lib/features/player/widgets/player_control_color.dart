import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui/cover_image_source.dart';
import '../../../core/ui/artwork_colors.dart';
import '../../../theme/app_motion.dart';
import '../player_controller.dart';
import 'player_palette.dart';

// Share the backdrop's resized image cache entry, including local artwork.
final playerArtworkProvider = Provider<ImageProvider<Object>?>((ref) {
  final cover = ref.watch(
    playerControllerProvider.select(
      (s) => (url: s.track?.coverUrl, bytes: s.track?.coverBytes),
    ),
  );
  final bytes = cover.bytes;
  if (bytes != null && bytes.isNotEmpty) {
    return ResizeImage(MemoryImage(bytes), width: 192, height: 192);
  }
  final url = CoverImageSource.normalizeUrl(
    cover.url,
    size: CoverImageSource.playerCoverSize,
  );
  if (url == null || url.isEmpty) return null;
  return ResizeImage(
    CachedNetworkImageProvider(url, headers: CoverImageSource.headersFor(url)),
    width: 192,
    height: 192,
  );
});

// AppShell keeps this alive, so selecting a song prepares its colors even
// before the player page is mounted or opened.
final playerArtworkColorsProvider = FutureProvider.autoDispose<ArtworkColors?>((
  ref,
) async {
  final provider = ref.watch(playerArtworkProvider);
  if (provider == null) return null;
  return loadArtworkColors(provider, requestGroup: 'player');
});

final playerLyricInkProvider = Provider.autoDispose<Color?>((ref) {
  final colors = ref.watch(playerArtworkColorsProvider);
  return colors.hasError ? null : colors.valueOrNull?.lyricInk;
});

/// Top-strip luminance below which the artwork's top region counts as
/// dark, so chrome floating over it switches to a light foreground.
const kArtworkTopDarkLuminanceThreshold = 0.25;

/// Whether chrome floating over the integrated background's artwork
/// component should use a light foreground: portrait square mode, a dark
/// artwork top strip, and the pager still on the cover page (once the
/// artwork has faded out over the lyrics page the default foreground
/// returns).
bool artworkChromeLightForeground({
  required bool squareCoverEnabled,
  required bool portrait,
  required double? topLuminance,
  required double pagerPage,
}) {
  return squareCoverEnabled &&
      portrait &&
      topLuminance != null &&
      topLuminance < kArtworkTopDarkLuminanceThreshold &&
      pagerPage < 0.5;
}

/// Mean relative luminance (0..1) of the current artwork's top strip —
/// the band the portrait top chrome floats over when the cover is part of
/// the integrated background. Null while unknown or on any decode failure;
/// consumers then keep the default dark foreground.
final playerArtworkTopLuminanceProvider = FutureProvider.autoDispose<double?>((
  ref,
) async {
  final provider = ref.watch(playerArtworkProvider);
  if (provider == null) return null;
  return _loadArtworkTopLuminance(provider);
});

Future<double?> _loadArtworkTopLuminance(ImageProvider<Object> provider) async {
  final ui.Image image;
  try {
    // Resolve the encoded bytes the same way the artwork-colour pipeline
    // does, then decode directly: going through an ImageStream here would
    // leave this provider at the mercy of frame scheduling.
    final bytes = await _artworkEncodedBytes(provider);
    if (bytes == null) return null;
    final codec = await ui.instantiateImageCodec(bytes);
    image = (await codec.getNextFrame()).image;
  } catch (_) {
    return null;
  }

  // Downscale to a small raster and average the top quarter's luminance:
  // that band is what sits behind the status bar and the top chrome row.
  const sampleSize = 48;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Rect.fromLTWH(0, 0, sampleSize.toDouble(), sampleSize.toDouble()),
    Paint()..filterQuality = FilterQuality.low,
  );
  image.dispose();
  final picture = recorder.endRecording();
  final raster = await picture.toImage(sampleSize, sampleSize);
  picture.dispose();
  final data = await raster.toByteData(format: ui.ImageByteFormat.rawRgba);
  raster.dispose();
  if (data == null) return null;

  const stripRows = sampleSize ~/ 4;
  var total = 0.0;
  var count = 0;
  for (var y = 0; y < stripRows; y++) {
    for (var x = 0; x < sampleSize; x++) {
      final offset = (y * sampleSize + x) * 4;
      total += Color.fromARGB(
        255,
        data.getUint8(offset),
        data.getUint8(offset + 1),
        data.getUint8(offset + 2),
      ).computeLuminance();
      count++;
    }
  }
  return count == 0 ? null : total / count;
}

/// The encoded cover bytes behind [provider], following the same source
/// resolution as the artwork-colour extraction: memory bytes directly,
/// local files from disk, network covers through their cache entry.
Future<Uint8List?> _artworkEncodedBytes(ImageProvider<Object> provider) async {
  var source = provider;
  while (source is ResizeImage) {
    source = source.imageProvider;
  }
  if (source is MemoryImage) return source.bytes;
  if (source is FileImage) return source.file.readAsBytes();
  if (source is CachedNetworkImageProvider) {
    final manager =
        source.cacheManager ?? CachedNetworkImageProvider.defaultCacheManager;
    final cached = await manager.getFileFromCache(
      source.cacheKey ?? source.url,
    );
    final file =
        cached?.file ??
        await manager.getSingleFile(
          source.url,
          key: source.cacheKey ?? source.url,
          headers: source.headers ?? const {},
        );
    return file.readAsBytes();
  }
  return null;
}

/// Keeps the cover's hue while using dark ink in light mode and pale ink in
/// dark mode. Only the transport controls and the action row opt into this
/// color.
class PlayerControlColor extends ConsumerWidget {
  const PlayerControlColor({super.key, required this.builder});

  final Widget Function(BuildContext context, Color color) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artworkColors = ref.watch(playerArtworkColorsProvider);
    // 新封面尚未就绪时沿用上次取色，避免换曲先闪回默认色。
    final accent = artworkColors.hasError
        ? null
        : artworkColors.valueOrNull?.accent;
    final fallback = playerInk(context);
    var color = fallback;
    if (accent != null) {
      final hsl = HSLColor.fromColor(accent);
      // The flow palette gives neutral artwork a small artificial saturation.
      // Keep genuinely monochrome covers neutral instead of tinting them red.
      if (hsl.saturation > 0.22) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        color = hsl
            .withSaturation(hsl.saturation.clamp(0.35, 0.75))
            // 略收紧浅色明度，为高亮黄色及队列角标保留对比度余量。
            .withLightness(dark ? 0.82 : 0.23)
            .toColor();
      }
    }
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: color, end: color),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : AppMotion.long,
      curve: AppMotion.emphasized,
      builder: (context, value, _) => builder(context, value ?? fallback),
    );
  }
}

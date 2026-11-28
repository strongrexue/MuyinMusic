import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Per-song stage theme: a dark [background] the lyrics sit on, a
/// near-white [primary] for the sung text, and a saturated [accent]
/// for glows and highlights. The background is always dark, so the
/// primary stays white; the song's own color rides on the accent.
@immutable
class FoliaTheme {
  const FoliaTheme({
    required this.background,
    required this.primary,
    required this.accent,
  });

  static const FoliaTheme fallback = FoliaTheme(
    background: Color(0xFF0D0D12),
    primary: Colors.white,
    accent: Color(0xFFFFB547),
  );

  final Color background;
  final Color primary;
  final Color accent;

  /// Maps the few colors the native extractor returns (base + accents)
  /// onto a stage theme. The precise path is [extractFoliaTheme],
  /// which reads the full cover pixels.
  factory FoliaTheme.fromArtwork({
    required Color base,
    required List<Color> accents,
  }) {
    final accent =
        accents
            .where(
              (color) =>
                  HSLColor.fromColor(color).saturation >= 0.35,
            )
            .firstOrNull ??
        fallback.accent;
    return FoliaTheme(
      background: _darken(base, 0.22),
      primary: Colors.white,
      accent: accent,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FoliaTheme &&
      other.background == background &&
      other.primary == primary &&
      other.accent == accent;

  @override
  int get hashCode => Object.hash(background, primary, accent);
}

/// Derives a stage theme from raw cover RGBA bytes (row-major, 4 bytes
/// per pixel) — the same buffer [extractLyricInk] reads, bucketed the
/// same way (4 bits per channel). The background is the most populous
/// usable swatch darkened to lightness 0.22; the accent is the most
/// saturated mid-lightness swatch, count-weighted.
FoliaTheme extractFoliaTheme(Uint8List rgba) {
  final buckets = <int, _Bucket>{};
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 125) continue;
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
    final bucket = buckets.putIfAbsent(key, _Bucket.new);
    bucket.count++;
    bucket.r += r;
    bucket.g += g;
    bucket.b += b;
  }
  if (buckets.isEmpty) return FoliaTheme.fallback;
  final swatches = buckets.values.map((bucket) => bucket.swatch).toList()
    ..sort((a, b) => b.count.compareTo(a.count));
  final maxCount = swatches.first.count;

  var backgroundSwatch = swatches.firstWhere(
    (swatch) => swatch.hsl.lightness <= 0.9,
    orElse: () => swatches.first,
  );
  final backgroundCandidates = swatches.where(
    (swatch) => !swatch.extreme && swatch.count >= maxCount / 2.5,
  );
  if (backgroundCandidates.isNotEmpty) {
    backgroundSwatch = backgroundCandidates.first;
  }
  final background = _darken(backgroundSwatch.color, 0.22);

  _Swatch? accentSwatch;
  var best = -1.0;
  for (final swatch in swatches) {
    final hsl = swatch.hsl;
    if (hsl.lightness < 0.3 || hsl.lightness > 0.7) continue;
    if (hsl.saturation < 0.35) continue;
    final score = 0.6 * hsl.saturation + 0.4 * (swatch.count / maxCount);
    if (score > best) {
      best = score;
      accentSwatch = swatch;
    }
  }
  accentSwatch ??= swatches
      .where((swatch) => swatch.hsl.saturation >= 0.35)
      .fold<_Swatch?>(null, (a, b) => a == null || b.count > a.count ? b : a);
  final accent = accentSwatch == null
      ? FoliaTheme.fallback.accent
      : HSLColor.fromAHSL(
          1,
          accentSwatch.hsl.hue,
          accentSwatch.hsl.saturation.clamp(0.55, 1.0).toDouble(),
          0.6,
        ).toColor();
  return FoliaTheme(
    background: background,
    primary: Colors.white,
    accent: accent,
  );
}

/// Thin seam over the pure extraction functions; callers hold the
/// result per track.
class FoliaThemeService {
  const FoliaThemeService();

  FoliaTheme deriveFromRgba(Uint8List rgba) => extractFoliaTheme(rgba);

  FoliaTheme deriveFromArtwork({
    required Color base,
    required List<Color> accents,
  }) => FoliaTheme.fromArtwork(base: base, accents: accents);
}

Color _darken(Color color, double maxLightness) {
  final hsl = HSLColor.fromColor(color);
  if (hsl.lightness <= maxLightness) return color;
  // Clamp a touch below the bound: the 8-bit RGB round-trip can add
  // ~0.002 to the lightness, which would break the guarantee.
  return hsl.withLightness(maxLightness - 0.01).toColor();
}

class _Bucket {
  int count = 0;
  int r = 0;
  int g = 0;
  int b = 0;

  _Swatch get swatch => _Swatch(
    Color.fromARGB(
      255,
      (r / count).round(),
      (g / count).round(),
      (b / count).round(),
    ),
    count,
  );
}

class _Swatch {
  _Swatch(this.color, this.count) : hsl = HSLColor.fromColor(color);
  final Color color;
  final int count;
  final HSLColor hsl;
  bool get extreme => hsl.lightness < 0.08 || hsl.lightness > 0.9;
}

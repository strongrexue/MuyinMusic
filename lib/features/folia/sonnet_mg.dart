import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'folia_theme.dart';
import 'sonnet_motion.dart';

/// Sonnet (商籁) MG (motion-graphics) decorations, ported from the
/// Folia blueprint (src/components/visualizer/sonnet/entry.tsx
/// DEFAULT_SONNET_TUNING, sonnetTextViewBuilder.ts,
/// sonnetBackgroundMgVariants.ts, sonnetFixedGeoVariants.ts,
/// sonnetBackgroundDecor.ts, sonnetFrameOverlay.ts, sonnetGuides.ts).
///
/// The blueprint's defaults are all on: guides, background MG,
/// fixed geometry, giant decorative text, background decor, and the
/// full outer frame. [SonnetMgSettings] keeps the same defaults and
/// exposes one switch per layer so they can be toggled off later;
/// the stage renders each layer only when its switch is on.
///
/// Colours: FoliaTheme has background/primary/accent only. The
/// blueprint's secondary maps to [FoliaTheme.accent] and its
/// primary (white text) to [FoliaTheme.primary].
///
/// Painters draw in center-based coordinates (0, 0 = stage center),
/// translated once in paint(). The stage places them inside the
/// camera transform, so they move with the shot — except the frame
/// overlay, which is screen-fixed (the blueprint draws it on a
/// separate overlay container above the scene).

class SonnetMgSettings {
  const SonnetMgSettings({
    this.showGuide = true,
    this.showBackgroundMg = true,
    this.showFixedGeo = true,
    this.showGiantDecorativeText = true,
    this.showBackgroundDecor = true,
    this.outerFrameMode = SonnetOuterFrameMode.full,
  });

  /// DEFAULT_SONNET_TUNING: every layer true, outer frame 'full'.
  static const SonnetMgSettings blueprintDefaults = SonnetMgSettings();

  final bool showGuide;
  final bool showBackgroundMg;
  final bool showFixedGeo;
  final bool showGiantDecorativeText;
  final bool showBackgroundDecor;
  final SonnetOuterFrameMode outerFrameMode;

  bool get showFrameOverlay => outerFrameMode != SonnetOuterFrameMode.none;

  SonnetMgSettings copyWith({
    bool? showGuide,
    bool? showBackgroundMg,
    bool? showFixedGeo,
    bool? showGiantDecorativeText,
    bool? showBackgroundDecor,
    SonnetOuterFrameMode? outerFrameMode,
  }) => SonnetMgSettings(
    showGuide: showGuide ?? this.showGuide,
    showBackgroundMg: showBackgroundMg ?? this.showBackgroundMg,
    showFixedGeo: showFixedGeo ?? this.showFixedGeo,
    showGiantDecorativeText:
        showGiantDecorativeText ?? this.showGiantDecorativeText,
    showBackgroundDecor:
        showBackgroundDecor ?? this.showBackgroundDecor,
    outerFrameMode: outerFrameMode ?? this.outerFrameMode,
  );

  @override
  bool operator ==(Object other) =>
      other is SonnetMgSettings &&
      showGuide == other.showGuide &&
      showBackgroundMg == other.showBackgroundMg &&
      showFixedGeo == other.showFixedGeo &&
      showGiantDecorativeText == other.showGiantDecorativeText &&
      showBackgroundDecor == other.showBackgroundDecor &&
      outerFrameMode == other.outerFrameMode;

  @override
  int get hashCode => Object.hash(
    showGuide,
    showBackgroundMg,
    showFixedGeo,
    showGiantDecorativeText,
    showBackgroundDecor,
    outerFrameMode,
  );
}

enum SonnetOuterFrameMode { full, none }

/// Scene hairlines: (sceneSeed % 6) + 4 lines (mgDensity 1 → 9).
/// (sonnetBackgroundMgVariants.ts scene hairlines).
int sonnetSceneHairlineCount(int sceneSeed) => (sceneSeed % 6) + 4 + 5;

/// Background HUD variant 0–7 (sonnetBackgroundMgVariants.ts):
/// mixSonnetSeed(seed, 0x9e3779b9) % 8.
int sonnetBackgroundHudVariant(int seed) =>
    sonnetMixSeed(seed, 0x9e3779b9) % 8;

/// Shot-level fixed geometry variant 0–7
/// (sonnetFixedGeoVariants.ts): mixSonnetSeed(seed, 0x85ebca6b) % 8.
int sonnetFixedGeoShotVariant(int seed) =>
    sonnetMixSeed(seed, 0x85ebca6b) % 8;

/// Background decor arrangement 0–5 (sonnetBackgroundDecor.ts):
/// mixSonnetSeed(seed, 0xc2b2ae35) % 6.
int sonnetBackgroundDecorVariant(int seed) =>
    sonnetMixSeed(seed, 0xc2b2ae35) % 6;

/// Text fixed-geo plan 0–6 (sonnetTextFixedGeo.ts): seed % 7.
int sonnetTextFixedGeoVariant(int seed) => seed % 7;

/// Text fixed geo is drawn only when the shot has enough words
/// (sonnetTextViewBuilder.ts: chorus ≥ 26, others ≥ 15).
int sonnetTextFixedGeoMinWords(bool isChorus) => isChorus ? 26 : 15;

/// Guide cue: lead = min(0.38, max(0.2, 0.18 + duration × 0.1)),
/// the line starts that far ahead of the word and fades by
/// start + 0.65s (sonnetGuides.ts).
double sonnetGuideLeadSeconds(double wordDurationSeconds) =>
    math.min(
      0.38,
      math.max(0.2, 0.18 + wordDurationSeconds * 0.1),
    );

/// A guide line for one word (sonnetGuides.ts): a bezier curve
/// from the stage edge to the word, with a star head, a burst of
/// small shapes at the tip, a ribbon trail and a rect spline.
class SonnetGuideSpec {
  const SonnetGuideSpec({
    required this.center,
    required this.enterX,
    required this.enterY,
    required this.fontSize,
    required this.isHero,
    required this.seed,
    required this.progress,
    required this.wordStartMs,
  });

  final Offset center;
  final double enterX;
  final double enterY;
  final double fontSize;
  final bool isHero;
  final int seed;
  final double progress;
  final int wordStartMs;
}

class SonnetGuidePainter extends CustomPainter {
  const SonnetGuidePainter({
    required this.guides,
    required this.primary,
    required this.accent,
  });

  final List<SonnetGuideSpec> guides;
  final Color primary;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    for (final guide in guides) {
      _paintGuide(canvas, guide, size);
    }
    canvas.restore();
  }

  void _paintGuide(Canvas canvas, SonnetGuideSpec guide, Size size) {
    if (guide.progress <= 0) return;
    final t = guide.progress.clamp(0.0, 1.0);
    final angle = math.atan2(-guide.enterY, -guide.enterX);
    final startRadius = math.sqrt(
      math.pow(size.width / 2, 2) + math.pow(size.height / 2, 2),
    );
    final endRadius = guide.fontSize * 0.75;
    final startPoint = Offset(
      math.cos(angle) * startRadius,
      math.sin(angle) * startRadius,
    );
    final endPoint = Offset(
      guide.center.dx + math.cos(angle) * endRadius,
      guide.center.dy + math.sin(angle) * endRadius,
    );
    final controlPoint = Offset(
      startPoint.dx +
          (endPoint.dx - startPoint.dx) * 0.5 +
          math.sin(angle) * guide.fontSize * 0.6,
      startPoint.dy +
          (endPoint.dy - startPoint.dy) * 0.5 -
          math.cos(angle) * guide.fontSize * 0.6,
    );
    final isHero = guide.isHero;
    final maxAlpha = isHero ? 0.95 : 0.7;
    final color = isHero ? accent : primary;

    // The line draws from 0.75 → 0.95 of progress, then fades.
    final drawProgress = t < 0.75
        ? t / 0.75
        : t < 0.95
        ? 1
        : 1 - (t - 0.95) / 0.05;
    if (drawProgress <= 0) return;
    final guideAlpha = (1 - (t * 0.65)) * maxAlpha * drawProgress;
    final paint = Paint()
      ..color = color.withValues(alpha: guideAlpha)
      ..strokeWidth = isHero ? 2 : 1
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(startPoint.dx, startPoint.dy)
      ..quadraticBezierTo(
        controlPoint.dx,
        controlPoint.dy,
        endPoint.dx,
        endPoint.dy,
      );
    canvas.drawPath(path, paint);

    // The star head appears only when the tip is reached.
    final starProgress = t < 0.75
        ? 0.0
        : t < 0.95
        ? (t - 0.75) / 0.2
        : (t - 0.95) / 0.05;
    if (starProgress > 0) {
      final starRadius = guide.fontSize * 0.35;
      final starPaint = Paint()
        ..color = color.withValues(alpha: 
          math.max(0.2, 1 - starProgress) * maxAlpha,
        )
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      _paintStar(canvas, endPoint, starRadius, starPaint);
      final burstCount = isHero ? 6 : 3;
      final burstScale = sonnetElasticOut(starProgress);
      final rng = sonnetMulberry32(guide.seed);
      for (var i = 0; i < burstCount; i++) {
        final burstAngle = rng() * 2 * math.pi;
        final burstDistance =
            rng() * guide.fontSize * 0.8 * burstScale;
        final burstSize = math.max(2.0, rng() * 6);
        canvas.drawCircle(
          Offset(
            endPoint.dx + math.cos(burstAngle) * burstDistance,
            endPoint.dy + math.sin(burstAngle) * burstDistance,
          ),
          burstSize,
          Paint()
            ..color = color.withValues(alpha: 
              (1 - starProgress) * 0.8 * maxAlpha,
            ),
        );
      }
    }

    // The ribbon trail trails behind the tip.
    final trailProgress = math.max(0, drawProgress - 0.4) * 0.5;
    if (trailProgress > 0) {
      final trailPaint = Paint()
        ..color = color.withValues(alpha: trailProgress * 0.3 * maxAlpha)
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke;
      final trailPath = Path()
        ..moveTo(startPoint.dx, startPoint.dy)
        ..quadraticBezierTo(
          controlPoint.dx,
          controlPoint.dy,
          endPoint.dx,
          endPoint.dy,
        );
      canvas.drawPath(trailPath, trailPaint);
    }

    // The rect spline: three cornered offsets around the target.
    final splineProgress = t < 0.75
        ? 0.0
        : t < 0.95
        ? (t - 0.75) / 0.2
        : 1 - (t - 0.95) / 0.05;
    if (splineProgress > 0) {
      final rect = Rect.fromCenter(
        center: guide.center,
        width: guide.fontSize * 1.5,
        height: guide.fontSize * 1.5,
      );
      final splinePaint = Paint()
        ..color = color.withValues(alpha: 
          splineProgress * 0.4 * maxAlpha,
        )
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      canvas.drawRect(rect, splinePaint);
    }
  }

  void _paintStar(Canvas canvas, Offset center, double radius, Paint paint) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4;
      final r = i % 2 == 0 ? radius : radius * 0.4;
      final point = Offset(
        center.dx + math.cos(angle) * r,
        center.dy + math.sin(angle) * r,
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant SonnetGuidePainter oldDelegate) =>
      oldDelegate.guides != guides ||
      oldDelegate.primary != primary ||
      oldDelegate.accent != accent;
}

/// Scene hairlines + the 8 HUD variants (classic-cross,
/// corner-brackets, marquee-strips, diagonal-corners,
/// dotted-columns, double-frame, ruler-frame, arc-gauge).
/// (sonnetBackgroundMgVariants.ts). The editorial grid and the
/// tableau/reveal scattered squares live here too, since the
/// blueprint draws them inside the same background MG layer
/// (sonnetBackgroundMg.ts).
class SonnetBackgroundHudPainter extends CustomPainter {
  const SonnetBackgroundHudPainter({
    required this.variant,
    required this.sceneSeed,
    required this.shotSeed,
    required this.primary,
    required this.accent,
    required this.isEditorial,
    required this.isTableauOrReveal,
  });

  final int variant;
  final int sceneSeed;
  final int shotSeed;
  final Color primary;
  final Color accent;
  final bool isEditorial;
  final bool isTableauOrReveal;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    final hairlines = sonnetSceneHairlineCount(sceneSeed);
    final rng = sonnetMulberry32(shotSeed);
    final linePaint = Paint()
      ..color = primary.withValues(alpha: 0.06)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < hairlines; i++) {
      final angle = rng() * math.pi * 2;
      final x1 = math.cos(angle) * size.width / 2;
      final y1 = math.sin(angle) * size.height / 2;
      final x2 = -x1;
      final y2 = -y1;
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), linePaint);
    }

    final marginW = size.width * 0.05;
    final marginH = size.height * 0.05;
    final left = -size.width / 2 + marginW;
    final right = size.width / 2 - marginW;
    final top = -size.height / 2 + marginH;
    final bottom = size.height / 2 - marginH;
    final framePaint = Paint()
      ..color = primary.withValues(alpha: 0.25)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final arcPaint = Paint()
      ..color = accent.withValues(alpha: 0.4)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    switch (variant % 8) {
      case 0: // classic-cross
        final crossPaint = Paint()
          ..color = primary.withValues(alpha: 0.2)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke;
        canvas.drawLine(
          Offset(size.width / 2 - marginW, 0),
          Offset(size.width / 2, size.height / 2 - marginH),
          crossPaint,
        );
        canvas.drawLine(
          Offset(size.width / 2, 0),
          Offset(size.width / 2, size.height / 2),
          crossPaint,
        );
        canvas.drawCircle(
          const Offset(0, 0),
          size.width * 0.05,
          crossPaint,
        );
      case 1: // corner-brackets
        final bracket = size.width * 0.1;
        _drawCornerBrackets(
          canvas,
          left,
          top,
          right,
          bottom,
          bracket,
          framePaint,
        );
      case 2: // marquee-strips
        final stripPaint = Paint()
          ..color = primary.withValues(alpha: 0.2)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
        canvas.drawLine(
          Offset(left, top),
          Offset(right, top),
          stripPaint,
        );
        canvas.drawLine(
          Offset(left, bottom),
          Offset(right, bottom),
          stripPaint,
        );
      case 3: // diagonal-corners
        final cornerLength = size.width * 0.1;
        _drawDiagonalCorner(
          canvas,
          left,
          top,
          cornerLength,
          1,
          1,
          framePaint,
        );
        _drawDiagonalCorner(
          canvas,
          right,
          top,
          cornerLength,
          -1,
          1,
          framePaint,
        );
        _drawDiagonalCorner(
          canvas,
          left,
          bottom,
          cornerLength,
          1,
          -1,
          framePaint,
        );
        _drawDiagonalCorner(
          canvas,
          right,
          bottom,
          cornerLength,
          -1,
          -1,
          framePaint,
        );
      case 4: // dotted-columns
        final dotPaint = Paint()..color = primary.withValues(alpha: 0.3);
        final columns = 7;
        final rows = 7;
        for (var col = 0; col < columns; col++) {
          final x =
              -size.width * 0.2 + col * size.width * 0.0666667;
          for (var row = 0; row < rows; row++) {
            canvas.drawCircle(
              Offset(x, -size.height * 0.2 + row * size.height * 0.0666667),
              2,
              dotPaint,
            );
          }
        }
      case 5: // double-frame
        canvas.drawRect(
          Rect.fromLTRB(left, top, right, bottom),
          framePaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(
            left + 8,
            top + 8,
            right - 8,
            bottom - 8,
          ),
          framePaint,
        );
      case 6: // ruler-frame
        final rulerPaint = Paint()
          ..color = primary.withValues(alpha: 0.3)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke;
        canvas.drawLine(
          Offset(left, top),
          Offset(right, top),
          rulerPaint,
        );
        final tickLength = 8.0;
        final ticks = (right - left) ~/ 20;
        for (var i = 0; i < ticks; i++) {
          final x = left + i * 20;
          final isLong = i % 5 == 0;
          canvas.drawLine(
            Offset(x, top),
            Offset(x, top + (isLong ? tickLength * 2 : tickLength)),
            rulerPaint,
          );
        }
      case 7: // arc-gauge
        canvas.drawArc(
          Rect.fromCircle(
            center: const Offset(0, 0),
            radius: size.width * 0.3,
          ),
          -math.pi / 4,
          math.pi / 2,
          false,
          arcPaint,
        );
        canvas.drawArc(
          Rect.fromCircle(
            center: const Offset(0, 0),
            radius: size.width * 0.28,
          ),
          -math.pi / 4,
          math.pi / 2,
          false,
          arcPaint,
        );
    }

    if (isEditorial) {
      final gridPaint = Paint()
        ..color = primary.withValues(alpha: 0.08)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      for (var i = 1; i < 6; i++) {
        canvas.drawLine(
          Offset(-size.width * 0.42, -size.height * 0.4 + i * size.height * 0.133),
          Offset(size.width * 0.42, -size.height * 0.4 + i * size.height * 0.133),
          gridPaint,
        );
        canvas.drawLine(
          Offset(-size.width * 0.42 + i * size.width * 0.14, -size.height * 0.4),
          Offset(-size.width * 0.42 + i * size.width * 0.14, size.height * 0.4),
          gridPaint,
        );
      }
    }
    if (isTableauOrReveal) {
      final scatteredPaint = Paint()..color = primary.withValues(alpha: 0.15);
      final scatterRng = sonnetMulberry32(shotSeed + 997);
      for (var i = 0; i < 12; i++) {
        final x =
            (scatterRng() * 2 - 1) * size.width * 0.4;
        final y =
            (scatterRng() * 2 - 1) * size.height * 0.4;
        final side = 8 + scatterRng() * 16;
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset(x, y),
            width: side,
            height: side,
          ),
          scatteredPaint,
        );
      }
    }
    canvas.restore();
  }

  void _drawCornerBrackets(
    Canvas canvas,
    double left,
    double top,
    double right,
    double bottom,
    double length,
    Paint paint,
  ) {
    final path = Path()
      ..moveTo(left + length, top)
      ..lineTo(left, top)
      ..lineTo(left, top + length)
      ..moveTo(right - length, top)
      ..lineTo(right, top)
      ..lineTo(right, top + length)
      ..moveTo(left + length, bottom)
      ..lineTo(left, bottom)
      ..lineTo(left, bottom - length)
      ..moveTo(right - length, bottom)
      ..lineTo(right, bottom)
      ..lineTo(right, bottom - length);
    canvas.drawPath(path, paint);
  }

  void _drawDiagonalCorner(
    Canvas canvas,
    double x,
    double y,
    double length,
    double dx,
    double dy,
    Paint paint,
  ) {
    canvas.drawLine(
      Offset(x, y),
      Offset(x + dx * length, y),
      paint,
    );
    canvas.drawLine(
      Offset(x, y),
      Offset(x, y + dy * length),
      paint,
    );
  }

  @override
  bool shouldRepaint(
    covariant SonnetBackgroundHudPainter oldDelegate,
  ) =>
      oldDelegate.variant != variant ||
      oldDelegate.sceneSeed != sceneSeed ||
      oldDelegate.shotSeed != shotSeed ||
      oldDelegate.primary != primary ||
      oldDelegate.accent != accent ||
      oldDelegate.isEditorial != isEditorial ||
      oldDelegate.isTableauOrReveal != isTableauOrReveal;
}

/// The 6 background decor arrangements (scatter, orbit,
/// edge-band, corner-clusters, constellation, twin-columns).
/// (sonnetBackgroundDecor.ts). Each particle carries its type,
/// a size of 4 + (seed + i) % 12 px, and alpha 0.55 + hash01 × 0.3.
class SonnetBackgroundDecorPainter extends CustomPainter {
  const SonnetBackgroundDecorPainter({
    required this.variant,
    required this.seed,
    required this.particleCount,
    required this.primary,
    required this.accent,
  });

  final int variant;
  final int seed;
  final int particleCount;
  final Color primary;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    final rng = sonnetMulberry32(seed);
    final offsets = <Offset>[];
    final sizes = <double>[];
    final alphas = <double>[];
    for (var i = 0; i < particleCount; i++) {
      sizes.add((4 + (seed + i) % 12).toDouble());
      alphas.add(
        0.55 + sonnetHash01(seed, i, 0x1234) * 0.3,
      );
      switch (variant % 6) {
        case 0: // scatter
          offsets.add(
            Offset(
              (rng() * 2 - 1) * size.width * 0.45,
              (rng() * 2 - 1) * size.height * 0.45,
            ),
          );
        case 1: // orbit
          final angle = rng() * math.pi * 2;
          final radius =
              math.min(size.width, size.height) * 0.35 +
              rng() * size.width * 0.05;
          offsets.add(
            Offset(
              math.cos(angle) * radius,
              math.sin(angle) * radius,
            ),
          );
        case 2: // edge-band
          offsets.add(
            Offset(
              (rng() * 2 - 1) * size.width * 0.45,
              (rng() > 0.5
                      ? size.height * 0.45
                      : -size.height * 0.45) +
                  (rng() * 2 - 1) * size.height * 0.05,
            ),
          );
        case 3: // corner-clusters
          final corner = rng() > 0.5 ? 1 : -1;
          offsets.add(
            Offset(
              corner * size.width * 0.4 + (rng() * 2 - 1) * 40,
              corner * size.height * 0.4 + (rng() * 2 - 1) * 40,
            ),
          );
        case 4: // constellation
          offsets.add(
            Offset(
              (rng() * 2 - 1) * size.width * 0.4,
              (rng() * 2 - 1) * size.height * 0.4,
            ),
          );
        case 5: // twin-columns
          final side = rng() > 0.5 ? 1 : -1;
          offsets.add(
            Offset(
              side * size.width * 0.4 + (rng() * 2 - 1) * 20,
              (rng() * 2 - 1) * size.height * 0.4,
            ),
          );
      }
    }
    for (var i = 0; i < particleCount; i++) {
      final offset = offsets[i];
      final particleSize = sizes[i];
      final alpha = alphas[i];
      final color = i % 3 == 0 ? accent : primary;
      final paint = Paint()
        ..color = color.withValues(alpha: alpha)
        ..style = PaintingStyle.fill;
      if (i % 3 == 0) {
        canvas.drawCircle(offset, particleSize * 0.4, paint);
      } else if (i % 3 == 1) {
        canvas.drawRect(
          Rect.fromCenter(
            center: offset,
            width: particleSize,
            height: particleSize,
          ),
          paint,
        );
      } else {
        final path = Path()
          ..moveTo(offset.dx, offset.dy - particleSize / 2)
          ..lineTo(offset.dx + particleSize / 2, offset.dy + particleSize / 2)
          ..lineTo(offset.dx - particleSize / 2, offset.dy + particleSize / 2)
          ..close();
        canvas.drawPath(path, paint);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(
    covariant SonnetBackgroundDecorPainter oldDelegate,
  ) =>
      oldDelegate.variant != variant ||
      oldDelegate.seed != seed ||
      oldDelegate.particleCount != particleCount ||
      oldDelegate.primary != primary ||
      oldDelegate.accent != accent;
}

/// Shot-level fixed geometry (sonnetFixedGeoVariants.ts): 8
/// variants (classic-blocks, twin-pillars, disc-ring,
/// diamond-pair, stripe-stack, corner-els, twin-wedges,
/// cross-ring) plus hatching. Alpha 0.4 (chorus) / 0.25
/// (sonnetTextFixedGeo.ts).
class SonnetFixedGeoShotPainter extends CustomPainter {
  const SonnetFixedGeoShotPainter({
    required this.variant,
    required this.seed,
    required this.radius,
    required this.primary,
    required this.accent,
    required this.isChorus,
  });

  final int variant;
  final int seed;
  final double radius;
  final Color primary;
  final Color accent;
  final bool isChorus;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    final alpha = (isChorus ? 0.4 : 0.25) + (seed % 10) * 0.03;
    final primaryPaint = Paint()
      ..color = primary.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final accentPaint = Paint()
      ..color = accent.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    switch (variant % 8) {
      case 0: // classic-blocks
        canvas.drawRect(
          Rect.fromCenter(
            center: const Offset(0, 0),
            width: radius * 2,
            height: radius * 2,
          ),
          primaryPaint,
        );
        canvas.drawRect(
          Rect.fromCenter(
            center: const Offset(0, 0),
            width: radius * 1.5,
            height: radius * 1.5,
          ),
          accentPaint,
        );
      case 1: // twin-pillars
        canvas.drawRect(
          Rect.fromLTRB(
            -radius * 1.2,
            -radius,
            -radius * 0.8,
            radius,
          ),
          primaryPaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(
            radius * 0.8,
            -radius,
            radius * 1.2,
            radius,
          ),
          accentPaint,
        );
      case 2: // disc-ring
        canvas.drawCircle(
          const Offset(0, 0),
          radius,
          primaryPaint,
        );
        canvas.drawCircle(
          const Offset(0, 0),
          radius * 0.7,
          accentPaint,
        );
      case 3: // diamond-pair
        final diamondPath = Path()
          ..moveTo(0, -radius)
          ..lineTo(radius, 0)
          ..lineTo(0, radius)
          ..lineTo(-radius, 0)
          ..close();
        canvas.drawPath(diamondPath, primaryPaint);
        final innerDiamondPath = Path()
          ..moveTo(0, -radius * 0.7)
          ..lineTo(radius * 0.7, 0)
          ..lineTo(0, radius * 0.7)
          ..lineTo(-radius * 0.7, 0)
          ..close();
        canvas.drawPath(innerDiamondPath, accentPaint);
      case 4: // stripe-stack
        for (var i = 0; i < 5; i++) {
          canvas.drawLine(
            Offset(-radius, -radius + i * radius * 0.5),
            Offset(radius, -radius + i * radius * 0.5),
            i % 2 == 0 ? primaryPaint : accentPaint,
          );
        }
      case 5: // corner-els
        final cornerLength = radius * 0.5;
        final cornerPaint = Paint()
          ..color = primary.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
        canvas.drawLine(
          const Offset(0, 0),
          Offset(-cornerLength, 0),
          cornerPaint,
        );
        canvas.drawLine(
          const Offset(0, 0),
          Offset(0, -cornerLength),
          cornerPaint,
        );
        canvas.drawLine(
          const Offset(0, 0),
          Offset(cornerLength, 0),
          cornerPaint,
        );
        canvas.drawLine(
          const Offset(0, 0),
          Offset(0, cornerLength),
          cornerPaint,
        );
      case 6: // twin-wedges
        final wedgePath = Path()
          ..moveTo(-radius, -radius)
          ..lineTo(radius, radius)
          ..lineTo(-radius, radius)
          ..close();
        canvas.drawPath(wedgePath, primaryPaint);
        final wedgePath2 = Path()
          ..moveTo(radius, -radius)
          ..lineTo(-radius, radius)
          ..lineTo(radius, radius)
          ..close();
        canvas.drawPath(wedgePath2, accentPaint);
      case 7: // cross-ring
        canvas.drawCircle(
          const Offset(0, 0),
          radius,
          primaryPaint,
        );
        canvas.drawLine(
          Offset(-radius, 0),
          Offset(radius, 0),
          accentPaint,
        );
        canvas.drawLine(
          Offset(0, -radius),
          Offset(0, radius),
          accentPaint,
        );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(
    covariant SonnetFixedGeoShotPainter oldDelegate,
  ) =>
      oldDelegate.variant != variant ||
      oldDelegate.seed != seed ||
      oldDelegate.radius != radius ||
      oldDelegate.primary != primary ||
      oldDelegate.accent != accent ||
      oldDelegate.isChorus != isChorus;
}

/// One fixed-geometric frame around a word (sonnetTextFixedGeo.ts):
/// 7 plans — hollow straight-frame, rotated-frame,
/// orbit-crosshair, split-arches; solid orb-hatch, music-steps,
/// bent-lines. Alpha 0.4 (chorus) / 0.25 (sonnetTextFixedGeo.ts).
class SonnetTextFixedGeoSpec {
  const SonnetTextFixedGeoSpec({
    required this.center,
    required this.width,
    required this.height,
    required this.rotation,
    required this.fontSize,
    required this.variant,
    required this.seed,
    required this.isChorus,
  });

  final Offset center;
  final double width;
  final double height;
  final double rotation;
  final double fontSize;
  final int variant;
  final int seed;
  final bool isChorus;
}

class SonnetTextFixedGeoPainter extends CustomPainter {
  const SonnetTextFixedGeoPainter({
    required this.specs,
    required this.primary,
    required this.accent,
  });

  final List<SonnetTextFixedGeoSpec> specs;
  final Color primary;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    for (final spec in specs) {
      _paintSpec(canvas, spec);
    }
    canvas.restore();
  }

  void _paintSpec(Canvas canvas, SonnetTextFixedGeoSpec spec) {
    final alpha = (spec.isChorus ? 0.4 : 0.25) + (spec.seed % 10) * 0.03;
    final paint = Paint()
      ..color = primary.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final accentPaint = Paint()
      ..color = accent.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.save();
    canvas.translate(spec.center.dx, spec.center.dy);
    canvas.rotate(spec.rotation);
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: spec.width,
      height: spec.height,
    );
    switch (spec.variant % 7) {
      case 0: // straight-frame
        canvas.drawRect(rect, paint);
      case 1: // rotated-frame
        canvas.drawRect(rect, paint);
        canvas.rotate(math.pi / 4);
        canvas.drawRect(rect, accentPaint);
      case 2: // orbit-crosshair
        canvas.drawCircle(Offset.zero, spec.fontSize * 0.8, paint);
        canvas.drawLine(
          Offset(-spec.width / 2, 0),
          Offset(spec.width / 2, 0),
          accentPaint,
        );
        canvas.drawLine(
          Offset(0, -spec.height / 2),
          Offset(0, spec.height / 2),
          accentPaint,
        );
      case 3: // split-arches
        canvas.drawArc(
          Rect.fromCircle(
            center: Offset.zero,
            radius: spec.fontSize * 0.8,
          ),
          -math.pi,
          math.pi,
          false,
          paint,
        );
        canvas.drawArc(
          Rect.fromCircle(
            center: Offset.zero,
            radius: spec.fontSize * 0.6,
          ),
          0,
          math.pi,
          false,
          accentPaint,
        );
      case 4: // orb-hatch
        canvas.drawCircle(Offset.zero, spec.fontSize * 0.8, paint);
        for (var i = -3; i <= 3; i++) {
          canvas.drawLine(
            Offset(i * spec.fontSize * 0.2, -spec.fontSize * 0.8),
            Offset(i * spec.fontSize * 0.2, spec.fontSize * 0.8),
            accentPaint,
          );
        }
      case 5: // music-steps
        final stepWidth = spec.width / 4;
        for (var i = 0; i < 4; i++) {
          canvas.drawRect(
            Rect.fromLTWH(
              -spec.width / 2 + i * stepWidth,
              spec.height / 2 - (i + 1) * spec.height / 4,
              stepWidth,
              (i + 1) * spec.height / 4,
            ),
            i % 2 == 0 ? paint : accentPaint,
          );
        }
      case 6: // bent-lines
        final path = Path()
          ..moveTo(-spec.width / 2, spec.height / 2)
          ..lineTo(0, -spec.height / 2)
          ..lineTo(spec.width / 2, spec.height / 2);
        canvas.drawPath(path, paint);
        final path2 = Path()
          ..moveTo(-spec.width / 2, -spec.height / 2)
          ..lineTo(0, spec.height / 2)
          ..lineTo(spec.width / 2, -spec.height / 2);
        canvas.drawPath(path2, accentPaint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(
    covariant SonnetTextFixedGeoPainter oldDelegate,
  ) =>
      oldDelegate.specs != specs ||
      oldDelegate.primary != primary ||
      oldDelegate.accent != accent;
}

/// One traced frame around a word (sonnetTextViewBuilder.ts):
/// a rectangle traced left → top → right → bottom (clockwise,
/// top-first) plus corner ornaments growing on the elastic curve
/// (sonnetFrameDecor.ts).
class SonnetFrameDecorSpec {
  const SonnetFrameDecorSpec({
    required this.center,
    required this.width,
    required this.height,
    required this.rotation,
    required this.fontSize,
    required this.variant,
    required this.progress,
  });

  final Offset center;
  final double width;
  final double height;
  final double rotation;
  final double fontSize;
  final int variant;
  final double progress;
}

class SonnetFrameDecorPainter extends CustomPainter {
  const SonnetFrameDecorPainter({
    required this.specs,
    required this.primary,
    required this.accent,
  });

  final List<SonnetFrameDecorSpec> specs;
  final Color primary;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    for (final spec in specs) {
      _paintSpec(canvas, spec);
    }
    canvas.restore();
  }

  void _paintSpec(Canvas canvas, SonnetFrameDecorSpec spec) {
    if (spec.progress <= 0) return;
    final t = spec.progress.clamp(0.0, 1.0);
    canvas.save();
    canvas.translate(spec.center.dx, spec.center.dy);
    canvas.rotate(spec.rotation);
    final halfW = spec.width / 2;
    final halfH = spec.height / 2;
    final alpha = 0.5 * (1 - t * 0.5);
    final paint = Paint()
      ..color = primary.withValues(alpha: alpha)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final corners = <Offset>[
      Offset(-halfW, -halfH),
      Offset(halfW, -halfH),
      Offset(halfW, halfH),
      Offset(-halfW, halfH),
    ];
    final path = Path()..moveTo(corners[0].dx, corners[0].dy);
    final totalLength = 2 * (spec.width + spec.height);
    final traceLength = t * totalLength;
    var remaining = traceLength;
    for (var i = 0; i < 4; i++) {
      final start = corners[i];
      final end = corners[(i + 1) % 4];
      final edgeLength = (end - start).distance;
      if (remaining <= 0) break;
      final drawLength = math.min(remaining, edgeLength);
      final ratio = drawLength / edgeLength;
      final to = Offset(
        start.dx + (end.dx - start.dx) * ratio,
        start.dy + (end.dy - start.dy) * ratio,
      );
      path.lineTo(to.dx, to.dy);
      remaining -= drawLength;
    }
    canvas.drawPath(path, paint);

    final ornamentScale = sonnetElasticOut(t);
    final ornamentPaint = Paint()
      ..color = accent.withValues(alpha: alpha)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final cornerLength = spec.fontSize * 0.3 * ornamentScale;
    for (final corner in corners) {
      final dx = corner.dx.sign;
      final dy = corner.dy.sign;
      canvas.drawLine(
        corner,
        Offset(corner.dx + dx * cornerLength, corner.dy),
        ornamentPaint,
      );
      canvas.drawLine(
        corner,
        Offset(corner.dx, corner.dy + dy * cornerLength),
        ornamentPaint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(
    covariant SonnetFrameDecorPainter oldDelegate,
  ) =>
      oldDelegate.specs != specs ||
      oldDelegate.primary != primary ||
      oldDelegate.accent != accent;
}

/// Screen-fixed outer frame (sonnetFrameOverlay.ts): a corner
/// cluster top-left, a cluster bottom-right, a cross, a diamond
/// and a ✦ star. Margin max(30, 5% of the smaller side). Skipped
/// when outerFrameMode is 'none'.
class SonnetFrameOverlayPainter extends CustomPainter {
  const SonnetFrameOverlayPainter({required this.primary});

  final Color primary;

  @override
  void paint(Canvas canvas, Size size) {
    final margin = math.max(30.0, math.min(size.width, size.height) * 0.05);
    final alpha = 0.5;
    final paint = Paint()
      ..color = primary.withValues(alpha: alpha)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final small = margin * 0.3;
    final large = margin * 0.6;
    // Top-left cluster.
    canvas.drawLine(
      Offset(margin, margin + large),
      Offset(margin, margin),
      paint,
    );
    canvas.drawLine(
      Offset(margin, margin),
      Offset(margin + large, margin),
      paint,
    );
    canvas.drawLine(
      Offset(margin, margin + small),
      Offset(margin + small, margin + small),
      paint,
    );
    canvas.drawLine(
      Offset(margin + small, margin + small),
      Offset(margin + small, margin),
      paint,
    );
    // Bottom-right cluster.
    canvas.drawLine(
      Offset(size.width - margin, size.height - margin - large),
      Offset(size.width - margin, size.height - margin),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - margin, size.height - margin),
      Offset(size.width - margin - large, size.height - margin),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - margin, size.height - margin - small),
      Offset(size.width - margin - small, size.height - margin - small),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - margin - small, size.height - margin - small),
      Offset(size.width - margin - small, size.height - margin),
      paint,
    );
    // Cross.
    final crossX = size.width * 0.5;
    final crossY = size.height * 0.08;
    canvas.drawLine(
      Offset(crossX - small, crossY),
      Offset(crossX + small, crossY),
      paint,
    );
    canvas.drawLine(
      Offset(crossX, crossY - small),
      Offset(crossX, crossY + small),
      paint,
    );
    // Diamond.
    final diamondX = size.width * 0.08;
    final diamondY = size.height * 0.5;
    final diamondPath = Path()
      ..moveTo(diamondX, diamondY - small)
      ..lineTo(diamondX + small, diamondY)
      ..lineTo(diamondX, diamondY + small)
      ..lineTo(diamondX - small, diamondY)
      ..close();
    canvas.drawPath(diamondPath, paint);
    // Star (✦).
    final starX = size.width * 0.92;
    final starY = size.height * 0.5;
    final starPath = Path()
      ..moveTo(starX, starY - small)
      ..lineTo(starX + small * 0.3, starY - small * 0.3)
      ..lineTo(starX + small, starY)
      ..lineTo(starX + small * 0.3, starY + small * 0.3)
      ..lineTo(starX, starY + small)
      ..lineTo(starX - small * 0.3, starY + small * 0.3)
      ..lineTo(starX - small, starY)
      ..lineTo(starX - small * 0.3, starY - small * 0.3)
      ..close();
    canvas.drawPath(starPath, paint);
  }

  @override
  bool shouldRepaint(
    covariant SonnetFrameOverlayPainter oldDelegate,
  ) =>
      oldDelegate.primary != primary;
}

/// Draws a list of hollow outline words (giant decorative text,
/// sonnetTextViewBuilder.ts). Decorations are hollow (stroke)
/// at alpha 0.2, with a soft glow of |zDepth| × fontSize × 0.12
/// (sonnetTextViewBuilder.ts). The stage renders each one with
/// the word's own style, rotated by [SonnetDecoration.rotation].
class SonnetDecorationStyle {
  const SonnetDecorationStyle({
    required this.color,
    required this.zDepthBlur,
  });

  final Color color;
  final double zDepthBlur;
}

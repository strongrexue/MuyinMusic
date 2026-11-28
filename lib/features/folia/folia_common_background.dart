import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'audio_analysis.dart';
import 'folia_stage_registry.dart';
import 'folia_theme.dart';

/// Folia's built-in "common" (通用) background, ported from
/// src/components/visualizer/backgrounds/common/ (entry.tsx,
/// GeometricBackground.tsx, GeometricBackground.css,
/// CommonBackgroundSettingsCard.tsx).
///
/// Layers, in order (all full-screen, like the blueprint):
/// 1. Base colour: the resolved theme background, opaque — the
///    blueprint daylight base (#f5f5f4) in light mode, the
///    cover-derived dark base in dark mode (see
///    FoliaTheme.resolveForBrightness; buildAppStyle.ts,
///    baseThemes.ts).
/// 2. Geometric layer: 15 drifting shapes + 20 rising particles,
///    pulsing gently with the audio bands, over a vignette.
///
/// Defaults, verified against the blueprint (entry.tsx +
/// CommonBackgroundSettingsCard.tsx + resetSettings):
/// useCoverColorBg = false, opacity = 0.75, disableVignette = false,
/// disableGeometricBackground = false.
///
/// The blueprint's cover-colour fluid layer (FluidBackground: a
/// blurred cover under a gradient) is OFF by default and is NOT
/// ported here: it needs cover-image plumbing plus a settings entry,
/// neither of which exists yet. The base colour below is the
/// brightness-resolved theme background (blueprint daylight base in
/// light mode, cover-derived dark base in dark mode), so the lyrics
/// stay readable in both — the reason this background was ported.
///
/// What is common's own layer vs the sonnet style's MG decor: the
/// geometric shapes / particles / vignette below are common's. The
/// sonnet MG layer (guides, HUD, frames) is the style's own and is
/// already ported in sonnet_mg.dart — it is NOT redrawn here.
///
/// Performance: no per-frame saveLayer (plain fills/strokes in one
/// CustomPaint, no blur, no ImageFilter). The geometric layer
/// repaints at most ~10Hz on a timer plus the ~12Hz analysis
/// cadence for the audio scale; the drift itself is a pure function
/// of elapsed time, so nothing is allocated per frame.
FoliaStageBackground commonStageBackground() => FoliaStageBackground(
  id: 'common',
  label: '通用',
  builder: (context, stage) => FoliaCommonBackground(
    theme: stage.theme,
    seed: stage.songId,
    analysis: stage.analysis,
    playingNow: stage.playingNow,
  ),
);

/// The common background: brightness-resolved base + geometric layer
/// + vignette. Opaque: it covers the player page's background
/// (the KTV photo) when used as the folia stage's bottom layer.
class FoliaCommonBackground extends StatelessWidget {
  const FoliaCommonBackground({
    super.key,
    required this.theme,
    required this.seed,
    required this.analysis,
    required this.playingNow,
    this.disableGeometricBackground = false,
    this.disableVignette = false,
  });

  /// Brightness-resolved base colour (blueprint theme.backgroundColor,
  /// resolved by FoliaTheme.resolveForBrightness).
  final FoliaTheme theme;

  /// Song id: the geometric layout is derived from it alone, so the
  /// same song always gets the same shapes (blueprint: seed).
  final String seed;

  /// Audio analysis frames, for the shapes' band-reactive scale.
  final Stream<AudioAnalysisFrame> analysis;

  /// Whether playback is running: pausing holds the drift loops
  /// where they are (blueprint: .geometric-paused).
  final bool Function() playingNow;

  /// Blueprint common.disableGeometricBackground (default false:
  /// the shapes are on).
  final bool disableGeometricBackground;

  /// Blueprint common.disableVignette (default false: the vignette
  /// is on).
  final bool disableVignette;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Base colour, opaque (blueprint: opacity 1 while the cover
        // colour layer is off).
        Container(color: theme.background),
        if (!disableGeometricBackground)
          FoliaGeometricBackground(
            seed: seed,
            analysis: analysis,
            playingNow: playingNow,
            // Blueprint GeometricBackground: shape faces use the
            // theme's secondary colour, particles the accent. Our
            // theme carries a single saturated cover colour, so it
            // serves both roles.
            shapeColor: theme.accent,
            particleColor: theme.accent,
          ),
        if (!disableVignette) const FoliaVignette(),
      ],
    );
  }
}

/// Vignette: radial gradient, transparent in the middle, black 60%
/// at the edges (blueprint: radial-gradient(circle, transparent
/// 40%, rgba(0,0,0,0.6) 100%)).
class FoliaVignette extends StatelessWidget {
  const FoliaVignette({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 0.75,
          colors: [Colors.transparent, Color(0x99000000)],
          stops: [0.4, 1.0],
        ),
      ),
    );
  }
}

/// One drifting shape (blueprint GeometricBackground.tsx).
class FoliaGeometricShape {
  const FoliaGeometricShape({
    required this.type,
    required this.xPercent,
    required this.yPercent,
    required this.size,
    required this.durationMs,
    required this.delayMs,
    required this.opacity,
    required this.reverse,
    required this.filled,
    required this.rotationDegrees,
  });

  final FoliaGeometricShapeType type;

  /// Position as a share of the canvas (blueprint initialX/Y %).
  final double xPercent;
  final double yPercent;

  /// Edge length in logical pixels (blueprint 40–140).
  final double size;

  /// Drift loop length (blueprint 30–60s).
  final int durationMs;

  /// Loop phase offset (blueprint delay 0–5s).
  final int delayMs;

  /// Face opacity (blueprint 0.11–0.19).
  final double opacity;

  /// Drift direction (blueprint --geometric-dir ±1).
  final bool reverse;

  /// Filled face vs 1px stroke (blueprint: 30% filled; only
  /// circle/square can be stroked).
  final bool filled;

  /// Starting rotation in degrees (blueprint 0–360).
  final double rotationDegrees;
}

enum FoliaGeometricShapeType { circle, square, triangle, cross }

/// One rising particle (blueprint GeometricBackground.tsx).
class FoliaGeometricParticle {
  const FoliaGeometricParticle({
    required this.size,
    required this.leftPercent,
    required this.topPercent,
    required this.opacity,
    required this.durationMs,
    required this.delayMs,
  });

  /// Diameter in logical pixels (blueprint 1–5).
  final double size;
  final double leftPercent;
  final double topPercent;

  /// Peak opacity (blueprint 0–0.3).
  final double opacity;

  /// Rise loop length (blueprint 15–35s).
  final int durationMs;

  /// Loop phase offset (blueprint delay 0–10s).
  final int delayMs;
}

/// 15 shapes, laid out from the seed alone (blueprint: useMemo on
/// seed; icon slots are skipped — our theme has no lyric icons, so
/// every shape shows its face, as the blueprint does with no icons).
List<FoliaGeometricShape> foliaGeometricShapes(String seed) {
  const types = FoliaGeometricShapeType.values;
  final random = _SeededRandom(_fnv1a(seed));
  return List.generate(15, (_) {
    return FoliaGeometricShape(
      type: types[(random.nextDouble() * types.length).floor()],
      xPercent: random.nextDouble() * 100,
      yPercent: random.nextDouble() * 100,
      size: 40 + random.nextDouble() * 100,
      durationMs: 30000 + (random.nextDouble() * 30000).round(),
      delayMs: (random.nextDouble() * 5000).round(),
      opacity: 0.11 + random.nextDouble() * 0.08,
      reverse: random.nextDouble() > 0.5,
      filled: random.nextDouble() < 0.3,
      rotationDegrees: random.nextDouble() * 360,
    );
  });
}

/// 20 particles, laid out from the seed alone (blueprint: useMemo
/// on seed).
List<FoliaGeometricParticle> foliaGeometricParticles(String seed) {
  final random = _SeededRandom(_fnv1a('particles:$seed'));
  return List.generate(20, (_) {
    return FoliaGeometricParticle(
      size: random.nextDouble() * 4 + 1,
      leftPercent: random.nextDouble() * 100,
      topPercent: random.nextDouble() * 100,
      opacity: random.nextDouble() * 0.3,
      durationMs: 15000 + (random.nextDouble() * 20000).round(),
      delayMs: (random.nextDouble() * 10000).round(),
    );
  });
}

/// The geometric layer: drifting shapes + rising particles. Repaints
/// at most ~10Hz on a timer (the drift is a pure function of
/// elapsed time) and picks up the latest audio bands at that same
/// cadence — no per-frame work.
class FoliaGeometricBackground extends StatefulWidget {
  const FoliaGeometricBackground({
    super.key,
    required this.seed,
    required this.analysis,
    required this.playingNow,
    required this.shapeColor,
    required this.particleColor,
  });

  final String seed;
  final Stream<AudioAnalysisFrame> analysis;
  final bool Function() playingNow;
  final Color shapeColor;
  final Color particleColor;

  @override
  State<FoliaGeometricBackground> createState() =>
      _FoliaGeometricBackgroundState();
}

class _FoliaGeometricBackgroundState
    extends State<FoliaGeometricBackground> {
  late List<FoliaGeometricShape> _shapes;
  late List<FoliaGeometricParticle> _particles;
  StreamSubscription<AudioAnalysisFrame>? _analysisSub;
  AudioBands _bands = const AudioBands.zero();
  Timer? _timer;
  int _elapsedMs = 0;

  @override
  void initState() {
    super.initState();
    _shapes = foliaGeometricShapes(widget.seed);
    _particles = foliaGeometricParticles(widget.seed);
    _analysisSub = widget.analysis.listen((frame) {
      _bands = frame.bands;
    });
    // ~10Hz repaint: the drift moves ~1px/s, so this is smooth
    // enough and keeps the layer cheap.
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      if (!widget.playingNow()) return;
      _elapsedMs += 100;
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(FoliaGeometricBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seed != widget.seed) {
      _shapes = foliaGeometricShapes(widget.seed);
      _particles = foliaGeometricParticles(widget.seed);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_analysisSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: FoliaGeometricPainter(
        shapes: _shapes,
        particles: _particles,
        elapsedMs: _elapsedMs,
        bands: _bands,
        shapeColor: widget.shapeColor,
        particleColor: widget.particleColor,
      ),
    );
  }
}

/// Draws the geometric shapes + particles. Pure functions of
/// (elapsedMs, bands): no allocations beyond the paths per paint.
class FoliaGeometricPainter extends CustomPainter {
  FoliaGeometricPainter({
    required this.shapes,
    required this.particles,
    required this.elapsedMs,
    required this.bands,
    required this.shapeColor,
    required this.particleColor,
  });

  final List<FoliaGeometricShape> shapes;
  final List<FoliaGeometricParticle> particles;
  final int elapsedMs;
  final AudioBands bands;
  final Color shapeColor;
  final Color particleColor;

  /// Audio-reactive scale: the blueprint maps its band value
  /// [10, 200] to [0.95, 1.45]; our bands are normalised 0–1, so
  /// the same span is 0.95 + band * 0.5. Circle reads bass, square
  /// low-mid, triangle mid, cross treble.
  @visibleForTesting
  static double shapeScaleFor(FoliaGeometricShapeType type, AudioBands b) {
    final band = switch (type) {
      FoliaGeometricShapeType.circle => b.bass,
      FoliaGeometricShapeType.square => b.lowMid,
      FoliaGeometricShapeType.triangle => b.mid,
      FoliaGeometricShapeType.cross => b.treble,
    };
    return 0.95 + band.clamp(0.0, 1.0) * 0.5;
  }

  /// Drift loop phase: (elapsed + delay) / duration, wrapped to
  /// [0, 1). The blueprint's CSS loop is linear with a delay that
  /// shows the loop's first frame, i.e. it starts partway through.
  double _phase(int durationMs, int delayMs) {
    final total = elapsedMs + delayMs;
    return (total % durationMs) / durationMs;
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final shape in shapes) {
      _paintShape(canvas, size, shape);
    }
    for (final particle in particles) {
      _paintParticle(canvas, size, particle);
    }
  }

  void _paintShape(Canvas canvas, Size size, FoliaGeometricShape shape) {
    final phase = _phase(shape.durationMs, shape.delayMs);
    final dir = shape.reverse ? -1.0 : 1.0;
    // Blueprint geometric-drift keyframes: 0% translate(-15, +30)
    // rotate(r); 50% translate(+15, -30) rotate(r+180); 100% back
    // to 0%. A triangle wave in both translation and rotation.
    final t = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
    final dx = (-15 + 30 * t) * dir;
    final dy = (30 - 60 * t) * dir;
    final rotation =
        (shape.rotationDegrees + 360 * phase) * math.pi / 180;
    final scale = shapeScaleFor(shape.type, bands);

    final cx = shape.xPercent / 100 * size.width + dx;
    final cy = shape.yPercent / 100 * size.height + dy;
    final half = shape.size / 2 * scale;

    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(rotation);
    final isCircleOrSquare =
        shape.type == FoliaGeometricShapeType.circle ||
        shape.type == FoliaGeometricShapeType.square;
    final stroked = isCircleOrSquare && !shape.filled;
    final paint = Paint()
      ..color = shapeColor.withValues(alpha: shape.opacity)
      ..style = stroked ? PaintingStyle.stroke : PaintingStyle.fill
      ..strokeWidth = 1;
    switch (shape.type) {
      case FoliaGeometricShapeType.circle:
        canvas.drawCircle(Offset.zero, half, paint);
      case FoliaGeometricShapeType.square:
        canvas.drawRect(Rect.fromCenter(
          center: Offset.zero,
          width: half * 2,
          height: half * 2,
        ), paint);
      case FoliaGeometricShapeType.triangle:
        canvas.drawPath(
          Path()
            ..moveTo(0, -half)
            ..lineTo(-half, half)
            ..lineTo(half, half)
            ..close(),
          paint,
        );
      case FoliaGeometricShapeType.cross:
        canvas.drawPath(_crossPath(half), paint);
    }
    canvas.restore();
  }

  Path _crossPath(double half) {
    // Blueprint cross clip-path, as fractions of the box:
    // polygon(20% 0%, 0% 20%, 30% 50%, 0% 80%, 20% 100%, 50% 70%,
    // 80% 100%, 100% 80%, 70% 50%, 100% 20%, 80% 0%, 50% 30%).
    const points = [
      (0.2, 0.0),
      (0.0, 0.2),
      (0.3, 0.5),
      (0.0, 0.8),
      (0.2, 1.0),
      (0.5, 0.7),
      (0.8, 1.0),
      (1.0, 0.8),
      (0.7, 0.5),
      (1.0, 0.2),
      (0.8, 0.0),
      (0.5, 0.3),
    ];
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = (points[i].$1 * 2 - 1) * half;
      final y = (points[i].$2 * 2 - 1) * half;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  void _paintParticle(
    Canvas canvas,
    Size size,
    FoliaGeometricParticle particle,
  ) {
    final phase = _phase(particle.durationMs, particle.delayMs);
    // Blueprint geometric-rise: 0% translateY(0) opacity 0;
    // 50% opacity peak; 100% translateY(-100px) opacity 0.
    final dy = -100 * phase;
    final opacity =
        particle.opacity * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
    if (opacity <= 0.001) return;
    final paint = Paint()
      ..color = particleColor.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(
        particle.leftPercent / 100 * size.width,
        particle.topPercent / 100 * size.height + dy,
      ),
      particle.size / 2,
      paint,
    );
  }

  @override
  bool shouldRepaint(FoliaGeometricPainter oldDelegate) {
    return oldDelegate.elapsedMs != elapsedMs ||
        oldDelegate.bands != bands ||
        !identical(oldDelegate.shapes, shapes) ||
        !identical(oldDelegate.particles, particles) ||
        oldDelegate.shapeColor != shapeColor ||
        oldDelegate.particleColor != particleColor;
  }
}

/// FNV-1a 32-bit hash (same as the storyboard compiler's seed).
int _fnv1a(String input) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < input.length; i++) {
    hash ^= input.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// Mulberry32: small deterministic PRNG for the seeded layout.
class _SeededRandom {
  _SeededRandom(int seed) : _state = seed & 0xFFFFFFFF;

  int _state;

  double nextDouble() {
    _state = (_state + 0x6D2B79F5) & 0xFFFFFFFF;
    var z = _state;
    z = ((z ^ (z >> 15)) * (z | 1)) & 0xFFFFFFFF;
    z ^= z + (((z ^ (z >> 7)) * (z | 61)) & 0xFFFFFFFF);
    return ((z ^ (z >> 14)) & 0xFFFFFFFF) / 4294967296.0;
  }
}

import 'dart:math' as math;

import '../player/lyric_parser.dart';
import 'folia_storyboard.dart';

/// Sonnet (商籁) motion math, ported from the Folia blueprint
/// (~/workspace/folia-sonnet-research/src/components/visualizer/sonnet).
/// Every function is a pure function of absolute playback time — no
/// state — so seeks and pauses evaluate exactly like continuous
/// playback (sonnetMotion.ts: "Pure absolute-time motion evaluation
/// keeps direct seeks identical to continuous playback").
///
/// Blueprint map (file: symbol):
///   sonnetMotion.ts — expoOut / cubic-bezier easings / shot path +
///     shot motion frames / breathing / gap drift / segment progress
///   sonnetProgram.ts — 7 shot kinds, max 4 lines / 6s per shot,
///     paragraph kinds, deterministic camera per shot
///   sonnetTypographyRoles.ts — hero / semi-hero scoring and roles
///   sonnetTypographyLayout.ts — per-kind hero/support font scales
///   sonnetTransitions.ts — fast-blur / mono-glitch / camera-pull
///   sonnetShotFrame.ts — per-glyph alpha/scale/offset, camera
///     focus tracking + smoothing, beat punch
///   sonnetBeatFx.ts — beat zoom 6%, tilt 0.6deg
///   sonnetCameraTracking.ts — focus interpolation, factor 0.5
///   sonnetTextViewBuilder.ts — glow blur, CA tints, ghost alphas
///
/// The 11 folium tunables (entry.tsx, all 0–3, identity 1) are NOT
/// ported: v1 runs at identity (defaults). No tuning UI in v1.

double sonnetClamp01(double value) => value.clamp(0, 1).toDouble();

double _cubicCoordinate(double p1, double p2, double t) {
  final inverse = 1 - t;
  return 3 * inverse * inverse * t * p1 +
      3 * inverse * t * t * p2 +
      t * t * t;
}

/// CSS-style cubic-bezier timing: solve the x curve, then sample y
/// (sonnetMotion.ts resolveCubicBezier, 12 bisection iterations).
double sonnetCubicBezier(
  double x1,
  double y1,
  double x2,
  double y2,
  double value,
) {
  final target = sonnetClamp01(value);
  if (target == 0 || target == 1) return target;
  var low = 0.0;
  var high = 1.0;
  var parameter = target;
  for (var i = 0; i < 12; i++) {
    final x = _cubicCoordinate(x1, x2, parameter);
    if (x < target) {
      low = parameter;
    } else {
      high = parameter;
    }
    parameter = (low + high) / 2;
  }
  return _cubicCoordinate(y1, y2, parameter);
}

double sonnetEaseInOut(double value) =>
    sonnetCubicBezier(0.65, 0, 0.35, 1, value);

double sonnetEaseEnter(double value) =>
    sonnetCubicBezier(0.22, 1, 0.36, 1, value);

/// High-tension PV easing for the per-word entrance
/// (sonnetMotion.ts easeSonnetExpoOut).
double sonnetExpoOut(double value) =>
    value == 1 ? 1 : (1 - math.pow(2, -10 * value)).toDouble();

/// Per-word entrance progress: ExpoOut over the word's own duration,
/// floored at 80ms (sonnetMotion.ts resolveSegmentProgress).
double sonnetSegmentProgress(int startMs, int endMs, int nowMs) =>
    sonnetExpoOut(
      sonnetClamp01(
        (nowMs - startMs) / math.max(endMs - startMs, 80),
      ),
    );

/// One word/segment of a line, with its own time window. Word-like
/// segments drive the hero scoring and the camera focus; spaces and
/// punctuation are not word-like.
class SonnetWord {
  const SonnetWord({
    required this.text,
    required this.startMs,
    required this.endMs,
    this.isWordLike = true,
  });

  final String text;
  final int startMs;
  final int endMs;
  final bool isWordLike;

  /// Visible length: non-space grapheme count
  /// (sonnetTypographyRoles.ts getSonnetVisibleSegmentLength).
  int get visibleLength =>
      text.runes.where((rune) => String.fromCharCode(rune).trim().isNotEmpty).length;

  double get durationSeconds => (endMs - startMs) / 1000;
}

/// Builds the effective word list for a line. With per-word
/// timestamps the line's own timings are used; without them the
/// line's sung duration (start → sweepEndMs, the same estimate the
/// KTV sweep uses) is split across segments by sweep weight, so the
/// timing math stays identical to the other lyric surfaces.
List<SonnetWord> sonnetWordsForLine(
  KaraokeLyricLine line, {
  required int limitMs,
}) {
  if (line.hasWordTiming) {
    return [
      for (final word in line.words)
        SonnetWord(
          text: word.text,
          startMs: word.startMs,
          endMs: word.endMs,
        ),
    ];
  }
  final text = line.text;
  if (text.isEmpty) return const [];
  final segments = lyricSweepSegments(text);
  final totalWeight = lyricSweepTotalWeight(segments);
  final endMs = sweepEndMs(
    startMs: line.startMs,
    totalWeight: totalWeight,
    limitMs: limitMs,
  );
  final durationMs = math.max(1, endMs - line.startMs);

  // Segment boundaries: one CJK grapheme per segment, Latin runs
  // split on spaces (spaces stay attached to the preceding word so
  // concatenating the segments reproduces the line exactly).
  final bounds = <(int, int)>[];
  var start = 0;
  var i = 0;
  final runes = text.runes.toList();
  while (i < runes.length) {
    final rune = runes[i];
    if (_isCjk(rune)) {
      if (start < i) bounds.add((start, i));
      bounds.add((i, i + 1));
      i++;
      start = i;
    } else if (rune == 0x20 || rune == 0x3000) {
      bounds.add((start, i + 1));
      i++;
      start = i;
    } else {
      i++;
    }
  }
  if (start < runes.length) bounds.add((start, runes.length));

  var weightOffset = 0.0;
  final words = <SonnetWord>[];
  for (final (from, to) in bounds) {
    var weight = 0.0;
    for (var r = from; r < to; r++) {
      weight += segments[r].weight;
    }
    final wordStart =
        line.startMs + (weightOffset / totalWeight * durationMs).round();
    weightOffset += weight;
    final wordEnd =
        line.startMs + (weightOffset / totalWeight * durationMs).round();
    final wordText = String.fromCharCodes(runes.sublist(from, to));
    words.add(
      SonnetWord(
        text: wordText,
        startMs: wordStart,
        endMs: math.max(wordEnd, wordStart + 1),
        isWordLike: wordText.trim().isNotEmpty,
      ),
    );
  }
  return words;
}

bool _isCjk(int rune) =>
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0x3040 && rune <= 0x30FF) ||
    (rune >= 0xAC00 && rune <= 0xD7A3);

/// Hero score: length (capped at 8 chars) × 14 + duration
/// (capped at 2.5s) × 18 (sonnetTypographyRoles.ts
/// scoreSonnetHeroSegment).
double sonnetHeroScore(SonnetWord word) =>
    math.min(word.visibleLength, 8) * 14 +
    math.min(2.5, math.max(0, word.durationSeconds)) * 18;

/// The hero (主角词): the highest-scoring word-like segment
/// (sonnetTypographyRoles.ts findSonnetHeroSegmentIndex).
int findSonnetHeroIndex(List<SonnetWord> words) {
  var bestIndex = words.indexWhere((word) => word.isWordLike);
  var bestScore = double.negativeInfinity;
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    if (!word.isWordLike || word.visibleLength == 0) continue;
    final score = sonnetHeroScore(word);
    if (score > bestScore) {
      bestScore = score;
      bestIndex = i;
    }
  }
  return math.max(0, bestIndex);
}

/// Secondary emphasis words (sonnetTypographyRoles.ts
/// findSonnetSemiHeroSegmentIndices): only lines with ≥4 word-like
/// segments earn them; candidates need ≥2 visible chars, ≥2 slots
/// away from the hero, and ≥35% of the hero's score; the pick goes
/// on the side opposite the hero's lean, with a second accent on
/// the other side for ≥9-word lines.
List<int> findSonnetSemiHeroIndices(
  List<SonnetWord> words,
  int heroIndex,
) {
  if (heroIndex < 0 || heroIndex >= words.length) return const [];
  final wordLikeCount = words
      .where((word) => word.isWordLike && word.visibleLength > 0)
      .length;
  if (wordLikeCount < 4) return const [];
  final heroScore = sonnetHeroScore(words[heroIndex]);
  final threshold = heroScore * 0.35;
  final candidates = <int>[];
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    if (i == heroIndex ||
        !word.isWordLike ||
        word.visibleLength < 2 ||
        (i - heroIndex).abs() < 2 ||
        sonnetHeroScore(word) < threshold) {
      continue;
    }
    candidates.add(i);
  }
  if (candidates.isEmpty) return const [];
  int bestOf(List<int> list) => list.reduce(
    (a, b) =>
        sonnetHeroScore(words[b]) > sonnetHeroScore(words[a]) ? b : a,
  );
  final heroLeansEarly = heroIndex <= (words.length - 1) / 2;
  final primarySide = candidates
      .where((i) => heroLeansEarly ? i > heroIndex : i < heroIndex)
      .toList();
  final secondarySide = candidates
      .where((i) => heroLeansEarly ? i < heroIndex : i > heroIndex)
      .toList();
  final picks = <int>[];
  final primary = primarySide.isNotEmpty
      ? bestOf(primarySide)
      : bestOf(secondarySide);
  picks.add(primary);
  if (wordLikeCount >= 9) {
    final secondary = secondarySide
        .where((i) => (i - primary).abs() >= 2)
        .toList();
    if (secondary.isNotEmpty) picks.add(bestOf(secondary));
  }
  picks.sort();
  return picks;
}

enum SonnetRole { hero, semiHero, support, decoration }

/// Per-kind hero / support font scales, from the typography layout
/// table (sonnetTypographyLayout.ts). The editorial variant is
/// deterministic per shot: (sum of trimmed segment lengths +
/// segment count) % 5.
({double hero, double support}) sonnetFontScales(
  FoliaShotKind kind, {
  int editorialVariant = 0,
}) {
  switch (kind) {
    case FoliaShotKind.editorial:
      if (editorialVariant == 3) return (hero: 3.8, support: 1.3);
      if (editorialVariant == 4) return (hero: 4.2, support: 1.25);
      if (editorialVariant == 2) return (hero: 3.2, support: 1.2);
      return (hero: 4.0, support: 1.2);
    case FoliaShotKind.impact:
      return (hero: 5.5, support: 1.5);
    case FoliaShotKind.collage:
      return (hero: 3.2, support: 1.35);
    case FoliaShotKind.ribbon:
      return (hero: 3.5, support: 1.5);
    case FoliaShotKind.reveal:
      return (hero: 4.5, support: 1.6);
    case FoliaShotKind.poster:
      return (hero: 4.4, support: 1.15);
    case FoliaShotKind.tableau:
      return (hero: 3.0, support: 1.15);
  }
}

/// Semi-hero scale: max(support × 1.35, hero × 0.72)
/// (sonnetTypographyLayout.ts).
double sonnetSemiHeroScale(double heroScale, double supportScale) =>
    math.max(supportScale * 1.35, heroScale * 0.72);

/// One shot's camera motion frame: fractions of the stage size for
/// x/y, a scale around 1, and a rotation in radians
/// (sonnetMotion.ts resolveShotMotionFrame). Blueprint shot kinds
/// map: editorial→editorial-column, impact→type-impact,
/// collage→fragment-collage, ribbon→tracking-ribbon,
/// reveal→mask-reveal, poster→poster-blocks, tableau→quiet-tableau.
class SonnetCameraFrame {
  const SonnetCameraFrame({
    required this.x,
    required this.y,
    required this.scale,
    required this.rotation,
  });

  final double x;
  final double y;
  final double scale;
  final double rotation;
}

/// Shot path progress: ExpoOut fast entry, near-constant drift in
/// the middle (speed never 0), soft settle into the transition
/// (sonnetMotion.ts resolveShotPathProgress). Ribbon / collage /
/// tableau / poster blend a constant-velocity drift into the
/// in-out curve instead.
double sonnetShotPathProgress(FoliaShotKind kind, double progress) {
  final linear = sonnetClamp01(progress);
  if (kind == FoliaShotKind.ribbon ||
      kind == FoliaShotKind.collage ||
      kind == FoliaShotKind.tableau ||
      kind == FoliaShotKind.poster) {
    return linear * 0.55 + sonnetEaseInOut(linear) * 0.45;
  }
  if (linear < 0.18) return sonnetExpoOut(linear / 0.18) * 0.22;
  if (linear < 0.78) return 0.22 + ((linear - 0.18) / 0.6) * 0.56;
  final settle = (linear - 0.78) / 0.22;
  return 0.78 + (1 - (1 - settle) * (1 - settle)) * 0.22;
}

SonnetCameraFrame resolveSonnetShotMotionFrame(
  FoliaShotKind kind,
  double progress,
) {
  final linear = sonnetClamp01(progress);
  final eased = sonnetShotPathProgress(kind, linear);
  switch (kind) {
    case FoliaShotKind.editorial:
      return SonnetCameraFrame(
        x: -0.055 + eased * 0.095,
        y: 0.025 - eased * 0.04,
        scale: 0.98 + eased * 0.07,
        rotation: -0.006 + eased * 0.01,
      );
    case FoliaShotKind.impact:
      return SonnetCameraFrame(
        x: -0.035 + eased * 0.07,
        y: 0.018 - eased * 0.028,
        scale:
            1 +
            (1 - sonnetExpoOut(math.min(linear / 0.18, 1))) * 0.22 +
            eased * 0.08,
        rotation: -0.01 + eased * 0.016,
      );
    case FoliaShotKind.collage:
      return SonnetCameraFrame(
        x: -0.045 + eased * 0.085,
        y: 0.028 - math.sin(eased * math.pi) * 0.055,
        scale: 0.97 + eased * 0.09,
        rotation: -0.014 + eased * 0.028,
      );
    case FoliaShotKind.ribbon:
      return SonnetCameraFrame(
        x: -0.16 + eased * 0.28,
        y: 0.05 - eased * 0.085,
        scale: 0.98 + eased * 0.07,
        rotation: 0.008 - eased * 0.014,
      );
    case FoliaShotKind.reveal:
      return SonnetCameraFrame(
        x: 0.035 - eased * 0.065,
        y: 0.1 - eased * 0.135,
        scale: 0.96 + eased * 0.12,
        rotation: -0.006 + eased * 0.009,
      );
    case FoliaShotKind.poster:
      return SonnetCameraFrame(
        x: -0.012 + eased * 0.024,
        y: 0.008 - eased * 0.016,
        scale: 0.99 + eased * 0.025,
        rotation: -0.0015 + eased * 0.003,
      );
    case FoliaShotKind.tableau:
      return SonnetCameraFrame(
        x: -0.022 + eased * 0.04,
        y: 0.014 - eased * 0.025,
        scale: 1 + eased * 0.028,
        rotation: -0.002 + eased * 0.003,
      );
  }
}

/// Deterministic hand-held breathing float: layered incommensurate
/// sines, evaluated on absolute time (sonnetMotion.ts
/// resolveSonnetCameraBreath). Caps: offset 0.006, scale 0.002,
/// rotation 0.0015.
SonnetCameraFrame resolveSonnetCameraBreath(
  double timeSeconds, [
  double phase = 0,
]) {
  final tau = timeSeconds * math.pi * 2;
  return SonnetCameraFrame(
    x:
        (math.sin(tau * 0.13 + phase) * 0.65 +
                math.sin(tau * 0.31 + phase * 1.7) * 0.35) *
            0.006,
    y:
        (math.cos(tau * 0.11 + phase * 2.3) * 0.65 +
                math.sin(tau * 0.29 + phase * 0.9) * 0.35) *
            0.006,
    scale: math.sin(tau * 0.09 + phase * 1.3) * 0.002,
    rotation: math.sin(tau * 0.07 + phase * 2.9) * 0.0015,
  );
}

/// Ramps the breathing float in over 1.2s after the lyric reveal
/// completes (sonnetMotion.ts resolveSonnetBreathWeight).
double resolveSonnetBreathWeight(
  double timeSeconds,
  double revealDoneSeconds,
) =>
    sonnetEaseInOut(
      sonnetClamp01((timeSeconds - revealDoneSeconds) / 1.2),
    );

/// Gap drift: after a shot ends, the camera keeps drifting in the
/// direction the shot's tail was moving (sonnetShotFrame.ts).
/// [gapSeconds] is time since the shot ended; returns the extra
/// frame offset to add to the end-of-shot frame.
SonnetCameraFrame sonnetGapDrift(
  SonnetCameraFrame endFrame,
  FoliaShotKind kind,
  double gapSeconds,
) {
  final tailStart = resolveSonnetShotMotionFrame(kind, 0.8);
  final speed = (1 - math.exp(-gapSeconds * 0.4)) * 2.0;
  return SonnetCameraFrame(
    x: (endFrame.x - tailStart.x) * speed,
    y: (endFrame.y - tailStart.y) * speed,
    scale: (endFrame.scale - tailStart.scale) * speed,
    rotation: (endFrame.rotation - tailStart.rotation) * speed,
  );
}

/// Beat punch (sonnetBeatFx.ts SONNET_BEAT_FX): zoom +6% of the
/// beat envelope, tilt 0.6deg alternating per beat.
double sonnetBeatZoom(double beatImpact) => 1 + 0.06 * beatImpact;

double sonnetBeatRotation(double beatImpact, int beatIndex) =>
    0.6 * math.pi / 180 * beatImpact * (beatIndex.isEven ? 1 : -1);

/// Camera intensity: the default tuning value, also the safe cap
/// (types.ts SONNET_CAMERA_INTENSITY_MAX = 0.7).
const double kSonnetCameraIntensity = 0.7;

/// Per-glyph frame (sonnetShotFrame.ts): glyphs start at 0.16 alpha
/// and rise to 1.0 with the ExpoOut entrance; the halo (glow)
/// starts at 1.0 and settles to 0.72. Emphasis glyphs in a
/// type-impact shot enter from a deeper scale (0.52 → 1.0);
/// everything else enters 0.86 → 1.0.
class SonnetGlyphFrame {
  const SonnetGlyphFrame({
    required this.alpha,
    required this.haloAlpha,
    required this.scale,
    required this.offsetFactor,
  });

  /// Core glyph alpha; 0 while waiting for its start time.
  final double alpha;

  /// Halo/glow alpha; 0 while waiting.
  final double haloAlpha;

  /// Glyph scale factor.
  final double scale;

  /// Entrance offset factor (1 - progress): multiply the enter
  /// offset and entry rotation by this.
  final double offsetFactor;
}

SonnetGlyphFrame resolveSonnetGlyphFrame({
  required int startMs,
  required int settleMs,
  required int nowMs,
  required bool isEmphasis,
  required FoliaShotKind shotKind,
}) {
  final waiting = nowMs < startMs;
  final progress = sonnetSegmentProgress(startMs, settleMs, nowMs);
  final scale = isEmphasis && shotKind == FoliaShotKind.impact
      ? 0.52 + progress * 0.48
      : 0.86 + progress * 0.14;
  return SonnetGlyphFrame(
    alpha: waiting ? 0 : 0.16 + progress * 0.84,
    haloAlpha: waiting ? 0 : 1 - progress * 0.28,
    scale: scale,
    offsetFactor: 1 - progress,
  );
}

/// Glow blur: max(12, fontSize × 0.18)
/// (sonnetTextViewBuilder.ts).
double sonnetGlowBlur(double fontSize) => math.max(12, fontSize * 0.18);

/// Chromatic aberration copy tints (sonnetTextViewBuilder.ts):
/// cyan 0x00ffff, red 0xff0044, alpha 0.8 for the hero, 0.5 else.
const int kSonnetCaCyan = 0xFF00FFFF;
const int kSonnetCaRed = 0xFFFF0044;

/// Semi-hero echo ghosts: hollow stroke-only copies, spread
/// fontSize × 0.85 along the layout normal, peak alphas 0.3 / 0.16
/// (sonnetTextViewBuilder.ts).
const double kSonnetGhostSpreadFactor = 0.85;
const List<double> kSonnetGhostAlphas = [0.3, 0.16];

/// Shot-boundary transition kinds (types.ts
/// SONNET_TRANSITION_KINDS).
enum SonnetTransitionKind { fastBlur, monoGlitch, cameraPull }

/// One transition frame: alpha / blur / glitch amounts
/// (sonnetTransitions.ts). v1 only renders [cameraPull] (pure
/// alpha fade — no filter, no saveLayer); fast-blur and mono-glitch
/// resolve here so the timing is right when their rendering lands.
class SonnetTransitionFrame {
  const SonnetTransitionFrame({
    required this.alpha,
    required this.blur,
    required this.glitch,
    required this.glitchSeed,
  });

  final double alpha;
  final double blur;
  final double glitch;
  final double glitchSeed;
}

const SonnetTransitionFrame kSonnetIdleTransitionFrame =
    SonnetTransitionFrame(alpha: 1, blur: 0, glitch: 0, glitchSeed: 0);

SonnetTransitionFrame resolveSonnetTransitionFrame(
  SonnetTransitionKind kind,
  String phase,
  double progress,
  int seed,
) {
  final linear = sonnetClamp01(progress);
  final eased = sonnetEaseInOut(linear);
  final amount = phase == 'exit' ? eased : 1 - eased;
  switch (kind) {
    case SonnetTransitionKind.fastBlur:
      return SonnetTransitionFrame(
        alpha: phase == 'exit' ? 1 - amount : 1 - amount * 0.82,
        blur: amount * 14,
        glitch: 0,
        glitchSeed: 0,
      );
    case SonnetTransitionKind.monoGlitch:
      final step = (linear * 14).floor();
      return SonnetTransitionFrame(
        alpha: phase == 'exit' && linear > 0.86
            ? 1 - (linear - 0.86) / 0.14
            : 1,
        blur: 0,
        glitch: amount,
        glitchSeed: seed * 0.0001 + step * 0.173,
      );
    case SonnetTransitionKind.cameraPull:
      return SonnetTransitionFrame(
        alpha: phase == 'exit' ? 1 - amount : 1 - amount * 0.72,
        blur: 0,
        glitch: 0,
        glitchSeed: 0,
      );
  }
}

/// Deterministic boundary kind from the shot seed
/// (sonnetTransitions.ts resolveBoundaryKind: seed mixed with
/// (index+1) × 0x9e3779b1, mod 3).
SonnetTransitionKind sonnetBoundaryKind(int seed, int boundaryIndex) {
  final mixed = (seed ^ ((boundaryIndex + 1) * 0x9e3779b1)) & 0xFFFFFFFF;
  return SonnetTransitionKind.values[mixed % 3];
}

/// Shot-boundary transition window: 0.14–0.24s
/// (sonnetTransitions.ts resolveSonnetShotTransitionFrame).
double sonnetTransitionDurationSeconds(int gapMs) =>
    math.min(0.24, math.max(0.14, gapMs * 0.18 / 1000));

/// Gaussian focus weights over the tracked segments' time ranges
/// (sonnetMotion.ts resolveSonnetFocusWeights, sigma 0.35s).
List<double> resolveSonnetFocusWeights(
  List<(int startMs, int endMs)> ranges,
  int nowMs,
) {
  if (ranges.isEmpty) return const [];
  const sigma = 0.35;
  final logWeights = ranges.map((range) {
    final start = math.min(range.$1, range.$2);
    final end = math.max(range.$1, range.$2);
    final distanceSeconds = nowMs < start
        ? (start - nowMs) / 1000
        : nowMs > end
        ? (nowMs - end) / 1000
        : 0.0;
    return -(distanceSeconds * distanceSeconds) / (2 * sigma * sigma);
  }).toList();
  final maxLog = logWeights.reduce(math.max);
  final weights = logWeights.map((w) => math.exp(w - maxLog)).toList();
  final total = weights.fold(0.0, (a, b) => a + b);
  return weights.map((w) => w / total).toList();
}

/// Camera focus interpolation between two glyph centers, pulled
/// 50% toward the segment centroid (sonnetCameraTracking.ts
/// resolveSonnetSegmentCameraFocus, trackingFactor 0.5).
({double x, double y}) sonnetCameraFocus(
  List<({double x, double y, int startMs})> glyphs,
  int nowMs,
) {
  if (glyphs.isEmpty) return (x: 0, y: 0);
  final first = glyphs.first;
  final last = glyphs.last;
  final centerX = (first.x + last.x) / 2;
  final centerY = (first.y + last.y) / 2;
  ({double x, double y}) apply(double exactX, double exactY) => (
    x: centerX + (exactX - centerX) * 0.5,
    y: centerY + (exactY - centerY) * 0.5,
  );
  if (nowMs <= first.startMs) return apply(first.x, first.y);
  if (nowMs >= last.startMs) return apply(last.x, last.y);
  for (var i = 0; i < glyphs.length - 1; i++) {
    final current = glyphs[i];
    final next = glyphs[i + 1];
    if (nowMs < current.startMs || nowMs > next.startMs) continue;
    final progress =
        (nowMs - current.startMs) /
        math.max(1, next.startMs - current.startMs);
    return apply(
      current.x + (next.x - current.x) * progress,
      current.y + (next.y - current.y) * progress,
    );
  }
  return apply(first.x, first.y);
}

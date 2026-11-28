import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'audio_analysis.dart';
import 'folia_stage_registry.dart';
import 'folia_storyboard.dart';
import 'folia_theme.dart';
import 'sonnet_motion.dart';

/// Sonnet (商籁) stage: the deterministic Japanese MG lyric-PV
/// director, ported from the Folia blueprint
/// (src/components/visualizer/sonnet). All motion is a pure
/// function of absolute playback time: the storyboard is precompiled
/// once per song, and every frame re-evaluates from the clock, so
/// seeks and pauses are exact.
///
/// Blueprint-faithful pieces (verified in source):
///   - 7 shot kinds with their own camera path tables
///     (sonnetMotion.ts resolveShotMotionFrame) and per-kind
///     hero/support font scales (sonnetTypographyLayout.ts)
///   - hero = highest-scoring word-like segment
///     (length × 14 + duration × 18), semi-heroes per the
///     opposite-side rule (sonnetTypographyRoles.ts)
///   - editorial-column variant 3 layout: two offset lines,
///     left-to-right, enterX +30 / -30, hero enterY +15% of the
///     stage height (sonnetShotFlowLayouts.ts)
///   - per-glyph entrance: ExpoOut, core alpha 0.16 → 1.0, halo
///     1.0 → 0.72, scale 0.86 → 1.0 (0.52 → 1.0 for emphasis in
///     type-impact), entry rotation ±0.055 / ±0.035 rad
///     (sonnetShotFrame.ts, sonnetGlyphLayout.ts)
///   - camera focus tracking the sung word with factor 0.5 and
///     5-sample smoothing (sonnetCameraTracking.ts, sonnetMotion.ts)
///   - breathing float after the reveal, gap drift after a shot
///     ends (sonnetShotFrame.ts)
///   - beat punch: zoom +6% of the beat envelope, tilt 0.6deg
///     alternating (sonnetBeatFx.ts)
///   - glow blur max(12, fontSize × 0.18); CA cyan 0x00ffff /
///     red 0xff0044, alpha 0.8 hero / 0.5 else; semi-hero echo
///     ghosts, hollow, spread fontSize × 0.85, alphas 0.3 / 0.16
///     (sonnetTextViewBuilder.ts)
///
/// Deliberately v1-scoped (see the report for the full list):
/// layout is editorial variant 3 for every shot kind; shot
/// boundaries fade (camera-pull) only — fast-blur / mono-glitch
/// are not rendered; the 11 folium tunables run at identity; no
/// MG decorations, guides, or outer frame. The style draws the
/// lyric layer only, on a transparent background.
///
/// Performance: no new per-frame saveLayer. Word alpha runs
/// through the text color, glow through TextStyle shadows, CA and
/// ghosts are plain positioned texts. Layout is measured once per
/// shot and cached; per frame only progress/alpha/transforms are
/// re-evaluated.
class SonnetStageWidget extends StatefulWidget {
  const SonnetStageWidget({super.key, required this.stage});

  final FoliaStageContext stage;

  @override
  State<SonnetStageWidget> createState() => _SonnetStageWidgetState();
}

class _SonnetStageWidgetState extends State<SonnetStageWidget>
    with SingleTickerProviderStateMixin {
  static const FoliaStoryboardCompiler _compiler =
      FoliaStoryboardCompiler();

  FoliaProgram? _program;
  String _programKey = '';
  late final Ticker _ticker;
  StreamSubscription<AudioAnalysisFrame>? _analysisSub;
  AudioAnalysisFrame? _latestAnalysis;
  int _beatIndex = 0;

  // Interpolated clock: the controller position only ticks a few
  // times a second, so between ticks the wall clock carries the
  // time forward; any jump in the controller position (seek or a
  // fresh tick) re-anchors. Pauses freeze the anchor.
  int _anchorMs = 0;
  int _anchorWallMs = 0;
  int _lastRawMs = -1;

  // Layout cache, keyed by shot start/end ms. Cleared on recompile.
  final Map<String, _ShotLayout> _layoutCache = {};

  @override
  void initState() {
    super.initState();
    _compile();
    _ticker = createTicker((_) {
      if (mounted) setState(() {});
    });
    _ticker.start();
    _analysisSub = widget.stage.analysis.listen((frame) {
      _latestAnalysis = frame;
      if (frame.beat) _beatIndex++;
    });
  }

  @override
  void didUpdateWidget(SonnetStageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stage.songId != widget.stage.songId ||
        !identical(oldWidget.stage.lyrics, widget.stage.lyrics)) {
      _compile();
    }
  }

  void _compile() {
    final key = '${widget.stage.songId}:${widget.stage.lyrics.lines.length}';
    if (key == _programKey && _program != null) return;
    _programKey = key;
    _program = _compiler.compile(widget.stage.lyrics, widget.stage.songId);
    _layoutCache.clear();
  }

  @override
  void dispose() {
    _ticker.dispose();
    unawaited(_analysisSub?.cancel());
    super.dispose();
  }

  int _effectiveNowMs() {
    final raw = widget.stage.positionNow().inMilliseconds;
    final wall = DateTime.now().millisecondsSinceEpoch;
    if (raw != _lastRawMs) {
      _anchorMs = raw;
      _anchorWallMs = wall;
      _lastRawMs = raw;
    }
    if (!widget.stage.playingNow()) return _anchorMs;
    return _anchorMs + (wall - _anchorWallMs);
  }

  FoliaShot? _activeShot(int nowMs) {
    final shots = _program?.shots ?? const <FoliaShot>[];
    for (final shot in shots) {
      if (nowMs >= shot.startMs && nowMs < shot.endMs) return shot;
    }
    FoliaShot? last;
    for (final shot in shots) {
      if (nowMs >= shot.endMs) {
        last = shot;
      } else {
        break;
      }
    }
    return last ?? shots.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final program = _program;
    if (program == null || program.isEmpty) {
      return const SizedBox.expand();
    }
    final nowMs = _effectiveNowMs();
    final shot = _activeShot(nowMs);
    if (shot == null) return const SizedBox.expand();
    final theme = widget.stage.theme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.width <= 0 || size.height <= 0) {
          return const SizedBox.expand();
        }
        final layout = _layoutFor(shot, size);
        final frame = _cameraFrame(shot, layout, nowMs, size);
        final transitionAlpha = _transitionAlpha(shot, nowMs);
        final content = Transform(
          transform: frame.matrix,
          child: Stack(
            children: [
              for (final placement in layout.placements)
                _wordWidget(placement, layout, nowMs, theme),
            ],
          ),
        );
        if (transitionAlpha >= 1) return content;
        return Opacity(opacity: transitionAlpha, child: content);
      },
    );
  }

  _ShotLayout _layoutFor(FoliaShot shot, Size size) {
    final key = '${shot.startMs}-${shot.endMs}';
    final cached = _layoutCache[key];
    if (cached != null && cached.size == size) return cached;
    final layout = _computeLayout(shot, size);
    _layoutCache[key] = layout;
    return layout;
  }

  _ShotLayout _computeLayout(FoliaShot shot, Size size) {
    final lines = [
      for (final index in shot.lineIndices) widget.stage.lyrics.lines[index],
    ];
    // Flatten the shot's lines into one word flow, in timeline
    // order — the blueprint lays out a whole shot at once
    // (sonnetTypographyLayout.ts: segments = lines.flat()).
    final words = <_FlowWord>[];
    for (var li = 0; li < lines.length; li++) {
      final line = lines[li];
      final nextStart = li + 1 < lines.length
          ? lines[li + 1].startMs
          : line.endMs;
      for (final word in sonnetWordsForLine(line, limitMs: nextStart)) {
        words.add(_FlowWord(word: word, lineIndex: li));
      }
    }
    final wordLikes = [
      for (var i = 0; i < words.length; i++)
        if (words[i].word.isWordLike) i,
    ];
    final heroIndex = wordLikes.isEmpty
        ? -1
        : findSonnetHeroIndex([
            for (final i in wordLikes) words[i].word,
          ]).let((local) => wordLikes[local]);
    // Semi-heroes are picked per line (blueprint); the global hero
    // is excluded from them.
    final semiHeroes = <int>{};
    for (var li = 0; li < lines.length; li++) {
      final lineWords = [
        for (var i = 0; i < words.length; i++)
          if (words[i].lineIndex == li) words[i].word,
      ];
      final localHero = findSonnetHeroIndex(lineWords);
      final localSemi = findSonnetSemiHeroIndices(lineWords, localHero);
      var offset = 0;
      for (var i = 0; i < words.length; i++) {
        if (words[i].lineIndex == li) break;
        offset++;
      }
      for (final local in localSemi) {
        final global = offset + local;
        if (global != heroIndex) semiHeroes.add(global);
      }
    }

    final scales = sonnetFontScales(shot.kind, editorialVariant: 3);
    final baseFontSize = size.height * 0.052;
    final flowGap = (baseFontSize * 0.35).clamp(16, 40).toDouble();
    final stackGap = math.max(24, flowGap * 1.35);

    // Measure with a global fit loop: shrink all sizes together
    // until the composition fits 82% of the stage
    // (sonnetTypographyLayout.ts placeWithGlobalFit).
    var fitScale = 1.0;
    List<_WordPlacement> placements = const [];
    for (var attempt = 0; attempt < 4; attempt++) {
      placements = _placeWords(
        words: words,
        heroIndex: heroIndex,
        semiHeroes: semiHeroes,
        scales: scales,
        baseFontSize: baseFontSize * fitScale,
        flowGap: flowGap * fitScale,
        stackGap: stackGap * fitScale,
        size: size,
      );
      final bounds = _boundsOf(placements);
      final scaleX = (size.width * 0.82) / math.max(1, bounds.width);
      final scaleY = (size.height * 0.82) / math.max(1, bounds.height);
      final needed = math.min(scaleX, scaleY);
      if (needed >= 1) break;
      fitScale *= needed;
    }
    return _ShotLayout(
      size: size,
      shot: shot,
      placements: placements,
      heroIndex: heroIndex,
      baseFontSize: baseFontSize * fitScale,
    );
  }

  List<_WordPlacement> _placeWords({
    required List<_FlowWord> words,
    required int heroIndex,
    required Set<int> semiHeroes,
    required ({double hero, double support}) scales,
    required double baseFontSize,
    required double flowGap,
    required double stackGap,
    required Size size,
  }) {
    // Measure every word at its role size.
    final measured = <_MeasuredWord>[];
    for (var i = 0; i < words.length; i++) {
      final word = words[i].word;
      final flowIndex = i;
      final role = i == heroIndex
          ? SonnetRole.hero
          : semiHeroes.contains(i)
          ? SonnetRole.semiHero
          : SonnetRole.support;
      final fontScale = role == SonnetRole.hero
          ? scales.hero
          : role == SonnetRole.semiHero
          ? sonnetSemiHeroScale(scales.hero, scales.support)
          : scales.support;
      final fontSize = baseFontSize * fontScale;
      final weight = role == SonnetRole.support
          ? FontWeight.w700
          : FontWeight.w900;
      final textSize = _measureText(word.text, fontSize, weight);
      measured.add(
        _MeasuredWord(
          word: word,
          role: role,
          flowIndex: flowIndex,
          fontSize: fontSize,
          weight: weight,
          width: textSize.width,
          height: textSize.height,
        ),
      );
    }
    if (measured.isEmpty) return const [];
    // Editorial variant 3: two offset lines, left-to-right in
    // timeline order; line 1 holds words up to and including the
    // hero, line 2 the rest (sonnetShotFlowLayouts.ts).
    final split = heroIndex < 0 ? measured.length : heroIndex + 1;
    final line1 = measured.sublist(0, split);
    final line2 = measured.sublist(split);
    double lineWidth(List<_MeasuredWord> line) =>
        line.fold(0.0, (sum, item) => sum + item.width) +
        flowGap * math.max(0, line.length - 1);
    double lineHeight(List<_MeasuredWord> line) => line.fold(
      0.0,
      (max, item) => math.max(max, item.height),
    );
    final width1 = lineWidth(line1);
    final width2 = lineWidth(line2);
    final height1 = lineHeight(line1);
    final height2 = lineHeight(line2);
    final totalHeight =
        height1 + (line2.isEmpty ? 0 : stackGap + height2);
    var line1Y = -totalHeight / 2 + height1 / 2;
    var line2Y = line1Y + height1 / 2 + stackGap + height2 / 2;
    // Staggered-stairs offset between the two lines.
    final offsetAmount = math.max(width1, width2) * 0.12;

    final placements = <_WordPlacement>[];
    void layLine(
      List<_MeasuredWord> line,
      double lineY,
      double xShift,
      double enterX,
    ) {
      if (line.isEmpty) return;
      var currentX = -lineWidth(line) / 2 + xShift;
      for (final item in line) {
        placements.add(
          _WordPlacement(
            word: item.word,
            role: item.role,
            flowIndex: item.flowIndex,
            fontSize: item.fontSize,
            weight: item.weight,
            x: size.width / 2 + currentX,
            y: size.height / 2 + lineY - item.height / 2,
            width: item.width,
            height: item.height,
            enterX: enterX,
            enterY: item.role == SonnetRole.hero ? size.height * 0.15 : 0,
            entryRotation:
                ((item.flowIndex.isEven ? 1 : -1) *
                    (item.role == SonnetRole.support ? 0.035 : 0.055)),
          ),
        );
        currentX += item.width + flowGap;
      }
    }

    layLine(line1, line1Y, -offsetAmount, 30);
    layLine(line2, line2Y, offsetAmount, -30);
    return placements;
  }

  Size _measureText(String text, double fontSize, FontWeight weight) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.size;
  }

  ({double left, double top, double width, double height}) _boundsOf(
    List<_WordPlacement> placements,
  ) {
    if (placements.isEmpty) {
      return (left: 0, top: 0, width: 0, height: 0);
    }
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (final placement in placements) {
      left = math.min(left, placement.x);
      top = math.min(top, placement.y);
      right = math.max(right, placement.x + placement.width);
      bottom = math.max(bottom, placement.y + placement.height);
    }
    return (
      left: left,
      top: top,
      width: right - left,
      height: bottom - top,
    );
  }

  ({double x, double y}) _focusAt(
    _ShotLayout layout,
    int nowMs,
  ) {
    final glyphs = [
      for (final placement in layout.placements)
        if (placement.word.isWordLike)
          (
            x: placement.x + placement.width / 2,
            y: placement.y + placement.height / 2,
            startMs: placement.word.startMs,
          ),
    ];
    if (glyphs.isEmpty) {
      return (x: layout.size.width / 2, y: layout.size.height / 2);
    }
    // 5-sample edge-preserving smoothing over a ±0.12s window,
    // weights 1/4/6/4/1; samples further than 96px from the
    // center are dropped so intentional jumps stay jumps
    // (sonnetMotion.ts resolveSonnetSmoothedCameraFocus).
    const offsets = [-0.12, -0.06, 0.0, 0.06, 0.12];
    const weights = [1.0, 4.0, 6.0, 4.0, 1.0];
    final center = sonnetCameraFocus(glyphs, nowMs);
    var x = 0.0;
    var y = 0.0;
    var totalWeight = 0.0;
    for (var i = 0; i < offsets.length; i++) {
      final sample = sonnetCameraFocus(
        glyphs,
        nowMs + (offsets[i] * 1000).round(),
      );
      final distanceSquared =
          (sample.x - center.x) * (sample.x - center.x) +
          (sample.y - center.y) * (sample.y - center.y);
      if (distanceSquared > 96 * 96) continue;
      x += sample.x * weights[i];
      y += sample.y * weights[i];
      totalWeight += weights[i];
    }
    if (totalWeight <= 0) return center;
    return (x: x / totalWeight, y: y / totalWeight);
  }

  _CameraEvaluation _cameraFrame(
    FoliaShot shot,
    _ShotLayout layout,
    int nowMs,
    Size size,
  ) {
    final progress = sonnetClamp01(
      (nowMs - shot.startMs) / math.max(shot.endMs - shot.startMs, 1),
    );
    final eased = sonnetShotPathProgress(shot.kind, progress);
    var frame = resolveSonnetShotMotionFrame(shot.kind, progress);
    // Gap drift after the shot ends (sonnetShotFrame.ts).
    final gapMs = nowMs - shot.endMs;
    if (gapMs > 0) {
      final drift = sonnetGapDrift(frame, shot.kind, gapMs / 1000);
      frame = SonnetCameraFrame(
        x: frame.x + drift.x,
        y: frame.y + drift.y,
        scale: frame.scale + drift.scale,
        rotation: frame.rotation + drift.rotation,
      );
    }
    // Breathing float, ramped in once the reveal completes.
    final revealDoneMs = layout.placements
        .map((p) => p.word.startMs)
        .fold(shot.startMs, math.max);
    final breathWeight = resolveSonnetBreathWeight(
      nowMs / 1000,
      revealDoneMs / 1000,
    );
    var breath = const SonnetCameraFrame(x: 0, y: 0, scale: 0, rotation: 0);
    if (breathWeight > 0) {
      breath = resolveSonnetCameraBreath(
        nowMs / 1000,
        _phaseFor(shot),
      );
    }
    final intensity = kSonnetCameraIntensity;
    final dx = (frame.x + breath.x * breathWeight) * intensity * size.width;
    final dy =
        (frame.y + breath.y * breathWeight) * intensity * size.height;
    // Foundation camera zoom (slow push-in over the shot) composed
    // with the blueprint motion frame's relative scale.
    final foundationZoom =
        shot.camera.startScale +
        (shot.camera.endScale - shot.camera.startScale) * eased;
    final impact = _latestAnalysis?.beatImpact ?? 0;
    final zoom =
        foundationZoom *
        (1 + (frame.scale - 1 + breath.scale * breathWeight) * intensity) *
        sonnetBeatZoom(impact);
    final rotation =
        frame.rotation * intensity +
        breath.rotation * breathWeight * intensity +
        sonnetBeatRotation(impact, _beatIndex);
    final focus = _focusAt(layout, nowMs);
    final matrix = Matrix4.identity()
      ..translateByDouble(focus.x + dx, focus.y + dy, 0, 1)
      ..scaleByDouble(zoom, zoom, 1, 1)
      ..rotateZ(rotation)
      ..translateByDouble(-focus.x, -focus.y, 0, 1);
    return _CameraEvaluation(matrix: matrix);
  }

  double _phaseFor(FoliaShot shot) {
    var hash = 0x811c9dc5;
    final id = '${shot.startMs}-${shot.endMs}';
    for (final unit in id.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return (hash % 1024) / 1024 * math.pi * 2;
  }

  double _transitionAlpha(FoliaShot shot, int nowMs) {
    final program = _program;
    if (program == null) return 1;
    final shots = program.shots;
    final index = shots.indexOf(shot);
    if (index < 0) return 1;
    // Enter: first 0.14–0.24s of the shot (camera-pull fade).
    if (index > 0) {
      final previous = shots[index - 1];
      final duration = sonnetTransitionDurationSeconds(
        shot.startMs - previous.startMs,
      );
      final elapsed = (nowMs - shot.startMs) / 1000;
      if (elapsed >= 0 && elapsed <= duration) {
        return resolveSonnetTransitionFrame(
          SonnetTransitionKind.cameraPull,
          'enter',
          elapsed / duration,
          shot.startMs,
        ).alpha;
      }
    }
    // Exit: last 0.14–0.24s before the next shot.
    if (index + 1 < shots.length) {
      final next = shots[index + 1];
      final duration = sonnetTransitionDurationSeconds(
        next.startMs - shot.startMs,
      );
      final remaining = (next.startMs - nowMs) / 1000;
      if (remaining >= 0 && remaining <= duration) {
        return resolveSonnetTransitionFrame(
          SonnetTransitionKind.cameraPull,
          'exit',
          1 - remaining / duration,
          shot.startMs,
        ).alpha;
      }
    }
    return 1;
  }

  Widget _wordWidget(
    _WordPlacement placement,
    _ShotLayout layout,
    int nowMs,
    FoliaTheme theme,
  ) {
    final word = placement.word;
    final isEmphasis =
        placement.role == SonnetRole.hero ||
        placement.role == SonnetRole.semiHero;
    final glyph = resolveSonnetGlyphFrame(
      startMs: word.startMs,
      settleMs: word.endMs,
      nowMs: nowMs,
      isEmphasis: isEmphasis,
      shotKind: layout.shot.kind,
    );
    if (glyph.alpha <= 0) return const SizedBox.shrink();
    final fontSize = placement.fontSize;
    final color = theme.primary.withValues(
      alpha: glyph.alpha,
    );
    final glow = Shadow(
      color: theme.accent.withValues(
        alpha: 0.8 * glyph.haloAlpha,
      ),
      blurRadius: sonnetGlowBlur(fontSize),
    );
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: placement.weight,
      color: color,
      shadows: [glow],
    );
    final core = Text(word.text, style: style);
    final children = <Widget>[];
    // Semi-hero echo ghosts: hollow stroke-only copies split
    // along the layout normal (sonnetTextViewBuilder.ts).
    if (placement.role == SonnetRole.semiHero) {
      final spread = fontSize * kSonnetGhostSpreadFactor;
      final side = placement.flowIndex.isEven ? 1.0 : -1.0;
      for (var layer = 0; layer < 2; layer++) {
        final ghostStyle = TextStyle(
          fontSize: fontSize,
          fontWeight: placement.weight,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1, math.min(8, fontSize * 0.006))
            ..color = theme.accent.withValues(
              alpha: kSonnetGhostAlphas[layer] * glyph.alpha,
            ),
        );
        children.add(
          Transform.translate(
            offset: Offset(0, side * (layer + 1) * spread),
            child: Text(word.text, style: ghostStyle),
          ),
        );
      }
    }
    // Chromatic aberration on the hero only: cyan/red copies that
    // start separated and merge to a subtle offset
    // (sonnetTextViewBuilder.ts, sonnetShotFrame.ts).
    if (placement.role == SonnetRole.hero) {
      final progress = sonnetSegmentProgress(
        word.startMs,
        word.endMs,
        nowMs,
      );
      // Starts separated (6px) and merges to a subtle 1px offset.
      final mergeOffset = 1 + (1 - sonnetEaseInOut(progress)) * 5;
      children.addAll([
        Transform.translate(
          offset: Offset(-mergeOffset, 0),
          child: Text(
            word.text,
            style: style.copyWith(
              color: Color(kSonnetCaCyan).withValues(
                alpha: 0.8 * glyph.alpha,
              ),
              shadows: const [],
            ),
          ),
        ),
        Transform.translate(
          offset: Offset(mergeOffset, 0),
          child: Text(
            word.text,
            style: style.copyWith(
              color: Color(kSonnetCaRed).withValues(
                alpha: 0.8 * glyph.alpha,
              ),
              shadows: const [],
            ),
          ),
        ),
      ]);
    }
    children.add(core);
    return Positioned(
      left: placement.x,
      top: placement.y,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..translateByDouble(
            placement.enterX * glyph.offsetFactor,
            placement.enterY * glyph.offsetFactor,
            0,
            1,
          )
          ..rotateZ(placement.entryRotation * glyph.offsetFactor)
          ..scaleByDouble(glyph.scale, glyph.scale, 1, 1),
        child: Stack(children: children),
      ),
    );
  }
}

class _CameraEvaluation {
  const _CameraEvaluation({required this.matrix});

  final Matrix4 matrix;
}

class _FlowWord {
  const _FlowWord({required this.word, required this.lineIndex});

  final SonnetWord word;
  final int lineIndex;
}

class _MeasuredWord {
  const _MeasuredWord({
    required this.word,
    required this.role,
    required this.flowIndex,
    required this.fontSize,
    required this.weight,
    required this.width,
    required this.height,
  });

  final SonnetWord word;
  final SonnetRole role;

  /// Index in the shot's flattened word flow (deterministic;
  /// drives the entry-rotation sign and the ghost side).
  final int flowIndex;
  final double fontSize;
  final FontWeight weight;
  final double width;
  final double height;
}

class _WordPlacement {
  const _WordPlacement({
    required this.word,
    required this.role,
    required this.flowIndex,
    required this.fontSize,
    required this.weight,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.enterX,
    required this.enterY,
    required this.entryRotation,
  });

  final SonnetWord word;
  final SonnetRole role;
  final int flowIndex;
  final double fontSize;
  final FontWeight weight;
  final double x;
  final double y;
  final double width;
  final double height;
  final double enterX;
  final double enterY;
  final double entryRotation;
}

class _ShotLayout {
  const _ShotLayout({
    required this.size,
    required this.shot,
    required this.placements,
    required this.heroIndex,
    required this.baseFontSize,
  });

  final Size size;
  final FoliaShot shot;
  final List<_WordPlacement> placements;
  final int heroIndex;
  final double baseFontSize;
}

extension _Let<T> on T {
  R let<R>(R Function(T value) f) => f(this);
}

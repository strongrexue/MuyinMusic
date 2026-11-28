import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../core/services/app_logger.dart';
import 'audio_analysis.dart';
import 'folia_stage_registry.dart';
import 'folia_storyboard.dart';
import 'folia_theme.dart';
import 'sonnet_layout.dart';
import 'sonnet_mg.dart';
import 'sonnet_motion.dart';

/// Temporary timing diagnostic for the 2026-11-28 second-round
/// blank/flash report （偏偏喜欢你： lines blank ~5s, flash ~1s).
/// Flip to true for ONE diagnostic build, reproduce, capture the
/// `[sonnet-timing]` lines — from logcat, or from the in-app journal
/// (Settings → 调试 → 记录分类 → 商籁时序诊断， then 日志控制台 → 导出） —
/// then flip back to false. Default off: no logging in normal builds. It logs (a) the lyrics object
/// the stage actually received (line/word timings) at compile time,
/// (b) a 1Hz sample of raw vs effective clock, active shot and how
/// many of its words are visible, and (c) backward-jump decisions.
/// (a) vs (b) decides data problem vs clock problem: spread word
/// timings + a smoothly advancing clock with 0 visible words
/// mid-line would be a stage bug; bunched word timings would be a
/// lyrics-data problem; a frozen/jumping clock would be a
/// position-source problem.
const bool kSonnetTimingDiagnostics = true;

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
///   - all 5 editorial variants (0 vertical pillar, 1 flush-right
///     rail, 2 magazine header, 3 double hero lines, 4 logo badge)
///     plus each of the other 6 shot kinds' own layout
///     (sonnetTypographyLayout.ts, sonnetShotFlowLayouts.ts,
///     sonnetPosterBlocksLayout.ts), selected by seed
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
///   - shot-boundary transitions: fast-blur (blur to 14),
///     mono-glitch (14 coarse + 58 fine slice-tear bands,
///     sonnetGlitchFilter.ts) and camera-pull, kind per boundary
///     from the program seed (sonnetTransitions.ts)
///   - MG decorations, all on by default (entry.tsx
///     DEFAULT_SONNET_TUNING): guide lines, background HUD + scene
///     hairlines, shot fixed geometry, giant decorative text,
///     background decor, text fixed geometry, and the full outer
///     frame (sonnetTextViewBuilder.ts, sonnetBackgroundMg.ts,
///     sonnetBackgroundDecor.ts, sonnetFrameOverlay.ts,
///     sonnetGuides.ts)
///
/// Remaining known gaps (deliberately v1-scoped): the 11 folium
/// tunables run at identity with no tuning UI; beat-impact frame
/// interpolation is as-is; the 100-variant geometric-chaos layer
/// (sonnetShotMg.ts) is not rendered; '♪'-only segments do not get
/// the staff-notation view; the glitch shader renders only on
/// Impeller and needs on-device verification.
///
/// Performance: no new per-frame saveLayer. Word alpha runs
/// through the text color, glow through TextStyle shadows, CA and
/// ghosts are plain positioned texts. Layout is measured once per
/// shot and cached; per frame only progress/alpha/transforms are
/// re-evaluated. The transition blur/glitch filters only exist
/// during the 0.14–0.24s boundary windows.
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
  //
  // The controller position can also deliver a stale reading that
  // jumps far backwards (observed on device: the clock falling
  // back to ~0 for seconds while audio kept playing, which blanked
  // the lyrics until the next good reading). A large backward jump
  // is therefore held, not followed: it is only accepted once the
  // next reading confirms the position is really advancing from
  // the lower value (a genuine seek). If the next reading jumps
  // back up, the candidate is discarded as a stale read.
  static const int _maxBackwardJumpMs = 1500;
  int _anchorMs = 0;
  int _anchorWallMs = 0;
  int _lastRawMs = -1;
  int? _pendingBackwardRawMs;

  // Layout cache, keyed by shot start/end ms. Cleared on recompile.
  final Map<String, _ShotLayout> _layoutCache = {};

  // Mono-glitch shader (Impeller only). Null until loaded, or on
  // backends that cannot run it — transitions then fall back to
  // the alpha component of the mono-glitch frame.
  ui.FragmentProgram? _glitchProgram;

  @override
  void initState() {
    super.initState();
    _compile();
    _loadGlitchProgram();
    _ticker = createTicker((_) {
      if (mounted) setState(() {});
    });
    _ticker.start();
    _analysisSub = widget.stage.analysis.listen((frame) {
      _latestAnalysis = frame;
      if (frame.beat) _beatIndex++;
    });
  }

  Future<void> _loadGlitchProgram() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'shaders/sonnet_glitch.frag',
      );
      if (mounted) setState(() => _glitchProgram = program);
    } catch (_) {
      // Shader unavailable (e.g. GLES backend): mono-glitch falls
      // back to its alpha component; the other two transitions
      // are unaffected.
    }
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
    if (kSonnetTimingDiagnostics) _logLyricsFingerprint();
  }

  /// Mirror one timing diagnostic line to both logcat (debugPrint,
  /// kept byte-identical) and the in-app file journal (AppLogger,
  /// scope 'sonnet-timing' → 商籁时序诊断 category), so the user can
  /// capture it from Settings without adb. The file line is
  /// `ISO8601 [sonnet-timing] <message>` (the scope supplies the tag,
  /// so it is not repeated in the message). AppLogger gates on the
  /// recording-category switch; the 1Hz samples differ every second
  /// and fingerprint lines differ per line, so the dedup policy never
  /// collapses them, and every line is far below the 1200-char
  /// compact cap (samples ~150 chars, fingerprint lines < 600).
  void _logTiming(String message) {
    debugPrint('[sonnet-timing] $message');
    unawaited(AppLogger.write('sonnet-timing', message));
  }

  void _logLyricsFingerprint() {
    final lyrics = widget.stage.lyrics;
    final withTiming =
        lyrics.lines.where((line) => line.hasWordTiming).length;
    _logTiming(
      'lyrics songId=${widget.stage.songId} '
      'lines=${lyrics.lines.length} withWordTiming=$withTiming',
    );
    for (var i = 0; i < lyrics.lines.length && i < 10; i++) {
      final line = lyrics.lines[i];
      final wordStarts = line.words.map((w) => w.startMs).join(',');
      _logTiming(
        'line $i ${line.startMs}-${line.endMs} '
        'words=${line.words.length} starts=[$wordStarts] '
        'text=${line.text}',
      );
    }
  }

  int _lastTimingSampleWallMs = 0;
  bool _renderProbePending = false;

  void _maybeLogTimingSample(
    FoliaShot shot,
    _ShotLayout layout,
    int nowMs,
    _CameraEvaluation frame,
    SonnetTransitionFrame transition,
  ) {
    if (!kSonnetTimingDiagnostics) return;
    final wall = DateTime.now().millisecondsSinceEpoch;
    if (wall - _lastTimingSampleWallMs < 1000) return;
    _lastTimingSampleWallMs = wall;
    var visible = 0;
    var firstWordStart = -1;
    var lastWordStart = -1;
    for (final placement in layout.placements) {
      final word = placement.word;
      if (firstWordStart < 0 || word.startMs < firstWordStart) {
        firstWordStart = word.startMs;
      }
      if (word.startMs > lastWordStart) lastWordStart = word.startMs;
      final glyph = resolveSonnetGlyphFrame(
        startMs: word.startMs,
        settleMs: word.endMs,
        nowMs: nowMs,
        isEmphasis: false,
        shotKind: shot.kind,
      );
      if (glyph.alpha > 0) visible++;
    }
    // Camera + beat + transition state on the same line: a NaN
    // beatImpact would poison the camera matrix (sonnetBeatZoom),
    // and a zero transition alpha would hide the whole stage
    // (words and MG alike). Matrix storage is column-major:
    // [m00, m01, m10, m11, tx, ty].
    final impact = _latestAnalysis?.beatImpact;
    final storage = frame.matrix.storage;
    _logTiming(
      'raw=${widget.stage.positionNow().inMilliseconds} '
      'now=$nowMs playing=${widget.stage.playingNow()} '
      'shot=${shot.startMs}-${shot.endMs} kind=${shot.kind} '
      'words=$visible/${layout.placements.length} '
      'firstWord=$firstWordStart lastWord=$lastWordStart '
      'beat=${impact?.toStringAsFixed(3) ?? 'null'} '
      'beatNaN=${impact?.isNaN ?? false} '
      'cam=[${storage[0].toStringAsFixed(2)},'
      '${storage[4].toStringAsFixed(2)},'
      '${storage[1].toStringAsFixed(2)},'
      '${storage[5].toStringAsFixed(2)},'
      '${storage[12].toStringAsFixed(1)},'
      '${storage[13].toStringAsFixed(1)}] '
      'camFinite=${storage.every((v) => v.isFinite)} '
      'trA=${transition.alpha.toStringAsFixed(2)} '
      'trBlur=${transition.blur.toStringAsFixed(1)} '
      'trGlitch=${transition.glitch.toStringAsFixed(2)}',
    );
    // Render-tree snapshot, read after layout in a post-frame
    // callback (never during build: sizes/offsets are not
    // trustworthy until layout has run). At most one pending.
    if (!_renderProbePending) {
      _renderProbePending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _renderProbePending = false;
        if (mounted && kSonnetTimingDiagnostics) {
          _logRenderProbe(shot, nowMs);
        }
      });
    }
  }

  /// Post-frame render-tree snapshot (temporary diagnostic): walks
  /// the stage's render tree after layout and reports every
  /// RenderParagraph — its text, laid-out size, attached state,
  /// global position, painted alpha and whether its global rect
  /// intersects the stage — so an on-device capture can tell
  /// "words not in the tree" (no paragraphs for the shot's words)
  /// from "in the tree but not painted" (paragraphs present but
  /// zero-size / unattached / zero alpha) from "painted but
  /// off-screen" (paragraphs present with sane alpha but a global
  /// rect outside the stage). Wrapped in try/catch: diagnostics
  /// must never break the stage.
  void _logRenderProbe(FoliaShot shot, int nowMs) {
    try {
      final root = context.findRenderObject();
      if (root is! RenderBox || !root.hasSize) {
        _logTiming('render unavailable root=$root');
        return;
      }
      final stageOffset = MatrixUtils.transformPoint(
        root.getTransformTo(null),
        Offset.zero,
      );
      final stageRect = Rect.fromLTWH(
        stageOffset.dx,
        stageOffset.dy,
        root.size.width,
        root.size.height,
      );
      final tokens = <String>[];
      void visit(RenderObject child) {
        if (child is RenderParagraph) {
          final text = child.text.toPlainText().replaceAll('\n', '');
          final size = child.hasSize ? child.size : Size.zero;
          var global = Offset.zero;
          var onScreen = false;
          if (child.attached) {
            global = MatrixUtils.transformPoint(
              child.getTransformTo(null),
              Offset.zero,
            );
            onScreen = Rect.fromLTWH(
              global.dx,
              global.dy,
              size.width,
              size.height,
            ).overlaps(stageRect);
          }
          tokens.add(
            '$text:${size.width.toStringAsFixed(0)}x'
            '${size.height.toStringAsFixed(0)}@'
            '${global.dx.toStringAsFixed(0)},'
            '${global.dy.toStringAsFixed(0)} '
            'a=${_paragraphAlpha(child).toStringAsFixed(2)} '
            'att=${child.attached ? 1 : 0} on=${onScreen ? 1 : 0}',
          );
        }
        child.visitChildren(visit);
      }

      root.visitChildren(visit);
      final capped = tokens.length > 24 ? tokens.sublist(0, 24) : tokens;
      _logTiming(
        'render shot=${shot.startMs}-${shot.endMs} now=$nowMs '
        'stage=${root.size.width.toStringAsFixed(0)}x'
        '${root.size.height.toStringAsFixed(0)}@'
        '${stageOffset.dx.toStringAsFixed(0)},'
        '${stageOffset.dy.toStringAsFixed(0)} '
        'paragraphs=${tokens.length} [${capped.join(' | ')}]',
      );
    } catch (e) {
      _logTiming('render probe failed: $e');
    }
  }

  /// Effective painted alpha of a paragraph: the core word Text
  /// carries it in its style color; ghost/CA copies in their
  /// foreground paint. -1 when neither is set.
  double _paragraphAlpha(RenderParagraph paragraph) {
    final style = paragraph.text.style;
    final color = style?.color;
    if (color != null) return color.a;
    final foreground = style?.foreground;
    if (foreground != null) return foreground.color.a;
    return -1;
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
      _lastRawMs = raw;
      final backwardJump = _anchorMs - raw;
      if (backwardJump <= _maxBackwardJumpMs) {
        // Forward tick, small correction, or the first reading:
        // accept and re-anchor.
        _anchorMs = raw;
        _anchorWallMs = wall;
        _pendingBackwardRawMs = null;
      } else if (_pendingBackwardRawMs == null) {
        // Large backward jump: hold the clock and wait for
        // confirmation (a real seek) or a jump back up (stale read).
        _pendingBackwardRawMs = raw;
        if (kSonnetTimingDiagnostics) {
          _logTiming('hold backward jump: anchor=$_anchorMs raw=$raw');
        }
      } else if (raw >= _pendingBackwardRawMs! &&
          raw - _pendingBackwardRawMs! <= _maxBackwardJumpMs) {
        // The position is advancing from the lower value: a real
        // backward seek. Accept it.
        _anchorMs = raw;
        _anchorWallMs = wall;
        _pendingBackwardRawMs = null;
        if (kSonnetTimingDiagnostics) {
          _logTiming('accept backward seek: raw=$raw');
        }
      } else if (raw > _anchorMs) {
        // The position jumped back up: the candidate was a stale
        // read. Discard it and re-anchor forward.
        final heldAnchor = _anchorMs;
        final heldCandidate = _pendingBackwardRawMs;
        _pendingBackwardRawMs = null;
        _anchorMs = raw;
        _anchorWallMs = wall;
        if (kSonnetTimingDiagnostics) {
          _logTiming(
            'discard stale backward candidate: '
            'anchor=$heldAnchor candidate=$heldCandidate raw=$raw',
          );
        }
      } else if (raw < _anchorMs - _maxBackwardJumpMs) {
        // A different large backward jump: replace the candidate.
        _pendingBackwardRawMs = raw;
      } else {
        // Small backward move near the anchor: a correction.
        _pendingBackwardRawMs = null;
        _anchorMs = raw;
        _anchorWallMs = wall;
      }
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
        final transition = _transitionFrame(shot, nowMs);
        _maybeLogTimingSample(shot, layout, nowMs, frame, transition);
        const mg = SonnetMgSettings.blueprintDefaults;
        Widget content = Transform(
          transform: frame.matrix,
          child: Stack(
            children: [
              if (mg.showBackgroundMg)
                Positioned.fill(
                  child: CustomPaint(
                    painter: SonnetBackgroundHudPainter(
                      variant: sonnetBackgroundHudVariant(layout.shotSeed),
                      sceneSeed: layout.sceneSeed,
                      shotSeed: layout.shotSeed,
                      primary: theme.primary,
                      accent: theme.accent,
                      isEditorial: shot.kind == FoliaShotKind.editorial,
                      isTableauOrReveal:
                          shot.kind == FoliaShotKind.tableau ||
                          shot.kind == FoliaShotKind.reveal,
                    ),
                  ),
                ),
              if (mg.showFixedGeo)
                Positioned.fill(
                  child: CustomPaint(
                    painter: SonnetFixedGeoShotPainter(
                      variant: sonnetFixedGeoShotVariant(layout.shotSeed),
                      seed: layout.shotSeed,
                      radius: math.min(size.width, size.height) * 0.4,
                      primary: theme.primary,
                      accent: theme.accent,
                      isChorus: layout.isChorus,
                    ),
                  ),
                ),
              if (mg.showBackgroundDecor)
                Positioned.fill(
                  child: CustomPaint(
                    painter: SonnetBackgroundDecorPainter(
                      variant: sonnetBackgroundDecorVariant(layout.shotSeed),
                      seed: layout.shotSeed,
                      particleCount: shot.kind == FoliaShotKind.impact
                          ? 24
                          : 12,
                      primary: theme.primary,
                      accent: theme.accent,
                    ),
                  ),
                ),
              if (mg.showGuide)
                Positioned.fill(
                  child: CustomPaint(
                    painter: SonnetGuidePainter(
                      guides: _guideSpecs(layout, nowMs),
                      primary: theme.primary,
                      accent: theme.accent,
                    ),
                  ),
                ),
              if (mg.showFixedGeo && layout.textFixedGeoSpecs.isNotEmpty)
                Positioned.fill(
                  child: CustomPaint(
                    painter: SonnetTextFixedGeoPainter(
                      specs: layout.textFixedGeoSpecs,
                      primary: theme.primary,
                      accent: theme.accent,
                    ),
                  ),
                ),
              if (mg.showGiantDecorativeText)
                for (final decoration in layout.decorations)
                  _decorationWidget(decoration, layout, nowMs, theme),
              if (layout.frameDecorSpecs.isNotEmpty)
                Positioned.fill(
                  child: CustomPaint(
                    painter: SonnetFrameDecorPainter(
                      specs: _frameDecorSpecs(layout, nowMs),
                      primary: theme.primary,
                      accent: theme.accent,
                    ),
                  ),
                ),
              for (final placement in layout.placements)
                _wordWidget(placement, layout, nowMs, theme),
            ],
          ),
        );
        if (transition.blur > 0.01) {
          content = ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: transition.blur,
              sigmaY: transition.blur,
            ),
            child: content,
          );
        } else if (transition.glitch > 0.01 &&
            _glitchProgram != null &&
            ui.ImageFilter.isShaderFilterSupported) {
          final shader = _glitchProgram!.fragmentShader();
          // Uniform layout: vec2 uSize is set by the engine;
          // float uAmount is slot 2, float uSeed is slot 3.
          shader.setFloat(2, transition.glitch);
          shader.setFloat(3, transition.glitchSeed);
          content = ImageFiltered(
            imageFilter: ui.ImageFilter.shader(shader),
            child: content,
          );
        }
        if (transition.alpha < 1) {
          content = Opacity(opacity: transition.alpha, child: content);
        }
        if (!mg.showFrameOverlay) return content;
        return Stack(
          children: [
            content,
            Positioned.fill(
              child: CustomPaint(
                painter: SonnetFrameOverlayPainter(primary: theme.primary),
              ),
            ),
          ],
        );
      },
    );
  }

  List<SonnetGuideSpec> _guideSpecs(_ShotLayout layout, int nowMs) {
    final specs = <SonnetGuideSpec>[];
    for (final placement in layout.placements) {
      if (!placement.word.isWordLike) continue;
      final durationSeconds =
          (placement.word.endMs - placement.word.startMs) / 1000;
      final leadMs = (sonnetGuideLeadSeconds(durationSeconds) * 1000)
          .round();
      final startMs = placement.word.startMs - leadMs;
      final progress = (nowMs - startMs) / 650;
      if (progress <= 0 || progress > 1) continue;
      specs.add(
        SonnetGuideSpec(
          center: Offset(
            placement.x + placement.width / 2 - layout.size.width / 2,
            placement.y + placement.height / 2 - layout.size.height / 2,
          ),
          enterX: placement.enterX,
          enterY: placement.enterY,
          fontSize: placement.fontSize,
          isHero: placement.role == SonnetRole.hero,
          seed: layout.shotSeed + placement.flowIndex * 97,
          progress: progress.clamp(0.0, 1.0),
          wordStartMs: placement.word.startMs,
        ),
      );
    }
    return specs;
  }

  List<SonnetFrameDecorSpec> _frameDecorSpecs(
    _ShotLayout layout,
    int nowMs,
  ) {
    final shotDurationSeconds =
        (layout.shot.endMs - layout.shot.startMs) / 1000;
    final growSeconds =
        1.25 * sonnetGlyphMotionDurationSeconds(shotDurationSeconds);
    final firstGlyphStartMs = layout.placements
        .map((p) => p.word.startMs)
        .fold(layout.shot.startMs, math.min);
    final progress = ((nowMs - firstGlyphStartMs) / 1000 / growSeconds)
        .clamp(0.0, 1.0);
    return [
      for (final spec in layout.frameDecorSpecs)
        SonnetFrameDecorSpec(
          center: spec.center,
          width: spec.width,
          height: spec.height,
          rotation: spec.rotation,
          fontSize: spec.fontSize,
          variant: spec.variant,
          progress: progress,
        ),
    ];
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
    final program = _program!;
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
    // Heroes are picked per line (sonnetTypographyLayout.ts: each
    // line gets its own hero); the global hero — the highest score
    // across the shot — only sets the two-line split point and the
    // focus phase. Semi-heroes are picked per line too, excluding
    // that line's hero.
    final heroIndices = <int>{};
    var globalHeroIndex = -1;
    var globalHeroScore = double.negativeInfinity;
    final semiHeroes = <int>{};
    var flowOffset = 0;
    for (var li = 0; li < lines.length; li++) {
      final lineWords = [
        for (var i = 0; i < words.length; i++)
          if (words[i].lineIndex == li) words[i].word,
      ];
      final localHero = findSonnetHeroIndex(lineWords);
      final globalHero = flowOffset + localHero;
      heroIndices.add(globalHero);
      final score = sonnetHeroScore(lineWords[localHero]);
      if (score > globalHeroScore) {
        globalHeroScore = score;
        globalHeroIndex = globalHero;
      }
      for (final local in findSonnetSemiHeroIndices(
        lineWords,
        localHero,
      )) {
        final global = flowOffset + local;
        if (global != globalHero) semiHeroes.add(global);
      }
      flowOffset += lineWords.length;
    }
    // Secondary hero for editorial variant 3: the best remaining
    // word-like segment, +50 when it is not adjacent to the global
    // hero (sonnetTypographyLayout.ts).
    var secondaryHeroIndex = -1;
    var secondaryHeroScore = double.negativeInfinity;
    for (var i = 0; i < words.length; i++) {
      if (i == globalHeroIndex) continue;
      final word = words[i].word;
      if (!word.isWordLike || word.visibleLength == 0) continue;
      final score =
          sonnetHeroScore(word) +
          ((i - globalHeroIndex).abs() > 1 ? 50 : 0);
      if (score > secondaryHeroScore) {
        secondaryHeroScore = score;
        secondaryHeroIndex = i;
      }
    }

    final layoutVariantSeed = sonnetLayoutVariantSeed([
      for (final flowWord in words) flowWord.word.text.trim().length,
    ]);
    final editorialVariant = shot.kind == FoliaShotKind.editorial
        ? sonnetEditorialVariant(
            layoutVariantSeed,
            words.length,
            secondaryHeroIndex,
          )
        : 0;
    final scales = sonnetFontScales(
      shot.kind,
      editorialVariant: editorialVariant,
    );
    final baseFontSize = size.height * 0.052;
    final paragraphKind = program.paragraphs
        .where((paragraph) => paragraph.shots.contains(shot))
        .map((paragraph) => paragraph.kind)
        .firstOrNull;
    final isChorus = paragraphKind == FoliaParagraphKind.chorus;
    final programSeed = sonnetSeedHash(program.songId);
    final shotSeed = sonnetSeedHash(
      '${program.songId}:${shot.startMs}',
    );
    final posterSeed = sonnetSeedHash(
      [
        for (final flowWord in words) flowWord.word.text,
      ].join('␟'),
    );

    // Measure every word at its role size; CJK words also get a
    // vertical-column measurement (glyphs stacked, one glyph wide,
    // line height fontSize × 0.9) for the vertical layouts.
    final measured = <_MeasuredWord>[];
    for (var i = 0; i < words.length; i++) {
      final word = words[i].word;
      final role = heroIndices.contains(i)
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
      final isCjk = sonnetIsCjk(word.text);
      measured.add(
        _MeasuredWord(
          word: word,
          role: role,
          flowIndex: i,
          fontSize: fontSize,
          weight: weight,
          width: textSize.width,
          height: textSize.height,
          verticalWidth: isCjk ? fontSize : null,
          verticalHeight: isCjk
              ? word.text.runes.length * fontSize * 0.9
              : null,
          verticalFontScale: isCjk ? fontScale : null,
        ),
      );
    }
    if (measured.isEmpty) {
      return _ShotLayout(
        size: size,
        shot: shot,
        placements: const [],
        decorations: const [],
        textFixedGeoSpecs: const [],
        frameDecorSpecs: const [],
        heroIndex: globalHeroIndex,
        baseFontSize: baseFontSize,
        editorialVariant: editorialVariant,
        isChorus: isChorus,
        shotSeed: shotSeed,
        sceneSeed: programSeed,
        programSeed: programSeed,
      );
    }

    // Which words stand in a vertical column is decided by the
    // layout kind and variant, before the layout pass, so the fit
    // ladder measures the true footprint. Collage decides per word
    // from the polar angle inside the layout, so it stays
    // horizontal here and the stage derives the rotation after.
    bool isPreVertical(int index) {
      final item = measured[index];
      if (item.verticalWidth == null) return false;
      switch (shot.kind) {
        case FoliaShotKind.editorial:
          return editorialVariant == 0 || editorialVariant == 1;
        case FoliaShotKind.tableau:
          final tableauVariant = layoutVariantSeed % 4;
          return tableauVariant == 0 || tableauVariant == 1;
        case FoliaShotKind.impact:
        case FoliaShotKind.reveal:
          final beforeCount = globalHeroIndex;
          final topCount = beforeCount ~/ 2;
          final afterCount = words.length - 1 - globalHeroIndex;
          final rightCount = (afterCount + 1) ~/ 2;
          return index < topCount ||
              index > globalHeroIndex + rightCount;
        default:
          return false;
      }
    }

    final layoutBoxes = <SonnetLayoutWord>[];
    for (var i = 0; i < measured.length; i++) {
      final item = measured[i];
      final preVertical = isPreVertical(i);
      layoutBoxes.add(
        SonnetLayoutWord(
          index: i,
          isHero: heroIndices.contains(i),
          isSemiHero: semiHeroes.contains(i),
          fontScale: item.fontSize / baseFontSize,
          measuredWidth: preVertical ? item.verticalWidth! : item.width,
          measuredHeight: preVertical
              ? item.verticalHeight!
              : item.height,
          vertical: preVertical,
          verticalMeasuredWidth: item.verticalWidth,
          verticalMeasuredHeight: item.verticalHeight,
          verticalFontScale: item.verticalFontScale,
        ),
      );
    }
    final outcome = sonnetLayoutShot(
      boxes: layoutBoxes,
      heroIndex: globalHeroIndex < 0 ? 0 : globalHeroIndex,
      secondaryHeroIndex: secondaryHeroIndex,
      kind: shot.kind,
      width: size.width,
      height: size.height,
      baseFontSize: baseFontSize,
      layoutVariantSeed: layoutVariantSeed,
      posterSeed: posterSeed,
    );

    // The global hero's entrance always starts at (0, 15% of the
    // stage height), whatever the layout set
    // (sonnetTypographyLayout.ts buildSonnetTextView).
    if (globalHeroIndex >= 0) {
      outcome.boxes[globalHeroIndex].enterX = 0;
      outcome.boxes[globalHeroIndex].enterY = size.height * 0.15;
    }

    final placements = <_WordPlacement>[];
    for (var i = 0; i < measured.length; i++) {
      final item = measured[i];
      final box = outcome.boxes[i];
      final fontSize = baseFontSize * box.fontScale;
      // Display footprint: poster already returns display dims;
      // a vertical CJK column is one glyph wide; a rotated
      // non-CJK word in a vertical column swaps w/h.
      final isVerticalColumn =
          box.layoutDirection == SonnetLayoutDirection.vertical;
      final isCjkColumn =
          isVerticalColumn && item.verticalWidth != null;
      final isRotated =
          isVerticalColumn &&
          item.verticalWidth == null &&
          shot.kind != FoliaShotKind.poster;
      final displayWidth = shot.kind == FoliaShotKind.poster
          ? box.measuredWidth
          : isCjkColumn
          ? fontSize
          : isRotated
          ? box.measuredHeight
          : box.measuredWidth;
      final displayHeight = shot.kind == FoliaShotKind.poster
          ? box.measuredHeight
          : isCjkColumn
          ? item.word.text.runes.length * fontSize * 0.9
          : isRotated
          ? box.measuredWidth
          : box.measuredHeight;
      var centerX = size.width / 2 + box.x;
      var centerY = size.height / 2 + box.y;
      // Support words get a small perpendicular jitter
      // (sonnetGlyphLayout.ts resolveSonnetSegmentNormalOffset):
      // (rand × 2 − 1) × fontSize × 0.3 along the layout normal.
      if (item.role == SonnetRole.support) {
        final normalSeed = sonnetSeedHash(
          '${item.word.text}:${item.flowIndex}:normal-offset',
        );
        final jitter =
            ((normalSeed / 4294967296) * 2 - 1) * fontSize * 0.3;
        if (isVerticalColumn) {
          centerX += jitter;
        } else {
          centerY += jitter;
        }
      }
      placements.add(
        _WordPlacement(
          word: item.word,
          role: item.role,
          flowIndex: item.flowIndex,
          fontSize: fontSize,
          weight: item.weight,
          x: centerX - displayWidth / 2,
          y: centerY - displayHeight / 2,
          width: displayWidth,
          height: displayHeight,
          enterX: box.enterX,
          enterY: box.enterY,
          entryRotation:
              ((item.flowIndex.isEven ? 1 : -1) *
                  (item.role == SonnetRole.support ? 0.035 : 0.055)),
          rotation: isRotated ? math.pi / 2 : box.rotation,
          vertical: isCjkColumn || box.vertical,
          layoutDirection: box.layoutDirection,
        ),
      );
    }

    // Giant decorative text (sonnetTypographyLayout.ts): hollow
    // oversized copies of the heroes, never for tableau or poster.
    final decorations = <_DecorationPlacement>[];
    if (SonnetMgSettings.blueprintDefaults.showGiantDecorativeText) {
      for (final decoration in sonnetDecorations(
        boxes: outcome.boxes,
        heroFontScale: scales.hero,
        width: size.width,
        height: size.height,
        kind: shot.kind,
      )) {
        final source = measured[decoration.sourceIndex];
        final sourceBox = outcome.boxes[decoration.sourceIndex];
        // The decoration shares its source word's fit rung.
        final rungFactor =
            sourceBox.fontScale / (source.fontSize / baseFontSize);
        final fontSize = baseFontSize * decoration.fontScale * rungFactor;
        final textSize = _measureText(
          source.word.text,
          fontSize,
          source.weight,
        );
        final decorSeed = sonnetSeedHash(
          'decor:${decoration.sourceIndex}:${shot.startMs}',
        );
        final decorRng = sonnetMulberry32(decorSeed);
        final zDepth = decorRng() > 0.5
            ? 0.5 + decorRng() * 0.8
            : -0.5 - decorRng() * 0.8;
        decorations.add(
          _DecorationPlacement(
            word: source.word,
            fontSize: fontSize,
            weight: source.weight,
            x:
                size.width / 2 +
                decoration.x -
                textSize.width / 2,
            y:
                size.height / 2 +
                decoration.y -
                textSize.height / 2,
            enterX: decoration.enterX,
            enterY: decoration.enterY,
            rotation: decoration.rotation,
            zDepthBlur: math.min(40, zDepth.abs() * fontSize * 0.12),
          ),
        );
      }
    }

    // Per-word frames: a word gets either the traced open frame
    // (40% chance, sonnetTextViewBuilder.ts) or, when the shot
    // has enough words, the fixed geometry — never both.
    final textFixedGeoSpecs = <SonnetTextFixedGeoSpec>[];
    final frameDecorSpecs = <_FrameDecorSpec>[];
    final fixedGeoThreshold = sonnetTextFixedGeoMinWords(isChorus);
    for (var i = 0; i < placements.length; i++) {
      final placement = placements[i];
      final wordSeed = sonnetMixSeed(shotSeed, i + 1);
      final hasFrame = sonnetMulberry32(wordSeed)() < 0.4;
      final center = Offset(
        placement.x + placement.width / 2 - size.width / 2,
        placement.y + placement.height / 2 - size.height / 2,
      );
      if (hasFrame) {
        frameDecorSpecs.add(
          _FrameDecorSpec(
            center: center,
            width: placement.width * 1.3,
            height: placement.height * 1.3,
            rotation: placement.rotation,
            fontSize: placement.fontSize,
            variant: wordSeed % 4,
          ),
        );
      } else if (measured.length >= fixedGeoThreshold) {
        textFixedGeoSpecs.add(
          SonnetTextFixedGeoSpec(
            center: center,
            width: placement.width * 1.2,
            height: placement.height * 1.2,
            rotation: placement.rotation,
            fontSize: placement.fontSize,
            variant: sonnetTextFixedGeoVariant(wordSeed),
            seed: wordSeed,
            isChorus: isChorus,
          ),
        );
      }
    }

    return _ShotLayout(
      size: size,
      shot: shot,
      placements: placements,
      decorations: decorations,
      textFixedGeoSpecs: textFixedGeoSpecs,
      frameDecorSpecs: frameDecorSpecs,
      heroIndex: globalHeroIndex,
      baseFontSize: baseFontSize,
      editorialVariant: editorialVariant,
      isChorus: isChorus,
      shotSeed: shotSeed,
      sceneSeed: programSeed,
      programSeed: programSeed,
    );
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

  SonnetTransitionFrame _transitionFrame(FoliaShot shot, int nowMs) {
    final program = _program;
    if (program == null) return kSonnetIdleTransitionFrame;
    final shots = program.shots;
    final index = shots.indexOf(shot);
    if (index < 0) return kSonnetIdleTransitionFrame;
    final programSeed = sonnetSeedHash(program.songId);
    // Enter: first 0.14–0.24s of the shot; the kind comes from the
    // boundary before this shot (sonnetTransitions.ts).
    if (index > 0) {
      final previous = shots[index - 1];
      final duration = sonnetTransitionDurationSeconds(
        shot.startMs - previous.startMs,
      );
      final elapsed = (nowMs - shot.startMs) / 1000;
      if (elapsed >= 0 && elapsed <= duration) {
        final kind = sonnetBoundaryKind(programSeed, index - 1);
        return resolveSonnetTransitionFrame(
          kind,
          'enter',
          elapsed / duration,
          programSeed + index * 97,
        );
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
        final kind = sonnetBoundaryKind(programSeed, index);
        return resolveSonnetTransitionFrame(
          kind,
          'exit',
          1 - remaining / duration,
          programSeed + (index + 1) * 97,
        );
      }
    }
    return kSonnetIdleTransitionFrame;
  }

  Widget _decorationWidget(
    _DecorationPlacement decoration,
    _ShotLayout layout,
    int nowMs,
    FoliaTheme theme,
  ) {
    final glyph = resolveSonnetGlyphFrame(
      startMs: decoration.word.startMs,
      settleMs: decoration.word.endMs,
      nowMs: nowMs,
      isEmphasis: true,
      shotKind: layout.shot.kind,
    );
    if (glyph.alpha <= 0) return const SizedBox.shrink();
    // Hollow outline at alpha 0.2 with the zDepth soft glow
    // (sonnetTextViewBuilder.ts).
    final style = TextStyle(
      fontSize: decoration.fontSize,
      fontWeight: decoration.weight,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, math.min(8, decoration.fontSize * 0.006))
        ..color = theme.primary.withValues(alpha: 0.2 * glyph.alpha),
      shadows: [
        Shadow(
          color: theme.accent.withValues(alpha: 0.5 * glyph.alpha),
          blurRadius: decoration.zDepthBlur,
        ),
      ],
    );
    return Positioned(
      left: decoration.x,
      top: decoration.y,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..translateByDouble(
            decoration.enterX * glyph.offsetFactor,
            decoration.enterY * glyph.offsetFactor,
            0,
            1,
          )
          ..rotateZ(decoration.rotation)
          ..scaleByDouble(glyph.scale, glyph.scale, 1, 1),
        child: Text(decoration.word.text, style: style),
      ),
    );
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
    // Vertical columns stack the glyphs (sonnetGlyphLayout.ts).
    final displayText = placement.vertical
        ? word.text.runes.map(String.fromCharCode).join('\n')
        : word.text;
    final core = Text(
      displayText,
      textAlign: TextAlign.center,
      style: style.copyWith(height: placement.vertical ? 0.9 : null),
    );
    final children = <Widget>[];
    // Semi-hero echo ghosts: hollow stroke-only copies split
    // along the layout normal — vertical for a vertical column,
    // horizontal otherwise (sonnetTextViewBuilder.ts).
    if (placement.role == SonnetRole.semiHero) {
      final spread = fontSize * kSonnetGhostSpreadFactor;
      final side = placement.flowIndex.isEven ? 1.0 : -1.0;
      final isVertical =
          placement.layoutDirection == SonnetLayoutDirection.vertical;
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
            offset: isVertical
                ? Offset(side * (layer + 1) * spread, 0)
                : Offset(0, side * (layer + 1) * spread),
            child: Text(
              displayText,
              textAlign: TextAlign.center,
              style: ghostStyle.copyWith(
                height: placement.vertical ? 0.9 : null,
              ),
            ),
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
            displayText,
            textAlign: TextAlign.center,
            style: style.copyWith(
              color: Color(kSonnetCaCyan).withValues(
                alpha: 0.8 * glyph.alpha,
              ),
              shadows: const [],
              height: placement.vertical ? 0.9 : null,
            ),
          ),
        ),
        Transform.translate(
          offset: Offset(mergeOffset, 0),
          child: Text(
            displayText,
            textAlign: TextAlign.center,
            style: style.copyWith(
              color: Color(kSonnetCaRed).withValues(
                alpha: 0.8 * glyph.alpha,
              ),
              shadows: const [],
              height: placement.vertical ? 0.9 : null,
            ),
          ),
        ),
      ]);
    }
    children.add(core);
    // Per-glyph entrance stagger (sonnetGlyphLayout.ts): a
    // vertical column staggers along x, a horizontal line along y.
    final stagger = placement.flowIndex.isEven ? -1.0 : 1.0;
    final enterX =
        placement.enterX +
        (placement.vertical ? stagger * fontSize * 0.28 : 0);
    final enterY =
        placement.enterY +
        (placement.vertical ? 0 : stagger * fontSize * 0.24);
    return Positioned(
      left: placement.x,
      top: placement.y,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..translateByDouble(
            enterX * glyph.offsetFactor,
            enterY * glyph.offsetFactor,
            0,
            1,
          )
          ..rotateZ(
            placement.rotation + placement.entryRotation * glyph.offsetFactor,
          )
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
    this.verticalWidth,
    this.verticalHeight,
    this.verticalFontScale,
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

  /// Vertical-column footprint for CJK words (one glyph wide,
  /// glyphs stacked at fontSize × 0.9). Null for non-CJK words.
  final double? verticalWidth;
  final double? verticalHeight;
  final double? verticalFontScale;
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
    this.rotation = 0,
    this.vertical = false,
    this.layoutDirection = SonnetLayoutDirection.horizontal,
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

  /// Base rotation (π/2 for a rotated non-CJK word in a vertical
  /// column); the entry rotation decays on top of it.
  final double rotation;

  /// Whether the word renders as a stacked CJK column.
  final bool vertical;
  final SonnetLayoutDirection layoutDirection;
}

class _DecorationPlacement {
  const _DecorationPlacement({
    required this.word,
    required this.fontSize,
    required this.weight,
    required this.x,
    required this.y,
    required this.enterX,
    required this.enterY,
    required this.rotation,
    required this.zDepthBlur,
  });

  final SonnetWord word;
  final double fontSize;
  final FontWeight weight;

  /// Top-left position (the decoration is centered on it).
  final double x;
  final double y;
  final double enterX;
  final double enterY;
  final double rotation;

  /// Soft glow blur: |zDepth| × fontSize × 0.12, capped at 40.
  final double zDepthBlur;
}

class _FrameDecorSpec {
  const _FrameDecorSpec({
    required this.center,
    required this.width,
    required this.height,
    required this.rotation,
    required this.fontSize,
    required this.variant,
  });

  /// Center in stage coordinates (0, 0 = stage center).
  final Offset center;
  final double width;
  final double height;
  final double rotation;
  final double fontSize;
  final int variant;
}

class _ShotLayout {
  const _ShotLayout({
    required this.size,
    required this.shot,
    required this.placements,
    required this.decorations,
    required this.textFixedGeoSpecs,
    required this.frameDecorSpecs,
    required this.heroIndex,
    required this.baseFontSize,
    required this.editorialVariant,
    required this.isChorus,
    required this.shotSeed,
    required this.sceneSeed,
    required this.programSeed,
  });

  final Size size;
  final FoliaShot shot;
  final List<_WordPlacement> placements;
  final List<_DecorationPlacement> decorations;
  final List<SonnetTextFixedGeoSpec> textFixedGeoSpecs;
  final List<_FrameDecorSpec> frameDecorSpecs;
  final int heroIndex;
  final double baseFontSize;
  final int editorialVariant;
  final bool isChorus;
  final int shotSeed;
  final int sceneSeed;
  final int programSeed;
}

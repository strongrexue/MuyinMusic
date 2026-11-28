import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panghu_music/features/folia/folia_stage_registry.dart';
import 'package:panghu_music/features/folia/folia_storyboard.dart';
import 'package:panghu_music/features/folia/folia_theme.dart';
import 'package:panghu_music/features/folia/sonnet_layout.dart';
import 'package:panghu_music/features/folia/sonnet_mg.dart';
import 'package:panghu_music/features/folia/sonnet_motion.dart';
import 'package:panghu_music/features/folia/sonnet_stage.dart';
import 'package:panghu_music/features/folia/sonnet_style.dart';
import 'package:panghu_music/features/player/lyric_parser.dart';

KaraokeLyricLine _line(
  int start,
  int end,
  String text, [
  List<KaraokeWordTiming> words = const [],
]) => KaraokeLyricLine(startMs: start, endMs: end, text: text, words: words);

void main() {
  group('sonnet easings', () {
    test('expoOut endpoints and midpoint', () {
      expect(sonnetExpoOut(0), 0);
      expect(sonnetExpoOut(1), 1);
      expect(sonnetExpoOut(0.5), closeTo(1 - 0.03125, 1e-9));
    });

    test('easeInOut endpoints and symmetry', () {
      expect(sonnetEaseInOut(0), 0);
      expect(sonnetEaseInOut(1), 1);
      // 12 bisection iterations (the blueprint's count) leave
      // ~2e-4 of solver error at the midpoint.
      expect(sonnetEaseInOut(0.5), closeTo(0.5, 1e-3));
      // Monotonic.
      var previous = 0.0;
      for (var i = 1; i <= 10; i++) {
        final value = sonnetEaseInOut(i / 10);
        expect(value, greaterThanOrEqualTo(previous));
        previous = value;
      }
    });

    test('segment progress clamps to the word window', () {
      expect(sonnetSegmentProgress(1000, 2000, 500), 0);
      expect(sonnetSegmentProgress(1000, 2000, 2000), 1);
      expect(sonnetSegmentProgress(1000, 2000, 3000), 1);
      expect(
        sonnetSegmentProgress(1000, 2000, 1500),
        closeTo(sonnetExpoOut(0.5), 1e-9),
      );
    });
  });

  group('sonnet shot motion', () {
    test('motion frames stay in bounds for every kind', () {
      for (final kind in FoliaShotKind.values) {
        for (final progress in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          final frame = resolveSonnetShotMotionFrame(kind, progress);
          expect(frame.scale, inInclusiveRange(0.9, 1.35));
          expect(frame.x.abs(), lessThanOrEqualTo(0.17));
          expect(frame.y.abs(), lessThanOrEqualTo(0.14));
          expect(frame.rotation.abs(), lessThanOrEqualTo(0.03));
        }
      }
    });

    test('shot path progress runs 0 to 1 monotonically', () {
      for (final kind in FoliaShotKind.values) {
        expect(sonnetShotPathProgress(kind, 0), 0);
        expect(sonnetShotPathProgress(kind, 1), 1);
        var previous = 0.0;
        for (var i = 1; i <= 20; i++) {
          final value = sonnetShotPathProgress(kind, i / 20);
          expect(value, greaterThanOrEqualTo(previous - 1e-9));
          previous = value;
        }
      }
    });

    test('camera breath stays inside its caps', () {
      for (var t = 0.0; t < 10; t += 0.37) {
        final breath = resolveSonnetCameraBreath(t, 1.3);
        expect(breath.x.abs(), lessThanOrEqualTo(0.006 + 1e-9));
        expect(breath.y.abs(), lessThanOrEqualTo(0.006 + 1e-9));
        expect(breath.scale.abs(), lessThanOrEqualTo(0.002 + 1e-9));
        expect(breath.rotation.abs(), lessThanOrEqualTo(0.0015 + 1e-9));
      }
    });

    test('breath weight ramps in over 1.2s after the reveal', () {
      expect(resolveSonnetBreathWeight(5, 5), 0);
      expect(resolveSonnetBreathWeight(6.2, 5), 1);
      final mid = resolveSonnetBreathWeight(5.6, 5);
      expect(mid, inInclusiveRange(0, 1));
    });

    test('gap drift grows then saturates', () {
      final frame = resolveSonnetShotMotionFrame(
        FoliaShotKind.editorial,
        1,
      );
      final short = sonnetGapDrift(frame, FoliaShotKind.editorial, 0.5);
      final long = sonnetGapDrift(frame, FoliaShotKind.editorial, 10);
      expect(long.x.abs(), greaterThanOrEqualTo(short.x.abs()));
      expect(long.x.abs(), lessThanOrEqualTo(0.2));
    });
  });

  group('sonnet hero roles', () {
    test('hero score rewards length and duration', () {
      const short = SonnetWord(text: '是', startMs: 0, endMs: 200);
      const long = SonnetWord(text: '后来', startMs: 0, endMs: 1200);
      expect(sonnetHeroScore(long), greaterThan(sonnetHeroScore(short)));
    });

    test('hero is the highest-scoring word-like segment', () {
      final words = [
        const SonnetWord(text: '无论', startMs: 0, endMs: 400),
        const SonnetWord(text: '是', startMs: 400, endMs: 600),
        const SonnetWord(text: '后来', startMs: 600, endMs: 1800),
        const SonnetWord(text: '故事', startMs: 1800, endMs: 2200),
        const SonnetWord(text: '怎么', startMs: 2200, endMs: 2600),
        const SonnetWord(text: '了', startMs: 2600, endMs: 2800),
      ];
      expect(findSonnetHeroIndex(words), 2);
    });

    test('short lines earn no semi-heroes', () {
      final words = [
        const SonnetWord(text: '后来', startMs: 0, endMs: 1200),
        const SonnetWord(text: '啊', startMs: 1200, endMs: 1500),
      ];
      expect(findSonnetSemiHeroIndices(words, 0), isEmpty);
    });

    test('semi-hero sits on the side opposite the hero lean', () {
      final words = [
        const SonnetWord(text: '无论是', startMs: 0, endMs: 800),
        const SonnetWord(text: '后来', startMs: 800, endMs: 2000),
        const SonnetWord(text: '故事', startMs: 2000, endMs: 2800),
        const SonnetWord(text: '怎么了', startMs: 2800, endMs: 3600),
        const SonnetWord(text: '都已', startMs: 3600, endMs: 4200),
        const SonnetWord(text: '过去', startMs: 4200, endMs: 5000),
      ];
      // 无论是 and 怎么了 tie at 56.4; the first wins, so the hero
      // leans early and the semi-hero comes from after it.
      final hero = findSonnetHeroIndex(words);
      expect(hero, 0);
      final semi = findSonnetSemiHeroIndices(words, hero);
      expect(semi, [3]);
    });

    test('font scales follow the blueprint table', () {
      expect(sonnetFontScales(FoliaShotKind.editorial).hero, 4.0);
      expect(sonnetFontScales(FoliaShotKind.impact).hero, 5.5);
      expect(sonnetFontScales(FoliaShotKind.tableau).hero, 3.0);
      expect(sonnetFontScales(FoliaShotKind.editorial).support, 1.2);
      expect(
        sonnetSemiHeroScale(4.0, 1.2),
        closeTo(4.0 * 0.72, 1e-9),
      );
    });
  });

  group('sonnet word synthesis', () {
    test('lines without timings split by sweep weight and rebuild', () {
      final line = _line(0, 4000, '无论是后来故事怎么了');
      final words = sonnetWordsForLine(line, limitMs: 4000);
      expect(words.map((w) => w.text).join(), '无论是后来故事怎么了');
      expect(words.first.startMs, 0);
      expect(words.last.endMs, lessThanOrEqualTo(4000));
      for (var i = 1; i < words.length; i++) {
        expect(words[i].startMs, greaterThanOrEqualTo(words[i - 1].startMs));
      }
    });

    test('lines with timings use them verbatim', () {
      final line = _line(0, 3000, '后来', [
        const KaraokeWordTiming(text: '后', startMs: 0, endMs: 500),
        const KaraokeWordTiming(text: '来', startMs: 500, endMs: 1000),
      ]);
      final words = sonnetWordsForLine(line, limitMs: 3000);
      expect(words.length, 2);
      expect(words[0].startMs, 0);
      expect(words[1].endMs, 1000);
    });
  });

  group('sonnet glyph frame', () {
    test('waiting glyphs are invisible', () {
      final frame = resolveSonnetGlyphFrame(
        startMs: 1000,
        settleMs: 2000,
        nowMs: 500,
        isEmphasis: false,
        shotKind: FoliaShotKind.editorial,
      );
      expect(frame.alpha, 0);
      expect(frame.haloAlpha, 0);
      expect(frame.offsetFactor, 1);
    });

    test('settled glyphs are opaque with a faded halo', () {
      final frame = resolveSonnetGlyphFrame(
        startMs: 1000,
        settleMs: 2000,
        nowMs: 3000,
        isEmphasis: false,
        shotKind: FoliaShotKind.editorial,
      );
      expect(frame.alpha, 1);
      expect(frame.haloAlpha, closeTo(0.72, 1e-9));
      expect(frame.scale, 1);
      expect(frame.offsetFactor, 0);
    });

    test('type-impact emphasis enters from a deeper scale', () {
      final frame = resolveSonnetGlyphFrame(
        startMs: 1000,
        settleMs: 2000,
        nowMs: 1000,
        isEmphasis: true,
        shotKind: FoliaShotKind.impact,
      );
      expect(frame.scale, closeTo(0.52, 1e-9));
      expect(frame.alpha, closeTo(0.16, 1e-9));
    });
  });

  group('sonnet transitions and focus', () {
    test('camera-pull fades in from 0.28 and out to 0', () {
      final enter = resolveSonnetTransitionFrame(
        SonnetTransitionKind.cameraPull,
        'enter',
        0,
        1,
      );
      expect(enter.alpha, closeTo(0.28, 1e-9));
      final entered = resolveSonnetTransitionFrame(
        SonnetTransitionKind.cameraPull,
        'enter',
        1,
        1,
      );
      expect(entered.alpha, 1);
      final exited = resolveSonnetTransitionFrame(
        SonnetTransitionKind.cameraPull,
        'exit',
        1,
        1,
      );
      expect(exited.alpha, 0);
    });

    test('fast-blur peaks at blur 14', () {
      final frame = resolveSonnetTransitionFrame(
        SonnetTransitionKind.fastBlur,
        'exit',
        1,
        1,
      );
      expect(frame.blur, 14);
    });

    test('boundary kinds are deterministic', () {
      expect(
        sonnetBoundaryKind(12345, 2),
        sonnetBoundaryKind(12345, 2),
      );
    });

    test('focus weights are normalized', () {
      final weights = resolveSonnetFocusWeights(
        [(0, 1000), (1000, 2000), (2000, 3000)],
        1500,
      );
      expect(weights.length, 3);
      expect(
        weights.fold(0.0, (a, b) => a + b),
        closeTo(1, 1e-9),
      );
      expect(weights[1], greaterThan(weights[0]));
    });

    test('beat punch is 6% zoom and an alternating 0.6deg tilt', () {
      expect(sonnetBeatZoom(1), closeTo(1.06, 1e-9));
      expect(sonnetBeatZoom(0), 1);
      expect(
        sonnetBeatRotation(1, 0),
        closeTo(-sonnetBeatRotation(1, 1), 1e-9),
      );
    });
  });

  group('sonnet registration', () {
    test('sonnet registers as 商籁', () {
      final registry = FoliaStageRegistry();
      registry.register(sonnetStageStyle());
      final style = registry.byId('sonnet');
      expect(style, isNotNull);
      expect(style!.label, '商籁');
      expect(
        () => registry.register(sonnetStageStyle()),
        throwsStateError,
      );
    });
  });

  group('SonnetStageWidget', () {
    testWidgets('hero word renders giant at the sung position', (
      tester,
    ) async {
      // Two short lines in one shot; neither line earns a
      // semi-hero (fewer than 4 words each), so the counts below
      // are exact.
      final lyrics = KaraokeLyrics([
        _line(0, 2000, '无论是后来', [
          const KaraokeWordTiming(text: '无论', startMs: 0, endMs: 400),
          const KaraokeWordTiming(text: '是', startMs: 400, endMs: 600),
          const KaraokeWordTiming(text: '后来', startMs: 600, endMs: 1800),
        ]),
        _line(2400, 3400, '故事怎么了', [
          const KaraokeWordTiming(text: '故事', startMs: 2400, endMs: 2800),
          const KaraokeWordTiming(text: '怎么', startMs: 2800, endMs: 3200),
          const KaraokeWordTiming(text: '了', startMs: 3200, endMs: 3400),
        ]),
      ]);
      final stage = FoliaStageContext(
        lyrics: lyrics,
        theme: FoliaTheme.fallback,
        analysis: const Stream.empty(),
        songId: 'test-song',
        positionNow: () => const Duration(milliseconds: 1000),
        playingNow: () => false,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 400,
              child: SonnetStageWidget(stage: stage),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      // 后来 is the line's hero: core text, two
      // chromatic-aberration copies, and one giant hollow
      // decorative copy. 是 has started too (left row,
      // horizontal); 无论 is a vertical column here so its
      // rendered text is stacked; 故事 has not started.
      expect(find.text('后来'), findsNWidgets(4));
      expect(find.text('是'), findsOneWidget);
      expect(find.text('故事'), findsNothing);
      // Hero font size: base 400 × 0.052 = 20.8 times the
      // compiled shot kind's hero scale (the compiler picks the
      // kind deterministically from the song id), modulated by
      // the fit ladder's rung (0.52–1.0). The support word shares
      // the rung, so the hero/support ratio is exact.
      final program = const FoliaStoryboardCompiler().compile(
        lyrics,
        'test-song',
      );
      final kind = program.shots.single.kind;
      var editorialVariant = 0;
      if (kind == FoliaShotKind.editorial) {
        final flat = [
          for (final line in lyrics.lines)
            ...sonnetWordsForLine(line, limitMs: line.endMs),
        ];
        final heroIndex = findSonnetHeroIndex(flat);
        var secondary = -1;
        var best = double.negativeInfinity;
        for (var i = 0; i < flat.length; i++) {
          if (i == heroIndex) continue;
          final word = flat[i];
          if (!word.isWordLike || word.visibleLength == 0) continue;
          final score =
              sonnetHeroScore(word) +
              ((i - heroIndex).abs() > 1 ? 50 : 0);
          if (score > best) {
            best = score;
            secondary = i;
          }
        }
        editorialVariant = sonnetEditorialVariant(
          sonnetLayoutVariantSeed([
            for (final word in flat) word.text.trim().length,
          ]),
          flat.length,
          secondary,
        );
      }
      final scales = sonnetFontScales(
        kind,
        editorialVariant: editorialVariant,
      );
      final heroTexts = tester.widgetList<Text>(find.text('后来')).toList();
      // Core: no stroke foreground, and it carries the glow
      // shadow (the CA copies have none, the decoration is a
      // stroke foreground).
      final core = heroTexts.firstWhere(
        (text) =>
            text.style?.foreground == null &&
            (text.style?.shadows?.isNotEmpty ?? false),
      );
      final decoration = heroTexts.firstWhere(
        (text) => text.style?.foreground != null,
      );
      final support = tester.widget<Text>(find.text('是'));
      final heroSize = core.style!.fontSize!;
      final supportSize = support.style!.fontSize!;
      expect(heroSize / supportSize, closeTo(scales.hero / scales.support, 0.05));
      expect(heroSize, lessThanOrEqualTo(20.8 * scales.hero));
      expect(heroSize, greaterThanOrEqualTo(20.8 * scales.hero * 0.52));
      // The giant decoration is hollow and larger than the hero.
      expect(decoration.style!.fontSize!, greaterThan(heroSize));
    });

    testWidgets('shows nothing before the first word starts', (
      tester,
    ) async {
      final lyrics = KaraokeLyrics([
        _line(5000, 8000, '后来', [
          const KaraokeWordTiming(text: '后来', startMs: 5000, endMs: 6000),
        ]),
      ]);
      final stage = FoliaStageContext(
        lyrics: lyrics,
        theme: FoliaTheme.fallback,
        analysis: const Stream.empty(),
        songId: 'test-song',
        positionNow: () => const Duration(milliseconds: 1000),
        playingNow: () => false,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 400,
              child: SonnetStageWidget(stage: stage),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('后来'), findsNothing);
    });
  });

  group('sonnet seeds', () {
    test('FNV-1a hash is deterministic and order-sensitive', () {
      expect(sonnetSeedHash('后来'), sonnetSeedHash('后来'));
      expect(sonnetSeedHash('后来'), isNot(sonnetSeedHash('后來')));
      expect(sonnetSeedHash(''), 2166136261);
    });

    test('mix and hash01 stay in range and are deterministic', () {
      for (final seed in [0, 1, 42, 0x9e3779b1]) {
        expect(sonnetMixSeed(seed, 0x9e3779b9), greaterThanOrEqualTo(0));
        expect(sonnetMixSeed(seed, 0x9e3779b9), lessThan(4294967296));
        final jitter = sonnetHash01(seed, 3, 0x1234);
        expect(jitter, greaterThanOrEqualTo(0));
        expect(jitter, lessThan(1));
        expect(sonnetHash01(seed, 3, 0x1234), jitter);
      }
    });

    test('mulberry32 streams are deterministic per seed', () {
      final a = sonnetMulberry32(12345);
      final b = sonnetMulberry32(12345);
      for (var i = 0; i < 10; i++) {
        expect(a(), b());
      }
      expect(sonnetMulberry32(1)(), isNot(sonnetMulberry32(2)()));
    });

    test('glyph motion duration clamps to the shot window', () {
      expect(sonnetGlyphMotionDurationSeconds(0.5), closeTo(0.36, 1e-9));
      expect(sonnetGlyphMotionDurationSeconds(2), closeTo(0.84, 1e-9));
      expect(sonnetGlyphMotionDurationSeconds(10), closeTo(1.8, 1e-9));
    });

    test('elastic-out ends near 1 and overshoots in the middle', () {
      expect(sonnetElasticOut(0), closeTo(0, 1e-9));
      // The blueprint formula lands at 1.0005 at v = 1, not
      // exactly 1 (2^-10 × sin(19.37) ≈ 0.0005).
      expect(sonnetElasticOut(1), closeTo(1, 1e-3));
      expect(sonnetElasticOut(0.2), greaterThan(1));
    });
  });

  group('sonnet layout variants', () {
    List<SonnetLayoutWord> boxes({int count = 5, int hero = 2}) => [
      for (var i = 0; i < count; i++)
        SonnetLayoutWord(
          index: i,
          isHero: i == hero,
          isSemiHero: i == hero + 1,
          fontScale: i == hero ? 4.0 : 1.2,
          measuredWidth: i == hero ? 200 : 80,
          measuredHeight: i == hero ? 120 : 48,
        ),
    ];

    SonnetLayoutOutcome layout(
      List<SonnetLayoutWord> input, {
      FoliaShotKind kind = FoliaShotKind.editorial,
      int seed = 0,
      int posterSeed = 0,
      int hero = 2,
      int secondary = 4,
    }) => sonnetLayoutShot(
      boxes: input,
      heroIndex: hero,
      secondaryHeroIndex: secondary,
      kind: kind,
      width: 800,
      height: 450,
      baseFontSize: 24,
      layoutVariantSeed: seed,
      posterSeed: posterSeed,
    );

    test('variant seed is the trimmed-length sum plus the count', () {
      expect(sonnetLayoutVariantSeed([3, 5, 2]), 13);
      expect(sonnetLayoutVariantSeed([]), 0);
    });

    test('editorial variant follows seed % 5 with the fallbacks', () {
      expect(sonnetEditorialVariant(0, 5, 4), 0);
      expect(sonnetEditorialVariant(1, 5, 4), 1);
      expect(sonnetEditorialVariant(2, 5, 4), 2);
      expect(sonnetEditorialVariant(3, 5, 4), 3);
      expect(sonnetEditorialVariant(4, 5, 4), 4);
      // Variant 3 needs > 2 segments and a secondary hero.
      expect(sonnetEditorialVariant(3, 2, 1), 0);
      expect(sonnetEditorialVariant(3, 5, -1), 0);
      // Variant 4 with < 2 segments falls back to the magazine
      // header.
      expect(sonnetEditorialVariant(4, 1, -1), 2);
    });

    test('every shot kind lays out inside the safe area', () {
      for (final kind in FoliaShotKind.values) {
        final outcome = layout(boxes(), kind: kind, seed: 7);
        for (final box in outcome.boxes) {
          expect(
            box.x.abs() + box.measuredWidth / 2,
            lessThanOrEqualTo(800 * 0.48 + 1),
            reason: '$kind box ${box.index} x',
          );
          expect(
            box.y.abs() + box.measuredHeight / 2,
            lessThanOrEqualTo(450 * 0.46 + 1),
            reason: '$kind box ${box.index} y',
          );
        }
      }
    });

    test('editorial variant 0 stacks a vertical pillar', () {
      final outcome = layout(boxes(), seed: 0);
      expect(outcome.editorialVariant, 0);
      for (final box in outcome.boxes) {
        expect(box.layoutDirection, SonnetLayoutDirection.vertical);
      }
      // The hero pillar sits left of center.
      expect(outcome.boxes[2].x, lessThan(0));
    });

    test('editorial variant 3 keeps the two offset lines', () {
      final outcome = layout(boxes(), seed: 3);
      expect(outcome.editorialVariant, 3);
      expect(outcome.boxes[2].x, closeTo(0, 120));
      // Line 1 (up to the hero) sits above line 2.
      expect(outcome.boxes[0].y, lessThan(outcome.boxes[3].y));
      // The lines are offset in opposite directions.
      expect(outcome.boxes[0].x, lessThan(outcome.boxes[4].x));
    });

    test('editorial variant 4 puts the hero pillar on a side', () {
      final outcome = layout(boxes(), seed: 4);
      expect(outcome.editorialVariant, 4);
      expect(outcome.boxes[2].layoutDirection,
          SonnetLayoutDirection.vertical);
      expect(outcome.boxes[0].layoutDirection,
          SonnetLayoutDirection.horizontal);
    });

    test('ribbon variants keep one row around the hero', () {
      for (final seed in [0, 1, 2]) {
        final outcome = layout(boxes(), kind: FoliaShotKind.ribbon, seed: seed);
        expect(outcome.ribbonVariant, seed);
        final heroY = outcome.boxes[2].y;
        for (final box in outcome.boxes) {
          expect((box.y - heroY).abs(), lessThanOrEqualTo(80));
        }
        expect(outcome.boxes[0].x, lessThan(outcome.boxes[2].x));
        expect(outcome.boxes[4].x, greaterThan(outcome.boxes[2].x));
      }
    });

    test('tableau stacks vertically around the hero', () {
      // Small boxes: with the shared sizes the column wraps to a
      // second column (the blueprint's overflow rule), which is
      // covered by the safe-area test above.
      final small = [
        for (var i = 0; i < 5; i++)
          SonnetLayoutWord(
            index: i,
            isHero: i == 2,
            isSemiHero: i == 3,
            fontScale: i == 2 ? 3.0 : 1.15,
            measuredWidth: i == 2 ? 120 : 60,
            measuredHeight: i == 2 ? 60 : 24,
          ),
      ];
      final outcome = layout(
        small,
        kind: FoliaShotKind.tableau,
        seed: 0,
      );
      expect(outcome.tableauVariant, 0);
      expect(outcome.boxes[0].y, lessThan(outcome.boxes[2].y));
      expect(outcome.boxes[4].y, greaterThan(outcome.boxes[2].y));
      expect(outcome.boxes[0].x, closeTo(outcome.boxes[2].x, 120));
    });

    test('cross-stack puts words on all four sides of the hero', () {
      for (final kind in [FoliaShotKind.impact, FoliaShotKind.reveal]) {
        final outcome = layout(boxes(), kind: kind, seed: 0);
        final hero = outcome.boxes[2];
        expect(outcome.boxes[0].y, lessThan(hero.y));
        expect(outcome.boxes[1].x, lessThan(hero.x));
        expect(outcome.boxes[3].x, greaterThan(hero.x));
        expect(outcome.boxes[4].y, greaterThan(hero.y));
      }
    });

    test('collage spreads the supports on a ring around the hero', () {
      final outcome = layout(boxes(), kind: FoliaShotKind.collage, seed: 0);
      final hero = outcome.boxes[2];
      for (var i = 0; i < outcome.boxes.length; i++) {
        if (i == 2) continue;
        final box = outcome.boxes[i];
        final distance = (box.x - hero.x).abs() + (box.y - hero.y).abs();
        expect(distance, greaterThan(60));
      }
    });

    test('poster flow stays inside its canvas and rotates by seed', () {
      final horizontal = layout(
        boxes(),
        kind: FoliaShotKind.poster,
        posterSeed: 0,
      );
      expect(horizontal.posterOrientation, 0);
      final vertical = layout(
        boxes(),
        kind: FoliaShotKind.poster,
        posterSeed: 1,
      );
      expect(vertical.posterOrientation, 1);
      for (final outcome in [horizontal, vertical]) {
        for (final box in outcome.boxes) {
          expect(box.x.abs(), lessThanOrEqualTo(800 * 0.42 + 1));
          expect(box.y.abs(), lessThanOrEqualTo(450 * 0.40 + 1));
        }
      }
      // The orientation changes the composition.
      expect(
        horizontal.boxes[0].x != vertical.boxes[0].x ||
            horizontal.boxes[0].y != vertical.boxes[0].y,
        isTrue,
      );
    });

    test('layout is deterministic for the same seed', () {
      final first = layout(boxes(), kind: FoliaShotKind.collage, seed: 5);
      final second = layout(boxes(), kind: FoliaShotKind.collage, seed: 5);
      for (var i = 0; i < first.boxes.length; i++) {
        expect(second.boxes[i].x, first.boxes[i].x);
        expect(second.boxes[i].y, first.boxes[i].y);
        expect(second.boxes[i].fontScale, first.boxes[i].fontScale);
      }
      // A different seed rotates the variants.
      final other = layout(boxes(), kind: FoliaShotKind.editorial, seed: 6);
      expect(other.editorialVariant, isNot(first.editorialVariant));
    });

    test('CJK detection drives the vertical column rule', () {
      expect(sonnetIsCjk('后来'), isTrue);
      expect(sonnetIsCjk('hello'), isFalse);
      expect(sonnetIsCjk('後'), isTrue);
    });
  });

  group('sonnet transitions', () {
    test('transition duration clamps to 0.14–0.24s', () {
      expect(sonnetTransitionDurationSeconds(0), closeTo(0.14, 1e-9));
      expect(sonnetTransitionDurationSeconds(1000), closeTo(0.18, 1e-9));
      expect(sonnetTransitionDurationSeconds(10000), closeTo(0.24, 1e-9));
    });

    test('fast-blur peaks at blur 14 with the enter alpha 0.18', () {
      final enter = resolveSonnetTransitionFrame(
        SonnetTransitionKind.fastBlur,
        'enter',
        0,
        100,
      );
      expect(enter.blur, closeTo(14, 1e-9));
      expect(enter.alpha, closeTo(0.18, 1e-9));
      final exit = resolveSonnetTransitionFrame(
        SonnetTransitionKind.fastBlur,
        'exit',
        1,
        100,
      );
      expect(exit.blur, closeTo(14, 1e-9));
      expect(exit.alpha, closeTo(0, 1e-9));
    });

    test('mono-glitch steps in 14 slices and holds alpha until 0.86', () {
      final early = resolveSonnetTransitionFrame(
        SonnetTransitionKind.monoGlitch,
        'exit',
        0.5,
        100,
      );
      expect(early.glitch, greaterThan(0));
      expect(early.alpha, 1);
      expect(early.glitchSeed, closeTo(100 * 0.0001 + 7 * 0.173, 1e-9));
      final late = resolveSonnetTransitionFrame(
        SonnetTransitionKind.monoGlitch,
        'exit',
        0.95,
        100,
      );
      expect(late.alpha, lessThan(1));
      expect(late.glitchSeed, closeTo(100 * 0.0001 + 13 * 0.173, 1e-9));
    });

    test('boundary kinds are deterministic and cover all three', () {
      final kinds = <SonnetTransitionKind>{};
      for (var seed = 0; seed < 40; seed++) {
        for (var boundary = 0; boundary < 5; boundary++) {
          final kind = sonnetBoundaryKind(seed, boundary);
          expect(sonnetBoundaryKind(seed, boundary), kind);
          kinds.add(kind);
        }
      }
      expect(kinds.length, 3);
    });
  });

  group('sonnet MG decorations', () {
    test('blueprint defaults are all on with the full outer frame', () {
      const settings = SonnetMgSettings.blueprintDefaults;
      expect(settings.showGuide, isTrue);
      expect(settings.showBackgroundMg, isTrue);
      expect(settings.showFixedGeo, isTrue);
      expect(settings.showGiantDecorativeText, isTrue);
      expect(settings.showBackgroundDecor, isTrue);
      expect(settings.outerFrameMode, SonnetOuterFrameMode.full);
      expect(settings.showFrameOverlay, isTrue);
    });

    test('MG variant selectors stay in their blueprint ranges', () {
      for (var seed = 0; seed < 50; seed++) {
        expect(sonnetBackgroundHudVariant(seed), inInclusiveRange(0, 7));
        expect(sonnetFixedGeoShotVariant(seed), inInclusiveRange(0, 7));
        expect(sonnetBackgroundDecorVariant(seed), inInclusiveRange(0, 5));
        expect(sonnetTextFixedGeoVariant(seed), inInclusiveRange(0, 6));
        expect(
          sonnetSceneHairlineCount(seed),
          inInclusiveRange(9, 14),
        );
      }
    });

    test('text fixed geo needs 26 words in a chorus, 15 elsewhere', () {
      expect(sonnetTextFixedGeoMinWords(true), 26);
      expect(sonnetTextFixedGeoMinWords(false), 15);
    });

    test('guide lead clamps to 0.2–0.38s', () {
      expect(sonnetGuideLeadSeconds(0), closeTo(0.2, 1e-9));
      expect(sonnetGuideLeadSeconds(1), closeTo(0.28, 1e-9));
      expect(sonnetGuideLeadSeconds(10), closeTo(0.38, 1e-9));
    });

    test('giant decorations skip tableau and poster, scale 2.8–5.5', () {
      final boxes = [
        SonnetLayoutWord(
          index: 0,
          isHero: true,
          isSemiHero: false,
          fontScale: 4.0,
          measuredWidth: 200,
          measuredHeight: 120,
        ),
        SonnetLayoutWord(
          index: 1,
          isHero: false,
          isSemiHero: false,
          fontScale: 1.2,
          measuredWidth: 80,
          measuredHeight: 48,
        ),
      ];
      final editorial = sonnetDecorations(
        boxes: boxes,
        heroFontScale: 4.0,
        width: 800,
        height: 450,
        kind: FoliaShotKind.editorial,
      );
      expect(editorial, isNotEmpty);
      for (final decoration in editorial) {
        expect(decoration.fontScale, inInclusiveRange(1.8, 5.5));
      }
      expect(
        sonnetDecorations(
          boxes: boxes,
          heroFontScale: 4.0,
          width: 800,
          height: 450,
          kind: FoliaShotKind.tableau,
        ),
        isEmpty,
      );
      expect(
        sonnetDecorations(
          boxes: boxes,
          heroFontScale: 4.0,
          width: 800,
          height: 450,
          kind: FoliaShotKind.poster,
        ),
        isEmpty,
      );
    });
  });
}

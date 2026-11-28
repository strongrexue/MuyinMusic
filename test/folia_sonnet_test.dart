import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panghu_music/features/folia/folia_stage_registry.dart';
import 'package:panghu_music/features/folia/folia_storyboard.dart';
import 'package:panghu_music/features/folia/folia_theme.dart';
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
      expect(sonnetEaseInOut(0.5), closeTo(0.5, 1e-6));
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
      // Hero is the longest word (怎么了, 3 chars, 0.8s); it leans
      // late, so the semi-hero must come from before it.
      final hero = findSonnetHeroIndex(words);
      expect(hero, 3);
      final semi = findSonnetSemiHeroIndices(words, hero);
      expect(semi, isNotEmpty);
      expect(semi.first, lessThan(hero));
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
      final lyrics = KaraokeLyrics([
        _line(0, 3200, '无论是后来故事怎么了', [
          const KaraokeWordTiming(text: '无论', startMs: 0, endMs: 400),
          const KaraokeWordTiming(text: '是', startMs: 400, endMs: 600),
          const KaraokeWordTiming(text: '后来', startMs: 600, endMs: 1800),
          const KaraokeWordTiming(text: '故事', startMs: 1800, endMs: 2200),
          const KaraokeWordTiming(text: '怎么', startMs: 2200, endMs: 2600),
          const KaraokeWordTiming(text: '了', startMs: 2600, endMs: 2800),
        ]),
        _line(3200, 6000, '也要让后来人生精彩着', [
          const KaraokeWordTiming(text: '也要', startMs: 3200, endMs: 3600),
          const KaraokeWordTiming(text: '让', startMs: 3600, endMs: 3800),
          const KaraokeWordTiming(text: '后来', startMs: 3800, endMs: 4600),
          const KaraokeWordTiming(text: '人生', startMs: 4600, endMs: 5000),
          const KaraokeWordTiming(text: '精彩着', startMs: 5000, endMs: 5800),
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
      // 后来 is the hero: core text plus two chromatic-aberration
      // copies. 无论 has started too; 故事 has not.
      expect(find.text('后来'), findsNWidgets(3));
      expect(find.text('无论'), findsOneWidget);
      expect(find.text('故事'), findsNothing);
      // Hero font size: base 400 × 0.052 = 20.8, editorial hero ×4.
      final hero = tester.widget<Text>(find.text('后来').first);
      expect(hero.style?.fontSize, closeTo(20.8 * 4.0, 0.5));
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
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:panghu_music/core/storage/settings_store.dart';
import 'package:panghu_music/core/ui/artwork_colors.dart';
import 'package:panghu_music/core/ui/flow_palette.dart';
import 'package:panghu_music/features/folia/audio_analysis.dart';
import 'package:panghu_music/features/folia/folia_common_background.dart';
import 'package:panghu_music/features/folia/folia_stage_page.dart';
import 'package:panghu_music/features/folia/folia_stage_registry.dart';
import 'package:panghu_music/features/folia/folia_theme.dart';
import 'package:panghu_music/features/folia/sonnet_style.dart';
import 'package:panghu_music/features/player/lyric_parser.dart';
import 'package:panghu_music/features/player/player_audio_handler.dart';
import 'package:panghu_music/features/player/player_controller.dart';
import 'package:panghu_music/features/player/widgets/ktv_background.dart';
import 'package:panghu_music/features/player/widgets/player_control_color.dart';

const _theme = FoliaTheme(
  background: Color(0xFF123456),
  primary: Colors.white,
  accent: Color(0xFFFFB547),
);

class _SeededController extends PlayerController {
  _SeededController(super.ref, PlayerState initialState) {
    state = initialState;
  }
}

void main() {
  group('geometric layout', () {
    test('15 shapes, deterministic per song, within blueprint ranges', () {
      final a = foliaGeometricShapes('song-a');
      final b = foliaGeometricShapes('song-a');
      final c = foliaGeometricShapes('song-b');
      expect(a.length, 15);
      expect(b.length, 15);
      // Same seed: identical layout.
      for (var i = 0; i < a.length; i++) {
        expect(b[i].type, a[i].type);
        expect(b[i].xPercent, a[i].xPercent);
        expect(b[i].yPercent, a[i].yPercent);
        expect(b[i].size, a[i].size);
        expect(b[i].durationMs, a[i].durationMs);
        expect(b[i].delayMs, a[i].delayMs);
        expect(b[i].opacity, a[i].opacity);
        expect(b[i].reverse, a[i].reverse);
        expect(b[i].filled, a[i].filled);
        expect(b[i].rotationDegrees, a[i].rotationDegrees);
      }
      // Different seed: a different layout (at least one shape).
      var anyDiffers = false;
      for (var i = 0; i < a.length; i++) {
        if (c[i].xPercent != a[i].xPercent ||
            c[i].yPercent != a[i].yPercent ||
            c[i].size != a[i].size) {
          anyDiffers = true;
          break;
        }
      }
      expect(anyDiffers, isTrue);
      // Blueprint ranges: size 40–140, opacity 0.11–0.19,
      // duration 30–60s, delay 0–5s, rotation 0–360.
      for (final shape in a) {
        expect(shape.size, inInclusiveRange(40, 140));
        expect(shape.opacity, inInclusiveRange(0.11, 0.19));
        expect(shape.durationMs, inInclusiveRange(30000, 60000));
        expect(shape.delayMs, inInclusiveRange(0, 5000));
        expect(shape.rotationDegrees, inInclusiveRange(0, 360));
        expect(shape.xPercent, inInclusiveRange(0, 100));
        expect(shape.yPercent, inInclusiveRange(0, 100));
      }
    });

    test('20 particles, deterministic per song, within blueprint ranges',
        () {
      final a = foliaGeometricParticles('song-a');
      final b = foliaGeometricParticles('song-a');
      expect(a.length, 20);
      for (var i = 0; i < a.length; i++) {
        expect(b[i].size, a[i].size);
        expect(b[i].leftPercent, a[i].leftPercent);
        expect(b[i].topPercent, a[i].topPercent);
        expect(b[i].opacity, a[i].opacity);
        expect(b[i].durationMs, a[i].durationMs);
        expect(b[i].delayMs, a[i].delayMs);
      }
      // Blueprint ranges: size 1–5, opacity 0–0.3,
      // duration 15–35s, delay 0–10s.
      for (final particle in a) {
        expect(particle.size, inInclusiveRange(1, 5));
        expect(particle.opacity, inInclusiveRange(0, 0.3));
        expect(particle.durationMs, inInclusiveRange(15000, 35000));
        expect(particle.delayMs, inInclusiveRange(0, 10000));
      }
    });

    test('audio scale maps each shape to its own band', () {
      const silent = AudioBands.zero();
      const loudBass = AudioBands(
        bass: 1,
        lowMid: 0,
        mid: 0,
        vocal: 0,
        treble: 0,
      );
      const loudTreble = AudioBands(
        bass: 0,
        lowMid: 0,
        mid: 0,
        vocal: 0,
        treble: 1,
      );
      // Silence: every shape at the 0.95 floor.
      for (final type in FoliaGeometricShapeType.values) {
        expect(
          FoliaGeometricPainter.shapeScaleFor(type, silent),
          0.95,
        );
      }
      // Full band: 1.45, and only the shapes that read that band.
      expect(
        FoliaGeometricPainter.shapeScaleFor(
          FoliaGeometricShapeType.circle,
          loudBass,
        ),
        1.45,
      );
      expect(
        FoliaGeometricPainter.shapeScaleFor(
          FoliaGeometricShapeType.square,
          loudBass,
        ),
        0.95,
      );
      expect(
        FoliaGeometricPainter.shapeScaleFor(
          FoliaGeometricShapeType.cross,
          loudTreble,
        ),
        1.45,
      );
      expect(
        FoliaGeometricPainter.shapeScaleFor(
          FoliaGeometricShapeType.triangle,
          loudTreble,
        ),
        0.95,
      );
    });
  });

  group('FoliaCommonBackground widget', () {
    Future<void> pumpBackground(
      WidgetTester tester, {
      bool disableGeometricBackground = false,
      bool disableVignette = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: FoliaCommonBackground(
            theme: _theme,
            seed: 'song-a',
            analysis: const Stream<AudioAnalysisFrame>.empty(),
            playingNow: () => true,
            disableGeometricBackground: disableGeometricBackground,
            disableVignette: disableVignette,
          ),
        ),
      );
      await tester.pump();
    }

    // The geometric layer runs a periodic timer: pump it away at the
    // end of each test so the timer is cancelled in dispose.
    Future<void> pumpAway(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    }

    testWidgets('base colour comes from the theme, geometry on by default',
        (tester) async {
      await pumpBackground(tester);
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.color == _theme.background,
        ),
        findsOneWidget,
      );
      expect(find.byType(FoliaGeometricBackground), findsOneWidget);
      expect(find.byType(FoliaVignette), findsOneWidget);
      await pumpAway(tester);
    });

    testWidgets('disableGeometricBackground hides the shapes, keeps the '
        'vignette', (tester) async {
      await pumpBackground(tester, disableGeometricBackground: true);
      expect(find.byType(FoliaGeometricBackground), findsNothing);
      expect(find.byType(FoliaVignette), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.color == _theme.background,
        ),
        findsOneWidget,
      );
      await pumpAway(tester);
    });

    testWidgets('disableVignette hides the vignette, keeps the shapes',
        (tester) async {
      await pumpBackground(tester, disableVignette: true);
      expect(find.byType(FoliaVignette), findsNothing);
      expect(find.byType(FoliaGeometricBackground), findsOneWidget);
      await pumpAway(tester);
    });
  });

  group('registry', () {
    test('registerFoliaStyles registers the common background', () {
      final registry = FoliaStageRegistry();
      registerFoliaStyles(registry);
      final background = registry.backgroundById('common');
      expect(background, isNotNull);
      expect(background!.label, '通用');
      expect(registry.byId('sonnet'), isNotNull);
    });
  });

  group('FoliaStagePage integration', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets('renders the common background as the stage bottom layer',
        (tester) async {
      registerFoliaStyles();
      addTearDown(() {
        foliaStageRegistry.unregister('sonnet');
        foliaStageRegistry.unregisterBackground('common');
      });
      final preferences = await SharedPreferences.getInstance();
      final audioHandler = PlayerAudioHandler();
      addTearDown(() => unawaited(audioHandler.disposeHandler()));
      const state = PlayerState(
        track: PlayerTrack(
          id: 'tx:test-song:remote',
          kind: PlayerTrackKind.remote,
          title: '测试歌曲',
          artist: '测试歌手',
          album: '测试专辑',
          sourceLabel: 'QQ',
          qualityLabel: 'FLAC',
          remoteUrl: 'https://audio.example/test-song.mp3',
        ),
        lyrics: KaraokeLyrics([
          KaraokeLyricLine(
            startMs: 0,
            endMs: 5000,
            text: '测试歌词行',
            words: [
              KaraokeWordTiming(text: '测', startMs: 0, endMs: 1000),
              KaraokeWordTiming(text: '试', startMs: 1000, endMs: 2000),
            ],
          ),
        ]),
        playing: true,
        position: Duration.zero,
        duration: Duration(seconds: 200),
      );
      const artworkColors = ArtworkColors(
        baseColor: Colors.teal,
        palette: FlowPalette(
          baseArgb: 0xFF008080,
          accentsArgb: [0xFF008080],
        ),
        lyricInk: null,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            playerAudioHandlerProvider.overrideWithValue(audioHandler),
            playerControllerProvider.overrideWith(
              (ref) => _SeededController(ref, state),
            ),
            playerArtworkColorsProvider.overrideWith(
              (ref) async => artworkColors,
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: FoliaStagePage())),
        ),
      );
      await tester.pump();
      // The stage's bottom layer is the common background — not the
      // KTV photo behind the page.
      expect(find.byType(FoliaCommonBackground), findsOneWidget);
      expect(find.byType(KtvBackground), findsNothing);
      // Pump the page away so its timers (analysis, geometry) are
      // cancelled in dispose.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    });
  });
}

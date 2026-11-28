// Sonnet timing diagnostics mirrored to the in-app file journal
// (AppLogger, scope 'sonnet-timing' → dedicated 商籁时序诊断 category),
// so the user can capture them from Settings without adb.
//
// NOTE: these tests cover the temporary diagnostic period while
// kSonnetTimingDiagnostics is true. If the flag is flipped back to
// false after the on-device capture, the "on" expectations below no
// longer hold and this file goes away with the flag.
//
// NOTE: this file only proves the widget half — the stage calls
// AppLogger.write with the right scope and the lines land in memory
// (and debugPrint is unchanged). The file/export half lives in
// folia_sonnet_timing_file_log_export_test.dart, which writes the
// scope directly in a plain test. The split is forced: in testWidgets
// the file-write chain AppLogger queues during pumping never drains —
// its callbacks sit in the FakeAsync microtask queue and real I/O
// completions never arrive there (verified: panghu.log stays 0 bytes
// after minutes of pumps) — so awaiting flush/export/clear from a
// widget test deadlocks, and the faked timers even swallow the test
// timeout. Never await the AppLogger write chain from a widget test,
// and never put a plain export test in this file: the chain is
// process-global, so a pending link queued by a widget test would
// hang a later flush in the same file too.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:panghu_music/core/services/app_logger.dart';
import 'package:panghu_music/core/services/log_category.dart';
import 'package:panghu_music/features/folia/folia_stage_registry.dart';
import 'package:panghu_music/features/folia/folia_theme.dart';
import 'package:panghu_music/features/folia/sonnet_stage.dart';
import 'package:panghu_music/features/player/lyric_parser.dart';

KaraokeLyricLine _line(
  int start,
  int end,
  String text,
  List<KaraokeWordTiming> words,
) => KaraokeLyricLine(startMs: start, endMs: end, text: text, words: words);

KaraokeWordTiming _w(String text, int start, int duration) =>
    KaraokeWordTiming(text: text, startMs: start, endMs: start + duration);

/// Two lines; the first has 10 words so the fingerprint's starts list
/// is long enough to prove nothing is truncated away.
KaraokeLyrics _lyrics() => KaraokeLyrics([
  _line(1000, 5000, '旧日情如醉此际怕再追', [
    _w('旧', 1000, 100),
    _w('日', 1100, 100),
    _w('情', 1200, 100),
    _w('如', 1300, 100),
    _w('醉', 1400, 100),
    _w('此', 1500, 100),
    _w('际', 1600, 100),
    _w('怕', 1700, 100),
    _w('再', 1800, 100),
    _w('追', 1900, 100),
  ]),
  _line(5000, 9000, '偏偏痴心想见你', [
    _w('偏', 5000, 100),
    _w('偏', 5100, 100),
    _w('痴', 5200, 100),
  ]),
]);

Future<void> _pumpStage(WidgetTester tester, String songId) async {
  var nowMs = 2500;
  final stage = FoliaStageContext(
    lyrics: _lyrics(),
    theme: FoliaTheme.fallback,
    analysis: const Stream.empty(),
    songId: songId,
    positionNow: () => Duration(milliseconds: nowMs),
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Sync only. Recording setup needs real async (SharedPreferences)
    // and therefore runs under tester.runAsync inside each test body.
    SharedPreferences.setMockInitialValues({});
  });

  test('scope maps to its own category, not 应用运行', () {
    expect(logCategoryForScope('sonnet-timing'), AppLogCategory.sonnetTiming);
  });

  testWidgets(
    'with 商籁时序诊断 enabled, diagnostics reach memory',
    (tester) async {
      final printed = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) printed.add(message);
      };

      await tester.runAsync(() async {
        AppLogger.configureRecording(await SharedPreferences.getInstance());
        await AppLogger.setRecordingCategories({AppLogCategory.sonnetTiming});
      });
      await _pumpStage(tester, 'file-log-on');

      // debugPrint behaviour unchanged: same lines, same prefix.
      expect(
        printed.any(
          (line) => line.contains(
            '[sonnet-timing] lyrics songId=file-log-on lines=2 '
            'withWordTiming=2',
          ),
        ),
        isTrue,
      );

      // Memory journal: fingerprint header, per-line starts list intact
      // (all 10 word starts present — no truncation), and a 1Hz sample.
      final memory = AppLogger.recentMemoryLines.join('\n');
      expect(memory, contains('[sonnet-timing] lyrics songId=file-log-on'));
      expect(
        memory,
        contains(
          '[sonnet-timing] line 0 1000-5000 words=10 '
          'starts=[1000,1100,1200,1300,1400,1500,1600,1700,1800,1900]',
        ),
      );
      expect(memory, contains('[sonnet-timing] raw=2500 now=2500'));
      expect(memory, contains('words='));

      // Restore before the body ends: the framework checks foundation
      // debug variables after the body, before addTearDown runs.
      debugPrint = originalPrint;
    },
  );

  testWidgets(
    'with 商籁时序诊断 off, diagnostics still print but never reach the journal',
    (tester) async {
      final printed = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) printed.add(message);
      };

      await tester.runAsync(() async {
        AppLogger.configureRecording(await SharedPreferences.getInstance());
        await AppLogger.setRecordingCategories({AppLogCategory.playback});
      });
      await _pumpStage(tester, 'file-log-off');

      // debugPrint is not gated by the recording switch.
      expect(
        printed.any(
          (line) => line.contains(
            '[sonnet-timing] lyrics songId=file-log-off',
          ),
        ),
        isTrue,
      );

      // Memory still holds the previous test's lines (same process),
      // so assert on this test's songId only.
      expect(
        AppLogger.recentMemoryLines.join('\n'),
        isNot(contains('file-log-off')),
      );

      // Restore before the body ends (see the note in the test above).
      debugPrint = originalPrint;
    },
  );
}

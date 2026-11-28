// Render-tree diagnostic lines for the sonnet blank-line bug
// (2026-11-29): on device each line stays blank while its words
// are entering and only flashes near the line end, although the
// [sonnet-timing] model log and the render probe prove the widget
// tree, layout, alpha and camera are all correct in the test env.
// This file proves the new diagnostic lines themselves report
// truthfully: the 1Hz sample now carries beat/camera/transition
// state, and a post-frame snapshot lists every RenderParagraph
// under the stage (text, size, global offset, painted alpha,
// attached, on-screen) so a device capture can tell "words not in
// the tree" from "in the tree but not painted" from "painted but
// off-screen".
//
// NOTE: temporary diagnostic while kSonnetTimingDiagnostics is
// true; this file goes away with the flag. The harness follows
// folia_sonnet_timing_file_log_test.dart: capture debugPrint, never
// await the AppLogger write chain from a widget test (FakeAsync
// deadlock), restore debugPrint before the body ends.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:panghu_music/core/services/app_logger.dart';
import 'package:panghu_music/core/services/log_category.dart';
import 'package:panghu_music/features/folia/folia_stage_registry.dart';
import 'package:panghu_music/features/folia/folia_theme.dart';
import 'package:panghu_music/features/folia/sonnet_stage.dart';
import 'package:panghu_music/features/player/lyric_parser.dart';

KaraokeWordTiming _w(String text, int start, int end) =>
    KaraokeWordTiming(text: text, startMs: start, endMs: end);

KaraokeLyricLine _line(
  int start,
  int end,
  String text,
  List<KaraokeWordTiming> words,
) => KaraokeLyricLine(startMs: start, endMs: end, text: text, words: words);

/// Device-log lines 0–6 of 偏偏喜欢你 (from the 2026-11-29
/// [sonnet-timing] fingerprint; endMs = next word start, last word =
/// line end). Same lyrics as folia_sonnet_render_probe_test.dart.
KaraokeLyrics _deviceLyrics() => KaraokeLyrics([
  _line(0, 4573, '偏偏喜欢你 - 陈百强', [
    _w('偏', 0, 508),
    _w('偏', 508, 1016),
    _w('喜', 1016, 1524),
    _w('欢', 1524, 2032),
    _w('你', 2032, 2540),
    _w(' ', 2540, 3048),
    _w('-', 3048, 3556),
    _w('陈', 3556, 4064),
    _w('百', 4064, 4573),
  ]),
  _line(4573, 6606, '词：郑国江', [
    _w('词', 4573, 5081),
    _w('：', 5081, 5589),
    _w('郑', 5589, 6097),
    _w('国', 6097, 6606),
  ]),
  _line(6606, 8639, '曲：陈百强', [
    _w('曲', 6606, 7114),
    _w('：', 7114, 7622),
    _w('陈', 7622, 8130),
    _w('百', 8130, 8639),
  ]),
  _line(8639, 11180, '编曲：陈辉阳', [
    _w('编', 8639, 9147),
    _w('曲', 9147, 9655),
    _w('：', 9655, 10163),
    _w('陈', 10163, 10671),
    _w('辉', 10671, 11180),
  ]),
  _line(11180, 14245, '制作人：陈百强', [
    _w('制', 11180, 11688),
    _w('作', 11688, 12196),
    _w('人', 12196, 12704),
    _w('：', 12704, 13212),
    _w('陈', 13212, 13720),
    _w('百', 13720, 14245),
  ]),
  _line(14245, 20346, '愁绪挥不去 苦闷散不去', [
    _w('愁', 14245, 14971),
    _w('绪', 14971, 16246),
    _w('挥', 16246, 16585),
    _w('不', 16585, 16909),
    _w('去', 16909, 17332),
    _w('苦', 17332, 17718),
    _w('闷', 17718, 18095),
    _w('散', 18095, 19211),
    _w('不', 19211, 19573),
    _w('去', 19573, 20346),
  ]),
  _line(20346, 26478, '为何我心一片空虚', [
    _w('为', 20346, 20745),
    _w('何', 20745, 21143),
    _w('我', 21143, 22303),
    _w('心', 22303, 22694),
    _w('一', 22694, 22986),
    _w('片', 22986, 23369),
    _w('空', 23369, 24157),
    _w('虚', 24157, 26478),
  ]),
]);

Future<List<String>> _pumpStageAt(
  WidgetTester tester,
  int nowMs,
) async {
  final printed = <String>[];
  final originalPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) printed.add(message);
  };

  await tester.runAsync(() async {
    AppLogger.configureRecording(await SharedPreferences.getInstance());
    await AppLogger.setRecordingCategories({AppLogCategory.sonnetTiming});
  });
  final stage = FoliaStageContext(
    lyrics: _deviceLyrics(),
    theme: FoliaTheme.fallback,
    analysis: const Stream.empty(),
    songId: 'tx-device-log',
    positionNow: () => Duration(milliseconds: nowMs),
    playingNow: () => true,
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
  // Lets the post-frame render probe run.
  await tester.pump(const Duration(milliseconds: 100));

  // Restore before the body ends: the framework checks foundation
  // debug variables after the body, before addTearDown runs.
  debugPrint = originalPrint;
  return printed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('sample carries beat/camera/transition, render lists words',
      (tester) async {
    final printed = await _pumpStageAt(tester, 15000);

    // Mid-line 5 (poster shot 14245-20346): 愁 settled, 绪 entered.
    final sample = printed.firstWhere(
      (line) => line.contains('[sonnet-timing] raw=15000 now=15000'),
      orElse: () => '',
    );
    expect(sample, isNotEmpty, reason: 'no 1Hz sample line');
    expect(sample, contains('words=2/10'));
    expect(sample, contains('beat=null beatNaN=false'));
    expect(sample, contains('cam=['));
    expect(sample, contains('camFinite=true'));
    // No transition window at 15000: idle frame.
    expect(sample, contains('trA=1.00 trBlur=0.0 trGlitch=0.00'));

    final render = printed.firstWhere(
      (line) => line.contains('[sonnet-timing] render shot=14245-20346'),
      orElse: () => '',
    );
    expect(render, isNotEmpty, reason: 'no render snapshot line');
    expect(render, contains('now=15000'));
    expect(render, contains('stage=800x400@0,0'));
    final tokens = render.split(' | ');
    // Started words are in the tree, attached, on screen, with the
    // model alpha (愁 settled at 1.00, 绪 just entered at ~0.28).
    final chou = tokens.where((t) => t.startsWith('愁:')).toList();
    expect(chou, isNotEmpty);
    expect(
      chou.any((t) => t.contains('a=1.00 att=1 on=1')),
      isTrue,
      reason: '愁 core token: $chou',
    );
    final xu = tokens.where((t) => t.startsWith('绪:')).toList();
    expect(xu, isNotEmpty);
    expect(
      xu.any((t) => t.contains('att=1 on=1')),
      isTrue,
      reason: '绪 token: $xu',
    );
    // Not-yet-started words are not in the tree as paragraphs.
    expect(tokens.any((t) => t.startsWith('苦:')), isFalse);

    // The render line also reaches the memory journal.
    expect(
      AppLogger.recentMemoryLines.join('\n'),
      contains('[sonnet-timing] render shot=14245-20346 now=15000'),
    );
  });

  testWidgets('render snapshot works in a second shot kind too',
      (tester) async {
    final printed = await _pumpStageAt(tester, 21000);

    // Mid-line 6 (shot 20346-26478): 为 settled, 何 entered. The
    // kind comes from the songId seed (collage for 'tx-device-log';
    // impact on device for the real songId) — the point here is a
    // second kind, not the kind itself.
    final sample = printed.firstWhere(
      (line) => line.contains('[sonnet-timing] raw=21000 now=21000'),
      orElse: () => '',
    );
    expect(sample, isNotEmpty, reason: 'no 1Hz sample line');
    expect(sample, contains('words=2/8'));
    expect(sample, contains('kind=FoliaShotKind.collage'));
    expect(sample, contains('camFinite=true'));

    final render = printed.firstWhere(
      (line) => line.contains('[sonnet-timing] render shot=20346-26478'),
      orElse: () => '',
    );
    expect(render, isNotEmpty, reason: 'no render snapshot line');
    final tokens = render.split(' | ');
    final wei = tokens.where((t) => t.startsWith('为:')).toList();
    expect(wei, isNotEmpty);
    expect(
      wei.any((t) => t.contains('a=1.00 att=1 on=1')),
      isTrue,
      reason: '为 core token: $wei',
    );
    expect(tokens.any((t) => t.startsWith('我:')), isFalse);
  });
}

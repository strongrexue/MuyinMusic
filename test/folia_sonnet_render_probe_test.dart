// Render probe for the sonnet blank-line bug (2026-11-29): on device
// each line stays blank while its words are entering and only flashes
// fully-entered for ~1s near the line end, although the [sonnet-timing]
// log proves the model (word timings, clock, visible counts) is
// correct. The existing repro test only asserts widget presence
// (find.text), which cannot distinguish "built" from "painted".
// This probe asserts the painted geometry: every started word's Text
// must sit inside the stage bounds, with a sane alpha, and the camera
// transform must be finite and keep the word on screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// Device-log lines 0–6 of 偏偏喜欢你 (starts from the 2026-11-29
/// [sonnet-timing] fingerprint; endMs = next word start, last word =
/// line end, matching the QRC structure).
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

void main() {
  testWidgets('mid-line words are painted on screen, not just in the tree',
      (tester) async {
    var nowMs = 0;
    final stage = FoliaStageContext(
      lyrics: _deviceLyrics(),
      theme: FoliaTheme.fallback,
      analysis: const Stream.empty(),
      songId: 'tx-device',
      positionNow: () => Duration(milliseconds: nowMs),
      playingNow: () => true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 820,
            height: 360,
            child: SonnetStageWidget(stage: stage),
          ),
        ),
      ),
    );

    Future<void> at(int ms) async {
      nowMs = ms;
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Mid-line 5 (~15.0s): 愁 started 755ms ago (settled), 绪 just
    // started. Both must be on screen with visible alpha.
    await at(15000);
    for (final word in ['愁', '绪']) {
      final finder = find.text(word);
      expect(finder, findsWidgets, reason: '$word missing at 15000');
      final text = tester.widget<Text>(finder.first);
      final alpha = text.style?.color?.a ?? -1;
      expect(alpha, greaterThan(0.1), reason: '$word alpha $alpha at 15000');
      final rect = tester.getRect(finder.first);
      expect(
        rect.left >= -1 && rect.top >= -1 && rect.right <= 821 && rect.bottom <= 361,
        isTrue,
        reason: '$word rect $rect outside 820x360 stage at 15000',
      );
    }

    // Mid-line 5 (~18.0s): 7 words started (散 starts at 18095, not
    // yet), 6 settled. All on screen.
    await at(18000);
    for (final word in ['愁', '绪', '挥', '不', '去', '苦', '闷']) {
      final finder = find.text(word);
      expect(finder, findsWidgets, reason: '$word missing at 18000');
      final text = tester.widget<Text>(finder.first);
      final alpha = text.style?.color?.a ?? -1;
      expect(alpha, greaterThan(0.5), reason: '$word alpha $alpha at 18000');
      final rect = tester.getRect(finder.first);
      expect(
        rect.left >= -1 && rect.top >= -1 && rect.right <= 821 && rect.bottom <= 361,
        isTrue,
        reason: '$word rect $rect outside 820x360 stage at 18000',
      );
    }

    // The camera transform itself must stay finite: a NaN matrix
    // would paint nothing (words and MG alike).
    final transformFinder = find.byType(Transform);
    expect(transformFinder, findsWidgets);
    for (final element in transformFinder.evaluate()) {
      final transform = (element.widget as Transform).transform;
      for (var i = 0; i < 16; i++) {
        expect(transform.storage[i].isFinite, isTrue,
            reason: 'camera/word transform storage[$i] not finite');
      }
    }
  });
}

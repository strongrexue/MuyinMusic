// Reproduction + regression for the sonnet stage timing bug
// (2026-11-28, 陈百强《偏偏喜欢你》 QQ QRC): on device each lyric
// line stayed blank for most of its sung window and only flashed
// fully-entered for ~1s near the line end, with ~5s of empty stage
// between lines. The blueprint (Folia on the same song) enters
// words one by one as they are sung and keeps them on screen for
// the whole shot.
//
// The fixture below is the song's REAL QQ QRC word timing
// (PlayLyricInfo songID 147057, decrypted + parsed by the app's own
// TxQrcLyric/KaraokeLyricsParser; raw QRC saved at
// /tmp/qq_147057_qrc.txt). Word timings are spread across each
// line's sung window, so a correct stage must accumulate words
// progressively — never a blank mid-line or a flash at line end.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// Real lyric lines 1:15–1:52 of 偏偏喜欢你 (QRC word timings).
KaraokeLyrics _realLyrics() => KaraokeLyrics([
  _line(75660, 82428, '旧日情如醉此际怕再追', [
    _w('旧', 75660, 335),
    _w('日', 75995, 464),
    _w('情', 76459, 1086),
    _w('如', 77545, 369),
    _w('醉', 77914, 781),
    _w('此', 78695, 351),
    _w('际', 79046, 415),
    _w('怕', 79461, 1087),
    _w('再', 80548, 432),
    _w('追', 80980, 656),
  ]),
  _line(82428, 87728, '偏偏痴心想见你', [
    _w('偏', 82428, 335),
    _w('偏', 82763, 400),
    _w('痴', 83163, 415),
    _w('心', 83578, 382),
    _w('想', 83960, 1023),
    _w('见', 84983, 515),
    _w('你', 85498, 1343),
  ]),
  _line(87728, 93807, '为何我心分秒想着过去', [
    _w('为', 87728, 431),
    _w('何', 88159, 463),
    _w('我', 88622, 1025),
    _w('心', 89647, 397),
    _w('分', 90044, 352),
    _w('秒', 90396, 350),
    _w('想', 90746, 383),
    _w('着', 91129, 431),
    _w('过', 91560, 1552),
    _w('去', 93112, 269),
  ]),
  _line(93807, 99440, '为何你一点都不记起', [
    _w('为', 93807, 383),
    _w('何', 94190, 417),
    _w('你', 94607, 1039),
    _w('一', 95646, 365),
    _w('点', 96011, 367),
    _w('都', 96378, 374),
    _w('不', 96752, 447),
    _w('记', 97199, 465),
    _w('起', 97664, 1159),
  ]),
  _line(99440, 105840, '情义已失去恩爱都失去', [
    _w('情', 99440, 319),
    _w('义', 99759, 783),
    _w('已', 100542, 1087),
    _w('失', 101629, 448),
    _w('去', 102077, 782),
    _w('恩', 102859, 335),
    _w('爱', 103194, 383),
    _w('都', 103577, 575),
    _w('失', 104152, 480),
    _w('去', 104632, 465),
  ]),
  _line(105840, 136043, '我却为何偏偏喜欢你', [
    _w('我', 105840, 383),
    _w('却', 106223, 415),
    _w('为', 106638, 1135),
    _w('何', 107773, 351),
    _w('偏', 108124, 368),
    _w('偏', 108492, 431),
    _w('喜', 108923, 382),
    _w('欢', 109305, 415),
    _w('你', 109720, 1439),
  ]),
]);

/// Words currently rendered on the stage (a word counts as visible
/// when any Text widget shows it; hero words render several copies).
Set<String> _visibleWords(WidgetTester tester, List<String> words) {
  final visible = <String>{};
  for (final word in words) {
    if (tester.widgetList(find.text(word)).isNotEmpty) {
      visible.add(word);
    }
  }
  return visible;
}

void main() {
  testWidgets('real QRC lyrics accumulate word by word, no blank mid-line',
      (tester) async {
    var nowMs = 0;
    final stage = FoliaStageContext(
      lyrics: _realLyrics(),
      theme: FoliaTheme.fallback,
      analysis: const Stream.empty(),
      songId: 'qq-147057',
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

    Future<Set<String>> at(int ms, List<String> words) async {
      nowMs = ms;
      await tester.pump(const Duration(milliseconds: 100));
      return _visibleWords(tester, words);
    }

    const lineB = ['为', '何', '你', '一', '点', '都', '不', '记', '起'];
    const lineC = ['情', '义', '已', '失', '去', '恩', '爱', '都', '失', '去'];
    const lineD = ['我', '却', '为', '何', '偏', '偏', '喜', '欢', '你'];

    // Mid-line B (~96.6s): the sung words are already there, the
    // not-yet-sung ones are not.
    var visible = await at(96600, lineB);
    expect(visible, containsAll(['为', '何', '你', '一', '点']));
    expect(visible, isNot(contains('起')));

    // End of line B (~99.0s): the whole line is on screen.
    visible = await at(99000, lineB);
    expect(visible, containsAll(lineB));

    // Just after line C starts (~99.5s): no blank gap — the new
    // line's first word is already entering.
    visible = await at(99500, lineC);
    expect(visible, contains('情'));

    // Mid-line C (~102.6s): sung words accumulated.
    visible = await at(102600, lineC);
    expect(visible, containsAll(['情', '义', '已', '失', '去']));

    // End of line C (~105.5s): whole line present.
    visible = await at(105500, lineC);
    expect(visible, containsAll(['情', '义', '已', '失', '去', '恩', '爱']));

    // Mid-line D (~108.5s): sung words accumulated (the line has
    // two 偏; the visible set dedupes them).
    visible = await at(108500, lineD);
    expect(visible, containsAll(['我', '却', '为', '何', '偏']));
    expect(visible, isNot(contains('喜')));

    // Words of D are done (~111.0s): whole line present.
    visible = await at(111000, lineD);
    expect(visible, containsAll(lineD.toSet()));

    // Long after D's words finished (~121s, shot holds until the
    // next line at 136s): the entered words STAY on screen.
    visible = await at(121000, lineD);
    expect(visible, containsAll(lineD.toSet()));
  });

  testWidgets('stale position reads jumping back to ~0 do not blank the stage',
      (tester) async {
    // The on-device failure: the controller position fell back to
    // ~0 for seconds at a time while audio kept playing, and the
    // stage followed it down, blanking the lyrics until the next
    // good reading. The stage clock must hold the last good time
    // through a stale backward jump and only accept a backward
    // jump once the next reading confirms it.
    var nowMs = 0;
    final stage = FoliaStageContext(
      lyrics: _realLyrics(),
      theme: FoliaTheme.fallback,
      analysis: const Stream.empty(),
      songId: 'qq-147057',
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

    Future<Set<String>> at(int ms, List<String> words) async {
      nowMs = ms;
      await tester.pump(const Duration(milliseconds: 100));
      return _visibleWords(tester, words);
    }

    const lineB = ['为', '何', '你', '一', '点', '都', '不', '记', '起'];

    // Mid-line B: sung words visible.
    var visible = await at(96600, lineB);
    expect(visible, containsAll(['为', '何', '你', '一', '点']));

    // Stale read back to ~0, held for several ticks: the line
    // must stay on screen, not blank.
    visible = await at(0, lineB);
    expect(visible, containsAll(['为', '何', '你', '一', '点']));
    visible = await at(0, lineB);
    expect(visible, containsAll(['为', '何', '你', '一', '点']));
    visible = await at(0, lineB);
    expect(visible, containsAll(['为', '何', '你', '一', '点']));

    // The next good reading jumps forward again: the stage
    // re-anchors and the following line enters.
    const lineC = ['情', '义', '已', '失', '去', '恩', '爱', '都', '失', '去'];
    visible = await at(99500, lineC);
    expect(visible, contains('情'));
  });

  testWidgets('a real backward seek is still followed once confirmed',
      (tester) async {
    var nowMs = 0;
    final stage = FoliaStageContext(
      lyrics: _realLyrics(),
      theme: FoliaTheme.fallback,
      analysis: const Stream.empty(),
      songId: 'qq-147057',
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

    Future<Set<String>> at(int ms, List<String> words) async {
      nowMs = ms;
      await tester.pump(const Duration(milliseconds: 100));
      return _visibleWords(tester, words);
    }

    const lineA = ['旧', '日', '情', '如', '醉', '此', '际', '怕', '再', '追'];
    const lineB = ['为', '何', '你', '一', '点', '都', '不', '记', '起'];

    // Mid-line B.
    var visible = await at(96600, lineB);
    expect(visible, containsAll(['为', '何', '你', '一', '点']));

    // Seek back to ~82s (line A). The first reading is held; the
    // second, advancing from the lower value, confirms the seek.
    visible = await at(82000, lineB);
    expect(visible, containsAll(['为', '何', '你', '一', '点']));
    visible = await at(82040, lineA);
    expect(visible, containsAll(lineA));
    expect(visible, isNot(contains('起')));
  });

  testWidgets('lines without word timing enter progressively by sweep',
      (tester) async {
    // Plain LRC (no per-word timestamps): words are synthesized
    // across the line's sung window, so they must still enter one
    // by one instead of flashing at the line end.
    final lyrics = KaraokeLyrics([
      _line(93807, 99440, '为何你一点都不记起', const []),
      _line(99440, 105840, '情义已失去恩爱都失去', const []),
    ]);
    var nowMs = 0;
    final stage = FoliaStageContext(
      lyrics: lyrics,
      theme: FoliaTheme.fallback,
      analysis: const Stream.empty(),
      songId: 'qq-147057-plain',
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

    Future<Set<String>> at(int ms, List<String> words) async {
      nowMs = ms;
      await tester.pump(const Duration(milliseconds: 100));
      return _visibleWords(tester, words);
    }

    const lineB = ['为', '何', '你', '一', '点', '都', '不', '记', '起'];

    // Mid-line (sweep ~3.15s): early words in, late words not yet.
    // Synthesized starts: 为 93807 何 94107 你 94407 一 94707
    // 点 95007 都 95307 … 起 96207.
    var visible = await at(95100, lineB);
    expect(visible, containsAll(['为', '何', '你', '一', '点']));
    expect(visible, isNot(contains('起')));

    // End of the sweep window: the whole line is on screen.
    visible = await at(97000, lineB);
    expect(visible, containsAll(lineB));

    // Next line starts right after: no blank gap.
    const lineC = ['情', '义', '已', '失', '去', '恩', '爱', '都', '失', '去'];
    visible = await at(99500, lineC);
    expect(visible, contains('情'));
  });
}

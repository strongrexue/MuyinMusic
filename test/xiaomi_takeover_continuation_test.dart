import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/panghu_speaker_adapter.dart';
import 'package:muyin_music/core/xiaomi/takeover/dispatch.dart';
import 'package:muyin_music/core/xiaomi/takeover/quiet.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_resolver.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_engine.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_state.dart';
import 'package:muyin_music/features/downloads/download_history_entry.dart';
import 'package:muyin_music/features/player/player_models.dart';

import 'xiaomi_takeover_test_utils.dart';

/// 播完续播（用户口径）：续播列表来自接管时刻 App 播放队列
/// 的快照——点播歌在队列中取其后、不在从当前项顺延；每首
/// 走正常解析+推流+watch；快照耗尽干净收尾（不绕回循环，
/// 与蓝本歌单循环的差异点）。音箱队列与 App 播放状态独立。
void main() {
  group('分发层续播（快照队列推进）', () {
    test('播完 → 按快照顺序续播 → 耗尽后干净收尾、不再重推', () async {
      final h = _Harness(
        tailFor: (song) => song.title == '歌A'
            ? const [
                SpeakerQueueItem(title: '歌B', artist: '歌手B', durationMs: 3000),
                SpeakerQueueItem(title: '歌C', artist: '歌手C', durationMs: 3000),
              ]
            : const [],
      );
      h.resolver.byKeyword['歌B'] = const ResolvedSong(
        url: 'http://example.com/b.mp3',
        title: '歌B',
        artist: '歌手B',
        durationMs: 3000,
      );
      h.resolver.byKeyword['歌C'] = const ResolvedSong(
        url: 'http://example.com/c.mp3',
        title: '歌C',
        artist: '歌手C',
        durationMs: 3000,
      );

      await h.dispatcher.onCommand(_record('播放歌曲歌A'), 0);
      await _elapse(h.clock, const Duration(seconds: 30));
      // A 播完 → B 已接上（第二次解析+发布+推送）。
      expect(h.proxy.publishedUrls, contains('http://example.com/b.mp3'));
      expect(h.nowPlaying?.queueLength, 3);
      expect(h.dispatcher.hasQueue, isTrue);

      // B、C 依次播完 → 队列耗尽：队列清除、watch 退出、
      // 不绕回重播 A，也没有第四次推送。
      await _elapse(h.clock, const Duration(seconds: 50));
      expect(h.proxy.publishedUrls, contains('http://example.com/c.mp3'));
      expect(
        h.gateway.calls.where((c) => c.name == 'playMusic'),
        hasLength(3),
      );
      expect(h.dispatcher.hasQueue, isFalse);
      expect(h.engine.playing, isFalse);
      final stops = h.gateway.calls.where((c) => c.name == 'stop').length;
      expect(stops, greaterThan(0)); // 每首收尾都有 stop-loop 压制
    });

    test('无快照续播（队列空）→ 播完干净收尾', () async {
      final h = _Harness(tailFor: (_) => const []);
      await h.dispatcher.onCommand(_record('播放歌曲歌A'), 0);
      await _elapse(h.clock, const Duration(seconds: 10));
      expect(h.engine.playing, isTrue);
      expect(h.dispatcher.hasQueue, isFalse);

      await _elapse(h.clock, const Duration(seconds: 30));
      expect(
        h.gateway.calls.where((c) => c.name == 'playMusic'),
        hasLength(1),
      );
      expect(
        h.gateway.calls.where((c) => c.name == 'stop'),
        isNotEmpty,
      );
      expect(h.engine.playing, isFalse);
    });

    test('续播中来新点歌 → 旧队列被顶替，旧队列不再推进', () async {
      final h = _Harness(
        tailFor: (song) => song.title == '歌A'
            ? const [
                SpeakerQueueItem(
                  title: '歌B',
                  artist: '歌手B',
                  durationMs: 60000,
                ),
              ]
            : const [],
      );
      h.resolver.byKeyword['歌B'] = const ResolvedSong(
        url: 'http://example.com/b.mp3',
        title: '歌B',
        artist: '歌手B',
        durationMs: 60000,
      );
      h.resolver.byKeyword['歌C'] = const ResolvedSong(
        url: 'http://example.com/c.mp3',
        title: '歌C',
        artist: '歌手C',
        durationMs: 3000,
      );

      await h.dispatcher.onCommand(_record('播放歌曲歌A'), 0);
      await _elapse(h.clock, const Duration(seconds: 30));
      // A 播完，B（长歌）已接上并在 watch 守护中。
      expect(h.proxy.publishedUrls, [
        'http://example.com/a.mp3',
        'http://example.com/b.mp3',
      ]);
      expect(h.engine.playing, isTrue);

      // 新点歌 C：顶替 B 的 run 与旧队列。
      h.resolver.result = h.resolver.byKeyword['歌C'];
      final now = h.clock.nowMs();
      await h.dispatcher.onCommand(_record('播放歌曲歌C', timeMs: now), now);
      await _elapse(h.clock, const Duration(seconds: 25));
      // 推送序列恰好是 A、B、C：B 的队列没有再推进，
      // C 播完后也干净结束（C 无续播列表）。
      expect(h.proxy.publishedUrls, [
        'http://example.com/a.mp3',
        'http://example.com/b.mp3',
        'http://example.com/c.mp3',
      ]);
      expect(
        h.gateway.calls.where((c) => c.name == 'playMusic'),
        hasLength(3),
      );
      expect(h.engine.playing, isFalse);
      expect(h.dispatcher.hasQueue, isFalse);
    });

    test('续播候选解析失败 → 跳过它取下一首', () async {
      final h = _Harness(
        tailFor: (song) => song.title == '歌A'
            ? const [
                SpeakerQueueItem(title: '歌B', artist: '歌手B', durationMs: 3000),
                SpeakerQueueItem(title: '歌C', artist: '歌手C', durationMs: 3000),
              ]
            : const [],
      );
      h.resolver.byKeyword['歌B'] = null; // B 解析不到
      h.resolver.byKeyword['歌C'] = const ResolvedSong(
        url: 'http://example.com/c.mp3',
        title: '歌C',
        artist: '歌手C',
        durationMs: 3000,
      );

      await h.dispatcher.onCommand(_record('播放歌曲歌A'), 0);
      await _elapse(h.clock, const Duration(seconds: 35));
      // B 被跳过，C 被推上（推送序列恰好 A、C 两次）。
      expect(h.proxy.publishedUrls, contains('http://example.com/c.mp3'));
      expect(h.proxy.publishedUrls, isNot(contains('http://example.com/b.mp3')));
      expect(
        h.gateway.calls.where((c) => c.name == 'playMusic'),
        hasLength(2),
      );
    });
  });

  group('快照口径（buildSpeakerQueueTail）', () {
    DownloadHistoryEntry entry(String name, String singer) {
      return DownloadHistoryEntry(
        id: name,
        musicId: name,
        name: name,
        singer: singer,
        albumName: '',
        sourceCode: '',
        qualityCode: '',
        status: DownloadHistoryStatus.completed,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
    }

    PlayerState state(List<DownloadHistoryEntry> queue, int index) {
      return PlayerState(queue: queue, queueIndex: index);
    }

    final queue = [
      entry('歌甲', '歌手甲'),
      entry('歌乙', '歌手乙'),
      entry('歌丙', '歌手丙'),
      entry('歌丁', '歌手丁'),
    ];

    test('点播歌在队列中 → 从它后面一首开始', () {
      final tail = buildSpeakerQueueTail(
        state(queue, 0),
        const ResolvedSong(url: 'http://x/y.mp3', title: '歌乙', artist: '歌手乙'),
      );
      expect(tail.map((e) => e.title), ['歌丙', '歌丁']);
    });

    test('点播歌在队列末尾 → 无续播', () {
      final tail = buildSpeakerQueueTail(
        state(queue, 0),
        const ResolvedSong(url: 'http://x/y.mp3', title: '歌丁', artist: '歌手丁'),
      );
      expect(tail, isEmpty);
    });

    test('点播歌不在队列中 → 从队列当前项起顺延（含当前项）', () {
      final tail = buildSpeakerQueueTail(
        state(queue, 1),
        const ResolvedSong(url: 'http://x/y.mp3', title: '歌外', artist: '歌手外'),
      );
      expect(tail.map((e) => e.title), ['歌乙', '歌丙', '歌丁']);
    });

    test('点播歌只在当前项之前（已播过）→ 按不在队列处理，从当前项顺延', () {
      final tail = buildSpeakerQueueTail(
        state(queue, 2),
        const ResolvedSong(url: 'http://x/y.mp3', title: '歌甲', artist: '歌手甲'),
      );
      expect(tail.map((e) => e.title), ['歌丙', '歌丁']);
    });

    test('队列为空 → 无续播', () {
      final tail = buildSpeakerQueueTail(
        state(const [], -1),
        const ResolvedSong(url: 'http://x/y.mp3', title: '歌甲', artist: '歌手甲'),
      );
      expect(tail, isEmpty);
    });
  });
}

ConversationRecord _record(String query, {int timeMs = 0}) {
  return ConversationRecord(timeMs: timeMs, query: query, answers: const []);
}

/// 按 100ms 步进推进假时钟并泵微任务，直到走完 [total]。
Future<void> _elapse(FakeTakeoverClock clock, Duration total) async {
  var remaining = total;
  const step = Duration(milliseconds: 100);
  while (remaining > Duration.zero) {
    final d = remaining < step ? remaining : step;
    clock.advance(d);
    await pumpMicrotasks(12);
    remaining -= d;
  }
  await pumpMicrotasks();
}

class _Harness {
  _Harness({required List<SpeakerQueueItem> Function(ResolvedSong) tailFor}) {
    clock = FakeTakeoverClock();
    gateway = FakeSpeakerGateway(clock);
    store = FakeTakeoverMuteStore();
    resolver = FakeSpeakerResolver();
    resolver.result = const ResolvedSong(
      url: 'http://example.com/a.mp3',
      title: '歌A',
      artist: '歌手A',
      durationMs: 3000,
    );
    proxy = FakeStreamProxy()..autoFetched = true;
    quiet = TakeoverQuiet(
      gateway: gateway,
      clock: clock,
      store: store,
      deviceId: 'device-1',
      onLog: logs.add,
    );
    engine = TakeoverEngine(
      gateway: gateway,
      clock: clock,
      device: fakeDevice(),
      quiet: quiet,
      onTakeoverRecord: records.add,
      onNowPlayingChanged: (np) => nowPlaying = np,
      onLog: logs.add,
    );
    dispatcher = TakeoverDispatcher(
      engine: engine,
      resolver: resolver,
      streamProxy: proxy,
      clock: clock,
      queueTailProvider: tailFor,
      onTakeoverRecord: records.add,
      onLog: logs.add,
    );
  }

  late final FakeTakeoverClock clock;
  late final FakeSpeakerGateway gateway;
  late final FakeTakeoverMuteStore store;
  late final FakeSpeakerResolver resolver;
  late final FakeStreamProxy proxy;
  late final TakeoverQuiet quiet;
  late final TakeoverEngine engine;
  late final TakeoverDispatcher dispatcher;
  final List<TakeoverRecord> records = [];
  final List<String> logs = [];
  SpeakerNowPlaying? nowPlaying;
}

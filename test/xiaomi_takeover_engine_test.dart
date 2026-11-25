import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/dispatch.dart';
import 'package:muyin_music/core/xiaomi/takeover/quiet.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_resolver.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_engine.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_state.dart';

import 'xiaomi_takeover_test_utils.dart';

/// TrackFerry 整体移植后的引擎/分发行为测试。
///
/// 对照蓝本用例：quiet_test（找不到歌也恢复音量、两次 Quiet
/// 只归还一次）、takeover_test（静音→停播→推流→确认→恢复的
/// 步序、播完停循环、从头重播的收尾、外来播放收尾不动它）、
/// control_test（静音持有中改音量只改落盘）。
void main() {
  group('TakeoverDispatcher + TakeoverEngine', () {
    test('点歌先 Quiet：解析未返回时静音已下发（Quiet 先行）', () async {
      final h = _Harness();
      final gate = Completer<ResolvedSong?>();
      h.resolver.handler = (_) => gate.future;
      final handle = FakeStreamHandle(
        url: 'http://192.168.50.10:18761/stream/t.mp3',
      )..fetchedValue = true;
      h.proxy.nextHandle = handle;

      final done = h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
      await pumpMicrotasks();
      // 解析还堵着，静音与落盘已经完成。
      expect(h.gateway.callNames, contains('setVolume'));
      expect(
        h.gateway.calls.firstWhere((c) => c.name == 'setVolume').detail,
        '0',
      );
      expect(h.store.values['device-1'], 30);

      gate.complete(h.resolver.result);
      await done;
      // 守卫跑满 8 秒窗口才落结局（蓝本 guard 全程守）。
      await _elapse(h.clock, const Duration(seconds: 10));
      expect(h.records, hasLength(1));
      expect(h.records.single.success, isTrue);
      expect(h.records.single.detail, contains('已播放'));
      // 确认后恢复原音量、落盘清除。
      expect(h.store.values.containsKey('device-1'), isFalse);
      expect(
        h.gateway.calls.where((c) => c.name == 'setVolume').last.detail,
        '30',
      );
    });

    test('落盘待恢复音量已存在：Quiet 仍重发 setVolume(0) 且不读状态，'
        '解析未返回时已下发（蓝本 quiet.go pending 分支）', () async {
      final h = _Harness();
      // 上一轮/上个进程残留的待恢复音量；音箱此刻实际音量未知，
      // 落盘值不证明它在 0——Quiet 必须重新压一次。
      h.store.values['device-1'] = 25;
      final gate = Completer<ResolvedSong?>();
      h.resolver.handler = (_) => gate.future;
      h.proxy.nextHandle = FakeStreamHandle(
        url: 'http://192.168.50.10:18761/stream/t.mp3',
      )..fetchedValue = true;

      final done = h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
      await pumpMicrotasks();
      // 解析还堵着：重发的 setVolume(0) 已下发，且全程没有读状态
      // （pending 路径只有这一次网络往返，蓝本量级）。
      expect(h.gateway.callNames, ['setVolume']);
      expect(h.gateway.calls.single.detail, '0');
      // 恢复目标仍是落盘的 25，没有被覆盖。
      expect(h.store.values['device-1'], 25);

      gate.complete(h.resolver.result);
      await done;
      await _elapse(h.clock, const Duration(seconds: 10));
      expect(h.records.single.success, isTrue);
      // 结局恢复的是落盘的 25，落盘清除。
      expect(
        h.gateway.calls.where((c) => c.name == 'setVolume').last.detail,
        '25',
      );
      expect(h.store.values.containsKey('device-1'), isFalse);
    });

    test('步序：status/mute/stop1 → settle → stop2 → play（蓝本步序）', () async {
      final h = _Harness();
      h.proxy.nextHandle = FakeStreamHandle(
        url: 'http://192.168.50.10:18761/stream/t.mp3',
      )..fetchedValue = true;
      await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
      await _elapse(h.clock, const Duration(seconds: 10));
      final names = h.gateway.callNames;
      final playAt = names.indexOf('playMusic');
      expect(playAt, greaterThan(0));
      // play 之前至少有两轮 stop（stop1 与 stop2）。
      expect(
        names.sublist(0, playAt).where((n) => n == 'stop').length,
        greaterThanOrEqualTo(2),
      );
      expect(h.records.single.success, isTrue);
    });

    test('找不到歌：quiet run 压住不出声，20 秒后恢复音量', () async {
      final h = _Harness();
      h.resolver.result = null;
      await h.dispatcher.onCommand(_record('播放歌曲不存在的歌'), 0);
      await _elapse(h.clock, const Duration(seconds: 2));
      expect(h.gateway.callNames, isNot(contains('playMusic')));
      expect(h.gateway.callNames, isNot(contains('playUrl')));
      expect(h.records, hasLength(1));
      expect(h.records.single.success, isFalse);
      expect(h.records.single.detail, contains('没有出声'));
      // 20 秒静默期满才恢复。
      expect(h.store.values['device-1'], 30);
      await _elapse(h.clock, const Duration(seconds: 21));
      expect(h.store.values.containsKey('device-1'), isFalse);
      expect(
        h.gateway.calls.where((c) => c.name == 'setVolume').last.detail,
        '30',
      );
    });

    test('取流 + 在播即确认：position 为 -1 也算数（蓝本实证）', () async {
      final h = _Harness();
      h.gateway.fallbackStatus = const MinaPlayerStatus(
        statusCode: 1,
        volume: 30,
        positionMs: -1,
        durationMs: 269000,
      );
      h.proxy.nextHandle = FakeStreamHandle(
        url: 'http://192.168.50.10:18761/stream/t.mp3',
      )..fetchedValue = true;
      await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
      await _elapse(h.clock, const Duration(seconds: 10));
      expect(h.records.single.success, isTrue);
      expect(h.records.single.detail, contains('已播放'));
    });

    test('守卫：外来媒体抢播 → 停掉重推，重推后确认', () async {
      final h = _Harness();
      var foreign = false;
      h.gateway.statusFn = () => foreign
          ? const MinaPlayerStatus(
              statusCode: 1,
              volume: 30,
              positionMs: 100,
              durationMs: 200000,
              audioId: '999999',
            )
          : h.gateway.fallbackStatus;
      h.proxy.nextHandle = FakeStreamHandle(
        url: 'http://192.168.50.10:18761/stream/t.mp3',
      )..fetchedValue = true;
      await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
      // 推流刚完成（settle 600ms + stop2），进入守卫后切外来。
      await _elapse(h.clock, const Duration(milliseconds: 900));
      foreign = true;
      await _elapse(h.clock, const Duration(seconds: 1));
      foreign = false;
      await _elapse(h.clock, const Duration(seconds: 9));
      final plays = h.gateway.calls.where((c) => c.name == 'playMusic').length;
      expect(plays, greaterThanOrEqualTo(2)); // 原推 + 重推
      expect(h.records.single.success, isTrue);
    });

    test('过时指令（迟到 >2 分钟）只记录不执行', () async {
      final h = _Harness();
      await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天', timeMs: 0), 200000);
      await _elapse(h.clock, const Duration(seconds: 1));
      expect(h.gateway.calls, isEmpty);
      expect(h.records, isEmpty);
    });

    test('备歌失败（发布流失败）交回小爱并记失败', () async {
      final h = _Harness();
      h.proxy.publishFails = true;
      await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
      await _elapse(h.clock, const Duration(seconds: 1));
      expect(h.gateway.callNames, isNot(contains('playMusic')));
      expect(h.records, hasLength(1));
      expect(h.records.single.success, isFalse);
      expect(h.records.single.detail, contains('准备音频失败'));
      // Quiet 已归还：音量恢复。
      expect(h.store.values.containsKey('device-1'), isFalse);
    });
  });

  group('watch 收尾（stop-loop）', () {
    test('歌播完音箱从头循环 → 停掉循环（蓝本 StopsTheRepeat）', () async {
      final h = _Harness();
      h.resolver.result = const ResolvedSong(
        url: 'http://example.com/short.mp3',
        title: '短歌',
        artist: '歌手',
        durationMs: 3000,
      );
      h.proxy.nextHandle =
          FakeStreamHandle(
            url: 'http://192.168.50.10:18761/stream/t.mp3',
            lengthMs: 3000,
          )..fetchedValue = true;
      await h.dispatcher.onCommand(_record('播放歌曲短歌'), 0);
      await _elapse(h.clock, const Duration(seconds: 16));
      expect(h.records.single.success, isTrue);
      final names = h.gateway.callNames;
      final playAt = names.indexOf('playMusic');
      // 播放之后出现收尾的 stop（停循环），且没有再推第二遍。
      expect(
        names.sublist(playAt + 1).where((n) => n == 'stop').length,
        greaterThanOrEqualTo(1),
      );
      expect(names.where((n) => n == 'playMusic').length, 1);
    });

    test('收尾时是外来媒体在播 → 不动它（蓝本 LeavesOtherPlaybackAlone）', () async {
      final h = _Harness();
      h.resolver.result = const ResolvedSong(
        url: 'http://example.com/short.mp3',
        title: '短歌',
        artist: '歌手',
        durationMs: 3000,
      );
      h.proxy.nextHandle =
          FakeStreamHandle(
            url: 'http://192.168.50.10:18761/stream/t.mp3',
            lengthMs: 3000,
          )..fetchedValue = true;
      await h.dispatcher.onCommand(_record('播放歌曲短歌'), 0);
      // 守卫跑满（8 秒）进入 watch 后，再切换成外来媒体：
      // watch 收尾时不应动它。
      await _elapse(h.clock, const Duration(seconds: 11));
      h.gateway.statusFn = () => const MinaPlayerStatus(
        statusCode: 1,
        volume: 30,
        positionMs: 100,
        durationMs: 200000,
        audioId: '888888',
      );
      final stopsBefore = h.gateway.calls.where((c) => c.name == 'stop').length;
      await _elapse(h.clock, const Duration(seconds: 8));
      final stopsAfter = h.gateway.calls.where((c) => c.name == 'stop').length;
      expect(stopsAfter, stopsBefore);
    });
  });

  group('队列推进', () {
    test('播完自动接下一首（turn 推进），队列耗尽收尾', () async {
      final h = _Harness(
        queueTail: const [
          SpeakerQueueItem(title: '歌B', artist: '歌手B', durationMs: 3000),
        ],
      );
      h.resolver.result = const ResolvedSong(
        url: 'http://example.com/a.mp3',
        title: '歌A',
        artist: '歌手A',
        durationMs: 3000,
      );
      h.resolver.byKeyword['歌B'] = const ResolvedSong(
        url: 'http://example.com/b.mp3',
        title: '歌B',
        artist: '歌手B',
        durationMs: 3000,
      );
      h.proxy.nextHandle =
          FakeStreamHandle(
            url: 'http://192.168.50.10:18761/stream/a.mp3',
            lengthMs: 3000,
          )..fetchedValue = true;
      h.proxy.autoFetched = true; // B 的句柄同样已取流
      await h.dispatcher.onCommand(_record('播放歌曲歌A'), 0);
      // A：守卫 8s + watch 3s 播完 → 推进 B：守卫 8s 后上报正在播放。
      await _elapse(h.clock, const Duration(seconds: 28));
      // A 播完后 B 被推上（第二次 publish + playMusic）。
      expect(h.proxy.publishedUrls, contains('http://example.com/b.mp3'));
      expect(
        h.gateway.calls.where((c) => c.name == 'playMusic').length,
        greaterThanOrEqualTo(2),
      );
      expect(h.nowPlaying?.queueIndex, 1);
      expect(h.nowPlaying?.queueLength, 2);
    });

    test('无队列时「下一首」交回小爱，不下发播放', () async {
      final h = _Harness();
      await h.dispatcher.onCommand(_record('下一首'), 0);
      await _elapse(h.clock, const Duration(seconds: 1));
      expect(h.gateway.callNames, isNot(contains('playMusic')));
      expect(h.gateway.callNames, isNot(contains('playUrl')));
    });
  });

  group('音量与自愈', () {
    test('静音持有中设音量只改落盘，不动音箱（蓝本 control 语义）', () async {
      final h = _Harness();
      final unquiet = h.engine.quiet();
      await pumpMicrotasks();
      expect(h.store.values['device-1'], 30);
      await h.dispatcher.onCommand(_record('音量设为50'), 0);
      expect(h.store.values['device-1'], 50);
      expect(
        h.gateway.calls.where((c) => c.name == 'setVolume' && c.detail == '50'),
        isEmpty,
      );
      unquiet(true);
      await pumpMicrotasks();
      // 归还时恢复的是改后的 50。
      expect(
        h.gateway.calls.where((c) => c.name == 'setVolume').last.detail,
        '50',
      );
      expect(h.store.values.containsKey('device-1'), isFalse);
    });

    test('RecoverVolumes：音量还 0 着 → 设回落盘值并清除', () async {
      final h = _Harness();
      h.store.values['device-1'] = 25;
      h.gateway.fallbackStatus = const MinaPlayerStatus(
        statusCode: 0,
        volume: 0,
      );
      await h.engine.recoverVolumesOnce();
      expect(h.store.values.containsKey('device-1'), isFalse);
      expect(
        h.gateway.calls.where((c) => c.name == 'setVolume').single.detail,
        '25',
      );
    });

    test('RecoverVolumes：音量已非 0 → 只清落盘', () async {
      final h = _Harness();
      h.store.values['device-1'] = 25;
      h.gateway.fallbackStatus = const MinaPlayerStatus(
        statusCode: 0,
        volume: 40,
      );
      await h.engine.recoverVolumesOnce();
      expect(h.store.values.containsKey('device-1'), isFalse);
      expect(h.gateway.calls.where((c) => c.name == 'setVolume'), isEmpty);
    });

    test('RecoverVolumes：被 quiet 持有时跳过', () async {
      final h = _Harness();
      final unquiet = h.engine.quiet();
      await pumpMicrotasks();
      h.gateway.calls.clear();
      await h.engine.recoverVolumesOnce();
      expect(h.gateway.calls.where((c) => c.name == 'setVolume'), isEmpty);
      unquiet(true);
      await pumpMicrotasks();
    });

    test('两次 Quiet 只归还一次（蓝本 TwoQuietsGiveBackOnce）', () async {
      final h = _Harness();
      final first = h.engine.quiet();
      await pumpMicrotasks();
      final second = h.engine.quiet();
      await pumpMicrotasks();
      first(true);
      await pumpMicrotasks();
      // 第一次归还不恢复（第二个还持有）。
      expect(h.store.values['device-1'], 30);
      second(true);
      await pumpMicrotasks();
      expect(h.store.values.containsKey('device-1'), isFalse);
      final restores = h.gateway.calls
          .where((c) => c.name == 'setVolume' && c.detail == '30')
          .length;
      expect(restores, 1);
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
  _Harness({List<SpeakerQueueItem> queueTail = const []}) : _queueTail = queueTail {
    clock = FakeTakeoverClock();
    gateway = FakeSpeakerGateway(clock);
    store = FakeTakeoverMuteStore();
    resolver = FakeSpeakerResolver();
    proxy = FakeStreamProxy();
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
      queueTailProvider: (_) => _queueTail,
      onTakeoverRecord: records.add,
      onLog: logs.add,
    );
  }

  final List<SpeakerQueueItem> _queueTail;
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

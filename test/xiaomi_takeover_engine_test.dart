import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_constants.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_intent.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_stream_proxy.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_resolver.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_engine.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_state.dart';

import 'xiaomi_takeover_test_utils.dart';

/// 假流代理：publish 返回固定代理 URL（或 null 模拟不可用），
/// wasFetched 可控。
class FakeStreamProxy implements SpeakerStreamProxy {
  FakeStreamProxy({this.publishResult, this.fetched = false});

  final String? publishResult;
  bool fetched;
  final List<String> publishedUpstreams = [];

  @override
  Future<String?> publish(String upstreamUrl) async {
    publishedUpstreams.add(upstreamUrl);
    return publishResult;
  }

  @override
  bool wasFetched(String pushUrl) => fetched;
}

/// 归属为我们的在播采样。
MinaPlayerStatus oursPlaying(int positionMs) => MinaPlayerStatus(
  statusCode: 1,
  volume: 30,
  positionMs: positionMs,
  durationMs: 200000,
  audioId: kDefaultMusicAudioId,
);

/// 原生小爱在播的采样（外来 audio_id）。
MinaPlayerStatus foreignPlaying(int positionMs) => MinaPlayerStatus(
  statusCode: 1,
  volume: 30,
  positionMs: positionMs,
  durationMs: 200000,
  audioId: '9999999999999999999',
);

/// 驱动点歌流程跑完：假时钟逐格推进，直到 future 完成。
Future<bool> driveIntent(Future<bool> future, FakeTakeoverClock clock) async {
  var done = false;
  bool? result;
  future.then((v) {
    done = true;
    result = v;
  });
  for (var i = 0; i < 300 && !done; i++) {
    await pumpMicrotasks();
    if (!done && clock.hasPendingSleeps) {
      clock.advance(const Duration(milliseconds: 350));
    }
  }
  await pumpMicrotasks();
  expect(done, isTrue, reason: 'handleIntent 未在预期步数内返回');
  return result!;
}

List<String> setVolumeDetails(FakeSpeakerGateway gateway) => [
  for (final c in gateway.calls.where((c) => c.name == 'setVolume')) c.detail!,
];

void main() {
  group('TakeoverEngine 点歌时序', () {
    test('发现即 halt → 解析 → settle 后第二轮 halt → 推播 → 验证 → 守卫 → 记录成功', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      // 推播验证脚本：首采样 position 已达 5000 → 首帧即落地。
      gateway.statusQueue.add(oursPlaying(5000));
      final resolver = FakeSpeakerResolver();
      final records = <TakeoverRecord>[];
      SpeakerNowPlaying? nowPlaying;
      var nowPlayingEvents = 0;
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: resolver,
        device: fakeDevice(),
        onTakeoverRecord: records.add,
        onNowPlayingChanged: (np) {
          nowPlaying = np;
          nowPlayingEvents++;
        },
      );

      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      await pumpMicrotasks();
      // 第一轮 halt 已发出（pause 与 stop 并发），卡在 settle 补睡上。
      expect(gateway.callNames, ['pause', 'stop']);
      expect(gateway.calls[0].atMs, 0);

      clock.advance(const Duration(milliseconds: 600));
      await pumpMicrotasks();
      expect(await driveIntent(future, clock), isTrue);

      final names = gateway.callNames;
      expect(names.sublist(0, 4), ['pause', 'stop', 'pause', 'stop']);
      expect(gateway.calls[2].atMs, 600); // 第二轮在 Settle 600ms 后
      expect(names[4], 'playMusic'); // LX06 走 playMusic
      expect(gateway.calls[4].detail, 'http://example.com/song.mp3');
      expect(names.sublist(5), contains('status')); // 推后回读验证/守卫

      expect(records, hasLength(1));
      expect(records.single.success, isTrue);
      expect(records.single.title, '晴天');
      expect(engine.hasActiveRelay, isTrue);
      expect(nowPlayingEvents, greaterThan(0));
      expect(nowPlaying?.title, '晴天');
    });

    test('解析未命中：只压制一轮不推播，记录失败', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final resolver = FakeSpeakerResolver()..result = null;
      final records = <TakeoverRecord>[];
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: resolver,
        device: fakeDevice(),
        onTakeoverRecord: records.add,
      );
      final future = engine.handleIntent(
        const PlaySongIntent('播放不存在的歌', keyword: '不存在的歌', title: '不存在的歌'),
      );
      expect(await driveIntent(future, clock), isTrue);
      expect(gateway.callNames, ['pause', 'stop']);
      expect(records.single.success, isFalse);
      expect(records.single.detail, '未找到可播版本');
      expect(engine.hasActiveRelay, isFalse);
    });

    test('解析出非 MP3 直链：视为未命中，不推播', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final resolver = FakeSpeakerResolver()
        ..result = const ResolvedSong(
          url: 'http://example.com/song.flac',
          title: '晴天',
          artist: '周杰伦',
        );
      final records = <TakeoverRecord>[];
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: resolver,
        device: fakeDevice(),
        onTakeoverRecord: records.add,
      );
      final future = engine.handleIntent(
        const PlaySongIntent('播放晴天', keyword: '晴天', title: '晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);
      expect(gateway.callNames, isNot(contains('playMusic')));
      expect(records.single.success, isFalse);
    });
  });

  group('TakeoverEngine 代理推播', () {
    test('注入假 proxy：推代理 URL，记录 viaProxy=true 且 fetched 随 wasFetched', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final proxy = FakeStreamProxy(
        publishResult: 'http://192.168.1.9:18761/stream/abc.mp3',
        fetched: true,
      );
      final records = <TakeoverRecord>[];
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: FakeSpeakerResolver(),
        device: fakeDevice(),
        streamProxy: proxy,
        onTakeoverRecord: records.add,
      );
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);

      expect(proxy.publishedUpstreams, ['http://example.com/song.mp3']);
      final pushCall = gateway.calls.singleWhere((c) => c.name == 'playMusic');
      expect(pushCall.detail, 'http://192.168.1.9:18761/stream/abc.mp3');
      expect(records.single.success, isTrue);
      expect(records.single.viaProxy, isTrue);
      expect(records.single.fetched, isTrue);
      expect(records.single.upstreamHostPath, 'example.com/song.mp3');
    });

    test('proxy publish 返回 null：直推上游 URL，记录 viaProxy=false', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.add(oursPlaying(5000));
      final proxy = FakeStreamProxy(publishResult: null);
      final records = <TakeoverRecord>[];
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: FakeSpeakerResolver(),
        device: fakeDevice(),
        streamProxy: proxy,
        onTakeoverRecord: records.add,
      );
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);

      final pushCall = gateway.calls.singleWhere((c) => c.name == 'playMusic');
      expect(pushCall.detail, 'http://example.com/song.mp3');
      expect(records.single.success, isTrue);
      expect(records.single.viaProxy, isFalse);
      expect(records.single.fetched, isFalse);
    });
  });

  group('TakeoverEngine 身份门与守卫', () {
    test('验证采样是原生在播（position 已推进）：身份门判未落地', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      // 没有身份门时这帧 position=5000 会被判落地。
      gateway.statusQueue.add(foreignPlaying(5000));
      gateway.fallbackStatus = foreignPlaying(6000);
      final records = <TakeoverRecord>[];
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: FakeSpeakerResolver(),
        device: fakeDevice(),
        onTakeoverRecord: records.add,
      );
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);
      expect(records.single.success, isFalse);
      expect(records.single.detail, '被原生抢播');
      expect(engine.hasActiveRelay, isFalse);
    });

    test('守卫期被原生抢播：halt + 重推同一 URL，抢回后记录成功', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.addAll([
        oursPlaying(5000), // 验证落地
        foreignPlaying(100), // 守卫首轮：原生抢播
      ]);
      final records = <TakeoverRecord>[];
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: FakeSpeakerResolver(),
        device: fakeDevice(),
        onTakeoverRecord: records.add,
      );
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);
      final pushes = gateway.calls.where((c) => c.name == 'playMusic').toList();
      expect(pushes, hasLength(2)); // 首推 + 守卫重推
      expect(pushes[1].detail, 'http://example.com/song.mp3');
      expect(records.single.success, isTrue);
      expect(engine.hasActiveRelay, isTrue);
    });

    test('守卫重推 2 次仍被抢：记录「被原生抢回」，不进接力', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.add(oursPlaying(5000)); // 验证落地
      gateway.fallbackStatus = foreignPlaying(500); // 之后全是原生在播
      final records = <TakeoverRecord>[];
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: FakeSpeakerResolver(),
        device: fakeDevice(),
        onTakeoverRecord: records.add,
      );
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);
      final pushes = gateway.calls.where((c) => c.name == 'playMusic').toList();
      expect(pushes, hasLength(3)); // 首推 + MaxReplays 2 次重推
      expect(records.single.success, isFalse);
      expect(records.single.detail, '被原生抢回');
      expect(engine.hasActiveRelay, isFalse);
    });
  });

  group('TakeoverEngine 正证据判定（经代理）', () {
    TakeoverEngine buildProxyEngine(
      FakeSpeakerGateway gateway,
      FakeTakeoverClock clock,
      FakeStreamProxy proxy,
      List<TakeoverRecord> records,
    ) {
      return TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: FakeSpeakerResolver(),
        device: fakeDevice(),
        streamProxy: proxy,
        onTakeoverRecord: records.add,
      );
    }

    test('在播但未取流（原生抢先起播、audio_id 为空）→ 记录「被原生抢播」', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      // 原生在播形态：position 5000 一路在播，但从没取我们的流。
      gateway.fallbackStatus = const MinaPlayerStatus(
        statusCode: 1,
        volume: 30,
        positionMs: 5000,
        durationMs: 200000,
      );
      final proxy = FakeStreamProxy(
        publishResult: 'http://192.168.1.9:18761/stream/abc.mp3',
        fetched: false,
      );
      final records = <TakeoverRecord>[];
      final engine = buildProxyEngine(gateway, clock, proxy, records);
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);
      expect(records.single.success, isFalse);
      expect(records.single.detail, '被原生抢播');
      expect(records.single.fetched, isFalse);
      expect(engine.hasActiveRelay, isFalse);
    });

    test('从未取流且不在播 → 记录「推送未被取流」', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.fallbackStatus = const MinaPlayerStatus(
        statusCode: 0,
        volume: 30,
      );
      final proxy = FakeStreamProxy(
        publishResult: 'http://192.168.1.9:18761/stream/abc.mp3',
        fetched: false,
      );
      final records = <TakeoverRecord>[];
      final engine = buildProxyEngine(gateway, clock, proxy, records);
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);
      expect(records.single.success, isFalse);
      expect(records.single.detail, '推送未被取流');
    });

    test('fetched+在播且 position=-1 → 确认落地，记录带阶段耗时', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.fallbackStatus = const MinaPlayerStatus(
        statusCode: 1,
        volume: 30,
        positionMs: -1,
        durationMs: 200000,
      );
      final proxy = FakeStreamProxy(
        publishResult: 'http://192.168.1.9:18761/stream/abc.mp3',
        fetched: true,
      );
      final records = <TakeoverRecord>[];
      final engine = buildProxyEngine(gateway, clock, proxy, records);
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);
      expect(records.single.success, isTrue);
      expect(
        records.single.stageMs.keys,
        containsAll(['mute', 'resolve', 'push', 'confirm']),
      );
    });
  });

  group('TakeoverEngine 新指令取代旧流程', () {
    test('旧点歌卡在解析时被新点歌取代：旧流程不推播、不写记录', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.add(oursPlaying(5000)); // 新歌的验证采样
      final gate = Completer<ResolvedSong?>();
      final resolver = FakeSpeakerResolver()
        ..handler = (request) async {
          if (request.keyword == '慢歌') return gate.future;
          return const ResolvedSong(
            url: 'http://example.com/fast.mp3',
            title: '快歌',
            artist: '歌手乙',
            durationMs: 200000,
          );
        };
      final records = <TakeoverRecord>[];
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: resolver,
        device: fakeDevice(),
        onTakeoverRecord: records.add,
      );

      final futureA = engine.handleIntent(
        const PlaySongIntent('播放慢歌', keyword: '慢歌', title: '慢歌'),
      );
      await pumpMicrotasks();
      expect(gateway.callNames, ['pause', 'stop']); // A 已压制、卡在解析

      final futureB = engine.handleIntent(
        const PlaySongIntent('播放快歌', keyword: '快歌', title: '快歌'),
      );
      expect(await driveIntent(futureB, clock), isTrue);
      expect(records, hasLength(1));
      expect(records.single.title, '快歌');

      gate.complete(
        const ResolvedSong(
          url: 'http://example.com/slow.mp3',
          title: '慢歌',
          artist: '歌手甲',
        ),
      );
      expect(await driveIntent(futureA, clock), isTrue);
      expect(records, hasLength(1)); // A 不写记录
      expect(
        gateway.calls.where((c) => c.name == 'playMusic'),
        hasLength(1), // 只有 B 推过
      );
    });
  });

  group('TakeoverEngine 静音与恢复', () {
    TakeoverEngine buildMutedEngine(
      FakeSpeakerGateway gateway,
      FakeTakeoverClock clock,
      FakeTakeoverMuteStore store,
      List<TakeoverRecord> records, {
      SpeakerSongResolver? resolver,
    }) {
      return TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: resolver ?? FakeSpeakerResolver(),
        device: fakeDevice(),
        muteStore: store,
        onTakeoverRecord: records.add,
      );
    }

    test('点歌全程：先落盘再置 0，落地后恢复原音量并清落盘', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.addAll([
        const MinaPlayerStatus(statusCode: 2, volume: 30), // 静音读音量
        oursPlaying(5000), // 验证落地
      ]);
      final store = FakeTakeoverMuteStore();
      final records = <TakeoverRecord>[];
      final engine = buildMutedEngine(gateway, clock, store, records);
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);
      expect(setVolumeDetails(gateway), ['0', '30']);
      expect(store.values, isEmpty);
      expect(records.single.success, isTrue);
    });

    test('没找到歌：不立即恢复，保持静音 20s 后恢复（Quiet 口径）', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.add(
        const MinaPlayerStatus(statusCode: 2, volume: 30),
      );
      final store = FakeTakeoverMuteStore();
      final records = <TakeoverRecord>[];
      final engine = buildMutedEngine(
        gateway,
        clock,
        store,
        records,
        resolver: FakeSpeakerResolver()..result = null,
      );
      final future = engine.handleIntent(
        const PlaySongIntent('播放不存在的歌', keyword: '不存在的歌', title: '不存在的歌'),
      );
      expect(await driveIntent(future, clock), isTrue);
      expect(records.single.success, isFalse);
      // 流程已返回，但音量还压着、落盘还在。
      expect(setVolumeDetails(gateway), ['0']);
      expect(store.values['device-1'], 30);

      clock.advance(const Duration(seconds: 20));
      await pumpMicrotasks();
      expect(setVolumeDetails(gateway), ['0', '30']);
      expect(store.values, isEmpty);
    });

    test('已有落盘待恢复音量：沿用它恢复（inherited），不被当前音量覆盖', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.add(oursPlaying(5000)); // inherited 不读状态，直接给验证
      final store = FakeTakeoverMuteStore()..values['device-1'] = 45;
      final records = <TakeoverRecord>[];
      final engine = buildMutedEngine(gateway, clock, store, records);
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);
      expect(setVolumeDetails(gateway), ['0', '45']);
      expect(store.values, isEmpty);
      expect(records.single.success, isTrue);
    });

    test('静音持有期间的音量指令改恢复目标，不直接下发', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      // fallback 在播 position 恒 500：验证不会落地，流程停在采样期，
      // 正好是静音持有窗口。
      final store = FakeTakeoverMuteStore();
      final records = <TakeoverRecord>[];
      final engine = buildMutedEngine(gateway, clock, store, records);
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      await pumpMicrotasks();
      expect(store.values['device-1'], 30); // 已落盘
      expect(setVolumeDetails(gateway), ['0']);

      expect(
        await engine.handleIntent(const SetVolumeIntent('音量调到50', 50)),
        isTrue,
      );
      expect(store.values['device-1'], 50); // 改的是恢复目标
      expect(setVolumeDetails(gateway), ['0']); // 没有直接下发 50

      expect(await driveIntent(future, clock), isTrue);
      expect(records.single.success, isFalse); // position 不推进，未落地
      expect(setVolumeDetails(gateway), ['0', '50']); // 恢复的是新目标
      expect(store.values, isEmpty);
    });

    test('静音下发失败重试：第 2 次成功照常静音并恢复', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.addAll([
        const MinaPlayerStatus(statusCode: 2, volume: 30), // 静音读音量
        oursPlaying(5000), // 验证落地
      ]);
      gateway.setVolumeResults.addAll([false, true]); // 置 0 首败次成
      final store = FakeTakeoverMuteStore();
      final records = <TakeoverRecord>[];
      final engine = buildMutedEngine(gateway, clock, store, records);
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);
      expect(setVolumeDetails(gateway), ['0', '0', '30']);
      expect(records.single.success, isTrue);
      expect(store.values, isEmpty);
    });

    test('静音下发三次全败：记日志、不置静音持有，音量指令走直发', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.addAll([
        const MinaPlayerStatus(statusCode: 2, volume: 30), // 静音读音量
        oursPlaying(5000), // 验证落地（直推证据链）
      ]);
      gateway.setVolumeResult = false; // 所有 setVolume 都失败
      final store = FakeTakeoverMuteStore();
      final records = <TakeoverRecord>[];
      final logs = <String>[];
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: FakeSpeakerResolver(),
        device: fakeDevice(),
        muteStore: store,
        onTakeoverRecord: records.add,
        onLog: logs.add,
      );
      final future = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(future, clock), isTrue);
      expect(
        logs,
        contains('takeover mute failed: setVolume(0) not acknowledged'),
      );
      // 没持有静音：绝对音量指令直接下发，不去改恢复目标。
      final before = gateway.calls.length;
      await engine.handleIntent(const SetVolumeIntent('音量调到50', 50));
      final newSetVolumes = gateway.calls
          .skip(before)
          .where((c) => c.name == 'setVolume')
          .toList();
      expect(newSetVolumes, hasLength(1));
      expect(newSetVolumes.single.detail, '50');
    });

    test('已知音量（上一首顺手记的）→ 静音不再先读状态', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.fallbackStatus = null;
      gateway.statusQueue.addAll([
        const MinaPlayerStatus(statusCode: 2, volume: 30), // 首静音读音量
        oursPlaying(5000), // 首验证
      ]);
      final store = FakeTakeoverMuteStore();
      final records = <TakeoverRecord>[];
      final engine = buildMutedEngine(gateway, clock, store, records);
      final first = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(first, clock), isTrue);
      expect(records.single.success, isTrue);

      gateway.calls.clear();
      gateway.statusQueue.add(oursPlaying(5000)); // 次验证（唯一状态采样）
      final second = engine.handleIntent(
        const PlaySongIntent('播放周杰伦晴天', keyword: '周杰伦晴天', title: '周杰伦晴天'),
      );
      expect(await driveIntent(second, clock), isTrue);
      expect(records, hasLength(2));
      expect(records[1].success, isTrue);
      // 静音没抢先读状态：首个 status 采样发生在推播之后（验证）。
      final names = gateway.callNames;
      expect(names.indexOf('status'), greaterThan(names.indexOf('playMusic')));
      expect(setVolumeDetails(gateway), ['0', '30']);
    });
  });

  group('TakeoverEngine 控制指令', () {
    test('无接力时下一首不接管（交还原生）', () async {
      final clock = FakeTakeoverClock();
      final engine = TakeoverEngine(
        gateway: FakeSpeakerGateway(clock),
        clock: clock,
        resolver: FakeSpeakerResolver(),
        device: fakeDevice(),
      );
      expect(await engine.handleIntent(const NextIntent('下一首')), isFalse);
    });

    test('停止：停接力并 pause→stop 设备', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: FakeSpeakerResolver(),
        device: fakeDevice(),
      );
      expect(await engine.handleIntent(const StopIntent('停止播放')), isTrue);
      expect(gateway.callNames, ['pause', 'stop']);
    });

    test('音量步进：读当前音量 30 → 设为 40', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: FakeSpeakerResolver(),
        device: fakeDevice(),
      );
      expect(
        await engine.handleIntent(const VolumeStepIntent('大声一点', up: true)),
        isTrue,
      );
      final setCall = gateway.calls.singleWhere((c) => c.name == 'setVolume');
      expect(setCall.detail, '40');
    });

    test('音量绝对值直接下发', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final engine = TakeoverEngine(
        gateway: gateway,
        clock: clock,
        resolver: FakeSpeakerResolver(),
        device: fakeDevice(),
      );
      await engine.handleIntent(const SetVolumeIntent('音量调到50', 50));
      expect(gateway.calls.single.detail, '50');
    });
  });
}

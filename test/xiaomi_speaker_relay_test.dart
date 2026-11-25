import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_relay.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_resolver.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_stream_proxy.dart';

import 'xiaomi_takeover_test_utils.dart';

const songA = ResolvedSong(
  url: 'http://example.com/a.mp3',
  title: '晴天',
  artist: '周杰伦',
  durationMs: 60000,
);
const songB = ResolvedSong(
  url: 'http://example.com/b.mp3',
  title: '麻雀',
  artist: '李荣浩',
  durationMs: 300000,
);
const songC = ResolvedSong(
  url: 'http://example.com/c.mp3',
  title: '歌C',
  artist: '歌手C',
  durationMs: 300000,
);

SpeakerRelay buildRelay(
  FakeSpeakerGateway gateway,
  FakeTakeoverClock clock,
  FakeSpeakerResolver resolver, {
  void Function(RelayEndReason)? onEnded,
  SpeakerStreamProxy? streamProxy,
}) {
  return SpeakerRelay(
    gateway: gateway,
    clock: clock,
    resolver: resolver,
    deviceId: 'device-1',
    usePlayMusic: true,
    streamProxy: streamProxy,
    onSessionEnded: onEnded,
  );
}

/// 假流代理：publish 把上游 URL 换成固定代理 URL。
class FakeStreamProxy implements SpeakerStreamProxy {
  final List<String> publishedUpstreams = [];

  @override
  Future<String?> publish(String upstreamUrl) async {
    publishedUpstreams.add(upstreamUrl);
    return 'http://192.168.1.9:18761/stream/relay.mp3';
  }

  @override
  bool wasFetched(String pushUrl) => false;
}

Future<void> elapse(FakeTakeoverClock clock, int seconds) async {
  for (var i = 0; i < seconds; i++) {
    clock.advance(const Duration(seconds: 1));
    await pumpMicrotasks(10);
  }
}

void main() {
  group('SpeakerRelay 定时器推进', () {
    test('时长到点且设备进度已到尾 → 切下一首', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final resolver = FakeSpeakerResolver()
        ..byKeyword['李荣浩 麻雀'] = songB;
      // position 随墙钟推进（模拟真实播放）。
      gateway.statusFn = () => MinaPlayerStatus(
        statusCode: 1,
        positionMs: clock.nowMs(),
        durationMs: 60000,
      );
      final relay = buildRelay(gateway, clock, resolver);
      await relay.startWith(songA, const [
        SpeakerQueueItem(title: '麻雀', artist: '李荣浩', durationMs: 300000),
      ]);
      expect(relay.nowPlaying?.queueIndex, 0);

      await elapse(clock, 65);
      final pushes = gateway.calls.where((c) => c.name == 'playMusic').toList();
      expect(pushes, hasLength(1));
      expect(pushes.single.detail, 'http://example.com/b.mp3');
      expect(relay.nowPlaying?.queueIndex, 1);
      relay.stop();
    });
  });

  group('SpeakerRelay position 回零推进', () {
    test('position 曾 >10s 又跌回 <3s → 判定播完切歌', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final resolver = FakeSpeakerResolver()
        ..byKeyword['李荣浩 麻雀'] = songB;
      gateway.statusQueue.addAll(const [
        MinaPlayerStatus(statusCode: 1, positionMs: 5000),
        MinaPlayerStatus(statusCode: 1, positionMs: 12000),
        MinaPlayerStatus(statusCode: 1, positionMs: 1000),
        // 推播验证采样：position 已达 3000 量级 → 首帧即落地
        // （静态 500 在收紧判定下永不落地）。
        MinaPlayerStatus(statusCode: 1, positionMs: 5000, durationMs: 300000),
      ]);
      const noDuration = ResolvedSong(
        url: 'http://example.com/a.mp3',
        title: '晴天',
        artist: '周杰伦',
      );
      final relay = buildRelay(gateway, clock, resolver);
      await relay.startWith(noDuration, const [
        SpeakerQueueItem(title: '麻雀', artist: '李荣浩'),
      ]);
      // 时长未知 → 5s 探测间隔，三轮采样走完回零序列。
      await elapse(clock, 16);
      final pushes = gateway.calls.where((c) => c.name == 'playMusic').toList();
      expect(pushes, hasLength(1));
      expect(pushes.single.detail, 'http://example.com/b.mp3');
      expect(relay.nowPlaying?.queueIndex, 1);
      relay.stop();
    });
  });

  group('SpeakerRelay 代理推播', () {
    test('接力推播走代理 URL（上游直链只进 publish，不直推）', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.add(
        const MinaPlayerStatus(
          statusCode: 1,
          positionMs: 5000,
          durationMs: 300000,
        ),
      );
      final resolver = FakeSpeakerResolver()
        ..byKeyword['李荣浩 麻雀'] = songB;
      final proxy = FakeStreamProxy();
      final relay = buildRelay(gateway, clock, resolver, streamProxy: proxy);
      await relay.startWith(songA, const [
        SpeakerQueueItem(title: '麻雀', artist: '李荣浩'),
      ]);

      expect(await relay.next(), isTrue);
      expect(proxy.publishedUpstreams, ['http://example.com/b.mp3']);
      final pushes = gateway.calls.where((c) => c.name == 'playMusic').toList();
      expect(pushes, hasLength(1));
      expect(
        pushes.single.detail,
        'http://192.168.1.9:18761/stream/relay.mp3',
      );
      expect(relay.nowPlaying?.title, '麻雀');
      relay.stop();
    });
  });

  group('SpeakerRelay 外部停止感知', () {
    test('连续 2 次未播且 position 不推进 → 结束会话，不再推歌', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final resolver = FakeSpeakerResolver()
        ..byKeyword['李荣浩 麻雀'] = songB;
      RelayEndReason? endedReason;
      gateway.statusFn = () => const MinaPlayerStatus(
        statusCode: 2,
        positionMs: 20000,
        durationMs: 300000,
      );
      final relay = buildRelay(
        gateway,
        clock,
        resolver,
        onEnded: (r) => endedReason = r,
      );
      const longSong = ResolvedSong(
        url: 'http://example.com/a.mp3',
        title: '晴天',
        artist: '周杰伦',
        durationMs: 300000,
      );
      await relay.startWith(longSong, const [
        SpeakerQueueItem(title: '麻雀', artist: '李荣浩'),
      ]);
      // 时长已知且离结尾远 → 20s 校准间隔，两轮命中外部停止。
      await elapse(clock, 45);
      expect(endedReason, RelayEndReason.externalStop);
      expect(relay.isActive, isFalse);
      expect(gateway.callNames, isNot(contains('playMusic')));
    });
  });

  group('SpeakerRelay 身份门（外来 audio_id）', () {
    test('连续 2 次读到原生在播 → 按外部停止收尾', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final resolver = FakeSpeakerResolver()
        ..byKeyword['李荣浩 麻雀'] = songB;
      RelayEndReason? endedReason;
      gateway.statusFn = () => const MinaPlayerStatus(
        statusCode: 1,
        positionMs: 20000,
        durationMs: 300000,
        audioId: '9999999999999999999',
      );
      final relay = buildRelay(
        gateway,
        clock,
        resolver,
        onEnded: (r) => endedReason = r,
      );
      const longSong = ResolvedSong(
        url: 'http://example.com/a.mp3',
        title: '晴天',
        artist: '周杰伦',
        durationMs: 300000,
      );
      await relay.startWith(longSong, const [
        SpeakerQueueItem(title: '麻雀', artist: '李荣浩'),
      ]);
      // 20s 校准间隔：两轮外来采样命中身份门。
      await elapse(clock, 45);
      expect(endedReason, RelayEndReason.externalStop);
      expect(relay.isActive, isFalse);
      expect(gateway.callNames, isNot(contains('playMusic')));
    });

    test('外来采样的 position 不记账：不会被回零探测误判播完切歌', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final resolver = FakeSpeakerResolver()
        ..byKeyword['李荣浩 麻雀'] = songB;
      var foreign = true;
      gateway.statusFn = () => foreign
          ? const MinaPlayerStatus(
              statusCode: 1,
              positionMs: 50000,
              durationMs: 60000,
              audioId: '9999999999999999999',
            )
          : const MinaPlayerStatus(
              statusCode: 1,
              positionMs: 100,
              durationMs: 60000,
            );
      final relay = buildRelay(gateway, clock, resolver);
      await relay.startWith(songA, const [
        SpeakerQueueItem(title: '麻雀', artist: '李荣浩', durationMs: 300000),
      ]);
      // 第一轮校准读到外来 position=50000：若记账，下一轮我们的
      // position=100 会触发「曾 >10s 又跌回 <3s」的播完切歌。
      await elapse(clock, 6);
      foreign = false;
      await elapse(clock, 6);
      expect(relay.isActive, isTrue);
      expect(relay.nowPlaying?.queueIndex, 0);
      expect(gateway.callNames, isNot(contains('playMusic')));
      relay.stop();
    });
  });

  group('SpeakerRelay 手动上下首', () {
    test('next 顺序推进，播完结束；previous 回上一首（走缓存）', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final resolver = FakeSpeakerResolver()
        ..byKeyword['李荣浩 麻雀'] = songB
        ..byKeyword['歌手C 歌C'] = songC;
      RelayEndReason? endedReason;
      // 推播验证脚本：首采样 position 已达 3000 量级 → 首帧即落地
      // （静态 fallback 的 500 在收紧判定下永不落地）。共 4 次推播，
      // 校准循环也会消费采样，故多备几份。
      gateway.statusQueue.addAll([
        for (var i = 0; i < 12; i++)
          const MinaPlayerStatus(
            statusCode: 1,
            positionMs: 5000,
            durationMs: 300000,
          ),
      ]);
      final relay = buildRelay(
        gateway,
        clock,
        resolver,
        onEnded: (r) => endedReason = r,
      );
      await relay.startWith(songA, const [
        SpeakerQueueItem(title: '麻雀', artist: '李荣浩'),
        SpeakerQueueItem(title: '歌C', artist: '歌手C'),
      ]);

      expect(await relay.next(), isTrue);
      expect(relay.nowPlaying?.title, '麻雀');
      expect(await relay.previous(), isTrue);
      expect(relay.nowPlaying?.title, '晴天');
      // 回第一首走的是 startWith 的缓存，没有重新解析。
      expect(
        resolver.requests.where((r) => r.keyword == '周杰伦 晴天'),
        isEmpty,
      );

      expect(await relay.next(), isTrue); // 麻雀
      expect(await relay.next(), isTrue); // 歌C
      expect(await relay.next(), isFalse); // 到头
      expect(endedReason, RelayEndReason.queueFinished);
      expect(relay.isActive, isFalse);

      final pushedUrls = [
        for (final c in gateway.calls.where((c) => c.name == 'playMusic'))
          c.detail,
      ];
      expect(pushedUrls, [
        'http://example.com/b.mp3',
        'http://example.com/a.mp3',
        'http://example.com/b.mp3',
        'http://example.com/c.mp3',
      ]);
    });
  });
}

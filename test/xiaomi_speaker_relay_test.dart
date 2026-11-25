import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_relay.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_resolver.dart';

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
}) {
  return SpeakerRelay(
    gateway: gateway,
    clock: clock,
    resolver: resolver,
    deviceId: 'device-1',
    usePlayMusic: true,
    onSessionEnded: onEnded,
  );
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
        // 推播验证采样：
        MinaPlayerStatus(statusCode: 1, positionMs: 500, durationMs: 300000),
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

  group('SpeakerRelay 手动上下首', () {
    test('next 顺序推进，播完结束；previous 回上一首（走缓存）', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final resolver = FakeSpeakerResolver()
        ..byKeyword['李荣浩 麻雀'] = songB
        ..byKeyword['歌手C 歌C'] = songC;
      RelayEndReason? endedReason;
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

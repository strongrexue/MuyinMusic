import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_intent.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_resolver.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_engine.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_state.dart';

import 'xiaomi_takeover_test_utils.dart';

void main() {
  group('TakeoverEngine 点歌时序', () {
    test('pause→stop 两轮（间隔 600ms）→ 推播 → 回读验证 → 记录成功', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
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
      // 第一轮已发出，第二轮卡在 600ms 间隔上。
      expect(gateway.callNames, ['pause', 'stop']);
      expect(gateway.calls[0].atMs, 0);

      clock.advance(const Duration(milliseconds: 600));
      await pumpMicrotasks();
      expect(await future, isTrue);

      final names = gateway.callNames;
      expect(names.sublist(0, 4), ['pause', 'stop', 'pause', 'stop']);
      expect(gateway.calls[2].atMs, 600); // 第二轮在 600ms 后
      expect(names[4], 'playMusic'); // LX06 走 playMusic
      expect(gateway.calls[4].detail, 'http://example.com/song.mp3');
      expect(names.sublist(5), contains('status')); // 推后回读验证

      expect(records, hasLength(1));
      expect(records.single.success, isTrue);
      expect(records.single.title, '晴天');
      expect(engine.hasActiveRelay, isTrue);
      expect(nowPlayingEvents, greaterThan(0));
      expect(nowPlaying?.title, '晴天');
    });

    test('解析未命中：只压制不推播，记录失败', () async {
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
      await pumpMicrotasks();
      clock.advance(const Duration(milliseconds: 600));
      await pumpMicrotasks();
      expect(await future, isTrue);
      expect(gateway.callNames, ['pause', 'stop', 'pause', 'stop']);
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
      await pumpMicrotasks();
      clock.advance(const Duration(milliseconds: 600));
      await pumpMicrotasks();
      await future;
      expect(gateway.callNames, isNot(contains('playMusic')));
      expect(records.single.success, isFalse);
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

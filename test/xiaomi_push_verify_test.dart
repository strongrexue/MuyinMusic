import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_constants.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/push_verify.dart';

import 'xiaomi_takeover_test_utils.dart';

MinaPlayerStatus st(int? positionMs, {int statusCode = 1, String? audioId}) =>
    MinaPlayerStatus(
      statusCode: statusCode,
      positionMs: positionMs,
      audioId: audioId,
    );

/// 驱动 verifyPushLanded 跑完（假时钟逐格推进 sleep）。
Future<PushVerifyOutcome> driveVerify(
  Future<PushVerifyOutcome> future,
  FakeTakeoverClock clock,
) async {
  var done = false;
  PushVerifyOutcome? result;
  future.then((v) {
    done = true;
    result = v;
  });
  for (var i = 0; i < 60 && !done; i++) {
    await pumpMicrotasks();
    if (!done && clock.hasPendingSleeps) {
      clock.advance(const Duration(milliseconds: 1200));
    }
  }
  await pumpMicrotasks();
  expect(done, isTrue, reason: 'verifyPushLanded 未在预期步数内返回');
  return result!;
}

void main() {
  group('verifyPushLanded 直推回退（position 证据链）', () {
    test('首帧 status=1/position=0 多帧不推进 → unconfirmed', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)..fallbackStatus = st(0);
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1'),
        clock,
      );
      expect(result, PushVerifyOutcome.unconfirmed);
      // 8 次采样都跑满（没有被首帧 position=0 误判提前返回）。
      expect(gateway.callNames.where((n) => n == 'status').length, 8);
    });

    test('position 推进（500→1500）→ landed', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..statusQueue.addAll([st(500), st(1500)]);
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1'),
        clock,
      );
      expect(result, PushVerifyOutcome.landed);
    });

    test('position 单帧达 3000 → landed', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)..statusQueue.add(st(3000));
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1'),
        clock,
      );
      expect(result, PushVerifyOutcome.landed);
    });

    test('position 恒 null 连续 2 次 playing → landed', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..statusQueue.addAll([st(null), st(null)]);
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1'),
        clock,
      );
      expect(result, PushVerifyOutcome.landed);
    });

    test('归属为我们的 audio_id：position 推进照常判 landed', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..statusQueue.addAll([
          st(500, audioId: kDefaultMusicAudioId),
          st(1500, audioId: kDefaultMusicAudioId),
        ]);
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1'),
        clock,
      );
      expect(result, PushVerifyOutcome.landed);
    });
  });

  group('verifyPushLanded 正证据模型（经代理推播）', () {
    test('fetched+playing → landed（position 不动）', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)..fallbackStatus = st(100);
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1', fetchedSignal: () => true),
        clock,
      );
      expect(result, PushVerifyOutcome.landed);
    });

    test('fetched+playing 且 position=-1 → landed（不依赖 position 数值）', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)..fallbackStatus = st(-1);
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1', fetchedSignal: () => true),
        clock,
      );
      expect(result, PushVerifyOutcome.landed);
    });

    test('fetched+playing 且 position=null → landed', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)..fallbackStatus = st(null);
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1', fetchedSignal: () => true),
        clock,
      );
      expect(result, PushVerifyOutcome.landed);
    });

    test('在播但从未取流（原生抢先起播，audio_id 为空）→ foreignPlaying', () async {
      final clock = FakeTakeoverClock();
      // position 一路推进也救不了：正证据模型下没取流就不是我们的。
      final gateway = FakeSpeakerGateway(clock)..fallbackStatus = st(5000);
      final result = await driveVerify(
        verifyPushLanded(
          gateway,
          clock,
          'device-1',
          fetchedSignal: () => false,
        ),
        clock,
      );
      expect(result, PushVerifyOutcome.foreignPlaying);
      // 连续 2 次采样确认（留一帧宽限），不跑满 8 次。
      expect(gateway.callNames.where((n) => n == 'status').length, 2);
    });

    test('从未取流且不在播 → notFetched', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..fallbackStatus = st(0, statusCode: 0);
      final result = await driveVerify(
        verifyPushLanded(
          gateway,
          clock,
          'device-1',
          fetchedSignal: () => false,
        ),
        clock,
      );
      expect(result, PushVerifyOutcome.notFetched);
      expect(gateway.callNames.where((n) => n == 'status').length, 8);
    });

    test('fetched 为真但从不在播 → unconfirmed', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..fallbackStatus = st(100, statusCode: 2);
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1', fetchedSignal: () => true),
        clock,
      );
      expect(result, PushVerifyOutcome.unconfirmed);
    });

    test('fetched 后迟迟不确认 → 2.5s 后触发 onFetchedStale 一次', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        // 已取流但一直是暂停：不落地，采样跑满 8 次。
        ..fallbackStatus = st(100, statusCode: 2);
      var staleCalls = 0;
      final result = await driveVerify(
        verifyPushLanded(
          gateway,
          clock,
          'device-1',
          fetchedSignal: () => true,
          onFetchedStale: () => staleCalls++,
        ),
        clock,
      );
      expect(result, PushVerifyOutcome.unconfirmed);
      expect(staleCalls, 1);
    });
  });

  group('verifyPushLanded 身份门（audio_id 认人）', () {
    test('原生在播且 position 推进 → 立即 foreignPlaying，不等采样跑满', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..statusQueue.addAll([
          st(500, audioId: '9999999999999999999'),
          st(1500, audioId: '9999999999999999999'),
        ]);
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1'),
        clock,
      );
      expect(result, PushVerifyOutcome.foreignPlaying);
      // 首帧即判：只读了 1 次状态。
      expect(gateway.callNames.where((n) => n == 'status').length, 1);
    });

    test('fetched 已取流但在播的是原生 → foreignPlaying（双证也要认人）', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..fallbackStatus = st(100, audioId: '9999999999999999999');
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1', fetchedSignal: () => true),
        clock,
      );
      expect(result, PushVerifyOutcome.foreignPlaying);
    });
  });

  group('MinaPlayerStatus.tryParseInfo audio_id', () {
    Map<String, Object?> infoWith(Object? audioId) => {
      'info': jsonEncode({
        'status': 1,
        'volume': 30,
        'play_song_detail': {
          'position': 1200,
          'duration': 200000,
          'audio_id': ?audioId,
        },
      }),
    };

    test('数字型 audio_id 解析为字符串', () {
      final status = MinaPlayerStatus.tryParseInfo(
        infoWith(1732418460076477549),
      );
      expect(status?.audioId, kDefaultMusicAudioId);
      expect(status?.isForeignPlayback, isFalse);
    });

    test('字符串型外来 audio_id → isForeignPlayback', () {
      final status = MinaPlayerStatus.tryParseInfo(infoWith('42'));
      expect(status?.audioId, '42');
      expect(status?.isForeignPlayback, isTrue);
    });

    test('缺失/空 audio_id → null，不判外来', () {
      expect(MinaPlayerStatus.tryParseInfo(infoWith(null))?.audioId, isNull);
      expect(MinaPlayerStatus.tryParseInfo(infoWith(''))?.audioId, isNull);
      expect(
        MinaPlayerStatus.tryParseInfo(infoWith(''))?.isForeignPlayback,
        isFalse,
      );
    });
  });
}

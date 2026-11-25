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
Future<bool> driveVerify(
  Future<bool> future,
  FakeTakeoverClock clock,
) async {
  var done = false;
  bool? result;
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
  group('verifyPushLanded 收紧判定', () {
    test('首帧 status=1/position=0 多帧不推进 → false', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..fallbackStatus = st(0);
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1'),
        clock,
      );
      expect(result, isFalse);
      // 8 次采样都跑满（没有被首帧 position=0 误判提前返回）。
      expect(
        gateway.callNames.where((n) => n == 'status').length,
        8,
      );
    });

    test('position 推进（500→1500）→ true', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..statusQueue.addAll([st(500), st(1500)]);
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1'),
        clock,
      );
      expect(result, isTrue);
    });

    test('position 单帧达 3000 → true', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..statusQueue.add(st(3000));
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1'),
        clock,
      );
      expect(result, isTrue);
    });

    test('fetched+playing → true（position 不动）', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..fallbackStatus = st(100);
      final result = await driveVerify(
        verifyPushLanded(
          gateway,
          clock,
          'device-1',
          fetchedSignal: () => true,
        ),
        clock,
      );
      expect(result, isTrue);
    });

    test('fetched 为真但从不在播 → false', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..fallbackStatus = st(100, statusCode: 2);
      final result = await driveVerify(
        verifyPushLanded(
          gateway,
          clock,
          'device-1',
          fetchedSignal: () => true,
        ),
        clock,
      );
      expect(result, isFalse);
    });

    test('position 恒 null 连续 2 次 playing → true', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..statusQueue.addAll([st(null), st(null)]);
      final result = await driveVerify(
        verifyPushLanded(gateway, clock, 'device-1'),
        clock,
      );
      expect(result, isTrue);
    });
  });

  group('verifyPushLanded 身份门（audio_id 认人）', () {
    test('原生在播且 position 推进 → 立即 false，不等采样跑满', () async {
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
      expect(result, isFalse);
      // 首帧即判：只读了 1 次状态（没有身份门时第二帧推进会判 true）。
      expect(gateway.callNames.where((n) => n == 'status').length, 1);
    });

    test('归属为我们的 audio_id：position 推进照常判 true', () async {
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
      expect(result, isTrue);
    });

    test('fetched 已取流但在播的是原生 → false（双证也要认人）', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock)
        ..fallbackStatus = st(100, audioId: '9999999999999999999');
      final result = await driveVerify(
        verifyPushLanded(
          gateway,
          clock,
          'device-1',
          fetchedSignal: () => true,
        ),
        clock,
      );
      expect(result, isFalse);
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
      expect(result, isFalse);
      expect(staleCalls, 1);
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

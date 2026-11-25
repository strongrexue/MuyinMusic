import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/push_verify.dart';

import 'xiaomi_takeover_test_utils.dart';

MinaPlayerStatus st(int? positionMs, {int statusCode = 1}) =>
    MinaPlayerStatus(statusCode: statusCode, positionMs: positionMs);

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
}

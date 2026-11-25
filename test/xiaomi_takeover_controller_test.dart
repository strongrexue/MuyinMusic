import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/lan_stream_server.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_log.dart';
import 'package:muyin_music/core/xiaomi/takeover_providers.dart';
import 'package:muyin_music/core/xiaomi/xiaoai_foreground_host.dart';

import 'xiaomi_takeover_test_utils.dart';

/// 只测启动自检 recoverPendingVolumeOnStart，不走 enable 全流程
/// （不起监听/前台服务）。
XiaoaiTakeoverController buildController(
  FakeSpeakerGateway gateway,
  FakeTakeoverClock clock,
  FakeTakeoverMuteStore store, {
  TakeoverLogBuffer? diagnosticLog,
}) {
  return XiaoaiTakeoverController(
    gateway: gateway,
    resolver: FakeSpeakerResolver(),
    streamServer: LanStreamServer(),
    host: const XiaoaiForegroundHost(),
    queueTailProvider: (_) => const [],
    muteStore: store,
    diagnosticLog: diagnosticLog,
  );
}

void main() {
  group('XiaoaiTakeoverController 启动自检恢复静音', () {
    test('有待恢复音量且当前音量为 0 → 设回去并清落盘', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.add(const MinaPlayerStatus(statusCode: 2, volume: 0));
      final store = FakeTakeoverMuteStore()..values['device-1'] = 40;
      final controller = buildController(gateway, clock, store);

      await controller.recoverPendingVolumeOnStart(fakeDevice());

      final setCall = gateway.calls.singleWhere((c) => c.name == 'setVolume');
      expect(setCall.detail, '40');
      expect(store.values, isEmpty);
    });

    test('当前音量已 >0（被人调大）→ 只清落盘，不覆盖', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.add(
        const MinaPlayerStatus(statusCode: 1, volume: 25),
      );
      final store = FakeTakeoverMuteStore()..values['device-1'] = 40;
      final controller = buildController(gateway, clock, store);

      await controller.recoverPendingVolumeOnStart(fakeDevice());

      expect(gateway.callNames, isNot(contains('setVolume')));
      expect(store.values, isEmpty);
    });

    test('读不到状态 → 保留落盘，下次再试', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.add(null);
      final store = FakeTakeoverMuteStore()..values['device-1'] = 40;
      final controller = buildController(gateway, clock, store);

      await controller.recoverPendingVolumeOnStart(fakeDevice());

      expect(gateway.callNames, isNot(contains('setVolume')));
      expect(store.values['device-1'], 40);
    });

    test('无落盘 → 什么都不做', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      final store = FakeTakeoverMuteStore();
      final controller = buildController(gateway, clock, store);

      await controller.recoverPendingVolumeOnStart(fakeDevice());

      expect(gateway.calls, isEmpty);
    });

    test('控制器日志落缓冲并同步进状态（页面可见）', () async {
      final clock = FakeTakeoverClock();
      final gateway = FakeSpeakerGateway(clock);
      gateway.statusQueue.add(const MinaPlayerStatus(statusCode: 2, volume: 0));
      final store = FakeTakeoverMuteStore()..values['device-1'] = 40;
      final buffer = TakeoverLogBuffer(
        now: () => DateTime(2026, 11, 25, 16, 20, 5),
      );
      final controller = buildController(
        gateway,
        clock,
        store,
        diagnosticLog: buffer,
      );

      await controller.recoverPendingVolumeOnStart(fakeDevice());

      expect(buffer.entries, ['16:20:05 takeover recovered muted volume 40']);
      expect(controller.state.diagnosticLog, buffer.entries);
    });
  });
}

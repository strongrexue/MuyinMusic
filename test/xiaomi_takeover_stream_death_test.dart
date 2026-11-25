import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/dispatch.dart';
import 'package:muyin_music/core/xiaomi/takeover/quiet.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_stream_proxy.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_engine.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_state.dart';

import 'xiaomi_takeover_test_utils.dart';

/// 推播中途断流死亡（1.3.29《后来》实证）：上游连接中途断开、
/// 音箱取流失败停播（不在播、条目 lost），且没有人跟小爱说话
/// （talkedUntil 恒为 0）。旧 watch 的恢复分支只为谈话恢复而设，
/// 此场景够不到 again，只能躺平到 maxPause（15 分钟）；现在
/// lost + 不在播应在数秒内触发续推。
void main() {
  test('断流死亡（lost+不在播、无谈话）→ 数秒内从断点续推', () async {
    final h = _Harness();
    final resumedHandle = FakeStreamHandle(
      url: 'http://192.168.50.10:18761/stream/resumed.mp3',
      lengthMs: 269000,
    )..fetchedValue = true;
    final handle = _RecordingHandle(
      url: 'http://192.168.50.10:18761/stream/t.mp3',
    )..fetchedValue = true;
    handle.resumeResult = (handle: resumedHandle, startMs: 0);
    h.proxy.nextHandle = handle;

    await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
    await _elapse(h.clock, const Duration(seconds: 10));
    expect(h.records.single.success, isTrue);
    expect(h.engine.playing, isTrue);

    // 流死亡：条目 lost，音箱停播（status=2），无人说话。
    var dead = true;
    h.gateway.statusFn = () => dead
        ? const MinaPlayerStatus(statusCode: 2, volume: 30)
        : h.gateway.fallbackStatus;
    handle.lostValue = true;

    // 数秒内应续推（不是等满 maxPause）。
    await _elapse(h.clock, const Duration(seconds: 6));
    expect(handle.resumeAtMs, isNotNull);
    expect(handle.resumeAtMs!, greaterThan(1500));
    final plays = h.gateway.calls.where((c) => c.name == 'playMusic').toList();
    expect(plays, hasLength(2));
    expect(plays.last.detail, resumedHandle.url);
    expect(h.engine.playing, isTrue);
    expect(
      h.logs.any((l) => l.contains('takeover step resume ok')),
      isTrue,
    );

    // 续播后设备恢复在播：watch 继续跟随，不重复重推。
    dead = false;
    handle.lostValue = false;
    await _elapse(h.clock, const Duration(seconds: 3));
    expect(h.engine.playing, isTrue);
    expect(
      h.gateway.calls.where((c) => c.name == 'playMusic'),
      hasLength(2),
    );
  });

  test('断流死亡且 resume 不可用 → 从头重推原 URL', () async {
    final h = _Harness();
    final handle = _RecordingHandle(
      url: 'http://192.168.50.10:18761/stream/t.mp3',
    )..fetchedValue = true;
    handle.resumeResult = null; // 不可从中续播
    h.proxy.nextHandle = handle;

    await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
    await _elapse(h.clock, const Duration(seconds: 10));
    expect(h.engine.playing, isTrue);

    h.gateway.statusFn = () =>
        const MinaPlayerStatus(statusCode: 2, volume: 30);
    handle.lostValue = true;

    // again 退回从头重推：第二次推送同一 URL，run 继续跟随。
    await _elapse(h.clock, const Duration(seconds: 12));
    final plays = h.gateway.calls.where((c) => c.name == 'playMusic').toList();
    expect(plays, hasLength(2));
    expect(plays.last.detail, handle.url);
    expect(
      h.logs.any((l) => l.contains('resume') && l.contains('从头放')),
      isTrue,
    );
    expect(h.engine.playing, isTrue);
  });

  test('断流死亡且续推也失败 → 限定时间内收尾，不躺平', () async {
    final h = _Harness();
    final handle = _RecordingHandle(
      url: 'http://192.168.50.10:18761/stream/t.mp3',
    )..fetchedValue = true;
    handle.resumeResult = null;
    h.proxy.nextHandle = handle;

    await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
    await _elapse(h.clock, const Duration(seconds: 10));
    expect(h.engine.playing, isTrue);

    // 上游彻底不可用：设备停播 + lost，且续推的推送全部失败。
    h.gateway.statusFn = () =>
        const MinaPlayerStatus(statusCode: 2, volume: 30);
    handle.lostValue = true;
    h.gateway.playMusicResult = false;

    // again 重试耗尽后应 over 收尾（远小于 maxPause 的 15 分钟）。
    await _elapse(h.clock, const Duration(seconds: 15));
    expect(h.engine.playing, isFalse);
    expect(
      h.logs.any((l) => l.contains('takeover step resume fail')),
      isTrue,
    );
    expect(
      h.logs.any((l) => l.contains('没能接着放')),
      isTrue,
    );
  });

  test('时长已知：时钟判尾先于固件循环重取触发 finish', () async {
    final h = _Harness();
    final handle = FakeStreamHandle(
      url: 'http://192.168.50.10:18761/stream/t.mp3',
      lengthMs: 12000,
    )..fetchedValue = true;
    h.proxy.nextHandle = handle;

    await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
    await _elapse(h.clock, const Duration(seconds: 10));
    expect(h.engine.playing, isTrue);

    // 设备一直报在播、无 restarted：at() 越过 length+EndSlack
    // 后应由时钟判尾 finish（stop-loop 收尾），run 结束。
    await _elapse(h.clock, const Duration(seconds: 16));
    expect(h.engine.playing, isFalse);
    expect(h.logs.any((l) => l.contains('播完了')), isTrue);
    expect(h.logs.any((l) => l.contains('音箱又从头放了')), isFalse);
  });

  test('歌尾重取落在判尾 slack 窗口内 → restarted 先判尾、同一 finish 收尾', () async {
    final h = _Harness();
    // restarted 标志在 t=30500 翻转：at()≈30000 刚到歌尾、
    // 尚未越过 30s+1.5s 的时钟判尾线。此窗口内 restarted
    // 先触发 finish 是预期语义（与蓝本竞速同理）：断言 run
    // 被 finish 收尾（停止循环）、没有把重取误判成回拖
    // 重置时钟继续放、也没有二次推送。
    final handle = _TimedRestartHandle(
      url: 'http://192.168.50.10:18761/stream/t.mp3',
      lengthMs: 30000,
      clock: h.clock,
      flipMs: 30500,
    )..fetchedValue = true;
    h.proxy.nextHandle = handle;

    await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
    await _elapse(h.clock, const Duration(seconds: 10));
    expect(h.engine.playing, isTrue);

    await _elapse(h.clock, const Duration(seconds: 35));
    expect(h.engine.playing, isFalse);
    expect(h.logs.any((l) => l.contains('停止循环')), isTrue);
    expect(
      h.gateway.calls.where((c) => c.name == 'playMusic'),
      hasLength(1),
    );
  });

  test('中途自愈重取（《体面》型）→ 时钟重同步、不在原时间轴误判播完', () async {
    final h = _Harness();
    // 120 秒的歌：播到约 40 秒时上游断流、音箱自愈从头重取
    // （事件 + 已供比例 0.3）。watch 应记 restarted step 并把
    // 时钟基准重置到重取时刻。
    final handle = _MidRestartHandle(
      url: 'http://192.168.50.10:18761/stream/t.mp3',
      lengthMs: 120000,
      clock: h.clock,
      flipMs: 40000,
      ratio: 0.3,
    )..fetchedValue = true;
    h.proxy.nextHandle = handle;

    await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
    await _elapse(h.clock, const Duration(seconds: 10));
    expect(h.engine.playing, isTrue);

    // 事件落地：重同步发生（step 日志），run 不结束、不重推。
    await _elapse(h.clock, const Duration(seconds: 35));
    expect(h.engine.playing, isTrue);
    expect(
      h.logs.any(
        (l) => l.contains('step restarted ok') && l.contains('时钟重同步'),
      ),
      isTrue,
    );
    expect(
      h.gateway.calls.where((c) => c.name == 'playMusic'),
      hasLength(1),
    );

    // 越过原时间轴的判尾点（120s+slack，约 t=122s）：重播才
    // 播到约 82 秒，绝不能判完。旧逻辑（无重同步）会在此切歌。
    await _elapse(h.clock, const Duration(seconds: 85));
    expect(h.engine.playing, isTrue);
    expect(h.logs.any((l) => l.contains('播完了')), isFalse);

    // 到重同步后的判尾点（40s+120s+slack，约 t=162s）：正常
    // 收尾（finish 的 halt 复查还要 1+2+3s，给足余量）。
    await _elapse(h.clock, const Duration(seconds: 50));
    expect(h.engine.playing, isFalse);
    expect(h.logs.any((l) => l.contains('播完了')), isTrue);
  });

  test('近尾声重取（已供 95%）→ 判循环 finish，不重同步续命', () async {
    final h = _Harness();
    final handle = _MidRestartHandle(
      url: 'http://192.168.50.10:18761/stream/t.mp3',
      lengthMs: 120000,
      clock: h.clock,
      flipMs: 40000,
      ratio: 0.95,
    )..fetchedValue = true;
    h.proxy.nextHandle = handle;

    await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
    await _elapse(h.clock, const Duration(seconds: 10));
    expect(h.engine.playing, isTrue);

    // 事件在 t=40s 落地，finish 的 halt 复查还要数秒。
    await _elapse(h.clock, const Duration(seconds: 45));
    expect(h.engine.playing, isFalse);
    expect(h.logs.any((l) => l.contains('音箱又从头放了')), isTrue);
    expect(h.logs.any((l) => l.contains('时钟重同步')), isFalse);
  });
}

/// 重取事件在指定假时钟时刻才落地的假句柄（模拟固件循环
/// 重取在 watch 等待间隙发生、下一轮顶部才被看到）。事件
/// 携带已供比例 0.97（上一请求近乎供满）→ 近尾声分流。
class _TimedRestartHandle extends FakeStreamHandle {
  _TimedRestartHandle({
    required super.url,
    required super.lengthMs,
    required this.clock,
    required this.flipMs,
  });

  final FakeTakeoverClock clock;
  final int flipMs;

  @override
  bool get restarted => clock.nowMs() >= flipMs;

  @override
  int? get restartAtMs => clock.nowMs() >= flipMs ? flipMs : null;

  @override
  double get restartServedRatio => 0.97;
}

/// 中途重取事件（已供比例可配）的假句柄：事件在 [flipMs]
/// 落地一次（restartAtMs 恒为 flipMs，watch 按已处理时刻去重）。
class _MidRestartHandle extends FakeStreamHandle {
  _MidRestartHandle({
    required super.url,
    required super.lengthMs,
    required this.clock,
    required this.flipMs,
    required this.ratio,
  });

  final FakeTakeoverClock clock;
  final int flipMs;
  final double ratio;

  @override
  int? get restartAtMs => clock.nowMs() >= flipMs ? flipMs : null;

  @override
  double get restartServedRatio => ratio;
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

/// 记录 resume 请求点位的假句柄。
class _RecordingHandle extends FakeStreamHandle {
  _RecordingHandle({required super.url});

  int? resumeAtMs;

  @override
  Future<({StreamHandle handle, int startMs})?> resume(int atMs) async {
    resumeAtMs = atMs;
    final r = resumeResult;
    if (r == null) return null;
    return (handle: r.handle, startMs: atMs);
  }
}

class _Harness {
  _Harness() {
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

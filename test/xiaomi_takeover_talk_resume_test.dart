import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/dispatch.dart';
import 'package:muyin_music/core/xiaomi/takeover/quiet.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_stream_proxy.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_engine.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_state.dart';

import 'xiaomi_takeover_test_utils.dart';

/// 插话续播全链：推播的歌播放中，用户说「声音大一点」（控制
/// 指令，接管侧执行音量），小爱开口应答并暂停播放；谈话窗
/// 结束后 watcher 应从断点前 1.5 秒续推（蓝本 watch 的
/// talkedUntil + again），而不是把暂停当无由停止等满
/// maxPause 放弃。
void main() {
  test('播放中音量指令 → 设备暂停说话 → 谈话窗结束 → 续播重推', () async {
    final h = _Harness();

    // 当前歌的句柄：已取流；resume 记录请求点位并返回已取流的
    // 续播句柄（从该点位起播）。
    final resumedHandle = FakeStreamHandle(
      url: 'http://192.168.50.10:18761/stream/resumed.mp3',
      lengthMs: 269000,
    )..fetchedValue = true;
    final handle = _RecordingHandle(
      url: 'http://192.168.50.10:18761/stream/t.mp3',
    )..fetchedValue = true;
    handle.resumeResult = (handle: resumedHandle, startMs: 0);
    h.proxy.nextHandle = handle;

    // 点歌并跑过守卫（8 秒），进入 watch 跟随播放。
    await h.dispatcher.onCommand(_record('播放歌曲周杰伦晴天'), 0);
    await _elapse(h.clock, const Duration(seconds: 10));
    expect(h.records.single.success, isTrue);
    expect(h.engine.playing, isTrue);
    final playsBefore = h.gateway.calls
        .where((c) => c.name == 'playMusic')
        .length;
    expect(playsBefore, 1);

    // 小爱应答期间设备暂停（status=2）；用户说「声音大一点」，
    // 小爱 TTS 回答「好的」。
    var interrupted = true;
    h.gateway.statusFn = () => interrupted
        ? const MinaPlayerStatus(statusCode: 2, volume: 30)
        : h.gateway.fallbackStatus;
    final heardAtMs = h.clock.nowMs();
    await h.dispatcher.onCommand(
      ConversationRecord(
        timeMs: heardAtMs,
        query: '声音大一点',
        answers: const [ConversationAnswer(type: 'TTS', ttsText: '好的')],
      ),
      heardAtMs,
    );
    // 音量仍由接管侧执行（30 → 40）。
    expect(
      h.gateway.calls.where((c) => c.name == 'setVolume' && c.detail == '40'),
      isNotEmpty,
    );

    // 谈话窗（回答 2 字）结束后：watcher 从 base-1.5s 续推。
    await _elapse(h.clock, const Duration(seconds: 5));
    expect(handle.resumeAtMs, isNotNull);
    expect(handle.resumeAtMs!, greaterThan(1500));
    final plays = h.gateway.calls.where((c) => c.name == 'playMusic').toList();
    expect(plays, hasLength(2));
    expect(plays.last.detail, resumedHandle.url);
    // run 仍在跟随，没有被判「停了很久」退出。
    expect(h.engine.playing, isTrue);

    // 续播后设备恢复在播状态，watcher 保持跟随、不再重推。
    interrupted = false;
    await _elapse(h.clock, const Duration(seconds: 3));
    expect(h.engine.playing, isTrue);
    expect(
      h.gateway.calls.where((c) => c.name == 'playMusic'),
      hasLength(2),
    );
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

/// 记录 resume 请求点位的假句柄。
class _RecordingHandle extends FakeStreamHandle {
  _RecordingHandle({required super.url});

  int? resumeAtMs;

  @override
  Future<({StreamHandle handle, int startMs})?> resume(int atMs) async {
    resumeAtMs = atMs;
    final r = resumeResult;
    if (r == null) return null;
    // 实际起始点即请求点位（测试只关心点位被正确算出并透传）。
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

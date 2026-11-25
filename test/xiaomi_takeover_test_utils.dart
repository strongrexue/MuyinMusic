import 'dart:async';

import 'package:muyin_music/core/xiaomi/mina_constants.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_gateway.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_resolver.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_clock.dart';

/// 手动推进的假时钟：sleep 挂起，直到 [advance] 推过其截止时刻。
class FakeTakeoverClock implements TakeoverClock {
  FakeTakeoverClock([int startMs = 0]) : _nowMs = startMs;

  int _nowMs;
  final List<Duration> sleepRequests = [];
  final List<({int deadlineMs, Completer<void> completer})> _pending = [];

  @override
  int nowMs() => _nowMs;

  @override
  Future<void> sleep(Duration duration) {
    sleepRequests.add(duration);
    final completer = Completer<void>();
    _pending.add((
      deadlineMs: _nowMs + duration.inMilliseconds,
      completer: completer,
    ));
    return completer.future;
  }

  void advance(Duration duration) {
    _nowMs += duration.inMilliseconds;
    final due = _pending.where((p) => p.deadlineMs <= _nowMs).toList();
    _pending.removeWhere((p) => p.deadlineMs <= _nowMs);
    for (final p in due) {
      if (!p.completer.isCompleted) p.completer.complete();
    }
  }

  bool get hasPendingSleeps => _pending.isNotEmpty;
}

/// 让微任务队列跑几轮（假时钟推进后用）。
Future<void> pumpMicrotasks([int times = 30]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 一次带时间戳的网关调用记录。
class GatewayCall {
  GatewayCall(this.name, this.atMs, [this.detail]);

  final String name;
  final int atMs;
  final String? detail;

  @override
  String toString() => detail == null ? name : '$name($detail)';
}

/// 假 SpeakerGateway：记录调用序列，状态可脚本化。
class FakeSpeakerGateway implements SpeakerGateway {
  FakeSpeakerGateway(this.clock);

  final FakeTakeoverClock clock;
  final List<GatewayCall> calls = [];

  /// 状态采样函数（优先于 [statusQueue]）。
  MinaPlayerStatus? Function()? statusFn;

  /// 状态采样队列（statusFn 为空时按序消费，耗尽后用 [fallbackStatus]）。
  final List<MinaPlayerStatus?> statusQueue = [];
  MinaPlayerStatus? fallbackStatus = const MinaPlayerStatus(
    statusCode: 1,
    volume: 30,
    positionMs: 500,
    durationMs: 200000,
  );

  bool playMusicResult = true;
  bool playUrlResult = true;
  ConversationFetchResult askResult = const ConversationFetchSuccess([]);

  List<String> get callNames => [for (final c in calls) c.name];

  void _record(String name, [String? detail]) {
    calls.add(GatewayCall(name, clock.nowMs(), detail));
  }

  @override
  Future<ConversationFetchResult> fetchLatestAsk({
    required String deviceId,
    required String hardware,
    int limit = 5,
  }) async {
    _record('fetchAsk');
    return askResult;
  }

  @override
  Future<MinaPlayerStatus?> getPlayerStatus(String deviceId) async {
    _record('status');
    if (statusFn != null) return statusFn!();
    if (statusQueue.isNotEmpty) return statusQueue.removeAt(0);
    return fallbackStatus;
  }

  @override
  Future<bool> playerPlay(String deviceId) async {
    _record('play');
    return true;
  }

  @override
  Future<bool> playerPause(String deviceId) async {
    _record('pause');
    return true;
  }

  @override
  Future<bool> playerStop(String deviceId) async {
    _record('stop');
    return true;
  }

  @override
  Future<bool> setVolume(String deviceId, int volume) async {
    _record('setVolume', '$volume');
    return true;
  }

  @override
  Future<bool> playMusic(String deviceId, String url) async {
    _record('playMusic', url);
    return playMusicResult;
  }

  @override
  Future<bool> playUrl(String deviceId, String url) async {
    _record('playUrl', url);
    return playUrlResult;
  }

  @override
  bool usePlayMusicApi(String hardware) => needUsePlayMusicApi(hardware);
}

/// 假解析器：按脚本返回（默认命中一首 MP3）。
class FakeSpeakerResolver implements SpeakerSongResolver {
  final List<SpeakerResolveRequest> requests = [];
  ResolvedSong? result = const ResolvedSong(
    url: 'http://example.com/song.mp3',
    title: '晴天',
    artist: '周杰伦',
    durationMs: 269000,
  );

  /// 按 keyword 区分结果（队列接力用）。
  final Map<String, ResolvedSong?> byKeyword = {};

  @override
  Future<ResolvedSong?> resolveTopOne(SpeakerResolveRequest request) async {
    requests.add(request);
    if (byKeyword.containsKey(request.keyword)) {
      return byKeyword[request.keyword];
    }
    return result;
  }
}

MinaDevice fakeDevice({String hardware = 'LX06'}) {
  return MinaDevice(
    deviceId: 'device-1',
    miotDid: '331987746',
    name: '小爱音箱Pro',
    alias: '小爱音箱Pro',
    model: '',
    hardware: hardware,
    presence: 'online',
  );
}

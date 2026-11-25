/// 接管核心的共享类型（TrackFerry `internal/takeover` 的结构移植）。
///
/// 蓝本结构：observe（轮询）→ Dispatcher（路由/分流/队列）→
/// Engine（run：mute/stop → push → guard → watch）→ stream
/// （取流证据）。本文件放各层共用的时序参数、step 名、事件与
/// 请求/结局类型；step 名与参数原值全部照蓝本。
library;

import 'takeover_state.dart';

/// 时序参数（蓝本 `DefaultTiming` + quiet/watch 常量，原值）。
class TakeoverTiming {
  const TakeoverTiming({
    this.settle = const Duration(milliseconds: 600),
    this.guard = const Duration(seconds: 8),
    this.poll = const Duration(milliseconds: 700),
    this.unmuteAfter = const Duration(milliseconds: 2500),
    this.maxReplays = 2,
    this.endSlack = const Duration(milliseconds: 1500),
    this.maxWatch = const Duration(hours: 3),
    this.look = const Duration(milliseconds: 2500),
    this.lookClose = const Duration(milliseconds: 900),
    this.speakPerRune = const Duration(milliseconds: 235),
    this.pause = const Duration(milliseconds: 1500),
    this.quietSettle = const Duration(seconds: 20),
    this.maxPause = const Duration(minutes: 15),
    this.startLag = const Duration(milliseconds: 500),
  });

  /// 两轮 stop 之间的沉降（蓝本 Settle）。
  final Duration settle;

  /// 推播后的守卫窗口（蓝本 Guard）。
  final Duration guard;

  /// 守卫确认后的轮询间隔（蓝本 Poll；未确认时用其一半）。
  final Duration poll;

  /// 取流后未确认也先恢复音量的时限（蓝本 UnmuteAfter）。
  final Duration unmuteAfter;

  /// 守卫/丢失重推上限（蓝本 MaxReplays）。
  final int maxReplays;

  /// 时钟判尾的富余（蓝本 EndSlack；我们 Duration 恒不用，保留）。
  final Duration endSlack;

  /// watch 最长跟随（蓝本 MaxWatch）。
  final Duration maxWatch;

  /// watch 常规回看间隔（蓝本 Look）。
  final Duration look;

  /// watch 谈话/刚暂停时的回看间隔（蓝本 LookClose）。
  final Duration lookClose;

  /// 估算小爱说话时长：每字耗时（蓝本 Speak）。
  final Duration speakPerRune;

  /// 谈话窗基础时长（蓝本 Pause）。
  final Duration pause;

  /// 没找到歌时压住音量的时长（蓝本 quietSettle）。
  final Duration quietSettle;

  /// watch 容忍暂停的最长时长（蓝本 maxPause）。
  final Duration maxPause;

  /// 取流到出声的滞后（蓝本 startLag）。
  final Duration startLag;
}

/// run 的 step 名（蓝本 `Step*` 常量全集，写进诊断日志）。
abstract final class TakeoverStepName {
  static const status = 'status';
  static const mute = 'mute';
  static const stop1 = 'stop1';
  static const quiet = 'quiet';
  static const wait = 'wait';
  static const stop2 = 'stop2';
  static const play = 'play';
  static const fetched = 'fetched';
  static const foreign = 'foreign';
  static const replay = 'replay';
  static const confirmed = 'confirmed';
  static const restore = 'restore';
  static const cancelled = 'cancelled';
  static const released = 'released';
  static const paused = 'paused';
  static const continued = 'continued';
  static const talked = 'talked';
  static const resume = 'resume';
  static const stopped = 'stopped';
  static const ended = 'ended';
}

/// run 的结局（蓝本 store 的 outcome 枚举；running 不落记录）。
enum RunOutcome { confirmed, fetched, dispatched, failed, cancelled }

/// 一首歌在 watch 阶段的终局（蓝本 End，仅供队列连播决策）。
enum TakeoverEnd { played, other, unplayed }

/// watch 听到的外部事件（蓝本 `Heard`）。
class HeardEvent {
  const HeardEvent({
    this.control,
    this.audio = false,
    this.woke = false,
    this.answerRunes = 0,
    this.atMs = 0,
  });

  /// 控制指令名（stop/pause/resume/next/previous…），空为非控制事件。
  final String? control;

  /// 小爱被要求放别的（交回原生的点歌）：watch 应让行。
  final bool audio;

  /// 只是被唤醒，没有后续指令。
  final bool woke;

  /// 谈话事件携带的小爱回答字数（估算谈话窗用）。
  final int answerRunes;

  /// 事件发生的服务端时刻（毫秒）。
  final int atMs;

  bool get isTalk => control == null && !audio && !woke;
}

/// 一次接管运行的请求（蓝本 `Request`）。
class TakeoverRequest {
  const TakeoverRequest({
    required this.kind,
    required this.query,
    this.title = '',
    this.artist = '',
    this.track,
    this.follows = false,
    this.onEnded,
    this.stageMs = const {},
    this.sourceName,
    this.qualityLabel,
    this.upstreamHostPath,
    this.nowPlaying,
  });

  /// command（点歌）/ quiet（没找到歌的静默 run）/ push（队列推进）。
  final String kind;

  /// 触发指令原文（quiet/push 可为空或歌名）。
  final String query;
  final String title;
  final String artist;

  /// 已备好的流（quiet run 为 null）。
  final Object? track;

  /// 队列推进的 run：静音多半还压着，跳过 mute/stop 阶段（蓝本 Follows）。
  final bool follows;

  /// watch 终局回调（队列 turn 机制）；command/quiet run 可为 null。
  final void Function(TakeoverEnd end)? onEnded;

  /// 分发层先测的阶段耗时（detect/resolve），引擎补 mute/push/confirm。
  final Map<String, int> stageMs;

  final String? sourceName;
  final String? qualityLabel;
  final String? upstreamHostPath;

  /// watch 开始时上报 UI 的正在播放（分发层按队列位置填）。
  final SpeakerNowPlaying? nowPlaying;

  bool get isQuiet => kind == 'quiet';
}

/// 一条 step 记录（蓝本 store.Step：名字、距 run 开始毫秒、成败、说明）。
class TakeoverStep {
  const TakeoverStep({
    required this.name,
    required this.atMs,
    required this.ok,
    this.detail = '',
  });

  final String name;
  final int atMs;
  final bool ok;
  final String detail;
}

/// 一次运行的运行时状态（蓝本 runner 的 Dart 对应物）。
///
/// steps 随执行实时追加并经 [onStep] 外发（诊断日志）；heard
/// 队列缓冲上限 8 条（蓝本 heard 通道缓冲），watch 消费。
class TakeoverRun {
  TakeoverRun({
    required this.gen,
    required this.req,
    required this.startedAtMs,
    required int Function() nowMs,
    required void Function(TakeoverStep step) onStep,
  }) : _nowMs = nowMs,
       _onStep = onStep;

  final int gen;
  final TakeoverRequest req;
  final int startedAtMs;
  final int Function() _nowMs;
  final void Function(TakeoverStep step) _onStep;

  final List<TakeoverStep> steps = [];
  final List<HeardEvent> heardQueue = [];

  bool watching = false;
  bool released = false;
  bool stopRequested = false;
  bool finished = false;
  RunOutcome? outcome;

  int get nowMs => _nowMs();

  void step(String name, bool ok, [String detail = '']) {
    final s = TakeoverStep(
      name: name,
      atMs: _nowMs() - startedAtMs,
      ok: ok,
      detail: detail,
    );
    steps.add(s);
    _onStep(s);
  }

  void hear(HeardEvent event) {
    if (heardQueue.length >= 8) heardQueue.removeAt(0);
    heardQueue.add(event);
  }

  List<HeardEvent> drainHeard() {
    if (heardQueue.isEmpty) return const [];
    final out = List<HeardEvent>.of(heardQueue);
    heardQueue.clear();
    return out;
  }
}

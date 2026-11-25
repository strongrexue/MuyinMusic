import 'dart:async';
import 'dart:math' as math;

import '../mina_models.dart';
import 'takeover_clock.dart';

/// 对话记录拉取函数（由网关适配，核心不直接依赖 MinaClient）。
typedef AskFetcher = Future<ConversationFetchResult> Function();

/// 新指令回调（按时间顺序逐条投递）。
///
/// [seenMs] 是本轮 poll 开始时刻（蓝本 observe.poll 的 started / handle 的
/// seen）：同一轮投递的每条记录共用同一个 seenMs，分发层用它算延迟与
/// stale，不能用记录自身的 timeMs 或投递时刻代替。
typedef ConversationRecordHandler =
    FutureOr<void> Function(ConversationRecord record, int seenMs);

/// 一轮轮询的结果。
enum PollOutcome {
  /// 首轮成功，只建立了去重基线，没有投递任何记录。
  primed,

  /// 成功，有新记录并已投递。
  delivered,

  /// 成功，无新记录。
  idle,

  /// 拉取失败（基线未动，见类注释）。
  failed,
}

/// 对话监听器：轮询目标设备的对话记录，只把新指令交给分发回调。
///
/// 基线纪律（蓝本 TrackFerry internal/observe/observe.go）：
/// - 去重基线只能取自**服务端**返回的记录时间戳，绝不用本地时钟
///   初始化（本地时钟超前会静默吞指令，落后会重放历史指令）；
/// - 首轮只建基线、不投递；
/// - 拉取失败时既不推进基线也不建基线——把失败当「没有记录」，
///   恢复后整批历史会被当成新消息重放。
/// 去重键：有 requestId 用 requestId，否则用蓝本兜底格式
/// `t<timeMs>|<query>`（observe.handle 的 RequestKey）——同一毫秒内的
/// 不同指令不互相吞掉，同一 requestId 重复出现只投递一次。
///
/// stale 纪律（蓝本 staleAfter=2min）：记录可见时距其识别时刻已超过
/// [staleAfterMs] 的，monitor 照常投递（蓝本是落库并标记 Stale），
/// 是否执行由分发层决定；monitor 只保证 seenMs 准确。
///
/// 轮询循环可启停、时钟可注入（[TakeoverClock]），便于单测。
class ConversationMonitor {
  ConversationMonitor({
    required AskFetcher fetcher,
    required TakeoverClock clock,
    required ConversationRecordHandler onRecord,
    this.pollInterval = const Duration(milliseconds: 500),
    this.fetchLimit = 5,
    void Function(String message)? onLog,
  }) : _fetcher = fetcher,
       _clock = clock,
       _onRecord = onRecord,
       _onLog = onLog;

  final AskFetcher _fetcher;
  final TakeoverClock _clock;
  final ConversationRecordHandler _onRecord;
  final void Function(String message)? _onLog;

  /// 基础轮询间隔（TrackFerry 实证 500ms：其检测延迟
  /// 369–586ms；2s 间隔曾让我们的检测+压制链路慢到原生抢先
  /// 起播，1.3.27 真机实证）。
  final Duration pollInterval;

  /// 每轮拉取的记录条数（蓝本用 5）。
  final int fetchLimit;

  /// stale 阈值：seenMs − timeMs 超过它即 stale（蓝本 staleAfter=2min）。
  static const int staleAfterMs = 120000;

  bool _running = false;
  int _session = 0;
  Completer<void>? _stopSignal;

  bool _primed = false;
  int _baselineMs = 0;
  Set<String> _baselineBoundaryKeys = {};
  int _failureStreak = 0;

  /// 最近一次失败是否为「被拒类」（原因含 'unauthorized'，蓝本
  /// ErrUnauthorized / KindAuth）；[currentBackoff] 据此选封顶策略。
  bool _lastFailureRefused = false;

  /// 最近一次失败是否为「网络类」。分类对齐蓝本 KindOf：含
  /// 'transport'/'HTTP'/'network'/'timeout' 等网络字样，或拿不准的，
  /// 一律按 network（KindOf 对传输错误默认 KindNetwork）；只有明确的
  /// 非网络类（'protocol'/'upstream'，蓝本 KindProtocol/KindUpstream）
  /// 才算「其余情况」。
  bool _lastFailureNetwork = true;

  bool get isRunning => _running;
  bool get isPrimed => _primed;
  int get baselineMs => _baselineMs;

  /// 当前失败退避时长（成功后归零）。
  ///
  /// 蓝本 observe.poll 的公式（其 interval=1s，本类 pollInterval=500ms，
  /// 故基数取 pollInterval×2=1s 与蓝本对齐）：
  /// backoff = (pollInterval×2) << min(failureStreak, 5)，上限 32s；
  /// - 网络类：封顶 5s（蓝本 maxOffline）；
  /// - 被拒类且 failureStreak>3：按蓝本被拒分支重算
  ///   (pollInterval×2) << min(failureStreak, 10)，封顶 5 分钟
  ///   （蓝本 maxRefused）；
  /// - 其余情况不封顶（公式上限即 1s<<5=32s）。
  Duration get currentBackoff {
    if (_failureStreak <= 0) return Duration.zero;
    final baseMs = pollInterval.inMilliseconds * 2;
    if (_lastFailureRefused && _failureStreak > 3) {
      final ms = baseMs << math.min(_failureStreak, 10);
      return Duration(milliseconds: math.min(ms, 5 * 60 * 1000));
    }
    var ms = baseMs << math.min(_failureStreak, 5);
    if (_lastFailureNetwork) ms = math.min(ms, 5000);
    return Duration(milliseconds: ms);
  }

  void start() {
    if (_running) return;
    _running = true;
    final session = ++_session;
    _stopSignal = Completer<void>();
    unawaited(_loop(session));
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _session++;
    final signal = _stopSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  Future<void> _loop(int session) async {
    while (_running && session == _session) {
      // 蓝本 ticker 语义：每轮目标周期 = pollInterval，从本轮开始计时，
      // sleep = max(0, pollInterval − 本轮耗时)；一轮超时则下一轮立即
      // 开始。顺序循环天然保证同一监听不重入（对应蓝本 inflight）。
      // 失败轮例外：退避优先于节奏，按退避时长睡。
      final pollStartMs = _clock.nowMs();
      final outcome = await pollOnce(session: session);
      if (!_running || session != _session) return;
      final Duration delay;
      if (outcome == PollOutcome.failed) {
        delay = currentBackoff;
      } else {
        final elapsedMs = _clock.nowMs() - pollStartMs;
        final remainingMs = pollInterval.inMilliseconds - elapsedMs;
        delay = Duration(milliseconds: math.max(0, remainingMs));
      }
      final signal = _stopSignal;
      if (signal == null) return;
      await cancellableSleep(_clock, delay, signal.future);
    }
  }

  /// 执行一轮轮询。供循环内部调用，也供单测直接驱动。
  Future<PollOutcome> pollOnce({int? session}) async {
    // 本轮 poll 开始时刻：本轮投递的所有记录共用它作 seenMs
    // （蓝本 poll 的 started，handle 里 seen.UnixMilli()）。
    final seenMs = _clock.nowMs();
    final result = await _fetcher();
    if (result is ConversationFetchFailure) {
      _failureStreak++;
      _recordFailureKind(result.reason);
      _onLog?.call('conversation fetch failed: ${result.reason}');
      return PollOutcome.failed;
    }
    _failureStreak = 0;
    _lastFailureRefused = false;
    _lastFailureNetwork = true;
    final records = (result as ConversationFetchSuccess).records;

    if (!_primed) {
      var maxMs = 0;
      for (final record in records) {
        if (record.timeMs > maxMs) maxMs = record.timeMs;
      }
      _baselineMs = maxMs;
      _baselineBoundaryKeys = {
        for (final record in records)
          if (record.timeMs == maxMs) _keyOf(record),
      };
      _primed = true;
      return PollOutcome.primed;
    }

    final fresh = <ConversationRecord>[];
    final freshKeys = <String>{};
    for (final record in records) {
      final key = _keyOf(record);
      if (record.timeMs > _baselineMs ||
          (record.timeMs == _baselineMs &&
              !_baselineBoundaryKeys.contains(key))) {
        // 同一轮内同键（同 requestId）重复出现只收一次。
        if (freshKeys.add(key)) fresh.add(record);
      }
    }
    if (fresh.isEmpty) return PollOutcome.idle;

    fresh.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    // 先推进基线再投递：处理回调抛错也不能导致同一指令被重放。
    var newBaseline = _baselineMs;
    for (final record in fresh) {
      if (record.timeMs > newBaseline) newBaseline = record.timeMs;
    }
    _baselineBoundaryKeys = {
      for (final record in records)
        if (record.timeMs == newBaseline) _keyOf(record),
    };
    _baselineMs = newBaseline;

    for (final record in fresh) {
      if (session != null && session != _session) break;
      // 检测延迟（蓝本 observe.handle 的「延迟ms」日志与 commands
      // 表 upstream_ms/seen_ms 口径）：记录的上游时间戳 → 本轮
      // seen 的毫秒差，每条新记录都记一行，事后可直接量检测
      // 链路慢在哪一段。
      final lagMs = seenMs - record.timeMs;
      _onLog?.call(
        'conversation detected: lag=${lagMs}ms '
        'upstream=${record.timeMs} seen=$seenMs query=${record.query}',
      );
      // stale 记录照常投递（见类注释）：只记日志，分发层决定不执行。
      if (lagMs > staleAfterMs) {
        _onLog?.call(
          'conversation record stale: lag ${lagMs}ms, query=${record.query}',
        );
      }
      try {
        await _onRecord(record, seenMs);
      } catch (e) {
        _onLog?.call('conversation record handler error: $e');
      }
    }
    return PollOutcome.delivered;
  }

  void _recordFailureKind(String reason) {
    final lower = reason.toLowerCase();
    _lastFailureRefused = lower.contains('unauthorized');
    // 明确的非网络类（蓝本 protocol/upstream）之外，一律按网络类
    // （含 transport/HTTP 字样与拿不准的情况，蓝本 KindOf 默认 network）。
    _lastFailureNetwork =
        !_lastFailureRefused &&
        !lower.contains('protocol') &&
        !lower.contains('upstream');
  }

  /// 去重键（蓝本 observe.handle 的 RequestKey）：有 requestId 用它，
  /// 否则兜底 `t<timeMs>|<query>`。
  static String _keyOf(ConversationRecord record) {
    final requestId = record.requestId;
    if (requestId != null && requestId.isNotEmpty) return requestId;
    return 't${record.timeMs}|${record.query}';
  }
}

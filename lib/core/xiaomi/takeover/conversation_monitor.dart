import 'dart:async';

import '../mina_models.dart';
import 'takeover_clock.dart';

/// 对话记录拉取函数（由网关适配，核心不直接依赖 MinaClient）。
typedef AskFetcher = Future<ConversationFetchResult> Function();

/// 新指令回调（按时间顺序逐条投递）。
typedef ConversationRecordHandler =
    FutureOr<void> Function(ConversationRecord record);

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
/// 基线纪律（miot `src/conversation/monitor.ts` 的血泪教训）：
/// - 去重基线只能取自**服务端**返回的记录时间戳，绝不用本地时钟
///   初始化（本地时钟超前会静默吞指令，落后会重放历史指令）；
/// - 首轮只建基线、不投递；
/// - 拉取失败时既不推进基线也不建基线——把失败当「没有记录」，
///   恢复后整批历史会被当成新消息重放。
/// 去重键为「时间戳 + query」：同一毫秒内的不同指令不互相吞掉。
///
/// 轮询循环可启停、时钟可注入（[TakeoverClock]），便于单测。
class ConversationMonitor {
  ConversationMonitor({
    required AskFetcher fetcher,
    required TakeoverClock clock,
    required ConversationRecordHandler onRecord,
    this.pollInterval = const Duration(seconds: 2),
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

  /// 基础轮询间隔（蓝本默认 2s）。
  final Duration pollInterval;

  /// 每轮拉取的记录条数（蓝本用 5）。
  final int fetchLimit;

  bool _running = false;
  int _session = 0;
  Completer<void>? _stopSignal;

  bool _primed = false;
  int _baselineMs = 0;
  Set<String> _baselineBoundaryKeys = {};
  int _failureStreak = 0;

  bool get isRunning => _running;
  bool get isPrimed => _primed;
  int get baselineMs => _baselineMs;

  /// 当前失败退避时长（成功后归零）。
  Duration get currentBackoff {
    if (_failureStreak <= 0) return Duration.zero;
    final factor = 1 << _failureStreak; // 2, 4, 8, …
    var ms = pollInterval.inMilliseconds * factor;
    const cap = 30000;
    if (ms > cap) ms = cap;
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
      final outcome = await pollOnce(session: session);
      if (!_running || session != _session) return;
      final delay = outcome == PollOutcome.failed
          ? currentBackoff
          : pollInterval;
      final signal = _stopSignal;
      if (signal == null) return;
      await cancellableSleep(_clock, delay, signal.future);
    }
  }

  /// 执行一轮轮询。供循环内部调用，也供单测直接驱动。
  Future<PollOutcome> pollOnce({int? session}) async {
    final result = await _fetcher();
    if (result is ConversationFetchFailure) {
      _failureStreak++;
      _onLog?.call('conversation fetch failed: ${result.reason}');
      return PollOutcome.failed;
    }
    _failureStreak = 0;
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
    for (final record in records) {
      if (record.timeMs > _baselineMs ||
          (record.timeMs == _baselineMs &&
              !_baselineBoundaryKeys.contains(_keyOf(record)))) {
        fresh.add(record);
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
      try {
        await _onRecord(record);
      } catch (e) {
        _onLog?.call('conversation record handler error: $e');
      }
    }
    return PollOutcome.delivered;
  }

  static String _keyOf(ConversationRecord record) =>
      '${record.timeMs}|${record.query}';
}

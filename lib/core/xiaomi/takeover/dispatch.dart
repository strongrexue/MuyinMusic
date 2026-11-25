import 'dart:async';
import 'dart:math' as math;

import '../mina_models.dart';
import 'speaker_intent.dart';
import 'speaker_resolver.dart';
import 'speaker_stream_proxy.dart';
import 'takeover_clock.dart';
import 'takeover_engine.dart';
import 'takeover_state.dart';
import 'takeover_types.dart';

/// App 队列里的一首待播（从 speaker_relay 迁来，定义归分发层）。
class SpeakerQueueItem {
  const SpeakerQueueItem({
    required this.title,
    required this.artist,
    this.durationMs,
    this.exactMusic,
    this.localPath,
  });

  final String title;
  final String artist;
  final int? durationMs;

  /// App 队列项携带的原始歌曲对象（对核心不透明，解析适配器用）。
  final Object? exactMusic;

  /// 本机文件路径（预留）：非空时备歌直接把文件注册成局域网
  /// 流（蓝本曲库 Song），不走线上解析。当前快照队列的条目
  /// 都走线上解析，此字段暂无生产方，流层能力保留待用。
  final String? localPath;
}

/// 点歌成功后取「接管续播列表」的回调：基于接管时刻 App
/// 播放队列的快照——点播歌在队列中取其后的部分，不在队列
/// 中从队列当前项起顺延；队列为空返回空（单曲收尾）。快照
/// 只取一次，音箱侧队列独立推进，不动 App 播放状态。
typedef SpeakerQueueTailProvider =
    List<SpeakerQueueItem> Function(ResolvedSong song);

/// 过时阈值（蓝本 staleAfter）：迟到超过 2 分钟才可见的对话
/// 记录只记录、绝不执行。
const int kStaleAfterMs = 120000;

/// 指令分发（TrackFerry `internal/takeover/dispatch.go` 的移植）。
///
/// 每条指令先开启新一代路由（旧指令还在找歌就作废）；控制指令
/// 不接管、交回小爱（只 Release + Hear 让 watch 知情）；切歌在
/// 有队列时走队列 skip；点歌先 Quiet 预静音（与找歌并行），
/// 路由只有两层：曲库恒 miss（删除）→ 洛雪（胖虎 LX 解析）；
/// 没找到走静默 run 不交还原生；备歌（解析+发布流）后复检
/// 代际才 Start。
class TakeoverDispatcher {
  TakeoverDispatcher({
    required TakeoverEngine engine,
    required SpeakerSongResolver resolver,
    required SpeakerStreamProxy streamProxy,
    required TakeoverClock clock,
    SpeakerQueueTailProvider? queueTailProvider,
    void Function(TakeoverRecord record)? onTakeoverRecord,
    void Function(String message)? onLog,
  }) : _engine = engine,
       _resolver = resolver,
       _streamProxy = streamProxy,
       _clock = clock,
       _queueTailProvider = queueTailProvider,
       _onTakeoverRecord = onTakeoverRecord,
       _onLog = onLog;

  final TakeoverEngine _engine;
  final SpeakerSongResolver _resolver;
  final SpeakerStreamProxy _streamProxy;
  final TakeoverClock _clock;
  final SpeakerQueueTailProvider? _queueTailProvider;
  final void Function(TakeoverRecord record)? _onTakeoverRecord;
  final void Function(String message)? _onLog;

  int _routingGen = 0;
  _TakeoverQueue? _queue;

  bool get hasQueue => _queue != null;

  bool Function() _begin() {
    final n = ++_routingGen;
    return () => n == _routingGen;
  }

  /// 停掉这一台的分发（蓝本 Halt）：队列丢弃、路由代际作废、
  /// 当前 run 按停止取消。
  void halt() {
    _routingGen++;
    _queue = null;
    _engine.cancelCurrentRun(byStop: true);
  }

  /// 监听器投递一条对话记录（蓝本 OnCommand）。
  /// [seenMs] 是本轮轮询开始时刻（算延迟/过时用）。
  Future<void> onCommand(ConversationRecord record, int seenMs) async {
    final lagMs = seenMs - record.timeMs;
    if (lagMs > kStaleAfterMs) {
      _onLog?.call(
        'takeover stale command skipped: ${record.query} lag=${lagMs}ms',
      );
      return;
    }
    final current = _begin();
    final intent = parseSpeakerIntent(record.query);
    if (intent == null) {
      // 不认识的话：watch 若在跟随，按谈话事件知会它。
      _engine.hear(_talkHeard(record));
      return;
    }
    switch (intent) {
      case PlaySongIntent():
        // Quiet 先行（蓝本 OnCommand：Quiet 在路由之前下发，是
        // 点歌的第一个网络动作）：意图一确定是点歌就在分发入口
        // 压音量，不等 _playSong 内部任何步骤，找歌/备歌全程
        // 被静音罩住。
        final unquiet = _engine.quiet();
        await _playSong(record, intent, current, seenMs, unquiet);
      case NextIntent():
        await _nextPrevious(record, 1, current);
      case PreviousIntent():
        await _nextPrevious(record, -1, current);
      case StopIntent():
        _engine.release();
        _engine.hear(HeardEvent(control: 'stop', atMs: record.timeMs));
      case PauseIntent():
        _engine.release();
        _engine.hear(HeardEvent(control: 'pause', atMs: record.timeMs));
      case ResumeIntent():
        _engine.release();
        _engine.hear(HeardEvent(control: 'resume', atMs: record.timeMs));
      case SetVolumeIntent():
        // 音量由接管侧执行，但小爱仍会开口应答并暂停播放：
        // 照控制指令的 Release 路径交回守卫，并按谈话事件知会
        // watch——否则 watcher 不知发生过对话，谈话窗不开，
        // 被打断的歌只会被当成无由暂停、等满 maxPause 放弃。
        _engine.release();
        _engine.hear(_talkHeard(record));
        await _engine.setVolumeValue(intent.value);
      case VolumeStepIntent():
        _engine.release();
        _engine.hear(_talkHeard(record));
        await _engine.volumeStep(up: intent.up);
    }
  }

  /// 一次对话的谈话事件（小爱应答的谈话窗由 watch 按
  /// 回答字数估算）：音量等「接管侧执行、小爱仍开口」的
  /// 指令与不认识的话共用。
  HeardEvent _talkHeard(ConversationRecord record) {
    return HeardEvent(
      answerRunes: record.ttsAnswerText.runes.length,
      atMs: record.timeMs,
    );
  }

  Future<void> _nextPrevious(
    ConversationRecord record,
    int by,
    bool Function() current,
  ) async {
    final q = _queue;
    if (q == null) {
      // 无队列：清掉残留并把切歌交回小爱（蓝本 Forget+Drop 后
      // 走 KindControl 分支）。
      _engine.release();
      _engine.hear(
        HeardEvent(
          control: by > 0 ? 'next' : 'previous',
          atMs: record.timeMs,
        ),
      );
      return;
    }
    final prepared = await _prepareCandidate(q, by);
    if (prepared == null) {
      _onLog?.call('takeover skip failed: no playable candidate');
      return;
    }
    if (!current()) {
      _onLog?.call('takeover superseded while preparing skip');
      return;
    }
    _startPrepared(q, prepared, kind: 'command', follows: false);
  }

  Future<void> _playSong(
    ConversationRecord record,
    PlaySongIntent intent,
    bool Function() current,
    int seenMs,
    void Function(bool) unquiet,
  ) async {
    final stageMs = <String, int>{'detect': seenMs - record.timeMs};
    // Not a word of the answer, however long it takes to find
    // the song：Quiet 已由 onCommand 在入口下发（见彼处注释），
    // 这里只负责用完后按结局归还/交接。
    try {
      // 曲库层已删除：恒 miss、0ms（蓝本 layer 1）。
      _onLog?.call('route library miss 0ms');
      final resolveStart = _clock.nowMs();
      final request = SpeakerResolveRequest(
        keyword: intent.keyword,
        hintTitle: intent.title,
        hintArtist: intent.artist,
      );
      ResolvedSong? resolved;
      try {
        resolved = await _resolver.resolveTopOne(request);
      } catch (e) {
        _onLog?.call('takeover resolve error: $e');
        resolved = null;
      }
      final resolveMs = _clock.nowMs() - resolveStart;
      stageMs['resolve'] = resolveMs;
      if (!current()) {
        unquiet(true);
        _onLog?.call('takeover superseded while routing: ${record.query}');
        return;
      }
      if (resolved == null || !isSpeakerPlayableUrl(resolved.url)) {
        _onLog?.call('route lx miss ${resolveMs}ms ${intent.keyword}');
        // 没找到：从不交回小爱——她自己的版本正是用户不要的，
        // 改走静默 run 压住不出声（蓝本 SilentWhenMissing）。
        _engine.start(
          TakeoverRequest(
            kind: 'quiet',
            query: intent.raw,
            title: intent.title ?? intent.keyword,
            artist: intent.artist ?? '',
            stageMs: stageMs,
          ),
        );
        unquiet(false);
        return;
      }
      _onLog?.call(
        'route lx hit ${resolveMs}ms ${resolved.title} - ${resolved.artist}',
      );
      // 备歌：发布局域网流（蓝本 TrackOf）。换链回调照蓝本
      // Opener：直链过期被拒时按同一请求重新解析取新地址。
      final handle = await _streamProxy.publish(
        resolved.url,
        durationMs: resolved.durationMs,
        label: '${resolved.title} - ${resolved.artist}',
        urlRefresher: () => _refreshUrl(request),
      );
      if (!current()) {
        unquiet(true);
        _onLog?.call('takeover superseded while preparing: ${record.query}');
        return;
      }
      if (handle == null) {
        // 备歌失败：交回小爱（蓝本 TrackOf err → Native 分支）。
        unquiet(true);
        _engine.release();
        _engine.hear(HeardEvent(audio: true, atMs: record.timeMs));
        _onTakeoverRecord?.call(
          TakeoverRecord(
            query: intent.raw,
            title: resolved.title,
            artist: resolved.artist,
            atMs: _clock.nowMs(),
            success: false,
            detail: '准备音频失败',
            sourceName: resolved.sourceName,
            qualityLabel: resolved.qualityLabel,
            upstreamHostPath: _hostPathOf(resolved.url),
            stageMs: stageMs,
          ),
        );
        return;
      }
      // 新点歌即旧队列终点（蓝本 unqueue）；续播列表来自
      // 接管时刻 App 播放队列的快照（queueTailProvider 的
      // 口径：在队列中取其后、不在从当前项顺延）。快照为空
      // 就单曲收尾，不建队列。
      final tail =
          _queueTailProvider?.call(resolved) ?? const <SpeakerQueueItem>[];
      _TakeoverQueue? queue;
      if (tail.isNotEmpty) {
        queue = _TakeoverQueue(
          all: [
            SpeakerQueueItem(
              title: resolved.title,
              artist: resolved.artist,
              durationMs: resolved.durationMs,
            ),
            ...tail,
          ],
          pos: 0,
          untilMs: _clock.nowMs() + const Duration(hours: 3).inMilliseconds,
        );
        _queue = queue;
      } else {
        _queue = null;
      }
      final q = queue;
      _engine.start(
        TakeoverRequest(
          kind: 'command',
          query: intent.raw,
          title: resolved.title,
          artist: resolved.artist,
          track: handle,
          stageMs: stageMs,
          sourceName: resolved.sourceName,
          qualityLabel: resolved.qualityLabel,
          upstreamHostPath: _hostPathOf(resolved.url),
          nowPlaying: SpeakerNowPlaying(
            title: resolved.title,
            artist: resolved.artist,
            queueIndex: 0,
            queueLength: 1 + tail.length,
          ),
          onEnded: q == null ? null : _turnCallback(q),
        ),
      );
      unquiet(false); // run 接手了静音
    } catch (e) {
      _onLog?.call('takeover dispatch error: $e');
      unquiet(true);
    }
  }

  // ===== 队列（蓝本 queue.go 的 turn/step/advance） =====

  /// 一首歌的终局回调（蓝本 turn）：校验队列与 turn 未被
  /// 顶替后计数成败，再决定是否推进。
  void Function(TakeoverEnd) _turnCallback(_TakeoverQueue q) {
    final n = ++q.turn;
    return (end) {
      if (!identical(_queue, q) || q.turn != n) return;
      switch (end) {
        case TakeoverEnd.played:
          q.fails = 0;
        case TakeoverEnd.unplayed:
          q.fails++;
        case TakeoverEnd.other:
          break;
      }
      if (end == TakeoverEnd.other || q.fails >= 3) {
        if (identical(_queue, q)) _queue = null;
        return;
      }
      unawaited(_advance(q, n));
    };
  }

  Future<void> _advance(_TakeoverQueue q, int n) async {
    if (!identical(_queue, q) || q.turn != n) return;
    if (_clock.nowMs() > q.untilMs) {
      if (identical(_queue, q)) _queue = null;
      _onLog?.call('takeover queue ended: time limit');
      return;
    }
    final prepared = await _prepareCandidate(q, 1);
    if (prepared == null) {
      if (identical(_queue, q)) _queue = null;
      _onLog?.call('takeover queue ended: no more playable songs');
      return;
    }
    if (!identical(_queue, q) || q.turn != n) return;
    _startPrepared(q, prepared, kind: 'push', follows: true);
  }

  /// 按蓝本 step() 在队列里走一步并备好歌：最多试
  /// min(40, 2n) 首、跳过解析/发布失败的。与蓝本的差异：
  /// 蓝本歌单到尾绕回开头循环，我方队列是 App 播放队列的
  /// 快照，**到尾即耗尽**（返回 null，advance 干净收尾），
  /// 不循环重播（用户口径）。
  Future<({int pos, SpeakerQueueItem item, StreamHandle handle})?>
  _prepareCandidate(_TakeoverQueue q, int by0) async {
    final all = q.all;
    final count = all.length;
    if (count == 0) return null;
    var by = by0;
    final was = q.pos;
    var pos = q.pos;
    final tries = math.min(40, 2 * count);
    for (var i = 0; i < tries; i++) {
      pos += by;
      if (pos < 0) {
        pos = 0;
        by = 1; // 第一首读不到就往后找（蓝本同）
      }
      if (pos >= count) return null; // 快照队列耗尽
      if (pos == was && by > 0) continue; // 顶到第一首自身，往后找
      final item = all[pos];
      final handle = await _prepareItem(item);
      if (handle != null) return (pos: pos, item: item, handle: handle);
    }
    return null;
  }

  Future<StreamHandle?> _prepareItem(SpeakerQueueItem item) async {
    try {
      // 本地曲库条目：文件直接注册成流（蓝本 Next→Song），
      // 不经线上解析；文件没了/读不到返回 null，step 跳过它。
      final localPath = item.localPath;
      if (localPath != null) {
        return await _streamProxy.publishFile(
          localPath,
          durationMs: item.durationMs,
          label: '${item.title} - ${item.artist}',
        );
      }
      final request = SpeakerResolveRequest(
        keyword: item.title,
        hintTitle: item.title,
        hintArtist: item.artist,
        hintDurationMs: item.durationMs,
        exactMusic: item.exactMusic,
      );
      final resolved = await _resolver.resolveTopOne(request);
      if (resolved == null || !isSpeakerPlayableUrl(resolved.url)) {
        return null;
      }
      return await _streamProxy.publish(
        resolved.url,
        durationMs: resolved.durationMs ?? item.durationMs,
        label: '${item.title} - ${item.artist}',
        urlRefresher: () => _refreshUrl(request),
      );
    } catch (e) {
      _onLog?.call('takeover queue prepare error: $e');
      return null;
    }
  }

  /// 换链（蓝本 Opener 的 refresh）：按原请求重新解析，取回
  /// 的新地址。解析不到/不可播返回 null（流层按打开失败处理）。
  Future<String?> _refreshUrl(SpeakerResolveRequest request) async {
    try {
      final resolved = await _resolver.resolveTopOne(request);
      if (resolved == null || !isSpeakerPlayableUrl(resolved.url)) {
        return null;
      }
      return resolved.url;
    } catch (e) {
      _onLog?.call('takeover url refresh error: $e');
      return null;
    }
  }



  void _startPrepared(
    _TakeoverQueue q,
    ({int pos, SpeakerQueueItem item, StreamHandle handle}) prepared, {
    required String kind,
    required bool follows,
  }) {
    q.pos = prepared.pos;
    _engine.start(
      TakeoverRequest(
        kind: kind,
        query: '',
        title: prepared.item.title,
        artist: prepared.item.artist,
        track: prepared.handle,
        follows: follows,
        nowPlaying: SpeakerNowPlaying(
          title: prepared.item.title,
          artist: prepared.item.artist,
          queueIndex: prepared.pos,
          queueLength: q.all.length,
        ),
        onEnded: _turnCallback(q),
      ),
    );
  }

  static String? _hostPathOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    return '${uri.host}${uri.path}';
  }
}

/// 连播队列（蓝本 queue 结构；ids 换成 App 队列项）。
class _TakeoverQueue {
  _TakeoverQueue({
    required this.all,
    required this.pos,
    required this.untilMs,
  });

  /// 全部歌曲（含当前这首），顺序即 App 队列顺序。
  final List<SpeakerQueueItem> all;

  /// 当前这首在 [all] 中的位置。
  int pos;

  /// 连播最长时长到点（蓝本 until，默认 3 小时）。
  final int untilMs;

  int turn = 0;
  int fails = 0;
}

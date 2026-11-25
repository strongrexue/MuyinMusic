import 'dart:async';

import '../mina_models.dart';
import 'quiet.dart';
import 'speaker_gateway.dart';
import 'speaker_stream_proxy.dart';
import 'takeover_clock.dart';
import 'takeover_state.dart';
import 'takeover_types.dart';
import 'watch.dart';

/// 音量步进（大声一点 / 小声一点）的单步幅度。
const int kSpeakerVolumeStep = 10;

/// 接管引擎（TrackFerry `internal/takeover` 的 Engine/runner 移植）。
///
/// 一个引擎管一台音箱：同一时刻至多一个 run 在执行，新 run 开始
/// 即取消旧 run（代际），旧 run 在检查点自行收尾且不恢复音量
/// （新 run 继承待恢复音量）。run 的时序照蓝本 execute：
/// mute 与 stop1 并行 → settle → stop2 → push（失败重试 2 次）
/// → guard 8s（取流/确认/外来重推）→ watch（自维护播放时钟、
/// 续播、防循环收尾）。每一步都以 step 形式写进诊断日志，
/// 结局以 TakeoverRecord 落到 UI 记录。
class TakeoverEngine implements WatchHost {
  TakeoverEngine({
    required SpeakerGateway gateway,
    required TakeoverClock clock,
    required MinaDevice device,
    required TakeoverQuiet quiet,
    TakeoverTiming timing = const TakeoverTiming(),
    void Function(TakeoverRecord record)? onTakeoverRecord,
    void Function(SpeakerNowPlaying? nowPlaying)? onNowPlayingChanged,
    void Function(String message)? onLog,
  }) : _gateway = gateway,
       _clock = clock,
       _device = device,
       _quiet = quiet,
       _timing = timing,
       _onTakeoverRecord = onTakeoverRecord,
       _onNowPlayingChanged = onNowPlayingChanged,
       _onLog = onLog;

  final SpeakerGateway _gateway;
  final TakeoverClock _clock;
  final MinaDevice _device;
  final TakeoverQuiet _quiet;
  final TakeoverTiming _timing;
  final void Function(TakeoverRecord record)? _onTakeoverRecord;
  final void Function(SpeakerNowPlaying? nowPlaying)? _onNowPlayingChanged;
  final void Function(String message)? _onLog;

  late final TakeoverWatcher _watcher = TakeoverWatcher(
    host: this,
    clock: _clock,
    timing: _timing,
  );

  TakeoverRun? _currentRun;
  int _generation = 0;
  Future<void> _tail = Future.value();
  bool _shutdown = false;

  /// 分发层预静音（Quiet）的持有令牌；run 接手后清掉。
  Object? _quietToken;

  String get _deviceId => _device.deviceId;
  bool get _usePlayMusic => _gateway.usePlayMusicApi(_device.hardware);

  /// 是否有 run 正在跟随播放（蓝本 Engine.Playing）。
  bool get playing => _currentRun?.watching ?? false;

  /// 这台音箱是否被接管侧持有（run 在跑、预静音未归还、或
  /// 静音还压着）——RecoverVolumes 据此跳过。
  bool get deviceHeld =>
      _currentRun != null || _quietToken != null || _quiet.muteHeld;

  TakeoverRun? get currentRun => _currentRun;

  // ===== Quiet（分发层预静音） =====

  /// 决策期预静音（蓝本 `Engine.Quiet`）：立即开始静音（不等
  /// 完成），返回归还函数。归还函数只生效一次：back=true 时
  /// 若静音仍归本令牌持有（没有 run 接手）则恢复音量；
  /// back=false 表示 run 已接手，什么都不做。
  void Function(bool) quiet() {
    final token = Object();
    _quietToken = token;
    final future = _quiet.mute();
    var used = false;
    return (bool back) {
      if (used) return;
      used = true;
      if (!back) {
        if (_quietToken == token) _quietToken = null;
        return;
      }
      unawaited(() async {
        final m = await future;
        if (_quietToken != token) return; // 已被 run 接手
        _quietToken = null;
        if (m.muted) await _quiet.putBack(m.volume);
      }());
    };
  }

  // ===== run 生命周期 =====

  /// 开始一个 run（蓝本 `Engine.Start`）：取消同设备旧 run，
  /// 新 run 排队串行执行（旧 run 被取消后会快速退出检查点）。
  void start(TakeoverRequest req) {
    _quietToken = null; // run 接手静音所有权
    final gen = ++_generation;
    final run = TakeoverRun(
      gen: gen,
      req: req,
      startedAtMs: _clock.nowMs(),
      nowMs: _clock.nowMs,
      onStep: (s) => _onLog?.call(
        'takeover step ${s.name} ${s.ok ? 'ok' : 'fail'} '
        '+${s.atMs}ms${s.detail.isEmpty ? '' : ' ${s.detail}'}',
      ),
    );
    _currentRun = run;
    _tail = _tail.then((_) => _execute(run)).catchError((Object e) {
      _onLog?.call('takeover run error: $e');
    });
  }

  /// 结束当前 run 的守卫（蓝本 `Engine.Release`）：守卫提前
  /// 退出，但 run 仍恢复音量并进 watch 防循环。
  void release() {
    _currentRun?.released = true;
  }

  /// 把外部事件递给当前 run 的 watch（蓝本 `Engine.Hear`）。
  void hear(HeardEvent event) {
    _currentRun?.hear(event);
  }

  /// 取消当前 run（蓝本 Halt 的引擎侧）：按「被取代」收尾；
  /// [byStop] 为真时按「按了停止」收尾（结局文案不同）。
  void cancelCurrentRun({bool byStop = false}) {
    final run = _currentRun;
    if (run == null) return;
    if (byStop) run.stopRequested = true;
    _generation++;
    _currentRun = null;
  }

  /// 等所有已启动的 run 执行完毕（测试与关闭流程用）。
  Future<void> whenIdle() => _tail;

  /// 宿主关闭：取消 run 并尽力恢复静音（不阻塞关闭）。
  void shutdown() {
    _shutdown = true;
    cancelCurrentRun(byStop: true);
    if (_quiet.muteHeld) {
      unawaited(
        _quiet.putBack(-1).then((_) {}, onError: (_) {}),
      );
    }
  }

  bool _runInactive(TakeoverRun run) =>
      _shutdown || run.gen != _generation || run.stopRequested;

  /// 蓝本 cancelled()：被取消时落 step 并以 cancelled 结局收尾。
  bool _cancelled(TakeoverRun run) {
    if (!_runInactive(run)) return false;
    if (run.stopRequested) {
      run.step(TakeoverStepName.stopped, true, '按了停止');
      _finish(run, RunOutcome.cancelled, '按了停止');
    } else {
      run.step(TakeoverStepName.cancelled, true, '同一台音箱有了更新的指令');
      _finish(run, RunOutcome.cancelled, '被更新的指令取代');
    }
    return true;
  }

  // ===== execute（蓝本 runner.execute） =====

  Future<void> _execute(TakeoverRun run) async {
    final req = run.req;
    final track = req.track as StreamHandle?;
    var volume = -1;
    var muted = false;
    var restored = false;

    // 恢复先于一切失败路径注册（蓝本 defer restore）：被取代/
    // 被取消时不恢复——新 run 继承待恢复音量，关闭流程另有兜底。
    Future<void> restore() async {
      if (!muted || restored) return;
      restored = true;
      if (_runInactive(run)) return;
      final r = await _quiet.putBack(volume);
      run.step(
        TakeoverStepName.restore,
        r.error == null,
        '音量 ${r.volume}${r.error == null ? '' : ' ${r.error}'}',
      );
    }

    try {
      var remute = false;
      if (req.follows) {
        // 队列推进的 run：静音是上一个 run 留下的，继承即可。
        final pending = await _quiet.pendingVolume();
        if (pending != null) {
          volume = pending;
          muted = true;
        }
      } else {
        final haltFuture = _halt();
        final m = await _quiet.mute();
        volume = m.volume;
        muted = m.muted;
        run.step(TakeoverStepName.status, m.statusOk, m.statusNote);
        if (m.muted || m.error != null || m.note.isNotEmpty) {
          run.step(
            TakeoverStepName.mute,
            m.muted,
            '${m.note}${m.error ?? ''}',
          );
        }
        remute = m.muted && m.error != null;
        final haltOk = await haltFuture;
        run.step(TakeoverStepName.stop1, haltOk, '');
        if (await _sleepOrInactive(run, _timing.settle)) return;
        if (remute) {
          await _gateway.setVolume(_deviceId, 0);
        }
        final ok2 = await _halt();
        run.step(TakeoverStepName.stop2, ok2, '');
      }
      if (_cancelled(run)) return;

      if (req.isQuiet || track == null) {
        // 没找到歌的静默 run：压住音量等小爱也没得放，再归还。
        restored = true; // 立即恢复改为延迟恢复（下方挂 later）
        if (await _quiet.hasPending()) {
          run.step(
            TakeoverStepName.quiet,
            true,
            '音量 $volume 先压住 ${_timing.quietSettle.inSeconds} 秒，等她没得放再还',
          );
          final v = volume;
          unawaited(_restoreAfterQuietSettle(run.gen, v));
        }
        run.step(TakeoverStepName.quiet, true, '曲库和线上都没有，停住不出声');
        _finish(run, RunOutcome.failed, '曲库和线上都没有这首歌，没有出声');
        req.onEnded?.call(TakeoverEnd.unplayed);
        return;
      }

      if (!await _push(run, track, TakeoverStepName.play)) {
        if (_cancelled(run)) return;
        _finish(run, RunOutcome.failed, '推送播放失败');
        req.onEnded?.call(TakeoverEnd.unplayed);
        return;
      }

      final end = await _guard(run, track, restore);
      if (end != null) {
        req.onEnded?.call(end);
        return;
      }
      // _guard 已落 confirmed/fetched 结局并置 watching，进 watch。
      _onNowPlayingChanged?.call(
        req.nowPlaying ??
            SpeakerNowPlaying(
              title: req.title,
              artist: req.artist,
              queueIndex: 0,
              queueLength: 1,
            ),
      );
      final how = await _watcher.watch(run, track);
      run.watching = false;
      if (identical(_currentRun, run)) {
        _onNowPlayingChanged?.call(null);
      }
      req.onEnded?.call(how);
    } finally {
      await restore();
      if (identical(_currentRun, run) && run.finished) {
        _currentRun = null;
      }
    }
  }

  Future<void> _restoreAfterQuietSettle(int gen, int volume) async {
    try {
      await _clock.sleep(_timing.quietSettle);
      // 新 run 接手了静音就不再归还（代际已变或有 run 在跑）。
      if (gen != _generation || _currentRun != null) return;
      final r = await _quiet.putBack(volume);
      _onLog?.call(
        'takeover quiet volume restored: ${r.volume} ${r.error ?? ''}',
      );
    } catch (_) {
      // 延迟恢复失败不外抛；落盘条目还在，RecoverVolumes 兜底。
    }
  }

  /// guard（蓝本 execute 第 4 段）：返回 null 表示已确认/已取流
  /// 并应进 watch；返回 End 表示 run 已收尾（结局已落）。
  Future<TakeoverEnd?> _guard(
    TakeoverRun run,
    StreamHandle track,
    Future<void> Function() restore,
  ) async {
    final deadlineMs = _clock.nowMs() + _timing.guard.inMilliseconds;
    int? fetchedAt = track.fetched ? track.fetchedAtMs : null;
    if (fetchedAt != null) run.step(TakeoverStepName.fetched, true, '');
    var confirmed = false;
    var left = false;
    var replays = 0;
    var pushedAtMs = _clock.nowMs();

    while (_clock.nowMs() < deadlineMs) {
      final tick = confirmed
          ? _timing.poll
          : (fetchedAt != null ? _timing.poll ~/ 4 : _timing.poll ~/ 2);
      final wake = await _guardWait(run, track, tick, fetchedAt != null);
      if (_runInactive(run)) {
        _cancelled(run);
        return TakeoverEnd.other;
      }
      if (run.released) {
        left = true;
        run.step(TakeoverStepName.released, true, '有新的口令交给小爱，不再守护');
        break;
      }
      if (wake == _GuardWake.fetched && fetchedAt == null) {
        fetchedAt = track.fetchedAtMs ?? _clock.nowMs();
        run.step(TakeoverStepName.fetched, true, '');
        continue;
      }
      if (fetchedAt != null &&
          !confirmed &&
          _clock.nowMs() - fetchedAt >= _timing.unmuteAfter.inMilliseconds) {
        await restore();
      }
      final status = await _statusOrNull();
      if (status == null) continue;
      _quiet.know(status);
      if (_isForeign(status)) {
        if (replays >= _timing.maxReplays) {
          run.step(TakeoverStepName.foreign, false, '小爱反复抢回播放，放弃');
          if (_cancelled(run)) return TakeoverEnd.other;
          _finish(run, RunOutcome.failed, '小爱的播放列表反复抢回音箱');
          return TakeoverEnd.other;
        }
        replays++;
        await _haltStep(run, TakeoverStepName.foreign);
        if (!await _push(run, track, TakeoverStepName.replay)) continue;
        pushedAtMs = _clock.nowMs();
        confirmed = false;
        continue;
      }
      // 受理了却没来取流、也没在播：流丢了，重推（同一额度）。
      if (!track.fetched &&
          !status.isPlaying &&
          replays < _timing.maxReplays &&
          _clock.nowMs() - pushedAtMs >=
              _timing.guard.inMilliseconds * 3 ~/ 8) {
        replays++;
        await _push(run, track, TakeoverStepName.replay);
        pushedAtMs = _clock.nowMs();
        continue;
      }
      if (!confirmed && fetchedAt != null && status.isPlaying) {
        confirmed = true;
        run.step(
          TakeoverStepName.confirmed,
          true,
          '播放中，进度 ${status.positionMs ?? -1} ms',
        );
        await restore();
      }
    }
    await restore();
    if (confirmed) {
      _finish(run, RunOutcome.confirmed, '');
      run.watching = true;
      return null;
    }
    if (fetchedAt != null) {
      _finish(run, RunOutcome.fetched, '音箱取了流，但播放状态没有确认');
      run.watching = true;
      return null;
    }
    _finish(run, RunOutcome.dispatched, '播放指令已受理，音箱没有来取流');
    return left ? TakeoverEnd.other : TakeoverEnd.unplayed;
  }

  /// 守卫等待：以短切片轮询取流/放行信号（蓝本是通道 select，
  /// 我们用 50ms 切片逼近，取流时刻误差 ≤50ms）。
  Future<_GuardWake> _guardWait(
    TakeoverRun run,
    StreamHandle track,
    Duration tick,
    bool hadFetched,
  ) async {
    final endMs = _clock.nowMs() + tick.inMilliseconds;
    while (true) {
      if (_runInactive(run) || run.released) return _GuardWake.signal;
      if (!hadFetched && track.fetched) return _GuardWake.fetched;
      final remainMs = endMs - _clock.nowMs();
      if (remainMs <= 0) return _GuardWake.tick;
      await _clock.sleep(
        Duration(milliseconds: remainMs < 50 ? remainMs : 50),
      );
    }
  }

  /// 守卫/watch 认人（蓝本 foreign）：仅 music API 型号按
  /// audio_id 判外来。
  bool _isForeign(MinaPlayerStatus status) =>
      _usePlayMusic && status.isForeignPlayback;

  /// 一轮压制：pause 与 stop 并发（蓝本 halt，只认 stop 结果）。
  Future<bool> _halt() async {
    try {
      final results = await Future.wait([
        _gateway.playerPause(_deviceId),
        _gateway.playerStop(_deviceId),
      ]);
      return results[1];
    } catch (_) {
      return false;
    }
  }

  Future<void> _haltStep(TakeoverRun run, String stepName) async {
    final ok = await _halt();
    run.step(stepName, ok, '');
  }

  /// 推流（蓝本 push）：失败重试 2 次（共 3 次），间隔 300ms。
  Future<bool> _push(
    TakeoverRun run,
    StreamHandle track,
    String stepName,
  ) async {
    var ok = await playUrl(track.url);
    for (var i = 0; !ok && i < 2; i++) {
      if (_runInactive(run)) break;
      run.step(stepName, false, '再试');
      await _clock.sleep(const Duration(milliseconds: 300));
      ok = await playUrl(track.url);
    }
    run.step(stepName, ok, ok ? '' : '推送失败');
    return ok;
  }

  /// 可取消的睡眠：被取代/停止时提前返回 true。
  Future<bool> _sleepOrInactive(TakeoverRun run, Duration d) async {
    final endMs = _clock.nowMs() + d.inMilliseconds;
    while (true) {
      if (_runInactive(run)) return true;
      final remainMs = endMs - _clock.nowMs();
      if (remainMs <= 0) return _runInactive(run);
      await _clock.sleep(
        Duration(milliseconds: remainMs < 100 ? remainMs : 100),
      );
    }
  }

  Future<MinaPlayerStatus?> _statusOrNull() async {
    try {
      return await _gateway.getPlayerStatus(_deviceId);
    } catch (_) {
      return null;
    }
  }

  /// 结局落盘（蓝本 finish）：command/quiet run 写 UI 记录，
  /// push（队列推进）run 只更新正在播放，不写记录。
  void _finish(TakeoverRun run, RunOutcome outcome, String detail) {
    if (run.finished) return;
    run.finished = true;
    run.outcome = outcome;
    final req = run.req;
    if (req.kind == 'push') return;
    final track = req.track as StreamHandle?;
    final stageMs = Map<String, int>.of(req.stageMs);
    int? stepAt(String name) {
      for (final s in run.steps) {
        if (s.name == name) return s.atMs;
      }
      return null;
    }

    final muteAt = stepAt(TakeoverStepName.mute);
    if (muteAt != null) stageMs['mute'] = muteAt;
    final playAt = stepAt(TakeoverStepName.play);
    if (playAt != null) stageMs['push'] = playAt - (muteAt ?? 0);
    final confirmedAt = stepAt(TakeoverStepName.confirmed);
    if (confirmedAt != null && playAt != null) {
      stageMs['confirm'] = confirmedAt - playAt;
    }
    _onTakeoverRecord?.call(
      TakeoverRecord(
        query: req.query,
        title: req.title,
        artist: req.artist,
        atMs: _clock.nowMs(),
        success: outcome == RunOutcome.confirmed,
        detail: detail.isNotEmpty
            ? detail
            : (outcome == RunOutcome.confirmed ? '已播放' : null),
        sourceName: req.sourceName,
        qualityLabel: req.qualityLabel,
        upstreamHostPath: req.upstreamHostPath,
        viaProxy: track != null,
        fetched: track?.fetched ?? false,
        stageMs: stageMs,
      ),
    );
  }

  // ===== 控制（蓝本 control.go 的音量部分；按钮 Press 无 UI 入口不移植） =====

  /// 设音量（蓝本 `Engine.SetVolume`）：静音持有中只改恢复
  /// 目标（当前保持 0），否则直发并更新已知音量。
  Future<bool> setVolumeValue(int value) async {
    final v = value.clamp(0, 100).toInt();
    if (_quiet.muteHeld) {
      final changed = await _quiet.changePendingVolume(v);
      if (changed) return true;
    }
    final ok = await _gateway.setVolume(_deviceId, v);
    if (ok) {
      _quiet.knowValue(v);
      if (v > 0 && !_quiet.muteHeld) {
        // 已被调回：落盘的待恢复条目作废（recoverOnce 同口径，
        // 这里顺手清掉免得 20s 后误恢复旧值）。
        await _quiet.clearPending();
      }
    }
    return true;
  }

  /// 音量步进：静音持有时以恢复目标为基准。
  Future<bool> volumeStep({required bool up}) async {
    if (_quiet.muteHeld) {
      final pending = await _quiet.pendingVolume();
      if (pending != null) {
        return setVolumeValue(
          pending + (up ? kSpeakerVolumeStep : -kSpeakerVolumeStep),
        );
      }
    }
    final status = await _statusOrNull();
    _quiet.know(status);
    final current = status?.volume;
    if (current == null) {
      _onLog?.call('volume step ignored: current volume unknown');
      return true;
    }
    return setVolumeValue(
      current + (up ? kSpeakerVolumeStep : -kSpeakerVolumeStep),
    );
  }

  /// RecoverVolumes 一轮（宿主每 20s 调一次）：有 run/quiet
  /// 持有时跳过。
  Future<void> recoverVolumesOnce() async {
    await _quiet.recoverOnce(held: deviceHeld);
  }

  /// 无条件恢复待恢复音量（关闭接管时用）：落盘有值就设回去。
  Future<void> restoreVolumeNow() async {
    if (await _quiet.hasPending()) {
      await _quiet.putBack(-1);
    }
  }

  // ===== WatchHost =====

  @override
  Future<MinaPlayerStatus?> status() => _statusOrNull();

  @override
  Future<bool> playUrl(String url) async {
    try {
      return _usePlayMusic
          ? await _gateway.playMusic(_deviceId, url)
          : await _gateway.playUrl(_deviceId, url);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> halt() async {
    await _halt();
  }

  @override
  bool runInactive(TakeoverRun run) => _runInactive(run);

  @override
  void knowVolume(MinaPlayerStatus? status) => _quiet.know(status);

  @override
  bool isForeign(MinaPlayerStatus status) => _isForeign(status);
}

enum _GuardWake { tick, fetched, signal }

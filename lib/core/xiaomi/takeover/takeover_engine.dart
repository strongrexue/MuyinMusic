import 'dart:async';

import '../mina_models.dart';
import 'speaker_gateway.dart';
import 'speaker_intent.dart';
import 'speaker_relay.dart';
import 'speaker_resolver.dart';
import 'speaker_stream_proxy.dart';
import 'push_verify.dart';
import 'takeover_clock.dart';
import 'takeover_state.dart';

/// 点歌成功后取「该歌在 App 当前队列之后的部分」的回调。
typedef SpeakerQueueTailProvider =
    List<SpeakerQueueItem> Function(ResolvedSong song);

/// 音量步进（大声一点 / 小声一点）的单步幅度。
const int kSpeakerVolumeStep = 10;

/// 待恢复音量的落盘接缝（TrackFerry 的 PendingVolume 语义）。
///
/// 接管静音前先把原音量落盘、恢复后才清除，App 异常退出也不会把
/// 音箱留在静音：宿主在下次监听启动时按落盘值自愈。
/// [savePendingVolume] 已有条目时不覆盖（先落盘的那份才是用户
/// 的真实音量，中途的 0 不是）。
abstract interface class TakeoverMuteStore {
  Future<int?> readPendingVolume(String deviceId);

  Future<void> savePendingVolume(String deviceId, int volume);

  /// 改恢复目标（静音期间用户调了音量）；返回此前是否有待恢复条目。
  Future<bool> changePendingVolume(String deviceId, int volume);

  Future<void> clearPendingVolume(String deviceId);
}

/// 接管引擎：意图 → 静音压制 → 解析 → 推播 → 验证 → 守卫 → 接力。
///
/// 时序照 TrackFerry `internal/takeover` 原版（参数全部取其
/// DefaultTiming 原值）：
/// 1. 发现点歌指令即静音（原音量先落盘再置 0，罩住后面的解析期，
///    对应 TrackFerry 在路由决定前就调用的 Quiet），同时第一轮
///    halt（pause 与 stop 并发，个别型号对单独 stop 不理）；
/// 2. 解析+探测在静音中进行；push 前补第二轮 halt，两轮之间至少
///    间隔 Settle 600ms（解析更快时补睡）；
/// 3. 推播后回读验证（position 证据链 + audio_id 身份门）；
/// 4. 落地后立即恢复音量，随后进入 Guard 8s 守卫：外来 audio_id
///    在播就 halt + 重推（MaxReplays 2 次），抢不回如实记失败；
/// 5. 没找到歌不交还原生：保持静音 quietSettle 20s 再恢复音量
///    （等小爱自己的版本也没机会起播）。
class TakeoverEngine {
  TakeoverEngine({
    required SpeakerGateway gateway,
    required TakeoverClock clock,
    required SpeakerSongResolver resolver,
    required MinaDevice device,
    SpeakerQueueTailProvider? queueTailProvider,
    SpeakerStreamProxy? streamProxy,
    TakeoverMuteStore? muteStore,
    void Function(TakeoverRecord record)? onTakeoverRecord,
    void Function(SpeakerNowPlaying? nowPlaying)? onNowPlayingChanged,
    void Function(String message)? onLog,
    Duration settle = const Duration(milliseconds: 600),
    Duration guardWindow = const Duration(seconds: 8),
    Duration guardPollFast = const Duration(milliseconds: 350),
    Duration guardPoll = const Duration(milliseconds: 700),
    int maxGuardReplays = 2,
    Duration quietSettle = const Duration(seconds: 20),
  }) : _gateway = gateway,
       _clock = clock,
       _resolver = resolver,
       _device = device,
       _streamProxy = streamProxy,
       _muteStore = muteStore,
       _queueTailProvider = queueTailProvider,
       _onTakeoverRecord = onTakeoverRecord,
       _onNowPlayingChanged = onNowPlayingChanged,
       _onLog = onLog,
       _settle = settle,
       _guardWindow = guardWindow,
       _guardPollFast = guardPollFast,
       _guardPoll = guardPoll,
       _maxGuardReplays = maxGuardReplays,
       _quietSettle = quietSettle;

  final SpeakerGateway _gateway;
  final TakeoverClock _clock;
  final SpeakerSongResolver _resolver;
  final MinaDevice _device;
  final SpeakerStreamProxy? _streamProxy;
  final TakeoverMuteStore? _muteStore;
  final SpeakerQueueTailProvider? _queueTailProvider;
  final void Function(TakeoverRecord record)? _onTakeoverRecord;
  final void Function(SpeakerNowPlaying? nowPlaying)? _onNowPlayingChanged;
  final void Function(String message)? _onLog;

  /// TrackFerry DefaultTiming 原值（可注入仅为单测缩短）。
  final Duration _settle;
  final Duration _guardWindow;
  final Duration _guardPollFast;
  final Duration _guardPoll;
  final int _maxGuardReplays;
  final Duration _quietSettle;

  SpeakerRelay? _relay;

  /// 上次读到的非 0 音量（TrackFerry `know`：状态读顺手记，
  /// 当前音量为 0 又无落盘时用它当恢复目标）。
  int? _lastKnownVolume;

  /// 本引擎正持有静音（已置 0、待恢复）。
  bool _mutedHeld = false;

  /// 本次静音要恢复到的音量（putBack 每次重读落盘，此为兜底）。
  int? _muteTargetVolume;

  /// 点歌流程代际：没找到歌的延迟恢复按它认领，新点歌接手后
  /// 旧的延迟恢复自动作废。
  int _playSongGeneration = 0;

  String get _deviceId => _device.deviceId;
  bool get _usePlayMusic => _gateway.usePlayMusicApi(_device.hardware);

  bool get hasActiveRelay => _relay?.isActive ?? false;
  SpeakerRelay? get relay => _relay;

  /// 处理一条意图。返回 true 表示已被接管侧处理（不再交还原生）。
  Future<bool> handleIntent(SpeakerIntent intent) async {
    switch (intent) {
      case PlaySongIntent():
        return _handlePlaySong(intent);
      case StopIntent():
        await _handleStop();
        return true;
      case PauseIntent():
        await _gateway.playerPause(_deviceId);
        return true;
      case ResumeIntent():
        await _gateway.playerPlay(_deviceId);
        return true;
      case NextIntent():
        if (!hasActiveRelay) return false;
        await _relay!.next();
        return true;
      case PreviousIntent():
        if (!hasActiveRelay) return false;
        await _relay!.previous();
        return true;
      case SetVolumeIntent():
        return _handleSetVolume(intent.value);
      case VolumeStepIntent():
        return _handleVolumeStep(intent);
    }
  }

  /// 一轮压制：pause 与 stop 并发发出（TrackFerry `halt`；
  /// 一些型号忽略单独的 stop）。回执不作数，停没停以回读为准。
  Future<void> suppressNative() async {
    await Future.wait([
      _gateway.playerPause(_deviceId),
      _gateway.playerStop(_deviceId),
    ]);
  }

  /// 宿主关闭接管时停接力，并尽力把静音恢复（不阻塞关闭流程）。
  void shutdown() {
    _relay?.stop();
    if (_mutedHeld) {
      unawaited(
        restorePendingVolume().catchError((Object _) {}),
      );
    }
  }

  // ===== 静音与恢复（TrackFerry mute / putBack） =====

  /// 顺手记音量：只记 >0 的（0 可能是我们自己压的）。
  void _know(MinaPlayerStatus? status) {
    final volume = status?.volume;
    if (volume != null && volume > 0) _lastKnownVolume = volume;
  }

  /// 静音：恢复目标先落盘、再置 0。已有落盘条目时沿用它
  /// （inherited：上一轮/上个进程留下的待恢复音量才是真实音量）。
  /// 读不到当前音量时用上次已知音量；都没有则不静音（没把握
  /// 恢复就不压，TrackFerry 同口径）。返回是否已持有静音。
  Future<bool> _mute() async {
    final store = _muteStore;
    if (store == null) return false;
    final pending = await store.readPendingVolume(_deviceId);
    if (pending != null) {
      _muteTargetVolume = pending;
      _mutedHeld = true;
      await _gateway.setVolume(_deviceId, 0);
      return true;
    }
    final status = await _gateway.getPlayerStatus(_deviceId);
    _know(status);
    int? volume;
    final current = status?.volume;
    if (current != null && current > 0) volume = current;
    volume ??= _lastKnownVolume;
    if (volume == null || volume <= 0) {
      _onLog?.call('takeover mute skipped: current volume unknown');
      return false;
    }
    // 先落盘后置 0：置 0 之后崩溃也有据可恢复。
    await store.savePendingVolume(_deviceId, volume);
    _muteTargetVolume = volume;
    await _gateway.setVolume(_deviceId, 0);
    _mutedHeld = true;
    return true;
  }

  /// 恢复音量（TrackFerry `putBack`）：最多 3 次尝试，间隔 300ms；
  /// 每次重读落盘值（静音期间用户改过恢复目标就用新值），
  /// 按值清除（恢复后落盘值又被改动则再循环一轮）。幂等。
  Future<void> restorePendingVolume() async {
    final store = _muteStore;
    if (store == null) return;
    var target = _muteTargetVolume;
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        final pending = await store.readPendingVolume(_deviceId);
        if (pending != null) target = pending;
        if (target == null) break;
        final ok = await _gateway.setVolume(_deviceId, target);
        if (ok) {
          _knowVolumeValue(target);
          final now = await store.readPendingVolume(_deviceId);
          if (now == null) break;
          if (now == target) {
            await store.clearPendingVolume(_deviceId);
            break;
          }
          target = now; // 恢复期间被改过：用新值再设一轮
          continue;
        }
        if (attempt < 2) {
          await _clock.sleep(const Duration(milliseconds: 300));
        }
      }
    } catch (e) {
      _onLog?.call('takeover volume restore error: $e');
    }
    _mutedHeld = false;
    _muteTargetVolume = null;
  }

  void _knowVolumeValue(int volume) {
    if (volume > 0) _lastKnownVolume = volume;
  }

  // ===== 点歌 =====

  Future<bool> _handlePlaySong(PlaySongIntent intent) async {
    final generation = ++_playSongGeneration;
    await _mute();

    var restored = false;
    Future<void> restoreOnce() async {
      if (restored) return;
      restored = true;
      await restorePendingVolume();
    }

    var quietHold = false;
    try {
      // 第一轮压制在发现时（解析之前），与静音一起罩住决策期。
      final halt1AtMs = _clock.nowMs();
      await suppressNative();

      ResolvedSong? resolved;
      try {
        resolved = await _resolver.resolveTopOne(
          SpeakerResolveRequest(
            keyword: intent.keyword,
            hintTitle: intent.title,
            hintArtist: intent.artist,
          ),
        );
      } catch (e) {
        _onLog?.call('takeover resolve error: $e');
        resolved = null;
      }

      if (resolved == null || !isSpeakerPlayableUrl(resolved.url)) {
        _emitRecord(
          TakeoverRecord(
            query: intent.raw,
            title: intent.title ?? intent.keyword,
            artist: intent.artist ?? '',
            atMs: _clock.nowMs(),
            success: false,
            detail: '未找到可播版本',
          ),
        );
        // 没找到歌不交还原生出声：保持静音满 quietSettle 再恢复，
        // 等小爱自己的版本也没机会起播（TrackFerry Quiet run）。
        // 新点歌接手（代际变化）时这份延迟恢复自动作废。
        quietHold = true;
        unawaited(
          _restoreAfterQuietSettle(generation, restoreOnce),
        );
        return true;
      }

      // 第二轮压制紧贴 push 前；与第一轮至少间隔 Settle。
      final elapsedMs = _clock.nowMs() - halt1AtMs;
      if (elapsedMs < _settle.inMilliseconds) {
        await _clock.sleep(
          Duration(milliseconds: _settle.inMilliseconds - elapsedMs),
        );
      }
      await suppressNative();

      final push = await publishViaProxyOrDirect(
        _streamProxy,
        resolved.url,
        onLog: _onLog,
      );
      bool Function()? fetchedSignal;
      if (push.viaProxy) {
        fetchedSignal = () => _streamProxy!.wasFetched(push.url);
      }
      final pushed = await _pushAndVerify(
        push.url,
        fetchedSignal: fetchedSignal,
        onFetchedStale: restoreOnce,
      );
      final fetched = push.viaProxy && _streamProxy!.wasFetched(push.url);
      if (!pushed) {
        _emitRecord(
          TakeoverRecord(
            query: intent.raw,
            title: resolved.title,
            artist: resolved.artist,
            atMs: _clock.nowMs(),
            success: false,
            detail: !push.viaProxy ? '推播未落地（代理不可用，已直推）' : '推播未落地',
            sourceName: resolved.sourceName,
            qualityLabel: resolved.qualityLabel,
            upstreamHostPath: _hostPathOf(resolved.url),
            viaProxy: push.viaProxy,
            fetched: fetched,
          ),
        );
        return true;
      }

      // 落地确认即恢复音量（TrackFerry 在 confirmed 时 restore，
      // 不等守卫结束），守卫在有声状态下继续。
      await restoreOnce();

      final held = await _guardPushed(push.url, fetchedSignal: fetchedSignal);
      if (!held) {
        _emitRecord(
          TakeoverRecord(
            query: intent.raw,
            title: resolved.title,
            artist: resolved.artist,
            atMs: _clock.nowMs(),
            success: false,
            detail: '被原生抢回',
            sourceName: resolved.sourceName,
            qualityLabel: resolved.qualityLabel,
            upstreamHostPath: _hostPathOf(resolved.url),
            viaProxy: push.viaProxy,
            fetched: fetched,
          ),
        );
        return true;
      }

      _emitRecord(
        TakeoverRecord(
          query: intent.raw,
          title: resolved.title,
          artist: resolved.artist,
          atMs: _clock.nowMs(),
          success: true,
          sourceName: resolved.sourceName,
          qualityLabel: resolved.qualityLabel,
          upstreamHostPath: _hostPathOf(resolved.url),
          viaProxy: push.viaProxy,
          fetched: fetched,
        ),
      );

      final tail =
          _queueTailProvider?.call(resolved) ?? const <SpeakerQueueItem>[];
      final relay = _ensureRelay();
      await relay.startWith(resolved, tail);
      return true;
    } finally {
      if (!quietHold) await restoreOnce();
    }
  }

  Future<void> _restoreAfterQuietSettle(
    int generation,
    Future<void> Function() restoreOnce,
  ) async {
    try {
      await _clock.sleep(_quietSettle);
      if (generation != _playSongGeneration) return;
      await restoreOnce();
    } catch (_) {
      // 延迟恢复失败不外抛；落盘条目还在，下次启动自检兜底。
    }
  }

  /// 推后守卫（TrackFerry Guard 原值）：落地后 [_guardWindow] 内
  /// 轮询状态，未确认前 [_guardPollFast]、确认后 [_guardPoll]。
  /// 外来 audio_id 在播 → halt + 重推同一 URL（最多
  /// [_maxGuardReplays] 次），仍被抢回返回 false。
  /// 另有流丢失重推：代理信号一直没等到取流、设备又没在播，
  /// 距推播超过 Guard*3/8（3s）时重推一次（同一 replay 额度）。
  Future<bool> _guardPushed(
    String url, {
    bool Function()? fetchedSignal,
  }) async {
    var replays = 0;
    var confirmed = false;
    var pushedAtMs = _clock.nowMs();
    final deadlineMs = pushedAtMs + _guardWindow.inMilliseconds;
    final lostAfterMs = _guardWindow.inMilliseconds * 3 ~/ 8;
    while (_clock.nowMs() < deadlineMs) {
      await _clock.sleep(confirmed ? _guardPoll : _guardPollFast);
      final status = await _gateway.getPlayerStatus(_deviceId);
      _know(status);
      if (status != null && _isForeign(status)) {
        if (replays >= _maxGuardReplays) return false;
        replays++;
        await suppressNative();
        await _pushRaw(url);
        pushedAtMs = _clock.nowMs();
        confirmed = false;
        continue;
      }
      if (!confirmed &&
          fetchedSignal != null &&
          fetchedSignal() &&
          status != null &&
          status.isPlaying) {
        confirmed = true;
      }
      if (fetchedSignal != null &&
          !fetchedSignal() &&
          status != null &&
          !status.isPlaying &&
          replays < _maxGuardReplays &&
          _clock.nowMs() - pushedAtMs >= lostAfterMs) {
        replays++;
        await _pushRaw(url);
        pushedAtMs = _clock.nowMs();
      }
    }
    return true;
  }

  /// 守卫认人：与 TrackFerry `foreign` 一致，只在 music API 型号上
  /// 按 audio_id 判外来（play_url 型号的状态归属语义不同）。
  bool _isForeign(MinaPlayerStatus status) =>
      _usePlayMusic && status.isForeignPlayback;

  /// 只推不验（守卫重推用）：按型号选推播 API。
  Future<void> _pushRaw(String url) async {
    if (_usePlayMusic) {
      await _gateway.playMusic(_deviceId, url);
    } else {
      await _gateway.playUrl(_deviceId, url);
    }
  }

  Future<bool> _pushAndVerify(
    String url, {
    bool Function()? fetchedSignal,
    void Function()? onFetchedStale,
  }) async {
    bool ok;
    if (_usePlayMusic) {
      ok = await _gateway.playMusic(_deviceId, url);
    } else {
      // play_url 无 REPLACE_ALL；压制第二轮已紧贴在推前，直接推。
      ok = await _gateway.playUrl(_deviceId, url);
    }
    final verified = await verifyPushLanded(
      _gateway,
      _clock,
      _deviceId,
      fetchedSignal: fetchedSignal,
      onFetchedStale: onFetchedStale,
    );
    if (ok != verified) {
      _onLog?.call('takeover push receipt=$ok but verify=$verified');
    }
    return verified;
  }

  /// 上游 URL 的 host+path（不含签名查询参数）；解析失败返回 null。
  static String? _hostPathOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    return '${uri.host}${uri.path}';
  }

  SpeakerRelay _ensureRelay() {
    final existing = _relay;
    if (existing != null) return existing;
    final relay = SpeakerRelay(
      gateway: _gateway,
      clock: _clock,
      resolver: _resolver,
      deviceId: _deviceId,
      usePlayMusic: _usePlayMusic,
      streamProxy: _streamProxy,
      onNowPlayingChanged: _onNowPlayingChanged,
      onSessionEnded: (reason) {
        _onLog?.call('relay ended: $reason');
      },
      onLog: _onLog,
    );
    _relay = relay;
    return relay;
  }

  // ===== 控制 =====

  Future<void> _handleStop() async {
    _relay?.stop();
    await _gateway.playerPause(_deviceId);
    await _gateway.playerStop(_deviceId);
  }

  /// 绝对音量：静音持有期间改的是恢复目标（TrackFerry
  /// `SetVolume`：pending 在就改 pending，不动当前 0 音量，
  /// 免得小爱的回答又能被听见）；其余时候直接下发。
  Future<bool> _handleSetVolume(int value) async {
    final v = value.clamp(0, 100).toInt();
    if (_mutedHeld && _muteStore != null) {
      final changed = await _muteStore.changePendingVolume(_deviceId, v);
      if (changed) {
        _muteTargetVolume = v;
        return true;
      }
    }
    await _gateway.setVolume(_deviceId, v);
    return true;
  }

  Future<bool> _handleVolumeStep(VolumeStepIntent intent) async {
    // 静音持有期间基准是恢复目标，不是当前的 0。
    if (_mutedHeld && _muteStore != null) {
      final pending = await _muteStore.readPendingVolume(_deviceId);
      if (pending != null) {
        final target = intent.up
            ? pending + kSpeakerVolumeStep
            : pending - kSpeakerVolumeStep;
        return _handleSetVolume(target);
      }
    }
    final status = await _gateway.getPlayerStatus(_deviceId);
    _know(status);
    final current = status?.volume;
    if (current == null) {
      _onLog?.call('volume step ignored: current volume unknown');
      return true;
    }
    final target = intent.up
        ? current + kSpeakerVolumeStep
        : current - kSpeakerVolumeStep;
    await _gateway.setVolume(_deviceId, target.clamp(0, 100).toInt());
    return true;
  }

  void _emitRecord(TakeoverRecord record) {
    _onTakeoverRecord?.call(record);
  }
}

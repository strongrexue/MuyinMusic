import 'dart:async';

import '../mina_models.dart';
import 'push_verify.dart';
import 'speaker_gateway.dart';
import 'speaker_resolver.dart';
import 'speaker_stream_proxy.dart';
import 'takeover_clock.dart';
import 'takeover_state.dart';

/// 音箱队列中的一项（接力用）。
class SpeakerQueueItem {
  const SpeakerQueueItem({
    required this.title,
    required this.artist,
    this.durationMs,
    this.exactMusic,
  });

  final String title;
  final String artist;
  final int? durationMs;

  /// App 队列项携带的原始歌曲对象（对核心不透明，解析适配器用）。
  final Object? exactMusic;
}

/// 接力会话结束的原因。
enum RelayEndReason {
  /// 队列播完。
  queueFinished,

  /// 被外部停掉（用户对音箱说停 / 米家操作等），接力主动收尾不打架。
  externalStop,

  /// 本侧主动结束（停止指令 / 新点歌替换 / 宿主关闭）。
  stopped,

  /// 连续推播失败，无歌可播。
  pushFailed,
}

/// 队列接力（最小版）：顺序连播 + 上下首。
///
/// 参数照蓝本 miot `src/player/manager.ts` 文件头注释：
/// - 状态校准轮询 20s（时长未知或临近结尾时 5s）；
/// - 外部停止探测：连续 2 次未在播放且 position 未推进 ≥5s 才认定，
///   距自然结束 15s 内不探测（尾段本身会短暂报停）；
/// - 播完探测：position 曾推进 >10s 又跌回 <3s = 音箱从头重拉同一
///   URL（自然播完）；
/// - 主推进靠本地时长定时器，到点用设备真实进度校准，不纯信墙钟。
/// 播放模式（随机/循环）不在 V1 范围。
class SpeakerRelay {
  SpeakerRelay({
    required SpeakerGateway gateway,
    required TakeoverClock clock,
    required SpeakerSongResolver resolver,
    required this.deviceId,
    required this.usePlayMusic,
    SpeakerStreamProxy? streamProxy,
    void Function(SpeakerNowPlaying? nowPlaying)? onNowPlayingChanged,
    void Function(RelayEndReason reason)? onSessionEnded,
    void Function(String message)? onLog,
  }) : _gateway = gateway,
       _clock = clock,
       _resolver = resolver,
       _streamProxy = streamProxy,
       _onNowPlayingChanged = onNowPlayingChanged,
       _onSessionEnded = onSessionEnded,
       _onLog = onLog;

  final SpeakerGateway _gateway;
  final TakeoverClock _clock;
  final SpeakerSongResolver _resolver;
  final SpeakerStreamProxy? _streamProxy;
  final String deviceId;
  final bool usePlayMusic;

  final void Function(SpeakerNowPlaying? nowPlaying)? _onNowPlayingChanged;
  final void Function(RelayEndReason reason)? _onSessionEnded;
  final void Function(String message)? _onLog;

  // 外部停止 / 播完探测参数（蓝本原值）。
  static const _calibrationInterval = Duration(seconds: 20);
  static const _probeInterval = Duration(seconds: 5);
  static const _tailGuardMs = 15000;
  static const _externalStopConfirmCount = 2;
  static const _positionAdvanceMinMs = 5000;
  static const _loopDetectMinAdvanceMs = 10000;
  static const _loopDetectResetThresholdMs = 3000;
  static const _deadlineGraceMs = 30000;

  bool _active = false;
  int _generation = 0;
  Completer<void>? _wakeSignal;

  List<SpeakerQueueItem> _items = const [];
  final Map<int, ResolvedSong> _resolvedCache = {};
  int _index = 0;

  // 当前曲目的进度跟踪（全部放字段里，切歌时同步重置，
  // 校准循环每轮只读字段，不持有过期局部状态）。
  int _trackStartedAtMs = 0;
  int? _durationMs;
  int _maxPositionMs = 0;
  int? _lastPositionMs;
  int _idleHits = 0;

  /// 连续读到外来 audio_id 在播的次数（身份门，见 _evaluate）。
  int _foreignHits = 0;

  bool get isActive => _active;
  int get currentIndex => _index;

  SpeakerNowPlaying? get nowPlaying {
    if (!_active || _items.isEmpty) return null;
    final item = _items[_index];
    return SpeakerNowPlaying(
      title: item.title,
      artist: item.artist,
      queueIndex: _index,
      queueLength: _items.length,
    );
  }

  /// 以一首已成功推播的歌开始接力，[tail] 为其后的队列。
  Future<void> startWith(
    ResolvedSong first,
    List<SpeakerQueueItem> tail,
  ) async {
    _generation++;
    _items = [
      SpeakerQueueItem(
        title: first.title,
        artist: first.artist,
        durationMs: first.durationMs,
      ),
      ...tail,
    ];
    _resolvedCache
      ..clear()
      ..[0] = first;
    _index = 0;
    _active = true;
    _resetTrackTracking(first.durationMs);
    _onNowPlayingChanged?.call(nowPlaying);
    _ensureLoop();
  }

  /// 手动下一首。返回 false 表示没有下一首（会话已结束）。
  Future<bool> next() async {
    if (!_active) return false;
    return _advance();
  }

  /// 手动上一首（已是第一首时重播当前首）。
  Future<bool> previous() async {
    if (!_active || _items.isEmpty) return false;
    final target = _index > 0 ? _index - 1 : 0;
    return _playIndex(target);
  }

  /// 结束会话（不操作设备，设备侧停止由引擎负责）。
  void stop() {
    if (!_active) return;
    _endSession(RelayEndReason.stopped);
  }

  // ===== 推进 =====

  Future<bool> _advance() async {
    var target = _index + 1;
    while (target < _items.length) {
      if (await _playIndex(target)) return true;
      target++;
    }
    _endSession(RelayEndReason.queueFinished);
    return false;
  }

  Future<bool> _playIndex(int target) async {
    final generation = _generation;
    final item = _items[target];
    var resolved = _resolvedCache[target];
    if (resolved == null) {
      try {
        resolved = await _resolver.resolveTopOne(
          SpeakerResolveRequest(
            keyword: '${item.artist} ${item.title}'.trim(),
            hintTitle: item.title,
            hintArtist: item.artist,
            hintDurationMs: item.durationMs,
            exactMusic: item.exactMusic,
          ),
        );
      } catch (e) {
        _onLog?.call('relay resolve failed for "${item.title}": $e');
        return false;
      }
      if (resolved == null || !isSpeakerPlayableUrl(resolved.url)) {
        _onLog?.call('relay: no playable version for "${item.title}"');
        return false;
      }
      _resolvedCache[target] = resolved;
    }
    if (!_active || generation != _generation) return false;

    // 代理 URL 每次推播现注册，不进 _resolvedCache（缓存的仍是上游直链）。
    final push = await publishViaProxyOrDirect(
      _streamProxy,
      resolved.url,
      onLog: _onLog,
    );
    final pushed = await _push(
      push.url,
      fetchedSignal: push.viaProxy
          ? () => _streamProxy!.wasFetched(push.url)
          : null,
    );
    if (!_active || generation != _generation) return false;
    if (!pushed) return false;

    _index = target;
    _resetTrackTracking(resolved.durationMs ?? item.durationMs);
    _onNowPlayingChanged?.call(nowPlaying);
    _poke();
    return true;
  }

  Future<bool> _push(String url, {bool Function()? fetchedSignal}) async {
    bool ok;
    if (usePlayMusic) {
      ok = await _gateway.playMusic(deviceId, url);
    } else {
      // play_url 路径没有 REPLACE_ALL，推前清旧媒体上下文。
      await _gateway.playerPause(deviceId);
      await _gateway.playerStop(deviceId);
      ok = await _gateway.playUrl(deviceId, url);
    }
    // 只认回读验证：回执不可信（3012 假失败 / 云端受理但设备没拉流
    // 的假成功都存在），两者矛盾时记日志。
    final verified = await verifyPushLanded(
      _gateway,
      _clock,
      deviceId,
      fetchedSignal: fetchedSignal,
    );
    if (ok != verified) {
      _onLog?.call('relay push receipt=$ok but verify=$verified');
    }
    return verified;
  }

  // ===== 校准循环 =====

  void _ensureLoop() {
    final generation = _generation;
    unawaited(_runLoop(generation));
  }

  Future<void> _runLoop(int generation) async {
    while (_active && generation == _generation) {
      final interval = _nextInterval();
      _wakeSignal = Completer<void>();
      await Future.any([_clock.sleep(interval), _wakeSignal!.future]);
      if (!_active || generation != _generation) return;
      await _evaluate();
    }
  }

  Duration _nextInterval() {
    final duration = _durationMs;
    if (duration == null) return _probeInterval;
    final remaining = _trackStartedAtMs + duration - _clock.nowMs();
    return remaining <= 60000 ? _probeInterval : _calibrationInterval;
  }

  Future<void> _evaluate() async {
    if (!_active || _items.isEmpty) return;
    final generation = _generation;
    MinaPlayerStatus? status;
    try {
      status = await _gateway.getPlayerStatus(deviceId);
    } catch (_) {
      status = null;
    }
    if (!_active || generation != _generation) return;

    final now = _clock.nowMs();
    final expectedEndMs = _durationMs == null
        ? null
        : _trackStartedAtMs + _durationMs!;

    if (status != null) {
      // 身份门（TrackFerry `foreign` 口径）：在播的是外来 audio_id
      // 时，那是原生/别人接管了音箱——它的 position/duration 不是
      // 我们的进度，一律不记账；连续 2 次按外部停止收尾，不打架。
      // 只在 music API 型号上按 audio_id 认人（relay 的 usePlayMusic）。
      if (usePlayMusic && status.isForeignPlayback) {
        _foreignHits++;
        if (_foreignHits >= _externalStopConfirmCount) {
          _endSession(RelayEndReason.externalStop);
        }
        return;
      }
      _foreignHits = 0;
      // 设备流长补齐未知时长。
      if (_durationMs == null &&
          status.durationMs != null &&
          status.durationMs! > 0) {
        _durationMs = status.durationMs;
      }
      final position = status.positionMs;
      if (position != null) {
        // 播完探测：音箱把同一 URL 从头重拉。
        if (_maxPositionMs > _loopDetectMinAdvanceMs &&
            position < _loopDetectResetThresholdMs) {
          await _advance();
          return;
        }
        if (position > _maxPositionMs) _maxPositionMs = position;
        final progressed =
            _lastPositionMs != null &&
            position - _lastPositionMs! >= _positionAdvanceMinMs;
        if (status.isPlaying || progressed) {
          // status 会撒谎：position 在推进就算还在播。
          _idleHits = 0;
        } else {
          final inTailGuard =
              expectedEndMs != null && now >= expectedEndMs - _tailGuardMs;
          if (!inTailGuard) {
            _idleHits++;
            if (_idleHits >= _externalStopConfirmCount) {
              _endSession(RelayEndReason.externalStop);
              return;
            }
          }
        }
        _lastPositionMs = position;
      } else if (status.isPlaying) {
        _idleHits = 0;
      } else {
        final inTailGuard =
            expectedEndMs != null && now >= expectedEndMs - _tailGuardMs;
        if (!inTailGuard) {
          _idleHits++;
          if (_idleHits >= _externalStopConfirmCount) {
            _endSession(RelayEndReason.externalStop);
            return;
          }
        }
      }
    }

    // 时长定时器到点：用设备真实进度校准后再决定切歌。
    if (expectedEndMs != null && now >= expectedEndMs) {
      final position = status?.positionMs;
      if (status != null &&
          status.isPlaying &&
          position != null &&
          _durationMs != null &&
          position < _durationMs! - 2000) {
        // 还在播且离结尾尚远：本地锚点漂了，按设备进度重锚。
        _trackStartedAtMs = now - position;
        return;
      }
      if (status == null && now < expectedEndMs + _deadlineGraceMs) {
        // 无证据时给一段宽限，避免查询失败误切（蓝本 #124 的有界等待）。
        return;
      }
      await _advance();
    }
  }

  // ===== 内部 =====

  void _resetTrackTracking(int? durationMs) {
    _trackStartedAtMs = _clock.nowMs();
    _durationMs = durationMs;
    _maxPositionMs = 0;
    _lastPositionMs = null;
    _idleHits = 0;
    _foreignHits = 0;
  }

  void _endSession(RelayEndReason reason) {
    if (!_active) return;
    _active = false;
    _generation++;
    _poke();
    _onNowPlayingChanged?.call(null);
    _onSessionEnded?.call(reason);
  }

  void _poke() {
    final signal = _wakeSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }
}

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

/// 接管引擎：意图 → 压制原生 → 解析 → 推播 → 验证 → 接力。
///
/// 接管时序（蓝本实测，见协议文档 1.6）：指令匹配后先 pause→stop
/// 一轮，间隔 600ms 再一轮（固件从播报转媒体播放有落定时间，
/// 一轮停不干净），然后才解析与推播；推播成败以状态回读的
/// position 证据链为准，不看单次回执。
class TakeoverEngine {
  TakeoverEngine({
    required SpeakerGateway gateway,
    required TakeoverClock clock,
    required SpeakerSongResolver resolver,
    required MinaDevice device,
    SpeakerQueueTailProvider? queueTailProvider,
    SpeakerStreamProxy? streamProxy,
    void Function(TakeoverRecord record)? onTakeoverRecord,
    void Function(SpeakerNowPlaying? nowPlaying)? onNowPlayingChanged,
    void Function(String message)? onLog,
  }) : _gateway = gateway,
       _clock = clock,
       _resolver = resolver,
       _device = device,
       _streamProxy = streamProxy,
       _queueTailProvider = queueTailProvider,
       _onTakeoverRecord = onTakeoverRecord,
       _onNowPlayingChanged = onNowPlayingChanged,
       _onLog = onLog;

  final SpeakerGateway _gateway;
  final TakeoverClock _clock;
  final SpeakerSongResolver _resolver;
  final MinaDevice _device;
  final SpeakerStreamProxy? _streamProxy;
  final SpeakerQueueTailProvider? _queueTailProvider;
  final void Function(TakeoverRecord record)? _onTakeoverRecord;
  final void Function(SpeakerNowPlaying? nowPlaying)? _onNowPlayingChanged;
  final void Function(String message)? _onLog;

  SpeakerRelay? _relay;

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
        await _gateway.setVolume(_deviceId, intent.value);
        return true;
      case VolumeStepIntent():
        return _handleVolumeStep(intent);
    }
  }

  /// pause→stop 两轮压制原生（间隔 600ms，蓝本实测值）。
  ///
  /// 每一步的回执都不作数：pause 被拒也要继续试 stop，
  /// 一轮停不干净是常态，第二轮才兜底。
  Future<void> suppressNative() async {
    await _gateway.playerPause(_deviceId);
    await _gateway.playerStop(_deviceId);
    await _clock.sleep(const Duration(milliseconds: 600));
    await _gateway.playerPause(_deviceId);
    await _gateway.playerStop(_deviceId);
  }

  /// 宿主关闭接管时停接力（不动设备播放）。
  void shutdown() {
    _relay?.stop();
  }

  // ===== 点歌 =====

  Future<bool> _handlePlaySong(PlaySongIntent intent) async {
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
      return true;
    }

    final push = await publishViaProxyOrDirect(
      _streamProxy,
      resolved.url,
      onLog: _onLog,
    );
    final pushed = await _pushAndVerify(
      push.url,
      fetchedSignal: push.viaProxy
          ? () => _streamProxy!.wasFetched(push.url)
          : null,
    );
    final fetched =
        push.viaProxy && _streamProxy!.wasFetched(push.url);
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

    final tail = _queueTailProvider?.call(resolved) ?? const <SpeakerQueueItem>[];
    final relay = _ensureRelay();
    await relay.startWith(resolved, tail);
    return true;
  }

  Future<bool> _pushAndVerify(
    String url, {
    bool Function()? fetchedSignal,
  }) async {
    bool ok;
    if (_usePlayMusic) {
      ok = await _gateway.playMusic(_deviceId, url);
    } else {
      // play_url 无 REPLACE_ALL；压制阶段已停过，这里直接推。
      ok = await _gateway.playUrl(_deviceId, url);
    }
    final verified = await verifyPushLanded(
      _gateway,
      _clock,
      _deviceId,
      fetchedSignal: fetchedSignal,
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

  Future<bool> _handleVolumeStep(VolumeStepIntent intent) async {
    final status = await _gateway.getPlayerStatus(_deviceId);
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

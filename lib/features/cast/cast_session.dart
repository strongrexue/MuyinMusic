import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/app_logger.dart';
import '../player/player_audio_handler.dart';
import '../player/player_controller.dart';
import 'av_transport_client.dart';
import 'cast_advance.dart';
import 'cast_relay_server.dart';
import 'didl_lite.dart';
import 'dlna_device.dart';
import 'dlna_discovery.dart';

enum CastPhase { idle, connecting, casting, failed }

class CastSessionState {
  const CastSessionState({
    this.phase = CastPhase.idle,
    this.device,
    this.devices = const [],
    this.searching = false,
    this.usingRelay = false,
    this.errorMessage,
  });

  final CastPhase phase;
  final DlnaDevice? device;
  final List<DlnaDevice> devices;
  final bool searching;
  final bool usingRelay;
  final String? errorMessage;

  bool get isCasting =>
      phase == CastPhase.connecting || phase == CastPhase.casting;

  CastSessionState copyWith({
    CastPhase? phase,
    DlnaDevice? device,
    List<DlnaDevice>? devices,
    bool? searching,
    bool? usingRelay,
    String? errorMessage,
    bool clearDevice = false,
    bool clearError = false,
  }) {
    return CastSessionState(
      phase: phase ?? this.phase,
      device: clearDevice ? null : (device ?? this.device),
      devices: devices ?? this.devices,
      searching: searching ?? this.searching,
      usingRelay: usingRelay ?? this.usingRelay,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Owns the DLNA cast session: discovery, the renderer control client,
/// the relay fallback, the 1 s position poll that drives both the player
/// state and the system media card, and queue advancement (renderers like
/// the Xiaomi speakers have a stub SetNextAVTransportURI, so the queue is
/// advanced from here).
///
/// Transport routing: this controller installs itself as the
/// [PlayerCastHooks] of the player controller, so UI buttons and media
/// session controls reach the renderer through the normal player paths.
class CastController extends StateNotifier<CastSessionState>
    implements PlayerCastHooks {
  CastController(this._ref) : super(const CastSessionState());

  final Ref _ref;
  final DlnaDiscovery _discovery = DlnaDiscovery();
  final CastRelayServer _relay = CastRelayServer();

  StreamSubscription<DlnaDevice>? _discoverySub;
  AvTransportClient? _client;
  Timer? _pollTimer;
  int _sessionSerial = 0;
  int _pollFailures = 0;
  bool _advancing = false;
  bool _expectPaused = false;
  bool _wasPlaying = false;
  Duration _lastPosition = Duration.zero;
  DateTime? _trackStartedAt;
  bool _trackViaRelay = false;
  bool _trackRetried = false;

  PlayerController get _player => _ref.read(playerControllerProvider.notifier);
  PlayerAudioHandler get _handler => _ref.read(playerAudioHandlerProvider);

  // ------------------------------------------------------------------
  // Discovery
  // ------------------------------------------------------------------

  void startSearch() {
    state = state.copyWith(searching: true, devices: const [], clearError: true);
    unawaited(_discoverySub?.cancel());
    _discoverySub = _discovery.search().listen(
      (device) {
        if (!mounted) return;
        if (state.devices.any((d) => d.udn == device.udn)) return;
        state = state.copyWith(devices: [...state.devices, device]);
      },
      onDone: () {
        if (mounted) state = state.copyWith(searching: false);
      },
      onError: (Object _) {
        if (mounted) state = state.copyWith(searching: false);
      },
    );
  }

  void stopSearch() {
    _discovery.cancel();
    unawaited(_discoverySub?.cancel());
    _discoverySub = null;
    if (mounted) state = state.copyWith(searching: false);
  }

  // ------------------------------------------------------------------
  // Session lifecycle
  // ------------------------------------------------------------------

  Future<void> connect(DlnaDevice device) async {
    stopSearch();
    if (state.isCasting) await disconnect();
    final serial = ++_sessionSerial;
    state = CastSessionState(
      phase: CastPhase.connecting,
      device: device,
      devices: state.devices,
    );
    _client = AvTransportClient(device);
    _resetTrackBookkeeping();
    try {
      await _player.pauseLocalForCast();
      if (serial != _sessionSerial) return;
      _player.setCastHooks(this);
      final track = _player.state.track;
      if (track != null) {
        await _castTrack(track, autoPlay: true, serial: serial);
      }
      if (!mounted || serial != _sessionSerial) return;
      state = state.copyWith(phase: CastPhase.casting);
      _startPolling(serial);
    } on DlnaException catch (error) {
      if (serial != _sessionSerial) return;
      await _failSession(error);
    } catch (error) {
      if (serial != _sessionSerial) return;
      await _failSession(
        DlnaException(DlnaErrorKind.network, '投播失败：$error'),
      );
    }
  }

  /// Ends the cast: stops the renderer, tears down hooks/relay, and leaves
  /// local playback paused on the presented track.
  Future<void> disconnect() async {
    _sessionSerial++;
    _pollTimer?.cancel();
    _pollTimer = null;
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        await client.stop();
      } on DlnaException {
        // The renderer may already be gone; teardown continues regardless.
      }
    }
    if (_player.castHooks == this) _player.setCastHooks(null);
    await _relay.stop();
    _resetTrackBookkeeping();
    if (mounted) {
      state = CastSessionState(
        devices: state.devices,
        searching: state.searching,
      );
    }
    await _player.restoreLocalAfterCast();
  }

  Future<void> _failSession(DlnaException error) async {
    _sessionSerial++;
    _pollTimer?.cancel();
    _pollTimer = null;
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        await client.stop();
      } on DlnaException {
        // Best effort only.
      }
    }
    if (_player.castHooks == this) _player.setCastHooks(null);
    await _relay.stop();
    _resetTrackBookkeeping();
    if (mounted) {
      state = CastSessionState(
        phase: CastPhase.failed,
        devices: state.devices,
        errorMessage: _describeError(error),
      );
    }
    await _player.restoreLocalAfterCast();
  }

  void _resetTrackBookkeeping() {
    _pollFailures = 0;
    _advancing = false;
    _expectPaused = false;
    _wasPlaying = false;
    _lastPosition = Duration.zero;
    _trackStartedAt = null;
    _trackViaRelay = false;
    _trackRetried = false;
  }

  String _describeError(DlnaException error) => switch (error.kind) {
    DlnaErrorKind.timeout => '设备响应超时',
    DlnaErrorKind.network => '无法连接设备',
    DlnaErrorKind.httpStatus => '设备返回错误（${error.statusCode}）',
    DlnaErrorKind.soapFault => '设备拒绝了投播请求',
    DlnaErrorKind.malformed => error.message,
  };

  // ------------------------------------------------------------------
  // Track casting
  // ------------------------------------------------------------------

  Future<void> _castTrack(
    PlayerTrack track, {
    required bool autoPlay,
    required int serial,
  }) async {
    final client = _client;
    if (client == null) return;
    _trackViaRelay = false;
    _trackRetried = false;
    _trackStartedAt = DateTime.now();
    _lastPosition = Duration.zero;
    _wasPlaying = false;
    _expectPaused = !autoPlay;

    final localPath = track.localPath;
    final String playUri;
    if (localPath != null && localPath.isNotEmpty) {
      playUri = (await _relay.registerFile(File(localPath))).toString();
      _trackViaRelay = true;
    } else {
      final remote = track.remoteUrl;
      if (remote == null || remote.isEmpty) {
        throw const DlnaException(
          DlnaErrorKind.malformed,
          '这首歌没有可投播的播放地址',
        );
      }
      playUri = remote;
    }
    if (serial != _sessionSerial) return;
    final playerState = _player.state;
    final metadata = buildDidlLite(
      uri: playUri,
      title: track.title,
      artist: track.artist,
      album: track.album,
      albumArtUri: track.coverUrl,
      duration: playerState.track?.id == track.id
          ? playerState.duration
          : null,
    );
    await client.setAvTransportUri(playUri, metadata);
    if (serial != _sessionSerial) return;
    if (autoPlay) await client.play();
    if (mounted && serial == _sessionSerial) {
      state = state.copyWith(usingRelay: _trackViaRelay);
    }
  }

  Future<void> _retryTrackViaRelay(int serial) async {
    final client = _client;
    final track = _player.state.track;
    if (client == null || track == null) return;
    final remote = track.remoteUrl;
    if (remote == null || remote.isEmpty) return;
    _trackRetried = true;
    _trackViaRelay = true;
    _trackStartedAt = DateTime.now();
    _lastPosition = Duration.zero;
    final relayUri = await _relay.registerRemote(Uri.parse(remote));
    if (serial != _sessionSerial) return;
    final metadata = buildDidlLite(
      uri: relayUri.toString(),
      title: track.title,
      artist: track.artist,
      album: track.album,
      albumArtUri: track.coverUrl,
    );
    await client.setAvTransportUri(relayUri.toString(), metadata);
    await client.play();
    if (mounted && serial == _sessionSerial) {
      state = state.copyWith(usingRelay: true);
    }
  }

  // ------------------------------------------------------------------
  // Polling: position sync + end-of-track + start-failure fallback
  // ------------------------------------------------------------------

  void _startPolling(int serial) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_poll(serial)),
    );
    unawaited(_poll(serial));
  }

  Future<void> _poll(int serial) async {
    final client = _client;
    if (client == null || !mounted || serial != _sessionSerial) return;
    if (_advancing) return;
    try {
      final transport = await client.getTransportInfo();
      final position = await client.getPositionInfo();
      if (!mounted || serial != _sessionSerial || _advancing) return;
      _pollFailures = 0;
      final playing =
          transport.state == AvTransportPlaybackState.playing ||
          transport.state == AvTransportPlaybackState.transitioning;

      if (!_expectPaused) {
        final decision = decideCastAdvance(
          transportState: transport.state,
          position: position.position,
          duration: position.trackDuration,
          previousPosition: _lastPosition,
          wasPlaying: _wasPlaying,
          playCommanded: true,
          sinceTrackStart: _trackStartedAt == null
              ? Duration.zero
              : DateTime.now().difference(_trackStartedAt!),
        );
        if (decision == CastAdvanceDecision.startFailed &&
            shouldFallbackToRelay(
              startedWithRelay: _trackViaRelay,
              isLocalFile: _player.state.track?.isLocal ?? false,
              alreadyRetried: _trackRetried,
            )) {
          await _retryTrackViaRelay(serial);
          return;
        }
        if (decision == CastAdvanceDecision.advance) {
          await _advanceQueue(serial);
          return;
        }
      }

      _wasPlaying = playing;
      _lastPosition = position.position;
      _player.syncCastPlayback(
        position: position.position,
        duration: position.trackDuration,
        playing: playing,
      );
      _handler.publishCastPlaybackState(
        playing: playing,
        position: position.position,
        duration: position.trackDuration,
      );
    } on DlnaException catch (error) {
      _pollFailures++;
      unawaited(
        AppLogger.write('dlna', 'poll failed ($_pollFailures): $error'),
      );
      if (_pollFailures >= 5 && serial == _sessionSerial) {
        await _failSession(
          const DlnaException(DlnaErrorKind.network, '与设备的连接已断开'),
        );
      }
    }
  }

  Future<void> _advanceQueue(int serial) async {
    _advancing = true;
    try {
      if (_player.state.playbackMode == PlayerPlaybackMode.repeatOne) {
        final track = _player.state.track;
        if (track != null) {
          await _castTrack(track, autoPlay: true, serial: serial);
        }
      } else {
        // Routes through the load interception → onTrackLoaded.
        await _player.castPlayNext();
      }
    } on DlnaException catch (error) {
      if (serial == _sessionSerial) await _failSession(error);
    } finally {
      _advancing = false;
    }
  }

  // ------------------------------------------------------------------
  // PlayerCastHooks
  // ------------------------------------------------------------------

  @override
  Future<void> onTrackLoaded(PlayerTrack track, {required bool autoPlay}) async {
    final serial = _sessionSerial;
    try {
      await _castTrack(track, autoPlay: autoPlay, serial: serial);
      if (mounted && serial == _sessionSerial && state.phase == CastPhase.connecting) {
        state = state.copyWith(phase: CastPhase.casting);
        _startPolling(serial);
      }
    } on DlnaException catch (error) {
      if (serial == _sessionSerial) await _failSession(error);
    }
  }

  @override
  Future<void> onToggle() async {
    final client = _client;
    if (client == null) return;
    try {
      if (_wasPlaying) {
        _expectPaused = true;
        await client.pause();
        _wasPlaying = false;
      } else {
        _expectPaused = false;
        await client.play();
        _wasPlaying = true;
      }
      _player.syncCastPlayback(
        position: _lastPosition,
        duration: _player.state.duration,
        playing: _wasPlaying,
      );
    } on DlnaException catch (error) {
      await _failSession(error);
    }
  }

  @override
  Future<void> onPause() async {
    final client = _client;
    if (client == null) return;
    _expectPaused = true;
    try {
      await client.pause();
      _wasPlaying = false;
    } on DlnaException {
      // A failed pause must not tear the session down (sleep timer path).
    }
  }

  @override
  Future<void> onSeek(Duration position) async {
    final client = _client;
    if (client == null) return;
    try {
      await client.seek(position);
      _lastPosition = position;
      _trackStartedAt = DateTime.now();
    } on DlnaException catch (error) {
      await _failSession(error);
    }
  }

  @override
  Future<void> onNext() => _player.castPlayNext();

  @override
  Future<void> onPrevious() => _player.castPlayPrevious();

  @override
  Future<void> onQueueItem(int index) => _player.castPlayQueueItem(index);

  @override
  void dispose() {
    _sessionSerial++;
    _pollTimer?.cancel();
    _discovery.cancel();
    unawaited(_discoverySub?.cancel());
    unawaited(_relay.stop());
    super.dispose();
  }
}

final castControllerProvider =
    StateNotifierProvider<CastController, CastSessionState>(
      (ref) => CastController(ref),
    );

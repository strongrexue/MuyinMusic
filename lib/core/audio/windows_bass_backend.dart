import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:bass_player/bass_player.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

// BASS 2.4 常量（bass.h，见 FFI 契约底稿）
const int _bassUnicode = 0x80000000;
const int _bassPosByte = 0;
const int _bassAttribVol = 2;
const int _bassFxDx8Parameq = 7;
const int _activeStopped = 0;

/// BASS 自带的 DX8 参数均衡器参数结构（bass.h BASS_DX8_PARAMEQ）。
final class _Dx8Parameq extends ffi.Struct {
  @ffi.Float()
  external double fCenter;

  @ffi.Float()
  external double fBandwidth;

  @ffi.Float()
  external double fGain;
}

/// Windows 桌面端的 BASS 后端：dart:ffi 直封 bass.dll，实现 [BassBackend]
/// 抽象，按原 MethodChannel 的 Map 契约收发。
///
/// 位置由 bass_player.dart 侧 40ms 插值器推进，本后端只在状态变化时推
/// snapshot；播放结束用 Timer 轮询 BASS_ChannelIsActive 检测（避开在 native
/// 更新线程跨线程回调 Dart 的风险）。
class WindowsBassBackend implements BassBackend {
  WindowsBassBackend() {
    _dll = ffi.DynamicLibrary.open(_resolveDllPath());
    _bind();
  }

  late final ffi.DynamicLibrary _dll;

  late final int Function() _getVersion;
  late final int Function() _errorGetCode;
  late final int Function(int, int, int, ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>) _init;
  late final int Function() _free;
  late final int Function(int, int, double) _channelSetAttribute;
  late final int Function(int, ffi.Pointer<ffi.Void>, int, int, int)
      _streamCreateFile;
  late final int Function(ffi.Pointer<Utf8>, int, int, ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>) _streamCreateUrl;
  late final int Function(int) _streamFree;
  late final double Function(int, int) _channelBytes2Seconds;
  late final int Function(int, double) _channelSeconds2Bytes;
  late final int Function(int) _channelIsActive;
  late final int Function(int, int) _channelPlay;
  late final int Function(int) _channelStop;
  late final int Function(int) _channelPause;
  late final int Function(int, int) _channelGetLength;
  late final int Function(int, int, int) _channelSetPosition;
  late final int Function(int, int) _channelGetPosition;
  late final int Function(int, int, int) _channelSetFx;
  late final int Function(int, int) _channelRemoveFx;
  late final int Function(int, ffi.Pointer<ffi.Void>) _fxSetParameters;

  final StreamController<Object?> _eventController =
      StreamController<Object?>.broadcast();

  @override
  Stream<Object?> get eventStream => _eventController.stream;

  int _stream = 0;
  bool _playing = false;
  String _processingState = 'idle';
  int _snapshotSeq = 0;
  String _sourceId = '';
  int? _durationMs;
  final List<int> _eqFx = <int>[];
  Timer? _watchTimer;
  bool _closed = false;

  void _bind() {
    _getVersion = _dll.lookupFunction<ffi.Uint32 Function(), int Function()>(
        'BASS_GetVersion');
    _errorGetCode = _dll.lookupFunction<ffi.Int32 Function(), int Function()>(
        'BASS_ErrorGetCode');
    _init = _dll.lookupFunction<
        ffi.Int32 Function(ffi.Int32, ffi.Uint32, ffi.Uint32,
            ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>),
        int Function(int, int, int, ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>)>('BASS_Init');
    _free = _dll.lookupFunction<ffi.Int32 Function(), int Function()>('BASS_Free');
    _channelSetAttribute = _dll.lookupFunction<
        ffi.Int32 Function(ffi.Uint32, ffi.Uint32, ffi.Float),
        int Function(int, int, double)>('BASS_ChannelSetAttribute');
    _streamCreateFile = _dll.lookupFunction<
        ffi.Uint32 Function(ffi.Int32, ffi.Pointer<ffi.Void>, ffi.Uint64,
            ffi.Uint64, ffi.Uint32),
        int Function(int, ffi.Pointer<ffi.Void>, int, int, int)>(
        'BASS_StreamCreateFile');
    _streamCreateUrl = _dll.lookupFunction<
        ffi.Uint32 Function(ffi.Pointer<Utf8>, ffi.Uint32, ffi.Uint32,
            ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>),
        int Function(ffi.Pointer<Utf8>, int, int, ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>)>('BASS_StreamCreateURL');
    _streamFree = _dll.lookupFunction<ffi.Int32 Function(ffi.Uint32),
        int Function(int)>('BASS_StreamFree');
    _channelBytes2Seconds = _dll.lookupFunction<
        ffi.Double Function(ffi.Uint32, ffi.Uint64),
        double Function(int, int)>('BASS_ChannelBytes2Seconds');
    _channelSeconds2Bytes = _dll.lookupFunction<
        ffi.Uint64 Function(ffi.Uint32, ffi.Double),
        int Function(int, double)>('BASS_ChannelSeconds2Bytes');
    _channelIsActive = _dll.lookupFunction<ffi.Uint32 Function(ffi.Uint32),
        int Function(int)>('BASS_ChannelIsActive');
    _channelPlay = _dll.lookupFunction<
        ffi.Int32 Function(ffi.Uint32, ffi.Int32),
        int Function(int, int)>('BASS_ChannelPlay');
    _channelStop = _dll.lookupFunction<ffi.Int32 Function(ffi.Uint32),
        int Function(int)>('BASS_ChannelStop');
    _channelPause = _dll.lookupFunction<ffi.Int32 Function(ffi.Uint32),
        int Function(int)>('BASS_ChannelPause');
    _channelGetLength = _dll.lookupFunction<
        ffi.Uint64 Function(ffi.Uint32, ffi.Uint32),
        int Function(int, int)>('BASS_ChannelGetLength');
    _channelSetPosition = _dll.lookupFunction<
        ffi.Int32 Function(ffi.Uint32, ffi.Uint64, ffi.Uint32),
        int Function(int, int, int)>('BASS_ChannelSetPosition');
    _channelGetPosition = _dll.lookupFunction<
        ffi.Uint64 Function(ffi.Uint32, ffi.Uint32),
        int Function(int, int)>('BASS_ChannelGetPosition');
    _channelSetFx = _dll.lookupFunction<
        ffi.Uint32 Function(ffi.Uint32, ffi.Int32, ffi.Int32),
        int Function(int, int, int)>('BASS_ChannelSetFX');
    _channelRemoveFx = _dll.lookupFunction<
        ffi.Int32 Function(ffi.Uint32, ffi.Uint32),
        int Function(int, int)>('BASS_ChannelRemoveFX');
    _fxSetParameters = _dll.lookupFunction<
        ffi.Int32 Function(ffi.Uint32, ffi.Pointer<ffi.Void>),
        int Function(int, ffi.Pointer<ffi.Void>)>('BASS_FXSetParameters');
  }

  String _resolveDllPath() {
    final exe = File(Platform.resolvedExecutable);
    final local = p.join(exe.parent.path, 'bass.dll');
    if (File(local).existsSync()) return local;
    const fallback = r'D:\projects\_muyin_windows\build\bass_spike\unzipped\x64\bass.dll';
    if (File(fallback).existsSync()) return fallback;
    throw StateError('bass.dll not found next to ${exe.path}');
  }

  Map<String, Object?> _snapshot({int? positionMsOverride}) {
    final positionMs = positionMsOverride ?? _currentPositionMs();
    return <String, Object?>{
      'event': 'snapshot',
      'processingState': _processingState,
      'playing': _playing,
      'positionMs': positionMs < 0 ? 0 : positionMs,
      'durationMs': _durationMs ?? -1,
      'bufferedPositionMs': _durationMs ?? 0,
      'sourceId': _sourceId,
      'snapshotSeq': ++_snapshotSeq,
      'networkAvailable': true,
    };
  }

  int _currentPositionMs() {
    if (_stream == 0) return 0;
    final bytes = _channelGetPosition(_stream, _bassPosByte);
    final seconds = _channelBytes2Seconds(_stream, bytes);
    return (seconds * 1000).round();
  }

  void _emit(Map<String, Object?> map) {
    if (!_eventController.isClosed) _eventController.add(map);
  }

  void _startWatcher() {
    _watchTimer?.cancel();
    _watchTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_closed) return;
      if (!_playing || _stream == 0) return;
      final active = _channelIsActive(_stream);
      if (active == _activeStopped) {
        _playing = false;
        _processingState = 'completed';
        _emit(_snapshot());
      }
    });
  }

  void _freeCurrentStream() {
    _watchTimer?.cancel();
    _watchTimer = null;
    _clearEq();
    if (_stream != 0) {
      _streamFree(_stream);
      _stream = 0;
    }
  }

  void _clearEq() {
    if (_stream == 0) return;
    for (final fx in _eqFx) {
      _channelRemoveFx(_stream, fx);
    }
    _eqFx.clear();
  }

  void _refreshDuration() {
    if (_stream == 0) {
      _durationMs = null;
      return;
    }
    final bytes = _channelGetLength(_stream, _bassPosByte);
    final seconds = _channelBytes2Seconds(_stream, bytes);
    _durationMs = seconds.isFinite && seconds > 0 ? (seconds * 1000).round() : null;
  }

  @override
  Future<Object?> invokeMethod(String method, [Object? arguments]) async {
    switch (method) {
      case 'setDiagnosticRecording':
        return <String, Object?>{'ok': true};

      case 'initialize':
        final ok = _init(-1, 44100, 0, ffi.nullptr, ffi.nullptr);
        if (ok == 0) {
          throw StateError('BASS_Init failed: code ${_errorGetCode()}');
        }
        final raw = _getVersion();
        final major = (raw >> 24) & 0xff;
        final minor = (raw >> 16) & 0xff;
        final rev = (raw >> 8) & 0xff;
        final build = raw & 0xff;
        _processingState = 'idle';
        return <String, Object?>{
          'version': '$major.$minor.$rev.$build',
          'fxVersion': '2.4',
          'plugins': <String, Object?>{},
        };

      case 'load':
        final args = arguments as Map<Object?, Object?>? ?? const {};
        final uri = args['uri']?.toString() ?? '';
        final isUrl = uri.startsWith('http://') || uri.startsWith('https://');
        _freeCurrentStream();
        _sourceId = uri;
        _processingState = 'loading';
        _playing = false;

        int handle;
        if (isUrl) {
          final urlPtr = uri.toNativeUtf8();
          try {
            handle = _streamCreateUrl(urlPtr, 0, 0, ffi.nullptr, ffi.nullptr);
          } finally {
            calloc.free(urlPtr);
          }
        } else {
          final pathPtr = uri.toNativeUtf16();
          try {
            handle = _streamCreateFile(
                0, pathPtr.cast<ffi.Void>(), 0, 0, _bassUnicode);
          } finally {
            calloc.free(pathPtr);
          }
        }
        if (handle == 0) {
          _processingState = 'error';
          throw StateError('BASS stream create failed: code ${_errorGetCode()}');
        }
        _stream = handle;
        _refreshDuration();
        _processingState = 'ready';
        _startWatcher();
        return _snapshot();

      case 'play':
        if (_stream != 0) {
          final ok = _channelPlay(_stream, 0);
          if (ok == 0) {
            _processingState = 'error';
            throw StateError('BASS_ChannelPlay failed: code ${_errorGetCode()}');
          }
          _playing = true;
          _processingState = 'ready';
        }
        final snap = _snapshot();
        _emit(snap);
        return snap;

      case 'pause':
        if (_stream != 0) {
          _channelPause(_stream);
          _playing = false;
        }
        final snap = _snapshot();
        _emit(snap);
        return snap;

      case 'stop':
        if (_stream != 0) {
          _channelStop(_stream);
        }
        _playing = false;
        _processingState = 'idle';
        final snap = _snapshot(positionMsOverride: 0);
        _emit(snap);
        return snap;

      case 'seek':
        final args = arguments as Map<Object?, Object?>? ?? const {};
        final positionMs = (args['positionMs'] as num?)?.toInt() ?? 0;
        if (_stream != 0) {
          final bytes = _channelSeconds2Bytes(_stream, positionMs / 1000.0);
          _channelSetPosition(_stream, bytes, _bassPosByte);
        }
        final snap = _snapshot(positionMsOverride: positionMs);
        _emit(snap);
        return snap;

      case 'setVolume':
        final args = arguments as Map<Object?, Object?>? ?? const {};
        final volume = (args['volume'] as num?)?.toDouble() ?? 1.0;
        if (_stream != 0) {
          _channelSetAttribute(_stream, _bassAttribVol, volume.clamp(0.0, 1.0));
        }
        return <String, Object?>{'ok': true};

      case 'setEqualizer':
        _applyEqualizer(arguments);
        return <String, Object?>{'ok': true};

      case 'setGrooveShift':
      case 'setGrooveShiftNext':
      case 'confirmGrooveShift':
      case 'cancelGrooveShift':
        return <String, Object?>{'ok': true};

      default:
        throw UnimplementedError('WindowsBassBackend: unknown method $method');
    }
  }

  void _applyEqualizer(Object? arguments) {
    if (_stream == 0) return;
    _clearEq();
    final cfg = arguments as Map<Object?, Object?>?;
    if (cfg == null || cfg['enabled'] != true) return;
    final bands = (cfg['bands'] as List<Object?>?) ?? const <Object?>[];
    for (final raw in bands) {
      if (raw is! Map<Object?, Object?>) continue;
      if (raw['enabled'] != true) continue;
      final fx = _channelSetFx(_stream, _bassFxDx8Parameq, 0);
      if (fx == 0) continue;
      final params = calloc<_Dx8Parameq>();
      try {
        params.ref.fCenter = (raw['frequencyHz'] as num?)?.toDouble() ?? 1000;
        final q = (raw['q'] as num?)?.toDouble() ?? 0.707;
        params.ref.fBandwidth = q > 0 ? 1.0 / q : 1.0;
        params.ref.fGain = (raw['gainDb'] as num?)?.toDouble() ?? 0;
        _fxSetParameters(fx, params.cast<ffi.Void>());
        _eqFx.add(fx);
      } finally {
        calloc.free(params);
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _freeCurrentStream();
    _free();
    await _eventController.close();
  }
}

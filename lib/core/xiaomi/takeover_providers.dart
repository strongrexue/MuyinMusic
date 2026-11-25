import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/music_api.dart';
import '../music_sources/music_url_resolver.dart';
import '../../features/player/player_controller.dart';
import '../storage/settings_store.dart';
import 'lan_stream_server.dart';
import 'mina_models.dart';
import 'panghu_speaker_adapter.dart';
import 'takeover/conversation_monitor.dart';
import 'takeover/dispatch.dart';
import 'takeover/quiet.dart';
import 'takeover/speaker_gateway.dart';
import 'takeover/speaker_resolver.dart';
import 'takeover/takeover_clock.dart';
import 'takeover/takeover_engine.dart';
import 'takeover/takeover_log.dart';
import 'takeover/takeover_state.dart';
import 'takeover/wake_word_filter.dart';
import 'xiaoai_foreground_host.dart';
import 'xiaomi_providers.dart';

/// 待恢复音量的落盘键（按设备分键；有键 = 有一笔音量等着恢复）。
String xiaoaiPendingVolumePrefsKey(String deviceId) =>
    'xiaoai_speaker_pending_volume_v1:$deviceId';

/// [TakeoverMuteStore] 的 SharedPreferences 实现（TrackFerry
/// PendingVolume 语义：save 已有条目不覆盖、change 只改已有条目、
/// 恢复成功后才清除）。
class SharedPreferencesTakeoverMuteStore implements TakeoverMuteStore {
  SharedPreferencesTakeoverMuteStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  Future<int?> readPendingVolume(String deviceId) async =>
      _prefs.getInt(xiaoaiPendingVolumePrefsKey(deviceId));

  @override
  Future<void> savePendingVolume(String deviceId, int volume) async {
    final key = xiaoaiPendingVolumePrefsKey(deviceId);
    if (_prefs.containsKey(key)) return; // 已有条目保留，不覆盖
    await _prefs.setInt(key, volume);
  }

  @override
  Future<bool> changePendingVolume(String deviceId, int volume) async {
    final key = xiaoaiPendingVolumePrefsKey(deviceId);
    if (!_prefs.containsKey(key)) return false;
    await _prefs.setInt(key, volume);
    return true;
  }

  @override
  Future<void> clearPendingVolume(String deviceId) async {
    await _prefs.remove(xiaoaiPendingVolumePrefsKey(deviceId));
  }
}

/// 胖虎音源适配器（topone 接缝实现）。
final speakerSongResolverProvider = Provider<SpeakerSongResolver>((ref) {
  return PanghuSpeakerSongResolver(
    api: ref.watch(musicApiProvider),
    urlResolver: ref.watch(musicUrlResolverProvider),
  );
});

final xiaoaiForegroundHostProvider = Provider<XiaoaiForegroundHost>((ref) {
  return const XiaoaiForegroundHost();
});

/// 局域网流代理服务（音箱推播时代理直链的宿主实现）。
final speakerStreamServerProvider = Provider<LanStreamServer>((ref) {
  return LanStreamServer();
});

/// 诊断日志的落盘键（环形缓冲快照，字符串列表）。
const String xiaoaiDiagnosticLogPrefsKey = 'xiaoai_takeover_diagnostic_log_v1';

/// 接管状态（模块三 UI 消费）：enable/disable 由设置页驱动。
final xiaoaiTakeoverControllerProvider =
    StateNotifierProvider<XiaoaiTakeoverController, XiaoaiTakeoverState>((ref) {
      final client = ref.watch(minaClientProvider);
      final prefs = ref.watch(sharedPreferencesProvider);
      return XiaoaiTakeoverController(
        gateway: MinaClientGateway(client),
        sessionValidator: client.validateToken,
        resolver: ref.watch(speakerSongResolverProvider),
        streamServer: ref.watch(speakerStreamServerProvider),
        muteStore: SharedPreferencesTakeoverMuteStore(prefs),
        diagnosticLog: TakeoverLogBuffer(
          initial: prefs.getStringList(xiaoaiDiagnosticLogPrefsKey) ?? [],
          onChanged: (entries) => unawaited(
            prefs.setStringList(xiaoaiDiagnosticLogPrefsKey, entries),
          ),
        ),
        host: ref.watch(xiaoaiForegroundHostProvider),
        queueTailProvider: (song) =>
            buildSpeakerQueueTail(ref.read(playerControllerProvider), song),
      );
    });

/// 接管总控：把监听器、分发层、接管引擎、前台宿主串起来。
///
/// 本类只做接线与状态汇总，业务全在核心层
/// （ConversationMonitor / TakeoverDispatcher / TakeoverEngine）。
class XiaoaiTakeoverController extends StateNotifier<XiaoaiTakeoverState> {
  XiaoaiTakeoverController({
    required SpeakerGateway gateway,
    required SpeakerSongResolver resolver,
    required LanStreamServer streamServer,
    required XiaoaiForegroundHost host,
    required SpeakerQueueTailProvider queueTailProvider,
    TakeoverMuteStore? muteStore,
    TakeoverLogBuffer? diagnosticLog,
    Future<bool> Function()? sessionValidator,
    void Function(String message)? onLog,
  }) : _gateway = gateway,
       _resolver = resolver,
       _streamServer = streamServer,
       _muteStore = muteStore,
       _diagnosticLog = diagnosticLog,
       _host = host,
       _queueTailProvider = queueTailProvider,
       _sessionValidator = sessionValidator,
       _onLog = onLog,
       super(
         XiaoaiTakeoverState(diagnosticLog: diagnosticLog?.entries ?? const []),
       ) {
    // 推流事件（取流/重开/换链/断流）并入接管诊断日志：流服务
    // 由 provider 独立构造，此前 onLog 无人接，断流零证据。
    _streamServer.onLog = _log;
  }

  final SpeakerGateway _gateway;
  final SpeakerSongResolver _resolver;
  final LanStreamServer _streamServer;
  final TakeoverMuteStore? _muteStore;
  final TakeoverLogBuffer? _diagnosticLog;
  final XiaoaiForegroundHost _host;
  final SpeakerQueueTailProvider _queueTailProvider;
  final Future<bool> Function()? _sessionValidator;
  final void Function(String message)? _onLog;

  /// 日志落点：写环形缓冲（落盘）+ 同步进状态供页面展示，
  /// 再转发外部 onLog。此前控制器没人传 onLog，引擎/监听的
  /// 日志全部丢弃，设备端零痕迹（1.3.27 审计定版）。
  void _log(String message) {
    final buffer = _diagnosticLog;
    if (buffer != null) {
      buffer.add(message);
      if (mounted) {
        state = state.copyWith(diagnosticLog: buffer.entries);
      }
    }
    _onLog?.call(message);
  }

  ConversationMonitor? _monitor;
  TakeoverEngine? _engine;
  TakeoverDispatcher? _dispatcher;
  int _enableGen = 0;

  WakeWordFilter _wakeWordFilter = const WakeWordFilter.disabled();

  /// 设置层同步专属口令过滤（开关/口令词变更时调用）。
  void setWakeWordFilter(WakeWordFilter filter) {
    _wakeWordFilter = filter;
  }

  /// 监听启动自检（TrackFerry `RecoverVolumes` 的单次版）：上一轮
  /// 接管若把音箱留在静音（App 被杀/恢复失败），落盘里留有待恢复
  /// 音量——当前音量仍为 0 就设回去并清除；已被人调大（>0）则
  /// 只清落盘；读不到状态就留着下次再试。
  Future<void> recoverPendingVolumeOnStart(MinaDevice device) async {
    final store = _muteStore;
    if (store == null) return;
    try {
      final pending = await store.readPendingVolume(device.deviceId);
      if (pending == null) return;
      final status = await _gateway.getPlayerStatus(device.deviceId);
      final volume = status?.volume;
      if (volume == null) return;
      if (volume > 0) {
        await store.clearPendingVolume(device.deviceId);
        return;
      }
      final ok = await _gateway.setVolume(device.deviceId, pending);
      if (ok) {
        await store.clearPendingVolume(device.deviceId);
        _log('takeover recovered muted volume $pending');
      }
    } catch (e) {
      _log('takeover volume recovery check error: $e');
    }
  }

  /// 对选定音箱开启接管：先探活登录态，再起监听与前台服务。
  Future<void> enable(MinaDevice device) async {
    await disable(keepRecord: true);
    await recoverPendingVolumeOnStart(device);

    if (_sessionValidator != null) {
      bool valid;
      try {
        valid = await _sessionValidator();
      } catch (_) {
        valid = false;
      }
      if (!valid) {
        state = state.copyWith(
          phase: TakeoverPhase.error,
          deviceName: _displayName(device),
          errorMessage: '登录态已失效，请重新登录',
        );
        return;
      }
    }

    // 流代理起不来不阻断接管：推播时自动回退直推。
    try {
      await _streamServer.start();
    } catch (e) {
      _log('stream server start failed: $e');
    }

    const clock = SystemTakeoverClock();
    void onRecord(TakeoverRecord record) {
      if (mounted) {
        state = state.copyWith(
          lastRecord: record,
          records: prependTakeoverRecord(state.records, record),
        );
      }
    }

    void onNowPlaying(SpeakerNowPlaying? nowPlaying) {
      if (!mounted) return;
      state = nowPlaying == null
          ? state.copyWith(clearNowPlaying: true)
          : state.copyWith(nowPlaying: nowPlaying);
    }

    final quiet = TakeoverQuiet(
      gateway: _gateway,
      clock: clock,
      store: _muteStore,
      deviceId: device.deviceId,
      onLog: _log,
    );
    final engine = TakeoverEngine(
      gateway: _gateway,
      clock: clock,
      device: device,
      quiet: quiet,
      onTakeoverRecord: onRecord,
      onNowPlayingChanged: onNowPlaying,
      onLog: _log,
    );
    final dispatcher = TakeoverDispatcher(
      engine: engine,
      resolver: _resolver,
      streamProxy: _streamServer,
      clock: clock,
      queueTailProvider: _queueTailProvider,
      onTakeoverRecord: onRecord,
      onLog: _log,
    );
    final monitor = ConversationMonitor(
      fetcher: () => _gateway.fetchLatestAsk(
        deviceId: device.deviceId,
        hardware: device.hardware,
        limit: 5,
      ),
      clock: clock,
      onRecord: (record, seenMs) {
        final query = _wakeWordFilter.apply(record.query);
        if (query == null) return; // 未命中口令：放行原生，不接管
        // 不 await：一条指令的处理（找歌/守卫/watch）不阻塞
        // 轮询，新指令由分发/引擎的代际机制取代旧流程。口令
        // 剥除后的文本以新记录形态进分发（时间戳不变）。
        final effective = query == record.query
            ? record
            : ConversationRecord(
                timeMs: record.timeMs,
                query: query,
                answers: record.answers,
                requestId: record.requestId,
              );
        unawaited(
          dispatcher.onCommand(effective, seenMs).catchError((Object e) {
            _log('takeover dispatch error: $e');
          }),
        );
      },
      onLog: _log,
    );
    _engine = engine;
    _dispatcher = dispatcher;
    _monitor = monitor;
    state = XiaoaiTakeoverState(
      phase: TakeoverPhase.listening,
      deviceName: _displayName(device),
      lastRecord: state.lastRecord,
      records: state.records,
      diagnosticLog: state.diagnosticLog,
    );
    unawaited(_host.start());
    monitor.start();
    final gen = ++_enableGen;
    unawaited(_recoverLoop(engine, gen));
  }

  /// RecoverVolumes（蓝本）：每 20 秒扫一遍待恢复音量，
  /// 被当前接管持有时引擎内部会跳过；接管途中崩溃也不会把
  /// 音箱永久留在静音。
  Future<void> _recoverLoop(TakeoverEngine engine, int gen) async {
    while (mounted && gen == _enableGen && _engine == engine) {
      await Future<void>.delayed(const Duration(seconds: 20));
      if (!mounted || gen != _enableGen || _engine != engine) return;
      try {
        await engine.recoverVolumesOnce();
      } catch (e) {
        _log('takeover recover volumes error: $e');
      }
    }
  }

  /// 关闭接管：停监听、停分发、撤前台服务（先恢复可能持有的静音）。
  Future<void> disable({bool keepRecord = false}) async {
    _enableGen++;
    _monitor?.stop();
    _monitor = null;
    _dispatcher?.halt();
    _dispatcher = null;
    try {
      await _engine?.restoreVolumeNow();
    } catch (_) {
      // 恢复失败不影响关闭；落盘条目留待 RecoverVolumes 兜底。
    }
    _engine?.shutdown();
    _engine = null;
    try {
      await _streamServer.stop();
    } catch (_) {
      // 停流服务失败不影响关闭接管。
    }
    await _host.stop();
    if (mounted) {
      state = XiaoaiTakeoverState(
        phase: TakeoverPhase.disabled,
        lastRecord: keepRecord ? state.lastRecord : null,
        records: keepRecord ? state.records : const [],
        diagnosticLog: state.diagnosticLog,
      );
    }
  }

  @override
  void dispose() {
    _monitor?.stop();
    _engine?.shutdown();
    super.dispose();
  }

  static String _displayName(MinaDevice device) {
    if (device.name.isNotEmpty) return device.name;
    if (device.alias.isNotEmpty) return device.alias;
    return device.hardware;
  }
}

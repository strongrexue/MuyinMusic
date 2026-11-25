import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/music_api.dart';
import '../music_sources/music_url_resolver.dart';
import '../../features/player/player_controller.dart';
import 'lan_stream_server.dart';
import 'mina_models.dart';
import 'panghu_speaker_adapter.dart';
import 'takeover/conversation_monitor.dart';
import 'takeover/speaker_gateway.dart';
import 'takeover/speaker_intent.dart';
import 'takeover/speaker_resolver.dart';
import 'takeover/takeover_clock.dart';
import 'takeover/takeover_engine.dart';
import 'takeover/takeover_state.dart';
import 'takeover/wake_word_filter.dart';
import 'xiaoai_foreground_host.dart';
import 'xiaomi_providers.dart';

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

/// 接管状态（模块三 UI 消费）：enable/disable 由设置页驱动。
final xiaoaiTakeoverControllerProvider =
    StateNotifierProvider<XiaoaiTakeoverController, XiaoaiTakeoverState>((
      ref,
    ) {
      final client = ref.watch(minaClientProvider);
      return XiaoaiTakeoverController(
        gateway: MinaClientGateway(client),
        sessionValidator: client.validateToken,
        resolver: ref.watch(speakerSongResolverProvider),
        streamServer: ref.watch(speakerStreamServerProvider),
        host: ref.watch(xiaoaiForegroundHostProvider),
        queueTailProvider: (song) =>
            buildSpeakerQueueTail(ref.read(playerControllerProvider), song),
      );
    });

/// 接管总控：把监听器、接管引擎、前台宿主串起来。
///
/// 本类只做接线与状态汇总，业务全在核心层
/// （ConversationMonitor / TakeoverEngine / SpeakerRelay）。
class XiaoaiTakeoverController extends StateNotifier<XiaoaiTakeoverState> {
  XiaoaiTakeoverController({
    required SpeakerGateway gateway,
    required SpeakerSongResolver resolver,
    required LanStreamServer streamServer,
    required XiaoaiForegroundHost host,
    required SpeakerQueueTailProvider queueTailProvider,
    Future<bool> Function()? sessionValidator,
    void Function(String message)? onLog,
  }) : _gateway = gateway,
       _resolver = resolver,
       _streamServer = streamServer,
       _host = host,
       _queueTailProvider = queueTailProvider,
       _sessionValidator = sessionValidator,
       _onLog = onLog,
       super(const XiaoaiTakeoverState());

  final SpeakerGateway _gateway;
  final SpeakerSongResolver _resolver;
  final LanStreamServer _streamServer;
  final XiaoaiForegroundHost _host;
  final SpeakerQueueTailProvider _queueTailProvider;
  final Future<bool> Function()? _sessionValidator;
  final void Function(String message)? _onLog;

  ConversationMonitor? _monitor;
  TakeoverEngine? _engine;

  WakeWordFilter _wakeWordFilter = const WakeWordFilter.disabled();

  /// 设置层同步专属口令过滤（开关/口令词变更时调用）。
  void setWakeWordFilter(WakeWordFilter filter) {
    _wakeWordFilter = filter;
  }

  /// 对选定音箱开启接管：先探活登录态，再起监听与前台服务。
  Future<void> enable(MinaDevice device) async {
    await disable(keepRecord: true);

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
      _onLog?.call('stream server start failed: $e');
    }

    const clock = SystemTakeoverClock();
    final engine = TakeoverEngine(
      gateway: _gateway,
      clock: clock,
      resolver: _resolver,
      device: device,
      streamProxy: _streamServer,
      queueTailProvider: _queueTailProvider,
      onTakeoverRecord: (record) {
        if (mounted) {
          state = state.copyWith(
            lastRecord: record,
            records: prependTakeoverRecord(state.records, record),
          );
        }
      },
      onNowPlayingChanged: (nowPlaying) {
        if (!mounted) return;
        state = nowPlaying == null
            ? state.copyWith(clearNowPlaying: true)
            : state.copyWith(nowPlaying: nowPlaying);
      },
      onLog: _onLog,
    );
    final monitor = ConversationMonitor(
      fetcher: () => _gateway.fetchLatestAsk(
        deviceId: device.deviceId,
        hardware: device.hardware,
        limit: 5,
      ),
      clock: clock,
      onRecord: (record) async {
        final query = _wakeWordFilter.apply(record.query);
        if (query == null) return; // 未命中口令：放行原生，不接管
        final intent = parseSpeakerIntent(query);
        if (intent == null) return; // 不认识的指令交还原生
        await engine.handleIntent(intent);
      },
      onLog: _onLog,
    );
    _engine = engine;
    _monitor = monitor;
    state = XiaoaiTakeoverState(
      phase: TakeoverPhase.listening,
      deviceName: _displayName(device),
      lastRecord: state.lastRecord,
      records: state.records,
    );
    unawaited(_host.start());
    monitor.start();
  }

  /// 关闭接管：停监听、停接力、撤前台服务。
  Future<void> disable({bool keepRecord = false}) async {
    _monitor?.stop();
    _monitor = null;
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

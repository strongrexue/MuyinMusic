import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/music_api.dart';
import '../music_sources/music_url_resolver.dart';
import '../../features/player/player_controller.dart';
import 'mina_models.dart';
import 'panghu_speaker_adapter.dart';
import 'takeover/conversation_monitor.dart';
import 'takeover/speaker_gateway.dart';
import 'takeover/speaker_intent.dart';
import 'takeover/speaker_resolver.dart';
import 'takeover/takeover_clock.dart';
import 'takeover/takeover_engine.dart';
import 'takeover/takeover_state.dart';
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
    required XiaoaiForegroundHost host,
    required SpeakerQueueTailProvider queueTailProvider,
    Future<bool> Function()? sessionValidator,
    void Function(String message)? onLog,
  }) : _gateway = gateway,
       _resolver = resolver,
       _host = host,
       _queueTailProvider = queueTailProvider,
       _sessionValidator = sessionValidator,
       _onLog = onLog,
       super(const XiaoaiTakeoverState());

  final SpeakerGateway _gateway;
  final SpeakerSongResolver _resolver;
  final XiaoaiForegroundHost _host;
  final SpeakerQueueTailProvider _queueTailProvider;
  final Future<bool> Function()? _sessionValidator;
  final void Function(String message)? _onLog;

  ConversationMonitor? _monitor;
  TakeoverEngine? _engine;

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

    const clock = SystemTakeoverClock();
    final engine = TakeoverEngine(
      gateway: _gateway,
      clock: clock,
      resolver: _resolver,
      device: device,
      queueTailProvider: _queueTailProvider,
      onTakeoverRecord: (record) {
        if (mounted) state = state.copyWith(lastRecord: record);
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
        final intent = parseSpeakerIntent(record.query);
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
    await _host.stop();
    if (mounted) {
      state = XiaoaiTakeoverState(
        phase: TakeoverPhase.disabled,
        lastRecord: keepRecord ? state.lastRecord : null,
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

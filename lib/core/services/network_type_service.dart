import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 网络类型通道约定（Dart / Android / iOS 三端必须一致）：
/// - MethodChannel 'cy_shine_music/network_type'：方法 getNetworkType，
///   返回 'wifi' 或 'cellular'。
/// - EventChannel 'cy_shine_music/network_type_events'：推送 'wifi' 或
///   'cellular' 字符串。
const String kNetworkTypeMethodChannel = 'cy_shine_music/network_type';
const String kNetworkTypeEventChannel = 'cy_shine_music/network_type_events';

/// 与原生两端通信的无状态服务。单独抽出来便于测试时替换/覆盖。
class NetworkTypeService {
  const NetworkTypeService({
    required this.methodChannel,
    required this.eventChannel,
  });

  final MethodChannel methodChannel;
  final EventChannel eventChannel;

  /// 读取当前网络是否 WiFi。原生通道缺失（单测/桌面）时回退为 WiFi。
  Future<bool> readIsWiFi() async {
    try {
      final value = await methodChannel.invokeMethod<String>('getNetworkType');
      return value != 'cellular';
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }

  /// 监听网络类型变化；把 'wifi'/'cellular' 映射为 bool。
  /// 原生 EventChannel 不存在时会产生 error 事件，这里吞掉以免污染调用方。
  Stream<bool> watchIsWiFi() {
    return eventChannel
        .receiveBroadcastStream()
        .handleError((_) {})
        .map((event) => event != 'cellular');
  }
}

final networkTypeServiceProvider = Provider<NetworkTypeService>((ref) {
  return const NetworkTypeService(
    methodChannel: MethodChannel(kNetworkTypeMethodChannel),
    eventChannel: EventChannel(kNetworkTypeEventChannel),
  );
});

/// 同步暴露当前是否 WiFi 的 Riverpod provider。
/// state 即 isWiFi：build() 先给同步默认值 true（WiFi），随后异步读原生初值，
/// 并订阅 EventChannel 在类型变化时更新 state。
final networkTypeProvider =
    NotifierProvider<NetworkTypeNotifier, bool>(NetworkTypeNotifier.new);

class NetworkTypeNotifier extends Notifier<bool> {
  StreamSubscription<bool>? _subscription;
  bool _disposed = false;

  @override
  bool build() {
    final service = ref.read(networkTypeServiceProvider);
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _subscription?.cancel();
      _subscription = null;
    });

    _subscription = service.watchIsWiFi().listen(
      (isWiFi) {
        if (!_disposed && state != isWiFi) state = isWiFi;
      },
      onError: (_) {},
    );

    unawaited(() async {
      final isWiFi = await service.readIsWiFi();
      if (!_disposed && state != isWiFi) state = isWiFi;
    }());

    return true;
  }

  /// 同步 getter：供播放控制器在选档时读取。
  bool get isWiFi => state;

  /// 网络类型变化流：供需要即时响应的调用方订阅。
  Stream<bool> get changes =>
      ref.read(networkTypeServiceProvider).watchIsWiFi();
}

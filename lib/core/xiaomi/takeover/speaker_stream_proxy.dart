/// 音箱推播的局域网流代理接缝（纯 Dart 接口）。
///
/// 核心只认此接口：把上游直链注册成代理地址，推给音箱的是代理的
/// 局域网 URL，音箱取流时由宿主实现起 HTTP 服务转发字节
/// （蓝本 TrackFerry stream 模式）。核心不感知服务细节，
/// 搬到 headless 服务端时换实现即可。
library;

/// 局域网流代理接口。
abstract interface class SpeakerStreamProxy {
  /// 把上游直链注册为代理地址，返回推给音箱的局域网 URL；
  /// 代理不可用（服务未启动 / 取不到局域网 IP）返回 null，调用方回退直推。
  Future<String?> publish(String upstreamUrl);

  /// 该推播 URL 是否已被音箱取流（按 publish 返回的完整 URL 查）。
  bool wasFetched(String pushUrl);
}

/// 经代理发布 [upstreamUrl]：proxy 为 null、publish 返回 null 或抛异常
/// 时回退直推（viaProxy=false），异常经 [onLog] 记一笔。
Future<({String url, bool viaProxy})> publishViaProxyOrDirect(
  SpeakerStreamProxy? proxy,
  String upstreamUrl, {
  void Function(String message)? onLog,
}) async {
  if (proxy == null) return (url: upstreamUrl, viaProxy: false);
  try {
    final published = await proxy.publish(upstreamUrl);
    if (published == null) return (url: upstreamUrl, viaProxy: false);
    return (url: published, viaProxy: true);
  } catch (e) {
    onLog?.call('stream proxy publish failed, fallback direct: $e');
    return (url: upstreamUrl, viaProxy: false);
  }
}

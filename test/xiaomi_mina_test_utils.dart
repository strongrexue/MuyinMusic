import 'dart:convert';

import 'package:muyin_music/core/xiaomi/mina_http.dart';

/// 测试用请求记录。
class RecordedRequest {
  RecordedRequest(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;

  String get urlText => url.toString();

  /// 解析 form 编码的请求体。
  Map<String, String> get form {
    if (body == null) return const {};
    return {
      for (final pair in body!.split('&'))
        if (pair.contains('='))
          Uri.decodeComponent(pair.substring(0, pair.indexOf('='))):
              Uri.decodeComponent(pair.substring(pair.indexOf('=') + 1)),
    };
  }
}

typedef FakeTransportHandler =
    MinaHttpResponse Function(RecordedRequest request);

/// 按脚本回放响应的假传输层。
class FakeMinaTransport implements MinaHttpTransport {
  FakeMinaTransport(this._handler);

  final FakeTransportHandler _handler;
  final List<RecordedRequest> requests = [];

  @override
  Future<MinaHttpResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
    Duration? timeout,
  }) async {
    final request = RecordedRequest(method, url, headers, body);
    requests.add(request);
    return _handler(request);
  }

  List<RecordedRequest> requestsTo(String urlPart) =>
      requests.where((r) => r.urlText.contains(urlPart)).toList();
}

/// 构造一个 JSON 文本响应。
MinaHttpResponse fakeJsonResponse(
  String body, {
  int status = 200,
  List<String> setCookies = const [],
  Map<String, List<String>> headers = const {},
}) {
  return MinaHttpResponse(
    statusCode: status,
    bodyBytes: utf8.encode(body),
    headers: {'set-cookie': setCookies, ...headers},
  );
}

/// 构造一个重定向响应。
MinaHttpResponse fakeRedirect(
  String location, {
  List<String> setCookies = const [],
}) {
  return MinaHttpResponse(
    statusCode: 302,
    bodyBytes: const [],
    headers: {
      'location': [location],
      'set-cookie': setCookies,
    },
  );
}

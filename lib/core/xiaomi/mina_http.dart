import 'dart:convert';

import 'package:dio/dio.dart';

import '../api/dio_factory.dart';
import 'mina_constants.dart';

/// MiNA 协议层的一次 HTTP 响应（单跳，不跟随重定向）。
class MinaHttpResponse {
  const MinaHttpResponse({
    required this.statusCode,
    required this.bodyBytes,
    this.headers = const {},
  });

  final int statusCode;
  final List<int> bodyBytes;

  /// 响应头，键为小写头名。
  final Map<String, List<String>> headers;

  String get bodyText => utf8.decode(bodyBytes, allowMalformed: true);

  List<String> get setCookies => headers['set-cookie'] ?? const [];

  String? header(String name) {
    final values = headers[name.toLowerCase()];
    return values == null || values.isEmpty ? null : values.first;
  }
}

/// 可注入的 HTTP 传输层：只做单跳请求，重定向跟随与 Cookie 管理
/// 由上层（MinaAuth）负责，便于单测用假响应驱动。
abstract class MinaHttpTransport {
  Future<MinaHttpResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
    Duration? timeout,
  });
}

/// 基于本仓 [createDio] 的传输实现（IO 适配器，与仓内其他中国区
/// 接口调用保持同一网络栈）。
class DioMinaHttpTransport implements MinaHttpTransport {
  DioMinaHttpTransport({Dio? dio}) : _dio = dio ?? _buildDio();

  final Dio _dio;

  static Dio _buildDio() => createDio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: kMinaHttpTimeout,
      receiveTimeout: kMinaHttpTimeout,
    ),
  );

  @override
  Future<MinaHttpResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
    Duration? timeout,
  }) async {
    final effectiveHeaders = Map<String, String>.of(headers);
    String? contentType;
    for (final key in effectiveHeaders.keys.toList()) {
      if (key.toLowerCase() == 'content-type') {
        contentType = effectiveHeaders.remove(key);
      }
    }
    final response = await _dio.request<List<int>>(
      url.toString(),
      data: body,
      options: Options(
        method: method,
        headers: effectiveHeaders,
        contentType: contentType,
        followRedirects: false,
        validateStatus: (_) => true,
        responseType: ResponseType.bytes,
        sendTimeout: timeout,
        receiveTimeout: timeout,
      ),
    );
    return MinaHttpResponse(
      statusCode: response.statusCode ?? 0,
      bodyBytes: response.data ?? const [],
      headers: response.headers.map,
    );
  }
}

/// 极简 Cookie 罐：按域名匹配（精确或父域后缀），忽略 Path / 过期属性。
///
/// 账号登录流程只在 account.xiaomi.com 一个域内跳转，这个粒度够用
/// （对应 miot `CookieJar` 在本协议中的实际用法）。
class MinaCookieJar {
  final Map<String, Map<String, String>> _byDomain = {};

  /// 吸收一批 Set-Cookie（[origin] 为响应来源 URL）。
  void absorb(List<String> setCookies, Uri origin) {
    for (final header in setCookies) {
      final first = header.split(';').first;
      final eq = first.indexOf('=');
      if (eq <= 0) continue;
      final name = first.substring(0, eq).trim();
      final value = first.substring(eq + 1).trim();
      var domain = origin.host;
      for (final attr in header.split(';').skip(1)) {
        final attrEq = attr.indexOf('=');
        if (attrEq <= 0) continue;
        if (attr.substring(0, attrEq).trim().toLowerCase() == 'domain') {
          // RFC 6265：Domain 值只忽略一个前导点。不能用 replaceFirst
          // 删任意位置的点——Domain=xiaomi.com（无前导点）会被改成
          // xiaomicom，cookie 永远存不进该发的域，真机上即表现为
          // 会话 cookie 丢失（单测夹具只用 Path=/ 时测不出来）。
          domain = attr.substring(attrEq + 1).trim().toLowerCase();
          if (domain.startsWith('.')) domain = domain.substring(1);
        }
      }
      if (name.isEmpty) continue;
      // 值为空或字面 EXPIRED 是服务器的删除标记（身份链上常用它清
      // 旧 passToken），不是凭据本身：按删除处理，绝不能存进罐里
      // 再被 value() 当真值取出——TrackFerry 每处取值（逐跳
      // cookieValue 与 jar 兜底）都跳过 EXPIRED，正是为此。
      if (value.isEmpty || value == 'EXPIRED') {
        _byDomain[domain]?.remove(name);
        continue;
      }
      _byDomain.putIfAbsent(domain, () => {})[name] = value;
    }
  }

  /// 手动写入一个 cookie（值为空时删除）。
  void setValue(String domain, String name, String value) {
    if (value.isEmpty) {
      _byDomain[domain]?.remove(name);
      return;
    }
    _byDomain.putIfAbsent(domain, () => {})[name] = value;
  }

  /// 按名字查任意域下的 cookie 值（miot CookieJar.getValue 语义）。
  String? value(String name) {
    for (final cookies in _byDomain.values) {
      final v = cookies[name];
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  /// 拼 [url] 可携带的 Cookie 头；无匹配时返回空串。
  String cookieHeaderFor(Uri url) {
    final parts = <String>[];
    _byDomain.forEach((domain, cookies) {
      if (url.host == domain || url.host.endsWith('.$domain')) {
        cookies.forEach((name, value) => parts.add('$name=$value'));
      }
    });
    return parts.join('; ');
  }

  void clear() => _byDomain.clear();
}

/// 从一组 Set-Cookie 里取指定名字的 cookie 值（取第一段 name=value）。
///
/// 空值与字面 EXPIRED 是删除标记，跳过不算命中（TrackFerry
/// cookieValue 同语义）。
String? setCookieValue(List<String> setCookies, String name) {
  for (final header in setCookies) {
    final first = header.split(';').first;
    final eq = first.indexOf('=');
    if (eq <= 0) continue;
    if (first.substring(0, eq).trim() == name) {
      final value = first.substring(eq + 1).trim();
      if (value.isEmpty || value == 'EXPIRED') continue;
      return value;
    }
  }
  return null;
}

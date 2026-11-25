import 'dart:io';
import 'dart:math';

import 'speaker_url_probe.dart' show kSpeakerUserAgent;
import 'takeover/speaker_stream_proxy.dart';

/// 选一个局域网 IPv4：过滤 loopback 与 169.254 链路本地地址，
/// 优先 192.168.0.0/16，其次 10.0.0.0/8、172.16.0.0/12；无则 null。
Future<String?> pickLanIpv4() async {
  final List<String> candidates;
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    candidates = [
      for (final iface in interfaces)
        for (final addr in iface.addresses)
          if (!addr.isLoopback && !addr.address.startsWith('169.254.'))
            addr.address,
    ];
  } catch (_) {
    return null;
  }
  bool is172Private(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4 || parts[0] != '172') return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }

  final tiers = <bool Function(String)>[
    (ip) => ip.startsWith('192.168.'),
    (ip) => ip.startsWith('10.'),
    is172Private,
  ];
  for (final tier in tiers) {
    for (final ip in candidates) {
      if (tier(ip)) return ip;
    }
  }
  return null;
}

class _StreamEntry {
  _StreamEntry({required this.upstreamUrl, required this.createdAtMs});

  final String upstreamUrl;
  final int createdAtMs;
  int? fetchedAtMs;
  int fetchCount = 0;
}

/// 局域网流服务：把平台直链在本机起一个无签名、带 token 的 HTTP 地址，
/// 音箱取流时再由手机向上游拉取并转供，绕开签名直链在音箱侧的拉流失败。
class LanStreamServer implements SpeakerStreamProxy {
  LanStreamServer({
    int basePort = 18761,
    int Function()? nowMs,
    Future<String?> Function()? lanIpLookup,
    void Function(String message)? onLog,
  }) : _basePort = basePort,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _lanIpLookup = lanIpLookup ?? pickLanIpv4,
       _onLog = onLog;

  static const int _portAttempts = 11; // basePort .. basePort+10
  static const int _unfetchedTtlMs = 5 * 60 * 1000;
  static const int _fetchedTtlMs = 30 * 60 * 1000;
  static const int _maxAgeMs = 2 * 60 * 60 * 1000;
  static final RegExp _pathPattern = RegExp(
    r'^/stream/([0-9a-f]{32})\.mp3$',
  );

  final int _basePort;
  final int Function() _nowMs;
  final Future<String?> Function() _lanIpLookup;
  final void Function(String message)? _onLog;

  HttpServer? _server;
  final Map<String, _StreamEntry> _entries = {};

  bool get isRunning => _server != null;

  int? get boundPort => _server?.port;

  Future<bool> start() async {
    if (_server != null) return true;
    for (var i = 0; i < _portAttempts; i++) {
      try {
        final server = await HttpServer.bind(
          InternetAddress.anyIPv4,
          _basePort + i,
        );
        _server = server;
        server.listen(
          (request) {
            _handle(request).catchError((Object e) {
              _log('stream request failed: $e');
            });
          },
          onError: (Object e) => _log('stream server error: $e'),
        );
        return true;
      } catch (e) {
        _log('stream bind ${_basePort + i} failed: $e');
      }
    }
    return false;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _entries.clear();
    if (server != null) {
      await server.close(force: true);
    }
  }

  @override
  Future<String?> publish(String upstreamUrl) async {
    if (_server == null) return null;
    final ip = await _lanIpLookup();
    if (ip == null) return null;
    final random = Random.secure();
    final token = [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    _pruneExpired();
    _entries[token] = _StreamEntry(
      upstreamUrl: upstreamUrl,
      createdAtMs: _nowMs(),
    );
    return 'http://$ip:${_server!.port}/stream/$token.mp3';
  }

  @override
  bool wasFetched(String pushUrl) {
    final token = _tokenFromUrl(pushUrl);
    if (token == null) return false;
    _pruneExpired();
    return _entries[token]?.fetchedAtMs != null;
  }

  String? _tokenFromUrl(String url) {
    try {
      final segments = Uri.parse(url).pathSegments;
      if (segments.isEmpty) return null;
      final last = segments.last;
      if (!last.endsWith('.mp3')) return null;
      final token = last.substring(0, last.length - '.mp3'.length);
      return _pathPattern.hasMatch('/stream/$token.mp3') ? token : null;
    } catch (_) {
      return null;
    }
  }

  bool _isExpired(_StreamEntry entry, int now) {
    if (now - entry.createdAtMs > _maxAgeMs) return true;
    final fetchedAt = entry.fetchedAtMs;
    if (fetchedAt == null) {
      return now - entry.createdAtMs > _unfetchedTtlMs;
    }
    return now - fetchedAt > _fetchedTtlMs;
  }

  void _pruneExpired() {
    final now = _nowMs();
    _entries.removeWhere((_, entry) => _isExpired(entry, now));
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    final match = _pathPattern.firstMatch(request.uri.path);
    _pruneExpired();
    final entry = match == null ? null : _entries[match.group(1)!];
    if (entry == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    entry.fetchedAtMs ??= _nowMs();
    entry.fetchCount++;
    await _proxy(request, entry);
  }

  Future<void> _proxy(HttpRequest request, _StreamEntry entry) async {
    final response = request.response;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final client = HttpClient();
    var wroteBody = false;
    try {
      final upstreamRequest = await client.getUrl(Uri.parse(entry.upstreamUrl));
      upstreamRequest.followRedirects = true;
      upstreamRequest.maxRedirects = 8;
      if (range != null) {
        upstreamRequest.headers.set(HttpHeaders.rangeHeader, range);
      }
      upstreamRequest.headers.set(
        HttpHeaders.userAgentHeader,
        kSpeakerUserAgent,
      );
      final upstream = await upstreamRequest.close();
      if (upstream.statusCode >= 400) {
        await upstream.drain<void>();
        response.statusCode = HttpStatus.badGateway;
        await response.close();
        return;
      }
      if (range != null && upstream.statusCode == HttpStatus.partialContent) {
        response.statusCode = HttpStatus.partialContent;
        final contentRange = upstream.headers.value(
          HttpHeaders.contentRangeHeader,
        );
        if (contentRange != null) {
          response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
        }
        if (upstream.contentLength >= 0) {
          response.contentLength = upstream.contentLength;
        }
        response.headers.contentType = ContentType('audio', 'mpeg');
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      } else {
        response.statusCode = HttpStatus.ok;
        response.headers.contentType = ContentType('audio', 'mpeg');
        if (upstream.contentLength >= 0) {
          response.contentLength = upstream.contentLength;
        }
      }
      if (request.method == 'HEAD') {
        await upstream.drain<void>();
        await response.close();
        return;
      }
      await for (final chunk in upstream) {
        wroteBody = true;
        response.add(chunk);
      }
      await response.flush();
      await response.close();
    } catch (e) {
      _log('stream proxy failed: $e');
      if (!wroteBody) {
        try {
          response.statusCode = HttpStatus.badGateway;
          await response.close();
        } catch (_) {
          // 响应已开始/已关闭，忽略。
        }
      } else {
        try {
          await response.close();
        } catch (_) {
          // 同上。
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  void _log(String message) => _onLog?.call(message);
}

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// A parsed single-range `Range: bytes=…` header against a body of
/// [total] bytes. [start] and [end] are inclusive byte offsets.
class ByteRange {
  const ByteRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start + 1;
}

/// Parses an HTTP Range header. Returns null when the header is absent,
/// malformed, multi-range, or unsatisfiable — callers then serve the full
/// body, which renderers tolerate better than a 416 for our use case.
ByteRange? parseByteRange(String? header, int total) {
  if (header == null || total <= 0) return null;
  final match = RegExp(
    r'^bytes=(\d*)-(\d*)$',
  ).firstMatch(header.trim());
  if (match == null) return null;
  final startText = match.group(1)!;
  final endText = match.group(2)!;
  if (startText.isEmpty && endText.isEmpty) return null;
  int start;
  int end;
  if (startText.isEmpty) {
    // Suffix range: the last N bytes.
    final suffix = int.parse(endText);
    if (suffix <= 0) return null;
    start = math.max(0, total - suffix);
    end = total - 1;
  } else {
    start = int.parse(startText);
    if (start >= total) return null;
    end = endText.isEmpty ? total - 1 : math.min(int.parse(endText), total - 1);
    if (end < start) return null;
  }
  return ByteRange(start, end);
}

/// Builds the relay URL for [token]. Pure — unit-tested.
Uri buildRelayUri({
  required String host,
  required int port,
  required String kind,
  required String token,
}) => Uri.parse('http://$host:$port/$kind/$token');

class _RelayTarget {
  const _RelayTarget.remote(this.source, this.headers) : file = null;
  const _RelayTarget.file(this.file) : source = null, headers = const {};

  final Uri? source;
  final Map<String, String> headers;
  final File? file;
}

/// Phone-hosted HTTP relay: serves local files and proxies remote streams
/// (with their required headers) so renderers that cannot reach or satisfy
/// the origin can still play. Supports Range, which renderers need to seek.
class CastRelayServer {
  CastRelayServer({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  final _targets = <String, _RelayTarget>{};
  final _random = math.Random.secure();
  HttpServer? _server;
  String? _host;
  int? _port;

  bool get running => _server != null;
  String? get host => _host;
  int? get port => _port;

  /// The phone's LAN IPv4 (Wi-Fi first), or null when not on a LAN.
  static Future<String?> lanAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    String? fallback;
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback) continue;
        final name = interface.name.toLowerCase();
        if (name.startsWith('wlan') ||
            name.startsWith('en') ||
            name.startsWith('eth') ||
            name.startsWith('ap')) {
          return address.address;
        }
        fallback ??= address.address;
      }
    }
    return fallback;
  }

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    final host = await lanAddress();
    if (host == null) {
      throw const SocketException('No LAN address available for relay');
    }
    final server = await HttpServer.bind(InternetAddress(host), 0);
    _server = server;
    _host = host;
    _port = server.port;
    server.listen(_handle, onError: (_) {});
  }

  String _newToken() =>
      List.generate(20, (_) => _random.nextInt(16).toRadixString(16)).join();

  /// Registers a remote stream for proxying and returns its relay URL.
  Future<Uri> registerRemote(
    Uri source, {
    Map<String, String> headers = const {},
  }) async {
    await _ensureStarted();
    final token = _newToken();
    _targets[token] = _RelayTarget.remote(source, headers);
    return buildRelayUri(host: _host!, port: _port!, kind: 'r', token: token);
  }

  /// Registers a local file for serving and returns its relay URL.
  Future<Uri> registerFile(File file) async {
    await _ensureStarted();
    final token = _newToken();
    _targets[token] = _RelayTarget.file(file);
    return buildRelayUri(host: _host!, port: _port!, kind: 'f', token: token);
  }

  Future<void> stop() async {
    _targets.clear();
    final server = _server;
    _server = null;
    _host = null;
    _port = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length != 2) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final target = _targets[segments[1]];
      if (target == null ||
          (segments[0] == 'r') != (target.file == null)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (target.file != null) {
        await _serveFile(request, target.file!);
      } else {
        await _serveRemote(request, target);
      }
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serveFile(HttpRequest request, File file) async {
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final total = await file.length();
    final response = request.response;
    response.headers.set('Accept-Ranges', 'bytes');
    final contentType = _contentTypeFor(file.path);
    if (contentType != null) response.headers.contentType = contentType;
    if (request.method == 'HEAD') {
      response.headers.contentLength = total;
      await response.close();
      return;
    }
    final range = parseByteRange(request.headers.value('range'), total);
    if (range == null) {
      response.headers.contentLength = total;
      await response.addStream(file.openRead());
    } else {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        'Content-Range',
        'bytes ${range.start}-${range.end}/$total',
      );
      response.headers.contentLength = range.length;
      await response.addStream(file.openRead(range.start, range.end + 1));
    }
    await response.close();
  }

  Future<void> _serveRemote(HttpRequest request, _RelayTarget target) async {
    final client = _clientFactory();
    try {
      final upstream = await client.openUrl(request.method, target.source!);
      target.headers.forEach(upstream.headers.set);
      if (!target.headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
        upstream.headers.set(
          'User-Agent',
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
        );
      }
      // Pass the renderer's Range through untouched — it is what lets the
      // renderer seek inside the proxied stream.
      final range = request.headers.value('range');
      if (range != null) upstream.headers.set('range', range);
      final upstreamResponse = await upstream.close();
      final response = request.response;
      response.statusCode = upstreamResponse.statusCode;
      for (final name in [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
      ]) {
        final value = upstreamResponse.headers.value(name);
        if (value != null) response.headers.set(name, value);
      }
      if (request.method != 'HEAD') {
        await response.addStream(upstreamResponse);
      }
      await response.close();
    } finally {
      client.close(force: true);
    }
  }

  ContentType? _contentTypeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp3')) return ContentType('audio', 'mpeg');
    if (lower.endsWith('.flac')) return ContentType('audio', 'flac');
    if (lower.endsWith('.m4a') || lower.endsWith('.aac')) {
      return ContentType('audio', 'mp4');
    }
    if (lower.endsWith('.wav')) return ContentType('audio', 'wav');
    if (lower.endsWith('.ogg')) return ContentType('audio', 'ogg');
    return null;
  }
}

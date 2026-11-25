import 'dart:async';
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

/// 已供统计（蓝本 `stream.Served`）：当前请求的已供字节（从其 Range
/// 起点起算）、总长、请求数、是否有请求在途。
class _Served {
  int bytes = 0;
  int total = 0;
  int requests = 0;
  bool open = false;
}

/// 无法从中起播（蓝本 `stream.ErrNoSeek`）。
class _NoSeek implements Exception {
  const _NoSeek();
}

class _UpstreamSource {
  _UpstreamSource(this.client, this.response);

  final HttpClient client;
  final HttpClientResponse response;

  void close() {
    try {
      client.close(force: true);
    } catch (_) {
      // 已关闭，忽略。
    }
  }
}

class _StreamEntry implements StreamHandle {
  _StreamEntry({
    required this.server,
    required this.url,
    required this.upstreamUrl,
    required this.labelText,
    required this.durationMs,
    required this.createdAtMs,
    required this.expiresAtMs,
    this.head,
    this.off = 0,
    this.virtualTotal,
  });

  final LanStreamServer server;

  @override
  final String url;

  final String upstreamUrl;
  final String labelText;
  final int durationMs;
  final int createdAtMs;
  final int expiresAtMs;

  /// 中段条目（蓝本 item.head/off/total）：虚拟文件 = [head] + 上游
  /// 自 [off] 起的内容，虚拟总长 [virtualTotal]。普通条目为 null。
  final List<int>? head;
  final int off;
  final int? virtualTotal;

  bool restartedFlag = false;
  final _Served served = _Served();
  int? _fetchedAtMsField;
  int _fetchCountField = 0;

  @override
  String get label => labelText;

  @override
  int get lengthMs => durationMs;

  @override
  bool get fetched => _fetchedAtMsField != null;

  @override
  int? get fetchedAtMs => _fetchedAtMsField;

  @override
  int get fetchCount => _fetchCountField;

  @override
  bool get restarted => restartedFlag;

  @override
  bool get lost =>
      served.requests > 0 &&
      !served.open &&
      served.total > 0 &&
      served.bytes < served.total;

  @override
  Future<({StreamHandle handle, int startMs})?> resume(int atMs) =>
      server._resume(this, atMs);
}

/// 局域网流服务：把平台直链在本机起一个无签名、带 token 的 HTTP 地址，
/// 音箱取流时再由手机向上游拉取并转供，绕开签名直链在音箱侧的拉流失败。
///
/// 语义对 TrackFerry `internal/stream`：token 16 字节安全随机 hex、
/// TTL 统一 6 小时、取流/重取信号、served/lost 统计、openAgain 重试、
/// steady 断流续传、MP3 中段续播（middle）。
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
  // 蓝本 ttl：publish 起 6 小时统一过期。
  static const int _ttlMs = 6 * 60 * 60 * 1000;
  // 蓝本 steady.stallAfter / reopenWait。
  static const Duration _stallAfter = Duration(seconds: 12);
  static const List<Duration> _reopenWait = [
    Duration(milliseconds: 100),
    Duration(milliseconds: 400),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];
  // 蓝本 openAgain 的重试间隔。
  static const Duration _openRetryDelay = Duration(milliseconds: 400);
  static final RegExp _pathPattern = RegExp(
    r'^/stream/([0-9a-f]{32})\.mp3$',
  );
  static final RegExp _contentRangePattern = RegExp(
    r'^bytes (\d+)-(\d+)/(\d+)$',
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
  Future<StreamHandle?> publish(
    String upstreamUrl, {
    int? durationMs,
    String? label,
  }) {
    return _register(
      upstreamUrl: upstreamUrl,
      labelText: label ?? '',
      durationMs: durationMs ?? 0,
    );
  }

  Future<_StreamEntry?> _register({
    required String upstreamUrl,
    required String labelText,
    required int durationMs,
    List<int>? head,
    int off = 0,
    int? virtualTotal,
  }) async {
    if (_server == null) return null;
    final ip = await _lanIpLookup();
    if (ip == null) return null;
    final random = Random.secure();
    final token = [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    final now = _nowMs();
    // 蓝本 register：publish 时顺带清理过期条目。
    _entries.removeWhere((_, entry) => now > entry.expiresAtMs);
    final entry = _StreamEntry(
      server: this,
      url: 'http://$ip:${_server!.port}/stream/$token.mp3',
      upstreamUrl: upstreamUrl,
      labelText: labelText,
      durationMs: durationMs,
      createdAtMs: now,
      expiresAtMs: now + _ttlMs,
      head: head,
      off: off,
      virtualTotal: virtualTotal,
    );
    _entries[token] = entry;
    return entry;
  }

  /// 蓝本 Handle.restartGap：时长已知取 9/10，未知 15 秒。
  static int _restartGapMs(int durationMs) =>
      durationMs > 0 ? durationMs * 9 ~/ 10 : 15 * 1000;

  static bool _fromStart(String? range) {
    if (range == null) return true;
    return range.replaceAll(' ', '').startsWith('bytes=0-');
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    final match = _pathPattern.firstMatch(request.uri.path);
    final entry = match == null ? null : _entries[match.group(1)!];
    // 蓝本：条目不存在或已过期 → 404（过期判定用请求时刻）。
    if (entry == null || _nowMs() > entry.expiresAtMs) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    // 取流信号（蓝本 ServeHTTP 的 fetched/restarted 记录段）：第一次
    // GET/HEAD 即记 fetched；首次之后隔 restartGap 再来从头请求记
    // restarted。日志只记首次取流与 restarted 两行（带 label 与第
    // 几次）——蓝本逐条记服务日志，我们的 onLog 是落盘环形缓冲，
    // 故其余请求不逐条记。
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final now = _nowMs();
    if (entry._fetchCountField == 0) {
      entry._fetchedAtMsField = now;
      _log(
        'stream fetched: label=${entry.labelText} count=1 '
        'method=${request.method} range=${range ?? ''}',
      );
    } else if (!entry.restartedFlag &&
        _fromStart(range) &&
        now - entry._fetchedAtMsField! >= _restartGapMs(entry.durationMs)) {
      entry.restartedFlag = true;
      _log(
        'stream restarted: label=${entry.labelText} '
        'count=${entry._fetchCountField + 1} method=${request.method}',
      );
    }
    entry._fetchCountField++;
    final count = entry._fetchCountField;

    response.headers.contentType = ContentType('audio', 'mpeg');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      if (entry.head != null) {
        await _middle(request, entry, count);
      } else {
        await _proxy(request, entry, count);
      }
    } finally {
      // 蓝本 counter 的收尾 add(0, done=true)：请求结束即不在途。
      entry.served.requests = count;
      entry.served.open = false;
    }
  }

  // —— served 统计（蓝本 counter）——

  /// 蓝本 counter.WriteHeader：从 Content-Range 初始化 bytes/total，
  /// 否则 200 且有 Content-Length 时 bytes=0、total=该长度。
  void _beginServed(
    _StreamEntry entry,
    int count,
    int statusCode, {
    String? contentRange,
    int? contentLength,
  }) {
    final parsed = contentRange == null
        ? null
        : _parseContentRange(contentRange);
    if (parsed != null) {
      entry.served.bytes = parsed.$1;
      entry.served.total = parsed.$3;
    } else if (statusCode == HttpStatus.ok &&
        contentLength != null &&
        contentLength >= 0) {
      entry.served.bytes = 0;
      entry.served.total = contentLength;
    }
    entry.served.requests = count;
    entry.served.open = true;
  }

  void _addServed(_StreamEntry entry, int count, int n) {
    entry.served.bytes += n;
    entry.served.requests = count;
    entry.served.open = true;
  }

  static (int, int, int)? _parseContentRange(String value) {
    final m = _contentRangePattern.firstMatch(value.trim());
    if (m == null) return null;
    return (int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
  }

  // —— 上游打开（蓝本 Opener / openAgain）——

  Future<_UpstreamSource> _openOnce(String url, String? range) async {
    final client = HttpClient();
    try {
      final upstreamRequest = await client.getUrl(Uri.parse(url));
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
      return _UpstreamSource(client, upstream);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  /// 蓝本 openAgain：打开失败先等 400ms 重试一次。
  Future<_UpstreamSource> _openAgain(String url, String? range) async {
    try {
      return await _openOnce(url, range);
    } catch (_) {
      await Future<void>.delayed(_openRetryDelay);
      return _openOnce(url, range);
    }
  }

  /// 蓝本 item.source：Range GET，要求 206 且 Content-Range 起点吻合，
  /// 返回 (source, 上游总长)；不满足即 _NoSeek。
  Future<(_UpstreamSource, int)> _sourceRange(
    String url,
    int from,
    int endInclusive,
  ) async {
    final holder = await _openOnce(url, 'bytes=$from-$endInclusive');
    final parsed = _parseContentRange(
      holder.response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
    );
    if (holder.response.statusCode != HttpStatus.partialContent ||
        parsed == null ||
        parsed.$1 != from) {
      holder.close();
      throw const _NoSeek();
    }
    return (holder, parsed.$3);
  }

  /// 蓝本 item.peek：Range GET 取一段上游字节，8 秒超时。
  Future<({List<int> bytes, int total})> _peek(
    _StreamEntry entry,
    int from,
    int n,
  ) {
    return _peekInner(entry, from, n).timeout(const Duration(seconds: 8));
  }

  Future<({List<int> bytes, int total})> _peekInner(
    _StreamEntry entry,
    int from,
    int n,
  ) async {
    final (holder, total) = await _sourceRange(
      entry.upstreamUrl,
      from,
      from + n - 1,
    );
    try {
      final bytes = <int>[];
      await for (final chunk in holder.response) {
        bytes.addAll(chunk);
        if (bytes.length >= n) break;
      }
      return (bytes: bytes.length > n ? bytes.sublist(0, n) : bytes, total: total);
    } finally {
      holder.close();
    }
  }

  // —— 转供（蓝本 proxy + steady）——

  Future<void> _proxy(HttpRequest request, _StreamEntry entry, int count) async {
    final response = request.response;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    _UpstreamSource holder;
    try {
      holder = await _openAgain(entry.upstreamUrl, range);
    } catch (e) {
      _log('stream proxy open failed: $e');
      _beginServed(entry, count, HttpStatus.badGateway);
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    final upstream = holder.response;
    if (upstream.statusCode >= 400) {
      try {
        await upstream.drain<void>();
      } catch (_) {}
      holder.close();
      _beginServed(entry, count, HttpStatus.badGateway);
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    // 蓝本 proxy：只透传 Content-Length / Content-Range / Accept-Ranges
    // 三个头 + 上游状态码原样；Cache-Control: no-store 已在 _handle 设；
    // Content-Type 固定 audio/mpeg——我们的候选都经 MP3 探测，蓝本
    // 按首字节嗅探类型的 sniffer 分支不适用，故不移植嗅探。
    final contentRange = upstream.headers.value(
      HttpHeaders.contentRangeHeader,
    );
    final acceptRanges = upstream.headers.value(HttpHeaders.acceptRangesHeader);
    if (contentRange != null) {
      response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
    }
    if (acceptRanges != null) {
      response.headers.set(HttpHeaders.acceptRangesHeader, acceptRanges);
    }
    if (upstream.contentLength >= 0) {
      response.contentLength = upstream.contentLength;
    }
    response.statusCode = upstream.statusCode;
    _beginServed(
      entry,
      count,
      upstream.statusCode,
      contentRange: contentRange,
      contentLength: upstream.contentLength,
    );
    if (request.method == 'HEAD') {
      // HEAD 不走 steady（蓝本 proxy 同）。
      try {
        await upstream.drain<void>();
      } catch (_) {}
      holder.close();
      await response.close();
      return;
    }
    // 蓝本 steady 门槛：200 有 Content-Length 或 206 有 Content-Range。
    Stream<List<int>> body = upstream;
    final steady = _steadyParams(upstream);
    if (steady != null) {
      body = _steadyChunks(
        url: entry.upstreamUrl,
        initial: holder,
        start: steady.$1,
        end: steady.$2,
        total: steady.$3,
      );
    }
    await _pump(request, entry, count, body, closeSource: holder);
  }

  /// steady 的 (起点, 终点(不含), 总长)；不满足门槛返回 null。
  (int, int, int)? _steadyParams(HttpClientResponse upstream) {
    if (upstream.statusCode == HttpStatus.ok) {
      if (upstream.contentLength <= 0) return null;
      return (0, upstream.contentLength, upstream.contentLength);
    }
    if (upstream.statusCode == HttpStatus.partialContent) {
      final parsed = _parseContentRange(
        upstream.headers.value(HttpHeaders.contentRangeHeader) ?? '',
      );
      if (parsed == null) return null;
      return (parsed.$1, parsed.$2 + 1, parsed.$3);
    }
    return null;
  }

  Future<void> _pump(
    HttpRequest request,
    _StreamEntry entry,
    int count,
    Stream<List<int>> body, {
    _UpstreamSource? closeSource,
  }) async {
    final response = request.response;
    var wroteBody = false;
    try {
      await for (final chunk in body) {
        wroteBody = true;
        response.add(chunk);
        _addServed(entry, count, chunk.length);
        await response.flush();
      }
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
      closeSource?.close();
    }
  }

  /// 蓝本 steady：读上游 12 秒无数据视为卡死；断开后按已供字节偏移用
  /// Range 重开（要求 206、Content-Range 起点==偏移、total 不变，否则
  /// 放弃并让本次响应失败）；重开等待 [100ms,400ms,1s,2s,4s] 至多 5
  /// 次；自上次重开起读满 256KB 后失败计数清零。
  Stream<List<int>> _steadyChunks({
    required String url,
    required _UpstreamSource initial,
    required int start,
    required int end,
    required int total,
  }) async* {
    var current = initial;
    var off = start;
    var fails = 0;
    var sinceReopen = 0;
    try {
      while (off < end) {
        Object? cause;
        var broke = false;
        final iterator = StreamIterator<List<int>>(current.response);
        while (off < end) {
          bool hasNext;
          try {
            hasNext = await iterator.moveNext().timeout(_stallAfter);
          } catch (e) {
            cause = e;
            broke = true;
            break;
          }
          if (!hasNext) {
            cause = StateError('upstream closed early at $off');
            broke = true;
            break;
          }
          var chunk = iterator.current;
          final remaining = end - off;
          if (chunk.length > remaining) {
            chunk = chunk.sublist(0, remaining);
          }
          if (chunk.isEmpty) continue;
          off += chunk.length;
          sinceReopen += chunk.length;
          if (sinceReopen >= 256 << 10) fails = 0;
          yield chunk;
        }
        if (!broke) break;
        current.close();
        _UpstreamSource? next;
        while (next == null) {
          if (fails >= _reopenWait.length) {
            throw cause ?? StateError('steady reopen exhausted');
          }
          await Future<void>.delayed(_reopenWait[fails]);
          fails++;
          try {
            final holder = await _openOnce(url, 'bytes=$off-${end - 1}');
            final parsed = _parseContentRange(
              holder.response.headers.value(HttpHeaders.contentRangeHeader) ??
                  '',
            );
            if (holder.response.statusCode != HttpStatus.partialContent ||
                parsed == null ||
                parsed.$1 != off ||
                (total > 0 && parsed.$3 != total)) {
              holder.close();
              throw const _NoSeek();
            }
            next = holder;
          } on _NoSeek {
            throw cause ?? const _NoSeek();
          } catch (e) {
            cause = e;
          }
        }
        current = next;
        sinceReopen = 0;
      }
    } finally {
      current.close();
    }
  }

  // —— 中段续播（蓝本 Resume / mp3At / middle）——

  Future<({StreamHandle handle, int startMs})?> _resume(
    _StreamEntry entry,
    int atMs,
  ) async {
    // 蓝本 Resume 前置：中段条目不再续、时长未知、at<=0 或 >=时长 →
    // ErrNoSeek（此处返回 null）。仅 MP3：我们的条目 Content-Type
    // 恒 audio/mpeg（候选都经 MP3 探测），对应蓝本 ctype 检查。
    if (entry.head != null ||
        entry.durationMs <= 0 ||
        atMs <= 0 ||
        atMs >= entry.durationMs) {
      return null;
    }
    try {
      final first = await _peek(entry, 0, 64 << 10);
      final off = await _mp3At(entry, first.bytes, first.total, atMs);
      if (off == null) return null;
      final handle = await _register(
        upstreamUrl: entry.upstreamUrl,
        labelText: entry.labelText,
        durationMs: entry.durationMs - atMs,
        head: const [],
        off: off,
        virtualTotal: first.total - off,
      );
      if (handle == null) return null;
      return (handle: handle, startMs: atMs);
    } catch (_) {
      return null;
    }
  }

  /// 蓝本 mp3At：ID3v2 头跳过、Xing TOC 优先、否则 CBR 比例估算，
  /// 落点后扫描两个连续合法帧头确认。找不到返回 null（ErrNoSeek）。
  Future<int?> _mp3At(
    _StreamEntry entry,
    List<int> first,
    int total,
    int atMs,
  ) async {
    var start = 0;
    if (first.length > 10 &&
        first[0] == 0x49 && // 'I'
        first[1] == 0x44 && // 'D'
        first[2] == 0x33) {
      // '3'
      start =
          10 +
          (first[6] << 21) +
          (first[7] << 14) +
          (first[8] << 7) +
          first[9];
      if (start >= total) return null;
    }
    var frac = atMs / entry.durationMs;
    try {
      final b = (await _peek(entry, start, 4096)).bytes;
      final i = _indexOfXing(b);
      if (i >= 0 && b.length > i + 16) {
        final flags =
            (b[i + 4] << 24) | (b[i + 5] << 16) | (b[i + 6] << 8) | b[i + 7];
        final p = i + 8 + 4 * (flags & 1) + 4 * ((flags >> 1) & 1);
        if (flags & 4 != 0 && b.length >= p + 100) {
          final toc = b.sublist(p, p + 100);
          final x = min(98, (frac * 100).toInt());
          var next = 256.0;
          if (x < 99) next = toc[x + 1].toDouble();
          frac =
              (toc[x] + (next - toc[x]) * (frac * 100 - x)) / 256;
        }
      }
    } catch (_) {
      // 蓝本：TOC peek 失败不致命，退回 CBR 比例。
    }
    final off = start + ((total - start) * frac).toInt();
    final List<int> b;
    try {
      b = (await _peek(entry, off, 8192)).bytes;
    } catch (_) {
      return null;
    }
    for (var i = 0; i + 4 < b.length; i++) {
      final n = _mp3FrameLength(b, i);
      if (n > 0 && i + n + 4 < b.length && _mp3FrameLength(b, i + n) > 0) {
        return off + i;
      }
    }
    return null;
  }

  static int _indexOfXing(List<int> b) {
    for (var i = 0; i + 4 <= b.length; i++) {
      if (b[i] == 0x58 && b[i + 1] == 0x69 && b[i + 2] == 0x6E && b[i + 3] == 0x67) {
        return i;
      }
    }
    return -1;
  }

  /// 蓝本 mp3Frame：返回从 [i] 起的 Layer III 帧长，非法为 0。
  static int _mp3FrameLength(List<int> b, int i) {
    if (i + 4 > b.length ||
        b[i] != 0xFF ||
        b[i + 1] & 0xE0 != 0xE0 ||
        (b[i + 1] >> 1) & 3 != 1) {
      return 0;
    }
    final ver = (b[i + 1] >> 3) & 3;
    final br = b[i + 2] >> 4;
    final sr = (b[i + 2] >> 2) & 3;
    if (ver == 1 || br == 0 || br == 15 || sr == 3) return 0;
    const v1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
    const v2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
    var rate = const [44100, 48000, 32000][sr];
    final pad = (b[i + 2] >> 1) & 1;
    if (ver == 3) {
      return 144000 * v1[br] ~/ rate + pad;
    }
    if (ver == 2) {
      rate ~/= 2;
    } else {
      rate ~/= 4;
    }
    return 72000 * v2[br] ~/ rate + pad;
  }

  /// 蓝本 middle：对虚拟长度解析 Range 作答（200/206/416），body =
  /// head 切片 + 上游 Range 流（带 steady）。
  Future<void> _middle(HttpRequest request, _StreamEntry entry, int count) async {
    final response = request.response;
    final total = entry.virtualTotal!;
    final headLen = entry.head!.length;
    int from = 0;
    int to = total - 1;
    var code = HttpStatus.ok;
    final rangeRaw = request.headers.value(HttpHeaders.rangeHeader);
    String? contentRange;
    if (rangeRaw != null) {
      final rng = rangeRaw.replaceAll(' ', '');
      if (rng.startsWith('bytes=')) {
        final dash = rng.indexOf('-', 6);
        final a = dash < 0 ? rng.substring(6) : rng.substring(6, dash);
        final bStr = dash < 0 ? '' : rng.substring(dash + 1);
        if (a.isEmpty) {
          final n = int.tryParse(bStr);
          if (n != null) from = max(0, total - n);
        } else {
          final n = int.tryParse(a);
          if (n != null) {
            from = n;
            final m = int.tryParse(bStr);
            if (m != null) to = min(to, m);
          }
        }
        if (from > to) {
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$total',
          );
          _beginServed(entry, count, HttpStatus.requestedRangeNotSatisfiable);
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await response.close();
          return;
        }
        code = HttpStatus.partialContent;
        contentRange = 'bytes $from-$to/$total';
      }
    }
    // body 来源先打开（失败回 502），再写响应头。
    _UpstreamSource? holder;
    int srcTotal = 0;
    if (to >= headLen) {
      final srcFrom = entry.off + (from - headLen < 0 ? 0 : from - headLen);
      final srcTo = entry.off + to - headLen;
      try {
        final (h, t) = await _sourceRange(entry.upstreamUrl, srcFrom, srcTo);
        holder = h;
        srcTotal = t;
      } catch (_) {
        _beginServed(entry, count, HttpStatus.badGateway);
        response.statusCode = HttpStatus.badGateway;
        await response.close();
        return;
      }
    }
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.contentLength = to - from + 1;
    if (contentRange != null) {
      response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
    }
    response.statusCode = code;
    _beginServed(
      entry,
      count,
      code,
      contentRange: contentRange,
      contentLength: to - from + 1,
    );
    if (request.method == 'HEAD') {
      holder?.close();
      await response.close();
      return;
    }
    final heldSource = holder;
    final bodySrcFrom = entry.off + (from - headLen < 0 ? 0 : from - headLen);
    final bodySrcEnd = entry.off + to - headLen + 1;
    Stream<List<int>> body() async* {
      if (from < headLen) {
        yield entry.head!.sublist(from, min(headLen, to + 1));
      }
      if (heldSource != null) {
        yield* _steadyChunks(
          url: entry.upstreamUrl,
          initial: heldSource,
          start: bodySrcFrom,
          end: bodySrcEnd,
          total: srcTotal,
        );
      }
    }

    await _pump(request, entry, count, body(), closeSource: holder);
  }

  void _log(String message) => _onLog?.call(message);
}

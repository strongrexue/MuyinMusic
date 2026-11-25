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
    required this.token,
    required this.url,
    required this.upstreamUrl,
    required this.labelText,
    required this.durationMs,
    required this.createdAtMs,
    required this.expiresAtMs,
    this.head,
    this.off = 0,
    this.virtualTotal,
    this.filePath,
    this.urlRefresher,
  });

  final LanStreamServer server;

  /// URL 里的 token（spool 临时文件命名用）。
  final String token;

  @override
  final String url;

  /// 上游直链（文件条目为空串）；换链成功后会被新地址覆盖
  /// （蓝本 Opener 把新地址留在闭包里供后续打开）。
  String upstreamUrl;

  /// 本机文件条目（蓝本 Song）：从磁盘供流，与 [upstreamUrl]
  /// 二选一。
  final String? filePath;

  /// 直链过期时向平台换新地址的回调（蓝本 Opener 的 refresh）。
  final Future<String?> Function()? urlRefresher;
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

  /// 实质重取事件（watch 时钟重同步用）：宽限期外、无请求
  /// 在途时的从头请求时刻与当时上一请求的已供比例快照。
  int? restartAtMsField;
  double restartServedRatioField = -1;

  /// 全速预读 spool 状态：首个请求触发后台整文件下载到临时
  /// 文件，后续请求从文件按前沿供流（见 [_Spool]）。
  bool spoolStarted = false;
  _Spool? spool;

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
  int? get restartAtMs => restartAtMsField;

  @override
  double get restartServedRatio => restartServedRatioField;

  @override
  bool get lost =>
      served.requests > 0 &&
      !served.open &&
      served.total > 0 &&
      served.bytes < served.total;

  @override
  Future<({StreamHandle handle, int startMs})?> resume(int atMs) =>
      server._resume(this, atMs);

  /// 删除 spool 临时文件（条目过期/服务停止时 best-effort）。
  void deleteSpoolFile() {
    final file = spool?.file;
    if (file == null) return;
    try {
      file.deleteSync();
    } catch (_) {
      // 已不存在等，忽略。
    }
  }
}

/// 预读 spool：一首歌的整文件后台下载状态。首个请求触发后，
/// 下载器以网络全速（而非音箱约 40KB/s 的消费速率）把整文件
/// 拉到临时文件，[frontier] 是已落盘字节数；供流从文件按前沿
/// tail-follow，上游连接的存续与音箱请求彻底解耦——CDN 按
/// 慢速连接掐断、网络秒级抖动都只影响下载器（其内部 steady
/// 自行重开续传），对音箱不可见。蓝本 stream 是消费速率透传
/// （io.Copy），无此层；这是手机侧自研鲁棒性（手机 Wi-Fi +
/// 电池环境与有线 NAS 不同），非蓝本对齐项。
class _Spool {
  _Spool(this.file);

  final File file;

  /// 总字节数；上游响应头到达前为 -1（无总长上游则一直 -1，
  /// done 后以 [frontier] 为准）。
  int total = -1;
  int frontier = 0;
  bool done = false;
  Object? error;
  final Completer<void> _ready = Completer<void>();

  /// 总长已知（或下载已失败）时完成。
  Future<void> get ready => _ready.future;

  void markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }
}

/// spool 下载源：总长 + 字节流 + 收尾。
class _SpoolSource {
  _SpoolSource({required this.total, required this.body, required this.close});

  final int total;
  final Stream<List<int>> body;
  final void Function() close;
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
  void Function(String message)? _onLog;

  /// 诊断日志汇：宿主（接管控制器）在构造后接线，把推流事件
  /// 并入接管诊断日志。此前生产环境从没接上，断流在推流层
  /// 零证据（1.3.29《后来》中途断流实证）。
  set onLog(void Function(String message)? value) => _onLog = value;

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
    for (final entry in _entries.values) {
      entry.deleteSpoolFile();
    }
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
    Future<String?> Function()? urlRefresher,
  }) {
    return _register(
      upstreamUrl: upstreamUrl,
      labelText: label ?? '',
      durationMs: durationMs ?? 0,
      urlRefresher: urlRefresher,
    );
  }

  @override
  Future<StreamHandle?> publishFile(
    String filePath, {
    int? durationMs,
    String? label,
  }) async {
    // 蓝本 Song 的前置是文件此刻可读（routing 的 openable 检查）：
    // 不存在/空文件直接判备歌失败，让 step 跳过这一首。
    try {
      final file = File(filePath);
      if (!await file.exists() || await file.length() <= 0) return null;
    } catch (_) {
      return null;
    }
    return _register(
      upstreamUrl: '',
      labelText: label ?? '',
      durationMs: durationMs ?? 0,
      filePath: filePath,
    );
  }

  Future<_StreamEntry?> _register({
    required String upstreamUrl,
    required String labelText,
    required int durationMs,
    List<int>? head,
    int off = 0,
    int? virtualTotal,
    String? filePath,
    Future<String?> Function()? urlRefresher,
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
    _entries.removeWhere((_, entry) {
      if (now <= entry.expiresAtMs) return false;
      entry.deleteSpoolFile();
      return true;
    });
    final entry = _StreamEntry(
      server: this,
      token: token,
      url: 'http://$ip:${_server!.port}/stream/$token.mp3',
      upstreamUrl: upstreamUrl,
      labelText: labelText,
      durationMs: durationMs,
      createdAtMs: now,
      expiresAtMs: now + _ttlMs,
      head: head,
      off: off,
      virtualTotal: virtualTotal,
      filePath: filePath,
      urlRefresher: urlRefresher,
    );
    _entries[token] = entry;
    return entry;
  }

  /// 蓝本 Handle.restartGap：时长已知取 9/10，未知 15 秒。
  static int _restartGapMs(int durationMs) =>
      durationMs > 0 ? durationMs * 9 ~/ 10 : 15 * 1000;

  /// 实质重取事件的宽限：首次取流后 10 秒内的从头请求视为
  /// 启动期探测/重连（蓝本 restartGap 注释要防的正是这类），
  /// 不记事件；宽限外的从头请求只可能是播完循环或断流自愈。
  static const int _restartNoticeMs = 10 * 1000;

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
      _log('stream fetch rejected: path=${request.uri.path}');
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
    } else {
      if (!entry.restartedFlag &&
          _fromStart(range) &&
          now - entry._fetchedAtMsField! >= _restartGapMs(entry.durationMs)) {
        entry.restartedFlag = true;
        _log(
          'stream restarted: label=${entry.labelText} '
          'count=${entry._fetchCountField + 1} method=${request.method}',
        );
      }
      // 实质重取事件（与上面的 gap 标志独立）：宽限期外、无
      // 请求在途时的从头请求。快照上一请求已供比例供 watch
      // 分流（近满=循环重取、未满=中途自愈）。1.3.29《体面》
      // 的自愈重取在约 40 秒处发生，被 9/10 时长的 gap 吞掉，
      // watch 既无日志也无时钟重同步——本事件补上这个信号。
      if (_fromStart(range) &&
          !entry.served.open &&
          now - entry._fetchedAtMsField! >= _restartNoticeMs &&
          entry.restartAtMsField != now) {
        entry.restartAtMsField = now;
        final t = entry.served.total;
        entry.restartServedRatioField = t > 0 ? entry.served.bytes / t : -1;
        _log(
          'stream restart noticed: label=${entry.labelText} '
          'served=${entry.served.bytes}/$t',
        );
      }
    }
    entry._fetchCountField++;
    final count = entry._fetchCountField;

    response.headers.contentType = ContentType('audio', 'mpeg');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      if (entry.head != null) {
        if (entry.filePath != null) {
          await _middleFile(request, entry, count);
        } else {
          await _middle(request, entry, count);
        }
      } else if (entry.filePath != null) {
        await _serveFile(request, entry, count);
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

  /// 蓝本 Opener：打开一条上游。先走 openAgain；连接失败或平台
  /// 回 ≥400（416 除外）且条目带换链回调时，向平台换一个新地址
  /// 再开一次——新地址覆盖条目直链，后续打开都用它（蓝本把
  /// 新地址留在 Opener 闭包里）。没有回调或换不到链时把原失败
  /// 原样交回（异常抛出 / ≥400 的 holder 返回给调用方处理）。
  ///
  /// 这是播完重取不失败的关键：平台签名直链几分钟就过期，歌
  /// 播完时固件从头重取若还用旧链只会吃 403、被我们回成 502，
  /// 固件随即播报「播放失败，请检查网络」。
  Future<_UpstreamSource> _openEntry(_StreamEntry entry, String? range) async {
    _UpstreamSource? rejected;
    Object? failure;
    try {
      final holder = await _openAgain(entry.upstreamUrl, range);
      final code = holder.response.statusCode;
      if (code < 400 || code == HttpStatus.requestedRangeNotSatisfiable) {
        return holder;
      }
      rejected = holder;
    } catch (e) {
      failure = e;
    }
    final refresher = entry.urlRefresher;
    if (refresher == null) {
      if (rejected != null) return rejected;
      throw failure ?? StateError('upstream open failed');
    }
    String? fresh;
    try {
      fresh = await refresher();
    } catch (_) {
      fresh = null;
    }
    if (fresh == null || fresh.isEmpty || fresh == entry.upstreamUrl) {
      _log(
        'stream refresh failed: label=${entry.labelText} '
        'range=${range ?? ''}',
      );
      if (rejected != null) return rejected;
      throw failure ?? StateError('upstream open failed');
    }
    rejected?.close();
    entry.upstreamUrl = fresh;
    _log(
      'stream upstream refreshed: label=${entry.labelText} '
      'range=${range ?? ''}',
    );
    return _openAgain(fresh, range);
  }

  /// 蓝本 item.source：Range GET，要求 206 且 Content-Range 起点吻合，
  /// 返回 (source, 上游总长)；不满足即 _NoSeek。
  Future<(_UpstreamSource, int)> _sourceRange(
    _StreamEntry entry,
    int from,
    int endInclusive,
  ) async {
    final holder = await _openEntry(entry, 'bytes=$from-$endInclusive');
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
    if (entry.filePath != null) return _peekFile(entry, from, n);
    return _peekInner(entry, from, n).timeout(const Duration(seconds: 8));
  }

  /// 文件条目的 peek：字节直接读盘（蓝本 Song 的源是本地文件）。
  Future<({List<int> bytes, int total})> _peekFile(
    _StreamEntry entry,
    int from,
    int n,
  ) async {
    final file = File(entry.filePath!);
    final total = await file.length();
    if (from >= total) return (bytes: const <int>[], total: total);
    final raf = await file.open();
    try {
      await raf.setPosition(from);
      final want = n < total - from ? n : total - from;
      final bytes = await raf.read(want);
      return (bytes: bytes, total: total);
    } finally {
      await raf.close();
    }
  }

  Future<({List<int> bytes, int total})> _peekInner(
    _StreamEntry entry,
    int from,
    int n,
  ) async {
    final (holder, total) = await _sourceRange(
      entry,
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

  // —— 转供（spool 预读 + 文件供流）——

  /// 普通条目供流：首个请求触发 spool 下载，之后所有请求
  /// （含本次）都从 spool 文件作答。偏离蓝本说明：蓝本 proxy
  /// 是 io.Copy 消费速率透传；我们 1.3.29 一晚 4 次中途卡顿
  /// 全在透传链上（上游按音箱约 40KB/s 的慢速下载被 CDN
  /// 掐断/网络抖动直接穿透到音箱），故改为全速预读。
  Future<void> _proxy(HttpRequest request, _StreamEntry entry, int count) async {
    _startProxySpool(entry);
    await _serveSpool(request, entry, count, entry.spool!);
  }

  /// 启动条目的 spool 下载（只启动一次）。下载器独立于任何
  /// 音箱请求存活：音箱断开/重取都不影响它把整文件拉完。
  void _startSpool(
    _StreamEntry entry,
    Future<_SpoolSource> Function() open,
  ) {
    if (entry.spoolStarted) return;
    entry.spoolStarted = true;
    final spool = _Spool(
      File('${Directory.systemTemp.path}/muyin_spool_${entry.token}.bin'),
    );
    entry.spool = spool;
    // 先建空文件：供流侧在 ready 后立即 open 读，不能等下载器
    // 建文件（竞态会让首个请求读到不存在的文件）。
    try {
      spool.file.createSync();
    } catch (_) {}
    unawaited(() async {
      RandomAccessFile? raf;
      _SpoolSource? src;
      try {
        src = await open();
        spool.total = src.total;
        spool.markReady();
        raf = await spool.file.open(mode: FileMode.write);
        await for (final chunk in src.body) {
          if (chunk.isEmpty) continue;
          await raf.writeFrom(chunk);
          spool.frontier += chunk.length;
        }
        spool.done = true;
        _log(
          'stream spooled: label=${entry.labelText} '
          'bytes=${spool.frontier}',
        );
      } catch (e) {
        spool.error = e;
        spool.markReady();
        _log('stream spool failed: label=${entry.labelText} $e');
      } finally {
        try {
          src?.close();
        } catch (_) {}
        try {
          await raf?.close();
        } catch (_) {}
      }
    }());
  }

  /// 普通条目的下载源：整文件 GET（不带 Range，音箱的 Range
  /// 由 spool 文件侧作答）+ steady 断流续传（其 reopen/refresh/
  /// lost 日志即下载侧证据）。上游 ≥400 按失败处理。
  void _startProxySpool(_StreamEntry entry) {
    _startSpool(entry, () async {
      final holder = await _openEntry(entry, null);
      if (holder.response.statusCode >= 400) {
        final code = holder.response.statusCode;
        try {
          await holder.response.drain<void>();
        } catch (_) {}
        holder.close();
        throw StateError('upstream HTTP $code');
      }
      final steady = _steadyParams(holder.response);
      if (steady == null) {
        // 无总长（chunked 上游）：裸流下载，done 后以 frontier
        // 为总长。QQ 等平台均带 Content-Length，此路罕用。
        return _SpoolSource(
          total: -1,
          body: holder.response,
          close: holder.close,
        );
      }
      return _SpoolSource(
        total: steady.$3,
        body: _steadyChunks(
          entry: entry,
          initial: holder,
          start: steady.$1,
          end: steady.$2,
          total: steady.$3,
        ),
        close: () {},
      );
    });
  }

  /// 中段条目的下载源：虚拟文件全量 = head + 上游自 off 起的
  /// steady 流（组成与旧 _middle 的 body 相同，只是改为整文件
  /// 一次性下载、请求侧统一走 spool 文件作答）。
  void _startMiddleSpool(_StreamEntry entry) {
    _startSpool(entry, () async {
      final total = entry.virtualTotal!;
      final headLen = entry.head!.length;
      final srcFrom = entry.off;
      final srcTo = entry.off + total - headLen - 1;
      _UpstreamSource? holder;
      Stream<List<int>>? tail;
      if (srcTo >= srcFrom) {
        final (h, srcTotal) = await _sourceRange(entry, srcFrom, srcTo);
        holder = h;
        tail = _steadyChunks(
          entry: entry,
          initial: h,
          start: srcFrom,
          end: srcTo + 1,
          total: srcTotal,
        );
      }
      final head = entry.head!;
      Stream<List<int>> body() async* {
        if (headLen > 0) yield head;
        if (tail != null) yield* tail;
      }

      return _SpoolSource(
        total: total,
        body: body(),
        close: holder?.close ?? () {},
      );
    });
  }

  /// 从 spool 文件作答一个请求（200/206/416/HEAD 语义与蓝本
  /// middle/serve 一致）：Range 段未落盘时等前沿推进；整文件
  /// GET 走 tail-follow（边下边供，速率由音箱决定、缓冲深度
  /// = 已下载未消费字节，随下载推进单调增长，整文件下完后
  /// 剩余播放全程本地供流）。下载失败/文件短于声明时截断
  /// 关闭——音箱会自行重取，重取仍走本文件（已落盘部分在）。
  Future<void> _serveSpool(
    HttpRequest request,
    _StreamEntry entry,
    int count,
    _Spool spool,
  ) async {
    final response = request.response;
    // 等总长（首个上游响应头）或下载失败。
    try {
      await spool.ready.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      // 用已知状态继续判定（下方按 error/frontier 收尾）。
    }
    if (spool.total < 0 && spool.error != null) {
      _beginServed(entry, count, HttpStatus.badGateway);
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    if (spool.total < 0) {
      // 无总长上游：等下载完成以 frontier 为总长（上限 20 秒）。
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!spool.done && spool.error == null) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (spool.error != null || spool.frontier <= 0) {
        _beginServed(entry, count, HttpStatus.badGateway);
        response.statusCode = HttpStatus.badGateway;
        await response.close();
        return;
      }
    }
    final total = spool.total >= 0 ? spool.total : spool.frontier;
    var from = 0;
    var to = total - 1;
    var code = HttpStatus.ok;
    String? contentRange;
    final range = _parseRangeHeader(
      request.headers.value(HttpHeaders.rangeHeader),
      total,
    );
    if (range != null) {
      from = range.$1;
      to = range.$2;
      if (from > to) {
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        _beginServed(entry, count, HttpStatus.requestedRangeNotSatisfiable);
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }
      code = HttpStatus.partialContent;
      contentRange = 'bytes $from-$to/$total';
    }
    _beginServed(
      entry,
      count,
      code,
      contentRange: contentRange,
      contentLength: total,
    );
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (contentRange != null) {
      response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
    }
    response.contentLength = to - from + 1;
    response.statusCode = code;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    RandomAccessFile? raf;
    try {
      raf = await spool.file.open(mode: FileMode.read);
      var cursor = from;
      while (cursor <= to) {
        if (cursor < spool.frontier) {
          final n = min(to, spool.frontier - 1) - cursor + 1;
          await raf.setPosition(cursor);
          final data = await raf.read(n);
          if (data.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            continue;
          }
          response.add(data);
          _addServed(entry, count, data.length);
          await response.flush();
          cursor += data.length;
        } else if (spool.done || spool.error != null) {
          // 文件短于声明/下载失败：截断关闭，音箱自行重取。
          // 注：Dart HttpServer 在 contentLength 未满足时 close
          // 会丢弃已 add 的 body，音箱可能只收到中止信号——
          // 与旧透传路径同行为，不影响其重取决策。
          break;
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    } catch (_) {
      // 音箱断开等：静默收尾（served 统计已记录，lost 由
      // watch 判定；下载器不受影响继续拉完）。
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
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
      _log(
        'stream proxy failed: label=${entry.labelText} '
        'served=${entry.served.bytes}/${entry.served.total} $e',
      );
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
    required _StreamEntry entry,
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
        _log(
          'stream reopen: label=${entry.labelText} '
          'off=$off/$total cause=$cause',
        );
        current.close();
        _UpstreamSource? next;
        while (next == null) {
          if (fails >= _reopenWait.length) {
            throw cause ?? StateError('steady reopen exhausted');
          }
          await Future<void>.delayed(_reopenWait[fails]);
          fails++;
          try {
            final holder = await _openEntry(entry, 'bytes=$off-${end - 1}');
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
        _log('stream reopened: label=${entry.labelText} off=$off');
      }
    } catch (e) {
      // steady 放弃：本次响应随之失败，音箱大概率播报失败——
      // 这行是断流定性的关键证据（断点偏移 + 已供/总量）。
      _log(
        'stream lost: label=${entry.labelText} '
        'off=$off/$total cause=$e',
      );
      rethrow;
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
        filePath: entry.filePath,
        urlRefresher: entry.urlRefresher,
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

  /// 单段 Range 解析（与蓝本 middle 同口径）：无 Range 头或解析
  /// 不出返回 null（按全量作答）；返回 (from, toInclusive)，to 已
  /// 夹到 total-1；from>to 由调用方判 416。
  static (int, int)? _parseRangeHeader(String? rangeRaw, int total) {
    if (rangeRaw == null) return null;
    final rng = rangeRaw.replaceAll(' ', '');
    if (!rng.startsWith('bytes=')) return null;
    final dash = rng.indexOf('-', 6);
    if (dash < 0) return null;
    final a = rng.substring(6, dash);
    final bStr = rng.substring(dash + 1);
    var from = 0;
    var to = total - 1;
    if (a.isEmpty) {
      final n = int.tryParse(bStr);
      if (n == null) return null;
      from = max(0, total - n);
    } else {
      final n = int.tryParse(a);
      if (n == null) return null;
      from = n;
      final m = int.tryParse(bStr);
      if (m != null) to = min(to, m);
    }
    return (from, to);
  }

  /// 文件条目供流（蓝本 Song 的 serve）：磁盘文件按 Range 作答
  /// （200/206/416）。本地字节没有过期问题——音箱播完从头重取
  /// 永远成功，收尾交给 watch 的 stop-loop 与队列推进的下一首
  /// 推送，不会触发固件的「播放失败」播报。
  Future<void> _serveFile(
    HttpRequest request,
    _StreamEntry entry,
    int count,
  ) async {
    final response = request.response;
    final file = File(entry.filePath!);
    final int total;
    try {
      total = await file.length();
    } catch (e) {
      _log('stream file read failed: ${entry.labelText} $e');
      _beginServed(entry, count, HttpStatus.badGateway);
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    var from = 0;
    var to = total - 1;
    var code = HttpStatus.ok;
    String? contentRange;
    final range = _parseRangeHeader(
      request.headers.value(HttpHeaders.rangeHeader),
      total,
    );
    if (range != null) {
      from = range.$1;
      to = range.$2;
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
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (contentRange != null) {
      response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
    }
    response.contentLength = to - from + 1;
    response.statusCode = code;
    _beginServed(
      entry,
      count,
      code,
      contentRange: contentRange,
      contentLength: to - from + 1,
    );
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    await _pump(request, entry, count, file.openRead(from, to + 1));
  }

  /// 文件版 middle：虚拟文件 = head 切片 + 源文件自 off 起的
  /// 内容，字节全部读盘（本地歌的中段续播）。
  Future<void> _middleFile(
    HttpRequest request,
    _StreamEntry entry,
    int count,
  ) async {
    final response = request.response;
    final total = entry.virtualTotal!;
    final headLen = entry.head!.length;
    final file = File(entry.filePath!);
    final int srcTotal;
    try {
      srcTotal = await file.length();
    } catch (e) {
      _log('stream file read failed: ${entry.labelText} $e');
      _beginServed(entry, count, HttpStatus.badGateway);
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    var from = 0;
    var to = total - 1;
    var code = HttpStatus.ok;
    String? contentRange;
    final range = _parseRangeHeader(
      request.headers.value(HttpHeaders.rangeHeader),
      total,
    );
    if (range != null) {
      from = range.$1;
      to = range.$2;
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
      await response.close();
      return;
    }
    Stream<List<int>> body() async* {
      if (from < headLen) {
        yield entry.head!.sublist(from, min(headLen, to + 1));
      }
      if (to >= headLen) {
        final srcFrom = entry.off + (from - headLen < 0 ? 0 : from - headLen);
        final srcTo = entry.off + to - headLen;
        if (srcFrom <= srcTo && srcFrom < srcTotal) {
          yield* file.openRead(srcFrom, min(srcTo, srcTotal - 1) + 1);
        }
      }
    }

    await _pump(request, entry, count, body());
  }

  /// 蓝本 middle 的 spool 版：虚拟文件（head + 上游自 off 起）
  /// 整文件预读落盘，请求侧按虚拟长度 Range 作答（200/206/
  /// 416），与旧 _middle 的对外语义一致。旧版每请求现开上游
  /// 子段流，续播条目同样暴露在透传断流下，故一并 spool 化。
  Future<void> _middle(HttpRequest request, _StreamEntry entry, int count) async {
    _startMiddleSpool(entry);
    await _serveSpool(request, entry, count, entry.spool!);
  }

  void _log(String message) => _onLog?.call(message);
}

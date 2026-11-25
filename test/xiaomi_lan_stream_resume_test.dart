import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/lan_stream_server.dart';

/// 构造 CBR MP3：ID3 头（20 字节标签）+ 100 帧。
/// 帧头 FF FB 90 00 = MPEG1 Layer III 128kbps 44100Hz，帧长
/// 144000*128~/44100 = 417。文件总长 30 + 417*100 = 41730，
/// 时长按 publish 的 durationMs 计，不由文件推导。
List<int> buildCbrMp3() {
  final bytes = <int>[
    0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 20,
    ...List.filled(20, 0),
  ];
  for (var frame = 0; frame < 100; frame++) {
    bytes.addAll([0xFF, 0xFB, 0x90, 0x00]);
    bytes.addAll(List.filled(417 - 4, frame % 251));
  }
  return bytes;
}

class _GetResult {
  _GetResult(this.statusCode, this.bytes, this.headers);
  final int statusCode;
  final List<int> bytes;
  final HttpHeaders headers;
}

Future<_GetResult> _httpGet(String url, {Map<String, String>? headers}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    headers?.forEach((k, v) => request.headers.set(k, v));
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return _GetResult(response.statusCode, bytes, response.headers);
  } finally {
    client.close(force: true);
  }
}

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void serveRange(HttpRequest request, List<int> data) {
  final response = request.response;
  final range = request.headers.value(HttpHeaders.rangeHeader);
  if (range != null) {
    final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
    final start = int.parse(match.group(1)!);
    final requestedEnd = match.group(2)!.isEmpty
        ? data.length - 1
        : int.parse(match.group(2)!);
    final end = requestedEnd > data.length - 1 ? data.length - 1 : requestedEnd;
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/${data.length}',
    );
    response.contentLength = end - start + 1;
    response.add(data.sublist(start, end + 1));
  } else {
    response.contentLength = data.length;
    response.add(data);
  }
  response.close();
}

void main() {
  final mp3 = buildCbrMp3();
  final steadyBytes = [for (var i = 0; i < 1000; i++) i % 251];
  late HttpServer upstream;
  late String upstreamBase;
  late LanStreamServer server;
  late List<String> breakRangeHeaders;
  late bool breakArmed;

  setUp(() async {
    breakRangeHeaders = [];
    breakArmed = true;
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstreamBase = 'http://127.0.0.1:${upstream.port}';
    upstream.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/song.mp3':
          serveRange(request, mp3);
        case '/norange.mp3':
          // 忽略 Range 恒 200：peek 拿不到 206，resume 应失败。
          response.contentLength = mp3.length;
          response.add(mp3);
          await response.close();
        case '/break.mp3':
          final range = request.headers.value(HttpHeaders.rangeHeader);
          if (range == null && breakArmed) {
            breakArmed = false;
            // 声明全长，只发 400 字节就优雅断开（FIN），模拟上游
            // 中途断流：客户端能收到已发的 400 字节，随后 EOF/报错。
            response.contentLength = steadyBytes.length;
            final socket = await response.detachSocket();
            socket.add(steadyBytes.sublist(0, 400));
            await socket.flush();
            await socket.close();
          } else {
            if (range != null) breakRangeHeaders.add(range);
            serveRange(request, steadyBytes);
          }
        default:
          response.statusCode = HttpStatus.notFound;
          await response.close();
      }
    });

    server = LanStreamServer(
      basePort: await freePort(),
      lanIpLookup: () async => '127.0.0.1',
    );
    expect(await server.start(), isTrue);
  });

  tearDown(() async {
    await server.stop();
    await upstream.close(force: true);
  });

  test('steady：上游中途断开后按已供偏移 Range 续上，字节完整', () async {
    final handle = await server.publish('$upstreamBase/break.mp3');
    final result = await _httpGet(handle!.url);
    expect(result.statusCode, 200);
    expect(result.bytes, steadyBytes);
    expect(breakRangeHeaders, contains('bytes=400-999'));
  });

  test('resume：CBR 落点在帧边界，新句柄从该帧起供流', () async {
    final handle = await server.publish(
      '$upstreamBase/song.mp3',
      durationMs: 10000,
      label: '续播歌',
    );
    // frac=0.5 → off = 30 + 41700/2 = 20880 = 第 50 帧起点。
    final resumed = await handle!.resume(5000);
    expect(resumed, isNotNull);
    expect(resumed!.startMs, 5000);
    expect(resumed.handle.lengthMs, 5000);

    final result = await _httpGet(resumed.handle.url);
    expect(result.statusCode, 200);
    expect(result.bytes.length, 41730 - 20880);
    expect(result.bytes, mp3.sublist(20880));
    // 落点即帧头。
    expect(result.bytes.sublist(0, 4), [0xFF, 0xFB, 0x90, 0x00]);
  });

  test('resume：中段条目 Range 对虚拟长度作答', () async {
    final handle = await server.publish(
      '$upstreamBase/song.mp3',
      durationMs: 10000,
    );
    final resumed = await handle!.resume(5000);
    final result = await _httpGet(
      resumed!.handle.url,
      headers: {HttpHeaders.rangeHeader: 'bytes=100-199'},
    );
    expect(result.statusCode, 206);
    expect(
      result.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 100-199/20850',
    );
    expect(result.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(result.bytes, mp3.sublist(20880 + 100, 20880 + 200));
  });

  test('resume：中段条目 Range 越界 → 416', () async {
    final handle = await server.publish(
      '$upstreamBase/song.mp3',
      durationMs: 10000,
    );
    final resumed = await handle!.resume(5000);
    final result = await _httpGet(
      resumed!.handle.url,
      headers: {HttpHeaders.rangeHeader: 'bytes=30000-'},
    );
    expect(result.statusCode, 416);
    expect(
      result.headers.value(HttpHeaders.contentRangeHeader),
      'bytes */20850',
    );
  });

  test('resume：atMs<=0 / >=时长 / 时长未知 → null', () async {
    final handle = await server.publish(
      '$upstreamBase/song.mp3',
      durationMs: 10000,
    );
    expect(await handle!.resume(0), isNull);
    expect(await handle.resume(-5), isNull);
    expect(await handle.resume(10000), isNull);
    expect(await handle.resume(15000), isNull);

    final unknown = await server.publish('$upstreamBase/song.mp3');
    expect(await unknown!.resume(5000), isNull);
  });

  test('resume：上游不支持 206 → null', () async {
    final handle = await server.publish(
      '$upstreamBase/norange.mp3',
      durationMs: 10000,
    );
    expect(await handle!.resume(5000), isNull);
  });
}

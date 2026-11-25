import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/lan_stream_server.dart';

/// 自构造 MP3 字节（与 xiaomi_lan_stream_test 同法）。
List<int> buildMp3Bytes(int total) {
  const id3Size = 20;
  final bytes = <int>[
    0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, id3Size,
    ...List.filled(id3Size, 0),
    0xFF, 0xFB, 0x90, 0x00,
  ];
  while (bytes.length < total) {
    bytes.add(0);
  }
  return bytes;
}

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// 正常供流（支持 Range 206）。
void serveSong(HttpRequest request, List<int> songBytes) {
  final response = request.response;
  final range = request.headers.value(HttpHeaders.rangeHeader);
  if (range != null) {
    final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
    final start = int.parse(match.group(1)!);
    final end = match.group(2)!.isEmpty
        ? songBytes.length - 1
        : int.parse(match.group(2)!);
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/${songBytes.length}',
    );
    response.headers.contentType = ContentType('application', 'octet-stream');
    response.contentLength = end - start + 1;
    response.add(songBytes.sublist(start, end + 1));
  } else {
    response.headers.contentType = ContentType('application', 'octet-stream');
    response.contentLength = songBytes.length;
    response.add(songBytes);
  }
  response.close();
}

/// 供出前 [n] 字节后毁连接（模拟上游中途断开）：先 detach 拿到
/// 原始 socket（自动写响应头），写部分字节后直接 destroy。
Future<void> servePartialThenDestroy(
  HttpRequest request,
  List<int> songBytes,
  int n,
) async {
  final response = request.response;
  response.headers.contentType = ContentType('application', 'octet-stream');
  response.contentLength = songBytes.length;
  final socket = await response.detachSocket();
  socket.add(songBytes.sublist(0, n));
  await socket.flush();
  socket.destroy();
}

/// 收集一次 GET 的结果：状态码、收到的字节、中途是否异常断开。
Future<({int status, List<int> bytes, bool aborted})> httpGetAll(
  String url,
) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final bytes = <int>[];
    var aborted = false;
    try {
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
    } catch (_) {
      aborted = true;
    }
    return (status: response.statusCode, bytes: bytes, aborted: aborted);
  } finally {
    client.close(force: true);
  }
}

void main() {
  final songBytes = buildMp3Bytes(1000);
  late HttpServer upstream;
  late String upstreamBase;
  late LanStreamServer server;
  late List<String> logs;
  late Map<String, int> hits;

  setUp(() async {
    logs = [];
    hits = {};
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstreamBase = 'http://127.0.0.1:${upstream.port}';
    upstream.listen((request) async {
      final path = request.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      switch (path) {
        case '/break.mp3':
          // 首次无 Range 打开：供一半毁连接；之后（Range 重开）正常。
          if (range == null && hits[path] == 1) {
            await servePartialThenDestroy(request, songBytes, 400);
          } else {
            serveSong(request, songBytes);
          }
        case '/expire.mp3':
          // 首次打开供一半毁连接；旧链此后一律 403（已过期）。
          if (range == null && hits[path] == 1) {
            await servePartialThenDestroy(request, songBytes, 400);
          } else {
            request.response.statusCode = HttpStatus.forbidden;
            await request.response.close();
          }
        case '/fresh.mp3':
          serveSong(request, songBytes);
        case '/die.mp3':
          // 首次供一半毁连接；此后任何打开都毁连接（彻底不可用）。
          if (range == null && hits[path] == 1) {
            await servePartialThenDestroy(request, songBytes, 400);
          } else {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.destroy();
          }
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    });

    server = LanStreamServer(
      basePort: await freePort(),
      lanIpLookup: () async => '127.0.0.1',
      onLog: logs.add,
    );
    expect(await server.start(), isTrue);
  });

  tearDown(() async {
    await server.stop();
    await upstream.close(force: true);
  });

  test('上游中途断开 → steady 重开续传，音箱侧拿到完整字节', () async {
    final handle = await server.publish(
      '$upstreamBase/break.mp3',
      durationMs: 200000,
      label: '断流歌',
    );
    expect(handle, isNotNull);

    final result = await httpGetAll(handle!.url);
    expect(result.status, HttpStatus.ok);
    expect(result.aborted, isFalse);
    expect(result.bytes, songBytes);
    expect(logs.any((l) => l.contains('stream reopen:')), isTrue);
    expect(logs.any((l) => l.contains('stream reopened:')), isTrue);
    expect(handle.lost, isFalse);
  });

  test('重开时旧链过期 → 换链后接上，音箱侧不断流', () async {
    final handle = await server.publish(
      '$upstreamBase/expire.mp3',
      durationMs: 200000,
      label: '过期歌',
      urlRefresher: () async => '$upstreamBase/fresh.mp3',
    );
    expect(handle, isNotNull);

    final result = await httpGetAll(handle!.url);
    expect(result.status, HttpStatus.ok);
    expect(result.aborted, isFalse);
    expect(result.bytes, songBytes);
    expect(logs.any((l) => l.contains('stream upstream refreshed:')), isTrue);
    expect(logs.any((l) => l.contains('stream reopened:')), isTrue);
  });

  test(
    '上游彻底不可用 → 响应中止、条目 lost、日志留痕',
    () async {
      final handle = await server.publish(
        '$upstreamBase/die.mp3',
        durationMs: 200000,
        label: '死链歌',
      );
      expect(handle, isNotNull);

      final result = await httpGetAll(handle!.url);
      // 只收到断开前的 400 字节，连接随 steady 放弃而中止。
      expect(result.bytes.length, lessThan(songBytes.length));
      // 等服务端收尾（served.open 落下）。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(handle.lost, isTrue);
      expect(logs.any((l) => l.contains('stream reopen:')), isTrue);
      expect(logs.any((l) => l.contains('stream lost:')), isTrue);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/lan_stream_server.dart';

/// 自构造 MP3 字节：ID3 头 + 帧头 0xFF 0xFB 0x90 0x00 + 填充。
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

void main() {
  final songBytes = buildMp3Bytes(1000);
  late HttpServer upstream;
  late String upstreamBase;
  late LanStreamServer server;
  late int nowMsValue;
  const startNow = 1700000000000;

  setUp(() async {
    nowMsValue = startNow;
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstreamBase = 'http://127.0.0.1:${upstream.port}';
    upstream.listen((request) {
      final response = request.response;
      if (request.uri.path == '/song.mp3') {
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
      } else if (request.uri.path == '/norange.mp3') {
        // 忽略 Range，恒回 200 全量。
        response.headers.contentType = ContentType('application', 'octet-stream');
        response.contentLength = songBytes.length;
        response.add(songBytes);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      response.close();
    });

    server = LanStreamServer(
      basePort: await freePort(),
      nowMs: () => nowMsValue,
      lanIpLookup: () async => '127.0.0.1',
    );
    expect(await server.start(), isTrue);
  });

  tearDown(() async {
    await server.stop();
    await upstream.close(force: true);
  });

  test('publish URL 形态 + GET 200 全量 + wasFetched false→true', () async {
    final pushUrl = await server.publish('$upstreamBase/song.mp3');
    expect(pushUrl, isNotNull);
    expect(
      pushUrl,
      matches(
        RegExp(
          r'^http://127\.0\.0\.1:\d+/stream/[0-9a-f]{32}\.mp3$',
        ),
      ),
    );
    expect(server.wasFetched(pushUrl!), isFalse);

    final result = await _httpGet(pushUrl);
    expect(result.statusCode, 200);
    expect(result.bytes, songBytes);
    expect(result.headers.contentType?.mimeType, 'audio/mpeg');
    expect(server.wasFetched(pushUrl), isTrue);
  });

  test('带 Range 且上游 206 → 206 分段', () async {
    final pushUrl = await server.publish('$upstreamBase/song.mp3');
    final result = await _httpGet(
      pushUrl!,
      headers: {HttpHeaders.rangeHeader: 'bytes=100-199'},
    );
    expect(result.statusCode, 206);
    expect(
      result.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 100-199/1000',
    );
    expect(result.bytes, songBytes.sublist(100, 200));
    expect(result.headers.contentType?.mimeType, 'audio/mpeg');
  });

  test('上游忽略 Range 恒 200 → 代理回 200 全量', () async {
    final pushUrl = await server.publish('$upstreamBase/norange.mp3');
    final result = await _httpGet(
      pushUrl!,
      headers: {HttpHeaders.rangeHeader: 'bytes=100-199'},
    );
    expect(result.statusCode, 200);
    expect(result.bytes, songBytes);
    expect(result.headers.value(HttpHeaders.contentRangeHeader), isNull);
  });

  test('未知 token → 404', () async {
    final result = await _httpGet(
      'http://127.0.0.1:${server.boundPort}/stream/${'a' * 32}.mp3',
    );
    expect(result.statusCode, 404);
  });

  test('未取流 token 推进 6 分钟 → 404', () async {
    final pushUrl = await server.publish('$upstreamBase/song.mp3');
    nowMsValue += 6 * 60 * 1000;
    final result = await _httpGet(pushUrl!);
    expect(result.statusCode, 404);
  });

  test('已取流 token：+20 分钟仍 200，fetched+31 分钟 → 404', () async {
    final pushUrl = await server.publish('$upstreamBase/song.mp3');
    expect((await _httpGet(pushUrl!)).statusCode, 200);

    nowMsValue += 20 * 60 * 1000;
    expect((await _httpGet(pushUrl)).statusCode, 200);

    nowMsValue += 11 * 60 * 1000;
    expect((await _httpGet(pushUrl)).statusCode, 404);
  });

  test('lanIpLookup 返回 null → publish null', () async {
    final noIp = LanStreamServer(
      basePort: await freePort(),
      nowMs: () => nowMsValue,
      lanIpLookup: () async => null,
    );
    expect(await noIp.start(), isTrue);
    expect(await noIp.publish('$upstreamBase/song.mp3'), isNull);
    await noIp.stop();
  });

  test('stop 后 publish → null', () async {
    expect(await server.publish('$upstreamBase/song.mp3'), isNotNull);
    await server.stop();
    expect(server.isRunning, isFalse);
    expect(await server.publish('$upstreamBase/song.mp3'), isNull);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/lan_stream_server.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_stream_proxy.dart';

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

Future<int> _httpHead(String url) async {
  final client = HttpClient();
  try {
    final request = await client.headUrl(Uri.parse(url));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
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

void main() {
  final songBytes = buildMp3Bytes(1000);
  late HttpServer upstream;
  late String upstreamBase;
  late LanStreamServer server;
  late int nowMsValue;
  late int flakyHits;
  const startNow = 1700000000000;

  setUp(() async {
    nowMsValue = startNow;
    flakyHits = 0;
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstreamBase = 'http://127.0.0.1:${upstream.port}';
    upstream.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/song.mp3') {
        serveSong(request, songBytes);
      } else if (request.uri.path == '/flaky.mp3') {
        flakyHits++;
        if (flakyHits == 1) {
          // 首次打开直接毁连接，模拟上游打开失败（openAgain 场景）。
          final socket = await response.detachSocket(writeHeaders: false);
          socket.destroy();
          return;
        }
        serveSong(request, songBytes);
      } else if (request.uri.path == '/norange.mp3') {
        // 忽略 Range，恒回 200 全量。
        response.headers.contentType = ContentType('application', 'octet-stream');
        response.contentLength = songBytes.length;
        response.add(songBytes);
        response.close();
      } else {
        response.statusCode = HttpStatus.notFound;
        response.close();
      }
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

  Future<StreamHandle> publishSong({int? durationMs, String path = '/song.mp3'}) async {
    final handle = await server.publish(
      '$upstreamBase$path',
      durationMs: durationMs,
      label: '测试歌',
    );
    expect(handle, isNotNull);
    return handle!;
  }

  test('publish URL 形态 + GET 200 全量 + fetched false→true', () async {
    final handle = await publishSong();
    expect(
      handle.url,
      matches(RegExp(r'^http://127\.0\.0\.1:\d+/stream/[0-9a-f]{32}\.mp3$')),
    );
    expect(handle.label, '测试歌');
    expect(handle.fetched, isFalse);
    expect(handle.fetchedAtMs, isNull);
    expect(handle.fetchCount, 0);

    final result = await _httpGet(handle.url);
    expect(result.statusCode, 200);
    expect(result.bytes, songBytes);
    expect(result.headers.contentType?.mimeType, 'audio/mpeg');
    expect(result.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
    expect(handle.fetched, isTrue);
    expect(handle.fetchedAtMs, startNow);
    expect(handle.fetchCount, 1);
  });

  test('HEAD 也记 fetched', () async {
    final handle = await publishSong();
    expect(await _httpHead(handle.url), 200);
    expect(handle.fetched, isTrue);
    expect(handle.fetchCount, 1);
  });

  test('带 Range 且上游 206 → 206 分段', () async {
    final handle = await publishSong();
    final result = await _httpGet(
      handle.url,
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

  test('上游忽略 Range 恒 200 → spool 吸收：Range 由本地文件作答 206', () async {
    // 旧透传语义是把上游的 200 全量原样回给音箱；spool 化后
    // 下载器恒全量取回整文件，音箱的 Range 在文件侧正确作答
    // （与文件条目/中段条目的 Range 语义一致）。
    final handle = await publishSong(path: '/norange.mp3');
    final result = await _httpGet(
      handle.url,
      headers: {HttpHeaders.rangeHeader: 'bytes=100-199'},
    );
    expect(result.statusCode, 206);
    expect(result.bytes, songBytes.sublist(100, 200));
    expect(
      result.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 100-199/${songBytes.length}',
    );
  });

  test('未知 token → 404', () async {
    final result = await _httpGet(
      'http://127.0.0.1:${server.boundPort}/stream/${'a' * 32}.mp3',
    );
    expect(result.statusCode, 404);
  });

  test('TTL 统一 6 小时：未取流 +5h59m 仍 200，+6h 后 404', () async {
    final handle = await publishSong();
    nowMsValue += 5 * 60 * 60 * 1000 + 59 * 60 * 1000;
    expect((await _httpGet(handle.url)).statusCode, 200);

    final handle2 = await publishSong();
    // handle2 的过期点是其 publish 时刻 +6h；把时钟推到该点之后。
    nowMsValue += 6 * 60 * 60 * 1000 + 1;
    expect((await _httpGet(handle2.url)).statusCode, 404);
  });

  test('TTL：已取流不缩短，publish +6h 后一律 404', () async {
    final handle = await publishSong();
    expect((await _httpGet(handle.url)).statusCode, 200);
    nowMsValue += 5 * 60 * 60 * 1000;
    expect((await _httpGet(handle.url)).statusCode, 200);
    nowMsValue += 60 * 60 * 1000 + 1;
    expect((await _httpGet(handle.url)).statusCode, 404);
  });

  test('restarted：时长已知 gap=时长*9/10', () async {
    final handle = await publishSong(durationMs: 10000); // gap 9000ms
    await _httpGet(handle.url);
    expect(handle.restarted, isFalse);

    nowMsValue += 8999;
    await _httpGet(handle.url);
    expect(handle.restarted, isFalse);

    nowMsValue += 1;
    await _httpGet(handle.url);
    expect(handle.restarted, isTrue);
    expect(handle.fetchCount, 3);
  });

  test('restarted：时长未知 gap=15s，且非从头请求不触发', () async {
    final handle = await publishSong();
    await _httpGet(handle.url);

    nowMsValue += 15000;
    // 非从头（bytes=100-）不算重取。
    await _httpGet(
      handle.url,
      headers: {HttpHeaders.rangeHeader: 'bytes=100-199'},
    );
    expect(handle.restarted, isFalse);

    await _httpGet(
      handle.url,
      headers: {HttpHeaders.rangeHeader: 'bytes=0-'},
    );
    expect(handle.restarted, isTrue);
  });

  test('restarted：时长未知时 15s 内从头请求不触发', () async {
    final handle = await publishSong();
    await _httpGet(handle.url);
    nowMsValue += 14999;
    await _httpGet(handle.url);
    expect(handle.restarted, isFalse);
  });

  test('lost：只取一半（Range 0-499）后请求结束 → lost', () async {
    final handle = await publishSong();
    final result = await _httpGet(
      handle.url,
      headers: {HttpHeaders.rangeHeader: 'bytes=0-499'},
    );
    expect(result.statusCode, 206);
    expect(result.bytes.length, 500);
    expect(handle.lost, isTrue);
  });

  test('lost：全量取完 → 不 lost', () async {
    final handle = await publishSong();
    await _httpGet(handle.url);
    expect(handle.lost, isFalse);
  });

  test('openAgain：上游首次打开失败、第二次成功 → 200 全量', () async {
    final handle = await publishSong(path: '/flaky.mp3');
    final result = await _httpGet(handle.url);
    expect(result.statusCode, 200);
    expect(result.bytes, songBytes);
    expect(flakyHits, 2);
  });

  test('上游 404 → 代理回 502', () async {
    final handle = await publishSong(path: '/missing.mp3');
    final result = await _httpGet(handle.url);
    expect(result.statusCode, 502);
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

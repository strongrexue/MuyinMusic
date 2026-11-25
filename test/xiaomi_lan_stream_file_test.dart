import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/lan_stream_server.dart';

/// 构造 CBR MP3：ID3 头（20 字节标签）+ 100 帧（帧长 417，
/// 128kbps/44100Hz），总长 41730（与 resume 测试同构造）。
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

void main() {
  final mp3 = buildCbrMp3();
  late Directory tempDir;
  late File songFile;
  late LanStreamServer server;
  late HttpServer upstream;
  late String upstreamBase;
  late bool songExpired;
  late int freshHits;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lan_stream_file_test');
    songFile = File('${tempDir.path}/song.mp3');
    await songFile.writeAsBytes(mp3);
    songExpired = false;
    freshHits = 0;
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstreamBase = 'http://127.0.0.1:${upstream.port}';
    upstream.listen((request) {
      final response = request.response;
      switch (request.uri.path) {
        case '/song.mp3':
          if (songExpired) {
            response.statusCode = HttpStatus.forbidden;
            response.close();
          } else {
            response.contentLength = mp3.length;
            response.add(mp3);
            response.close();
          }
        case '/fresh.mp3':
          freshHits++;
          response.contentLength = mp3.length;
          response.add(mp3);
          response.close();
        default:
          response.statusCode = HttpStatus.forbidden;
          response.close();
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
    await tempDir.delete(recursive: true);
  });

  group('本地文件供流（蓝本 Song）', () {
    test('publishFile → GET 200 全量 + Range 206 分段 + fetched', () async {
      final handle = await server.publishFile(
        songFile.path,
        durationMs: 2612,
        label: '本地歌',
      );
      expect(handle, isNotNull);
      expect(handle!.fetched, isFalse);

      final full = await _httpGet(handle.url);
      expect(full.statusCode, 200);
      expect(full.bytes, mp3);
      expect(full.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(handle.fetched, isTrue);

      final part = await _httpGet(
        handle.url,
        headers: {HttpHeaders.rangeHeader: 'bytes=100-199'},
      );
      expect(part.statusCode, 206);
      expect(
        part.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 100-199/${mp3.length}',
      );
      expect(part.bytes, mp3.sublist(100, 200));
    });

    test('publishFile 文件不存在 → null（备歌失败，step 跳过）', () async {
      expect(
        await server.publishFile('${tempDir.path}/gone.mp3'),
        isNull,
      );
    });

    test('文件条目中段续播：resume 后从帧边界供流', () async {
      final handle = await server.publishFile(
        songFile.path,
        durationMs: 2612,
        label: '本地歌',
      );
      expect(handle, isNotNull);
      final resumed = await handle!.resume(1300);
      expect(resumed, isNotNull);
      expect(resumed!.startMs, 1300);
      // CBR 估算落点 20784，扫描对齐到下一帧头 20880。
      final result = await _httpGet(resumed.handle.url);
      expect(result.statusCode, 200);
      expect(result.bytes, mp3.sublist(20880));
    });

    test('文件被删后再请求 → 502 而非挂死（watch 会收尾）', () async {
      final handle = await server.publishFile(songFile.path);
      expect(handle, isNotNull);
      await songFile.delete();
      final result = await _httpGet(handle!.url);
      expect(result.statusCode, 502);
    });
  });

  group('直链过期换链（蓝本 Opener refresh）', () {
    test('旧链 403 + 有换链回调 → 换新链后 200 供流', () async {
      final handle = await server.publish(
        '$upstreamBase/dead.mp3',
        label: '线上歌',
        urlRefresher: () async => '$upstreamBase/fresh.mp3',
      );
      expect(handle, isNotNull);
      final result = await _httpGet(handle!.url);
      expect(result.statusCode, 200);
      expect(result.bytes, mp3);
      expect(freshHits, 1);
    });

    test('播完重取时旧链已过期 → spool 本地续供，不回 502、不必换链', () async {
      final handle = await server.publish(
        '$upstreamBase/song.mp3',
        durationMs: 2612,
        label: '线上歌',
        urlRefresher: () async => '$upstreamBase/fresh.mp3',
      );
      expect(handle, isNotNull);
      expect((await _httpGet(handle!.url)).statusCode, 200);
      // 歌播完，签名链过期；固件从头重取（单曲循环）。spool
      // 化后整文件已落盘，重取直接本地作答——旧语义靠换链
      // 续供（freshHits≥1），现在连上游都不用打，更强。
      songExpired = true;
      final again = await _httpGet(handle.url);
      expect(again.statusCode, 200);
      expect(again.bytes, mp3);
      expect(freshHits, 0);
    });

    test('无换链回调 + 旧链 403 → 仍回 502（原行为不变）', () async {
      final handle = await server.publish('$upstreamBase/dead.mp3');
      expect(handle, isNotNull);
      final result = await _httpGet(handle!.url);
      expect(result.statusCode, 502);
    });
  });
}

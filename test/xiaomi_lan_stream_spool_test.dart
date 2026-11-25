import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/lan_stream_server.dart';

/// 自构造 MP3 字节（与 xiaomi_lan_stream_break_test 同法）。
List<int> buildMp3Bytes(int total) {
  const id3Size = 20;
  final bytes = <int>[
    0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, id3Size,
    ...List.filled(id3Size, 0),
    0xFF, 0xFB, 0x90, 0x00,
  ];
  while (bytes.length < total) {
    bytes.add(bytes.length & 0xFF);
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

/// 供出前 [n] 字节后毁连接（模拟上游中途断开）。
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
  String url, {
  String? range,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, range);
    }
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

/// 推流预读 spool（2026-11-25 第四轮追加）：首个请求触发全速
/// 下载整文件落盘，音箱请求从文件按前沿供流——上游中途断开、
/// 慢速滴流对音箱不可见；二次取流不再打上游。另测实质重取
/// 事件（restartAtMs）落信号。
void main() {
  final songBytes = buildMp3Bytes(1000);
  final bigBytes = buildMp3Bytes(200000);
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
          if (range == null && hits[path] == 1) {
            await servePartialThenDestroy(request, songBytes, 400);
          } else {
            serveSong(request, songBytes);
          }
        case '/drip.mp3':
          if (range == null) {
            // 慢速滴流：4KB / 30ms，全程不断。
            final response = request.response;
            response.headers.contentType = ContentType(
              'application',
              'octet-stream',
            );
            response.contentLength = bigBytes.length;
            var off = 0;
            while (off < bigBytes.length) {
              final end = off + 4096 > bigBytes.length
                  ? bigBytes.length
                  : off + 4096;
              response.add(bigBytes.sublist(off, end));
              await response.flush();
              off = end;
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            await response.close();
          } else {
            serveSong(request, bigBytes);
          }
        case '/die.mp3':
          if (range == null && hits[path] == 1) {
            await servePartialThenDestroy(request, songBytes, 400);
          } else {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.destroy();
          }
        case '/song.mp3':
          serveSong(request, songBytes);
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

  test('spool：上游中途断开对音箱不可见；二次取流不再打上游', () async {
    final handle = await server.publish(
      '$upstreamBase/break.mp3',
      durationMs: 269000,
      label: '断流歌',
    );
    expect(handle, isNotNull);

    final first = await httpGetAll(handle!.url);
    expect(first.status, HttpStatus.ok);
    expect(first.aborted, isFalse);
    expect(first.bytes, songBytes);
    // 下载器：首次打开（断）+ steady 一次重开。
    expect(hits['/break.mp3'], 2);
    expect(logs.any((l) => l.contains('stream reopen')), isTrue);

    // 等下载器收尾，再取一遍：全程本地文件，上游零新请求。
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!logs.any((l) => l.contains('stream spooled'))) {
      if (DateTime.now().isAfter(deadline)) fail('spool 未在 3 秒内下完');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final second = await httpGetAll(handle.url);
    expect(second.bytes, songBytes);
    expect(hits['/break.mp3'], 2);
  });

  test('spool：下载中 Range 请求等前沿到达后正确作答', () async {
    final handle = await server.publish(
      '$upstreamBase/drip.mp3',
      durationMs: 269000,
      label: '滴流歌',
    );
    expect(handle, isNotNull);

    final fullFuture = httpGetAll(handle!.url);
    // 下载进行中（前沿约 20KB）时请求靠后的段：应等前沿
    // 推进到该段后以 206 作答，字节正确。
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final segment = await httpGetAll(
      handle.url,
      range: 'bytes=100000-100099',
    );
    expect(segment.status, HttpStatus.partialContent);
    expect(segment.bytes, bigBytes.sublist(100000, 100100));

    final full = await fullFuture;
    expect(full.status, HttpStatus.ok);
    expect(full.aborted, isFalse);
    expect(full.bytes, bigBytes);
    // 上游只有下载器打过一次。
    expect(hits['/drip.mp3'], 1);
  });

  test('spool：上游彻底死亡 → 已落盘部分供出后截断、lost 成立', () async {
    final handle = await server.publish(
      '$upstreamBase/die.mp3',
      durationMs: 269000,
      label: '死链歌',
    );
    expect(handle, isNotNull);

    final result = await httpGetAll(
      handle!.url,
    ).timeout(const Duration(seconds: 30));
    // 截断关闭：Dart HttpServer 在 contentLength 未满足时
    // close 会丢弃已 add 的 body，客户端可能只看到 0 字节 +
    // 中止——关键契约是不挂起、不假成功（与旧透传路径同）。
    expect(result.bytes.length, lessThan(songBytes.length));
    expect(result.aborted, isTrue);
    expect(handle.lost, isTrue);
    expect(logs.any((l) => l.contains('stream lost')), isTrue);
    expect(logs.any((l) => l.contains('stream spool failed')), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('重取事件：宽限内不记、宽限后从头请求记 restartAtMs 与已供比例', () async {
    var fakeNow = 1000000;
    final timed = LanStreamServer(
      basePort: await freePort(),
      nowMs: () => fakeNow,
      lanIpLookup: () async => '127.0.0.1',
      onLog: logs.add,
    );
    expect(await timed.start(), isTrue);
    addTearDown(timed.stop);
    final handle = await timed.publish(
      '$upstreamBase/song.mp3',
      durationMs: 269000,
      label: '重取歌',
    );
    expect(handle, isNotNull);

    final first = await httpGetAll(handle!.url);
    expect(first.bytes, songBytes);
    expect(handle.restartAtMs, isNull);

    // 宽限内（+5s）从头请求：不记事件。
    fakeNow += 5000;
    await httpGetAll(handle.url);
    expect(handle.restartAtMs, isNull);

    // 宽限后（累计 +40s）从头请求：记事件；上一请求已供满，
    // 比例为 1.0（watch 据此走近尾声分流）。
    fakeNow += 35000;
    await httpGetAll(handle.url);
    expect(handle.restartAtMs, fakeNow);
    expect(handle.restartServedRatio, 1.0);
    expect(logs.any((l) => l.contains('stream restart noticed')), isTrue);
  });
}

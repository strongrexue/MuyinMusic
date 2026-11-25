import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/speaker_url_probe.dart';

/// 自构造 MP3 字节：ID3v2 小头 + 帧头 0xFF 0xFB 0x90 0x00（MPEG1 Layer III
/// 128kbps）+ 填充。
List<int> buildMp3Bytes({int id3Size = 20, required int total}) {
  final bytes = <int>[
    0x49, 0x44, 0x33, // 'ID3'
    3, 0, 0,
    (id3Size >> 21) & 0x7F,
    (id3Size >> 14) & 0x7F,
    (id3Size >> 7) & 0x7F,
    id3Size & 0x7F,
    ...List.filled(id3Size, 0),
    0xFF, 0xFB, 0x90, 0x00,
  ];
  while (bytes.length < total) {
    bytes.add(0);
  }
  return bytes;
}

SpeakerUrlProbe probeWith(Map<String, ProbeFetchResponse> byUrl) {
  return SpeakerUrlProbe(
    fetcher: (uri, headers) async {
      final resp = byUrl[uri.toString()];
      if (resp == null) throw Exception('no such url');
      return resp;
    },
  );
}

void main() {
  const url = 'https://example.com/song.mp3';

  test('206 + Content-Range 总量 → ok 且按 128kbps 估时长', () async {
    final probe = probeWith({
      url: ProbeFetchResponse(
        statusCode: 206,
        contentType: 'audio/mpeg',
        contentRange: 'bytes 0-32767/4194304',
        contentLength: 32768,
        bodyBytes: buildMp3Bytes(total: 32768),
      ),
    });
    final result = await probe.probe(url);
    expect(result.ok, isTrue);
    expect(result.totalBytes, 4194304);
    // (4194304 - 30) * 8 / 128 ≈ 262143ms ≈ 262s
    expect(result.estimatedDurationMs, inInclusiveRange(260000, 265000));
  });

  test('404 → http-404', () async {
    final probe = probeWith({
      url: const ProbeFetchResponse(
        statusCode: 404,
        contentLength: 0,
        bodyBytes: [],
      ),
    });
    final result = await probe.probe(url);
    expect(result.ok, isFalse);
    expect(result.rejectReason, 'http-404');
  });

  test('contentType text/html → not-audio', () async {
    final probe = probeWith({
      url: ProbeFetchResponse(
        statusCode: 200,
        contentType: 'text/html; charset=utf-8',
        contentLength: 100,
        bodyBytes: buildMp3Bytes(total: 100),
      ),
    });
    final result = await probe.probe(url);
    expect(result.ok, isFalse);
    expect(result.rejectReason, 'not-audio');
  });

  test('body 为 JSON 且 contentType 缺失 → not-mp3', () async {
    final body = utf8.encode('{"code": -1, "msg": "no auth"}');
    final probe = probeWith({
      url: ProbeFetchResponse(
        statusCode: 200,
        contentLength: body.length,
        bodyBytes: body,
      ),
    });
    final result = await probe.probe(url);
    expect(result.ok, isFalse);
    expect(result.rejectReason, 'not-mp3');
  });

  test('估算≈10s 且 expected=240000 → trial', () async {
    // (160030 - 30) * 8 / 128 = 10000ms
    final probe = probeWith({
      url: ProbeFetchResponse(
        statusCode: 206,
        contentType: 'audio/mpeg',
        contentRange: 'bytes 0-32767/160030',
        contentLength: 32768,
        bodyBytes: buildMp3Bytes(total: 32768),
      ),
    });
    final result = await probe.probe(url, expectedDurationMs: 240000);
    expect(result.ok, isFalse);
    expect(result.rejectReason, 'trial');
    expect(result.estimatedDurationMs, 10000);
  });

  test('expected 为 null 且估算≈30s → trial', () async {
    // (480030 - 30) * 8 / 128 = 30000ms
    final probe = probeWith({
      url: ProbeFetchResponse(
        statusCode: 206,
        contentType: 'audio/mpeg',
        contentRange: 'bytes 0-32767/480030',
        contentLength: 32768,
        bodyBytes: buildMp3Bytes(total: 32768),
      ),
    });
    final result = await probe.probe(url);
    expect(result.ok, isFalse);
    expect(result.rejectReason, 'trial');
    expect(result.estimatedDurationMs, 30000);
  });

  test('200 用 contentLength 估算 → ok', () async {
    final probe = probeWith({
      url: ProbeFetchResponse(
        statusCode: 200,
        contentType: 'audio/mpeg',
        contentLength: 4194304,
        bodyBytes: buildMp3Bytes(total: 32768),
      ),
    });
    final result = await probe.probe(url);
    expect(result.ok, isTrue);
    expect(result.totalBytes, 4194304);
    expect(result.estimatedDurationMs, inInclusiveRange(260000, 265000));
  });

  test('ID3 声明大小大于 body 长度 → 嗅探放行 ok，时长不估', () async {
    // ID3 声明 50000 字节，但本次只抓到 100 字节（封面太大，音频未到）。
    final body = <int>[
      0x49, 0x44, 0x33, 3, 0, 0,
      (50000 >> 21) & 0x7F, (50000 >> 14) & 0x7F, (50000 >> 7) & 0x7F,
      50000 & 0x7F,
      ...List.filled(90, 0),
    ];
    final probe = probeWith({
      url: ProbeFetchResponse(
        statusCode: 206,
        contentType: 'audio/mpeg',
        contentRange: 'bytes 0-99/4194304',
        contentLength: 100,
        bodyBytes: body,
      ),
    });
    final result = await probe.probe(url);
    expect(result.ok, isTrue);
    expect(result.totalBytes, 4194304);
    expect(result.estimatedDurationMs, isNull);
  });

  test('fetcher 抛错 → unreachable', () async {
    final probe = SpeakerUrlProbe(
      fetcher: (uri, headers) async => throw Exception('boom'),
    );
    final result = await probe.probe(url);
    expect(result.ok, isFalse);
    expect(result.rejectReason, 'unreachable');
  });
}

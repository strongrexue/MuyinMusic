import 'dart:io';

/// 推播请求统一 UA（与局域网流服务共用口径）。
const String kSpeakerUserAgent =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// 探测用的一次抓取结果（只取头部字节，不整文件下载）。
class ProbeFetchResponse {
  const ProbeFetchResponse({
    required this.statusCode,
    this.contentType,
    this.contentRange,
    required this.contentLength,
    required this.bodyBytes,
  });

  final int statusCode;
  final String? contentType;
  final String? contentRange;

  /// 响应头 Content-Length；未知为 -1。
  final int contentLength;
  final List<int> bodyBytes;
}

typedef ProbeFetcher =
    Future<ProbeFetchResponse> Function(Uri uri, Map<String, String> headers);

class ProbeResult {
  const ProbeResult({
    required this.ok,
    this.rejectReason,
    this.totalBytes,
    this.estimatedDurationMs,
  });

  final bool ok;

  /// 淘汰短码：unreachable / http-<code> / not-audio / not-mp3 / trial。
  final String? rejectReason;
  final int? totalBytes;
  final int? estimatedDurationMs;
}

/// 推前探测：移植 TrackFerry online check 口径——先用 Range 抓一小段，
/// 排除死链、假音频（错误页/JSON）、试听短音频，再决定是否推给音箱。
class SpeakerUrlProbe {
  SpeakerUrlProbe({ProbeFetcher? fetcher}) : _fetcher = fetcher ?? _defaultFetch;

  final ProbeFetcher _fetcher;

  /// TrackFerry 常量：短于 45s 视为试听；完整歌至少应有期望时长的 85%。
  static const int shortestSongMs = 45 * 1000;
  static const double minFullShare = 0.85;

  static const List<int> _bitrateMpeg1Layer3 = [
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
  ];
  static const List<int> _bitrateMpeg2Layer3 = [
    0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
  ];

  Future<ProbeResult> probe(String url, {int? expectedDurationMs}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return const ProbeResult(ok: false, rejectReason: 'unreachable');
    }
    final ProbeFetchResponse resp;
    try {
      resp = await _fetcher(uri, {
        HttpHeaders.rangeHeader: 'bytes=0-32767',
        HttpHeaders.userAgentHeader: kSpeakerUserAgent,
      });
    } catch (_) {
      return const ProbeResult(ok: false, rejectReason: 'unreachable');
    }
    if (resp.statusCode >= 400 ||
        (resp.statusCode != 200 && resp.statusCode != 206)) {
      return ProbeResult(
        ok: false,
        rejectReason: 'http-${resp.statusCode}',
      );
    }
    final contentType = resp.contentType?.toLowerCase();
    if (contentType != null &&
        contentType.isNotEmpty &&
        (contentType.startsWith('text/') ||
            contentType.contains('json') ||
            contentType.contains('html'))) {
      return const ProbeResult(ok: false, rejectReason: 'not-audio');
    }

    final totalBytes = _totalBytes(resp);
    final sniff = _sniffMp3(resp.bodyBytes);
    if (sniff == null) {
      return ProbeResult(
        ok: false,
        rejectReason: 'not-mp3',
        totalBytes: totalBytes,
      );
    }

    int? estimatedDurationMs;
    final kbps = sniff.kbps;
    if (totalBytes != null && kbps != null) {
      estimatedDurationMs = (totalBytes - sniff.audioOffset) * 8 ~/ kbps;
    }
    if (estimatedDurationMs != null) {
      final d = estimatedDurationMs;
      final looksShort =
          d < shortestSongMs &&
          (expectedDurationMs == null ||
              expectedDurationMs >= shortestSongMs);
      final underShare =
          expectedDurationMs != null && d < expectedDurationMs * minFullShare;
      if (looksShort || underShare) {
        return ProbeResult(
          ok: false,
          rejectReason: 'trial',
          totalBytes: totalBytes,
          estimatedDurationMs: d,
        );
      }
    }
    return ProbeResult(
      ok: true,
      totalBytes: totalBytes,
      estimatedDurationMs: estimatedDurationMs,
    );
  }

  int? _totalBytes(ProbeFetchResponse resp) {
    if (resp.statusCode == 206) {
      final range = resp.contentRange;
      if (range == null) return null;
      final match = RegExp(r'/\s*(\d+)\s*$').firstMatch(range);
      if (match == null) return null;
      return int.tryParse(match.group(1)!);
    }
    return resp.contentLength > 0 ? resp.contentLength : null;
  }

  /// MP3 嗅探：跳过 ID3v2 头，在 body 内找首个合法 Layer III 帧头。
  /// 返回 null 表示嗅探未过；ID3 声明大小已超出本次抓取长度时放行
  /// （kbps 为 null，不估时长）。
  _Sniff? _sniffMp3(List<int> body) {
    var off = 0;
    if (body.length >= 10 &&
        body[0] == 0x49 && // 'I'
        body[1] == 0x44 && // 'D'
        body[2] == 0x33) {
      // '3'
      final id3Size =
          ((body[6] & 0x7F) << 21) |
          ((body[7] & 0x7F) << 14) |
          ((body[8] & 0x7F) << 7) |
          (body[9] & 0x7F);
      off = 10 + id3Size;
      if (id3Size >= body.length) {
        return _Sniff(audioOffset: off);
      }
    }
    for (var i = off; i + 3 < body.length; i++) {
      if (body[i] != 0xFF || (body[i + 1] & 0xE0) != 0xE0) continue;
      final kbps = _layer3BitrateKbps(body[i + 1], body[i + 2]);
      if (kbps == null) continue;
      return _Sniff(audioOffset: off, kbps: kbps);
    }
    return null;
  }

  /// 校验帧头（Layer III、bitrate index 非 0/15）并返回 kbps；不合法返回 null。
  int? _layer3BitrateKbps(int b1, int b2) {
    final version = (b1 >> 3) & 0x03; // 3=MPEG1, 2=MPEG2, 0=MPEG2.5, 1=保留
    if (version == 1) return null;
    final layer = (b1 >> 1) & 0x03; // 1=Layer III
    if (layer != 1) return null;
    final bitrateIndex = (b2 >> 4) & 0x0F;
    if (bitrateIndex == 0 || bitrateIndex == 15) return null;
    final table = version == 3 ? _bitrateMpeg1Layer3 : _bitrateMpeg2Layer3;
    final kbps = table[bitrateIndex];
    return kbps > 0 ? kbps : null;
  }

  static Future<ProbeFetchResponse> _defaultFetch(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 8;
      headers.forEach((name, value) => request.headers.set(name, value));
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length >= 40000) break;
      }
      return ProbeFetchResponse(
        statusCode: response.statusCode,
        contentType: response.headers.contentType?.toString(),
        contentRange: response.headers.value(HttpHeaders.contentRangeHeader),
        contentLength: response.contentLength,
        bodyBytes: bytes.length > 40000 ? bytes.sublist(0, 40000) : bytes,
      );
    } finally {
      client.close(force: true);
    }
  }
}

class _Sniff {
  const _Sniff({required this.audioOffset, this.kbps});

  /// 音频数据起点（ID3 头之后）。
  final int audioOffset;
  final int? kbps;
}

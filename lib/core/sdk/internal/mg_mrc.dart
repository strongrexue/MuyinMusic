import 'dart:convert' show LineSplitter;
import 'dart:typed_data';

/// Decrypts and converts Migu `mrc` word-timed lyrics into the lx
/// `lxlyric` format (`[mm:ss.xxx]<relMs,durMs>word`) that
/// `KaraokeLyricsParser` consumes.
///
/// mrc payloads are hex strings encrypted with a TEA variant (the scheme
/// LX Music implements in `mg/utils/mrc.js`); decrypted lines look like:
///   [1247,1297]作(1247,250)词(1497,249)：李(1746,249)…
/// Each word is followed by its own absolute `(startMs,durationMs)` tag.
///
/// Kept free of Flutter imports so `dart test` can exercise it directly.

const _delta = 2654435769;
const _key = <int>[
  27303562373562475,
  18014862372307051,
  22799692160172081,
  34058940340699235,
  30962724186095721,
  27303523720101991,
  27303523720101998,
  31244139033526382,
  28992395054481524,
];

/// Full pipeline: hex mrc payload → lxlyric text, or null when the
/// payload is not a usable mrc (too short, not hex, no timed lines).
String? mgMrcToLxLyric(String cipherText) {
  final plain = mgMrcDecrypt(cipherText);
  if (plain == null) return null;
  return mgMrcPlainToLxLyric(plain);
}

/// Decrypts a hex mrc payload into its plain lyric text (UTF-16LE).
/// Returns null for inputs that cannot be mrc data.
String? mgMrcDecrypt(String data) {
  final hex = data.replaceAll(RegExp(r'\s+'), '');
  if (hex.length < 32) return null;
  try {
    final count = hex.length ~/ 16;
    final values = List<int>.generate(count, (i) {
      final chunk = hex.substring(i * 16, i * 16 + 16);
      // Parse via two 32-bit halves: a full 16-hex-digit literal can
      // exceed the signed 64-bit range, and assembling it from halves
      // lands on the same two's-complement value the JS BigInt
      // reference wraps to.
      final hi = int.parse(chunk.substring(0, 8), radix: 16);
      final lo = int.parse(chunk.substring(8), radix: 16);
      return (hi << 32) | lo;
    });
    _teaDecrypt(values);
    final bytes = Uint8List(count * 8);
    for (var i = 0; i < count; i++) {
      final value = values[i];
      for (var b = 0; b < 8; b++) {
        bytes[i * 8 + b] = (value >> (8 * b)) & 0xFF;
      }
    }
    var text = String.fromCharCodes(Uint16List.view(bytes.buffer));
    // The ciphertext is block-padded; the plaintext tail carries NULs.
    while (text.endsWith('\x00')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  } on FormatException {
    return null;
  }
}

/// The XXTEA-family round function. Dart ints are signed 64-bit with
/// wrapping arithmetic on native platforms, which matches the
/// reference implementation's wrap-to-signed-64 after every step, so
/// no explicit masking is needed (or wanted: `>>` must stay arithmetic).
int _mx(int z, int y, int sum, int p, int e) {
  final a = ((z >> 5) ^ (y << 2)) + ((y >> 3) ^ (z << 4));
  final b = (sum ^ y) + (_key[(p & 3) ^ e] ^ z);
  return a ^ b;
}

void _teaDecrypt(List<int> data) {
  final n = data.length;
  if (n < 1) return;
  var y = data[0];
  var sum = (6 + 52 ~/ n) * _delta;
  while (sum != 0) {
    final e = (sum >> 2) & 3;
    for (var p = n - 1; p > 0; p--) {
      final z = data[p - 1];
      y = data[p] = data[p] - _mx(z, y, sum, p, e);
    }
    final z = data[n - 1];
    y = data[0] = data[0] - _mx(z, y, sum, 0, e);
    sum -= _delta;
  }
}

/// Converts decrypted mrc text into lxlyric. Lines without word tags
/// (metadata, credits without timing) are dropped; returns null when
/// no line carries word timings.
String? mgMrcPlainToLxLyric(String mrc) {
  final lineExp = RegExp(r'^\s*\[(\d+),\d+\]');
  final wordExp = RegExp(r'\((\d+),(\d+)\)');
  final out = <String>[];
  for (final line in const LineSplitter().convert(mrc.replaceAll('\r', ''))) {
    if (line.length < 6) continue;
    final head = lineExp.firstMatch(line);
    if (head == null) continue;
    final startMs = int.parse(head.group(1)!);
    final body = line.substring(head.end);
    final tags = wordExp.allMatches(body).toList(growable: false);
    if (tags.isEmpty) continue;
    // mrc places each word before its own tag, so segment i (the text
    // ahead of tag i) is timed by tag i; text after the last tag is
    // dropped, matching the reference parser.
    final buf = StringBuffer(_lxTime(startMs));
    var offset = 0;
    for (final tag in tags) {
      final text = body.substring(offset, tag.start);
      offset = tag.end;
      // mrc word stamps are absolute ms; lxlyric wants line-relative.
      final rel = int.parse(tag.group(1)!) - startMs;
      buf.write('<${rel < 0 ? 0 : rel},${tag.group(2)}>$text');
    }
    out.add(buf.toString());
  }
  if (out.isEmpty) return null;
  return out.join('\n');
}

String _lxTime(int ms) {
  final minutes = (ms ~/ 60000).toString().padLeft(2, '0');
  final seconds = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
  final millis = (ms % 1000).toString().padLeft(3, '0');
  return '[$minutes:$seconds.$millis]';
}

import 'package:flutter_test/flutter_test.dart';

import 'package:panghu_music/features/cast/cast_relay_server.dart';

void main() {
  group('parseByteRange', () {
    const total = 1000;

    test('full range forms', () {
      expect(parseByteRange('bytes=0-', total)!.start, 0);
      expect(parseByteRange('bytes=0-', total)!.end, 999);
      final middle = parseByteRange('bytes=100-199', total)!;
      expect(middle.start, 100);
      expect(middle.end, 199);
      expect(middle.length, 100);
    });

    test('suffix range takes the tail', () {
      final range = parseByteRange('bytes=-200', total)!;
      expect(range.start, 800);
      expect(range.end, 999);
    });

    test('end is clamped to the body', () {
      expect(parseByteRange('bytes=900-5000', total)!.end, 999);
    });

    test('absent, malformed or unsatisfiable ranges serve the full body', () {
      expect(parseByteRange(null, total), isNull);
      expect(parseByteRange('', total), isNull);
      expect(parseByteRange('bytes=-', total), isNull);
      expect(parseByteRange('bytes=0-99,200-299', total), isNull);
      expect(parseByteRange('items=0-10', total), isNull);
      expect(parseByteRange('bytes=1000-', total), isNull);
      expect(parseByteRange('bytes=500-400', total), isNull);
      expect(parseByteRange('bytes=0-', 0), isNull);
    });
  });

  group('buildRelayUri', () {
    test('builds token URLs per kind', () {
      expect(
        buildRelayUri(
          host: '192.168.50.10',
          port: 4321,
          kind: 'r',
          token: 'abc123',
        ).toString(),
        'http://192.168.50.10:4321/r/abc123',
      );
      expect(
        buildRelayUri(
          host: '192.168.50.10',
          port: 4321,
          kind: 'f',
          token: 'def456',
        ).toString(),
        'http://192.168.50.10:4321/f/def456',
      );
    });
  });
}

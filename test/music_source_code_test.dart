import 'package:panghu_music/core/models/enums.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MusicSource codes', () {
    test('soda uses the imported-source code', () {
      expect(MusicSource.qs.code, 'qs');
      expect(MusicSource.qs.label, '汽水');
      expect(MusicSource.fromCode('qs'), MusicSource.qs);
    });

    test('the pre-rename code still resolves', () {
      // Saved playlists, download history and settings written by earlier
      // releases carry `qishui`; they must keep working after the rename.
      expect(MusicSource.fromCode('qishui'), MusicSource.qs);
      expect(MusicSource.tryFromCode('qishui'), MusicSource.qs);
    });

    test('unknown codes still fall back', () {
      expect(MusicSource.fromCode('nope'), MusicSource.all);
      expect(MusicSource.tryFromCode('nope'), isNull);
    });
  });
}

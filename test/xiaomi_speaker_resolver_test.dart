import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_resolver.dart';

void main() {
  group('isSpeakerPlayableUrl（只推 MP3）', () {
    test('扩展名判定', () {
      expect(isSpeakerPlayableUrl('http://a.com/x/song.mp3'), isTrue);
      expect(isSpeakerPlayableUrl('http://a.com/x/song.MP3'), isTrue);
      expect(isSpeakerPlayableUrl('http://a.com/x/song.mp3?token=abc'), isTrue);
      expect(isSpeakerPlayableUrl('http://a.com/x/song.flac'), isFalse);
      expect(isSpeakerPlayableUrl('http://a.com/x/song.m4a'), isFalse);
      expect(isSpeakerPlayableUrl('http://a.com/x/song'), isFalse);
    });

    test('mime 查询参数优先于扩展名', () {
      expect(isSpeakerPlayableUrl('http://a.com/play?mime=audio/mpeg'), isTrue);
      expect(isSpeakerPlayableUrl('http://a.com/play?mime=audio/mp3'), isTrue);
      // mime 说是 mp4，哪怕路径长得像 mp3 也拒。
      expect(
        isSpeakerPlayableUrl('http://a.com/x/song.mp3?mime=audio/mp4'),
        isFalse,
      );
      expect(
        isSpeakerPlayableUrl('http://a.com/x/song.flac?mime=audio/mpeg'),
        isTrue,
      );
    });
  });
}

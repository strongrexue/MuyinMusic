import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:audio_service/audio_service.dart';

MediaItem item({
  required String id,
  String title = '仙瑶',
  String? artist = '叶里',
  String? album = '仙瑶',
  Duration? duration = const Duration(minutes: 4, seconds: 21),
  String? artUri = 'https://music.126.net/cover.jpg?param=700y700',
}) =>
    MediaItem(
      id: id,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      artUri: artUri == null ? null : Uri.parse(artUri),
    );

void main() {
  group('isLyricOnlyResend', () {
    test('a lyric-line change (title/artist) is a lyric-only re-send', () {
      final previous = item(id: 'track-1', artist: '悬琴箫');
      final current = item(id: 'track-1', artist: '风雅温柔声色告');
      expect(isLyricOnlyResend(previous, current), isTrue);
    });

    test('an unchanged re-send counts as lyric-only', () {
      expect(isLyricOnlyResend(item(id: 'track-1'), item(id: 'track-1')),
          isTrue);
    });

    test('a track change is not a lyric-only re-send', () {
      expect(
        isLyricOnlyResend(item(id: 'track-1'), item(id: 'track-2')),
        isFalse,
      );
    });

    test('an artwork change is not a lyric-only re-send', () {
      final previous = item(id: 'track-1');
      final current = item(
        id: 'track-1',
        artUri: 'https://music.126.net/other.jpg?param=700y700',
      );
      expect(isLyricOnlyResend(previous, current), isFalse);
    });

    test('a duration change is not a lyric-only re-send', () {
      final previous = item(id: 'track-1');
      final current = item(
        id: 'track-1',
        duration: const Duration(minutes: 4, seconds: 22),
      );
      expect(isLyricOnlyResend(previous, current), isFalse);
    });

    test('an album change is not a lyric-only re-send', () {
      final previous = item(id: 'track-1');
      final current = item(id: 'track-1', album: '另一张专辑');
      expect(isLyricOnlyResend(previous, current), isFalse);
    });
  });

  group('ArtworkFileMemo', () {
    test('stores and looks up a resolved file by track id and art URL', () {
      final memo = ArtworkFileMemo();
      memo.store('track-1', 'https://example.com/a.jpg', '/cache/a.jpg');
      expect(memo.lookup('track-1', 'https://example.com/a.jpg'),
          '/cache/a.jpg');
    });

    test('a different art URL for the same track misses', () {
      final memo = ArtworkFileMemo();
      memo.store('track-1', 'https://example.com/a.jpg', '/cache/a.jpg');
      expect(memo.lookup('track-1', 'https://example.com/b.jpg'), isNull);
    });

    test('a different track misses', () {
      final memo = ArtworkFileMemo();
      memo.store('track-1', 'https://example.com/a.jpg', '/cache/a.jpg');
      expect(memo.lookup('track-2', 'https://example.com/a.jpg'), isNull);
    });

    test('prune keeps the current and next track, drops the rest', () {
      final memo = ArtworkFileMemo();
      memo.store('old', 'https://example.com/old.jpg', '/cache/old.jpg');
      memo.store('current', 'https://example.com/c.jpg', '/cache/c.jpg');
      memo.store('next', 'https://example.com/n.jpg', '/cache/n.jpg');
      memo.prune({'current', 'next'});
      expect(memo.lookup('old', 'https://example.com/old.jpg'), isNull);
      expect(memo.lookup('current', 'https://example.com/c.jpg'),
          '/cache/c.jpg');
      expect(memo.lookup('next', 'https://example.com/n.jpg'), '/cache/n.jpg');
    });
  });

  group('SharedArtworkLoader.isLoading', () {
    test('reports in-flight loads and forgets them once done', () async {
      final loader = SharedArtworkLoader();
      final gate = Completer<String?>();
      expect(loader.isLoading('https://example.com/a.jpg'), isFalse);

      final future =
          loader.load('https://example.com/a.jpg', () => gate.future);
      expect(loader.isLoading('https://example.com/a.jpg'), isTrue);
      expect(loader.isLoading('https://example.com/b.jpg'), isFalse);

      gate.complete('/cache/a.jpg');
      expect(await future, '/cache/a.jpg');
      // The forget runs on the completed future's microtask.
      await Future<void>.delayed(Duration.zero);
      expect(loader.isLoading('https://example.com/a.jpg'), isFalse);
    });
  });
}

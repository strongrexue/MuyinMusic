import 'package:flutter_test/flutter_test.dart';

import 'package:panghu_music/features/player/now_playing_push_gate.dart';

void main() {
  final t0 = DateTime(2026, 11, 26, 12, 0, 0);

  String key({
    String trackId = 't1',
    String artist = '歌词第一行',
    bool playing = true,
    bool liked = false,
    String coverIdentity = 'https://example.com/cover.jpg',
  }) {
    return NowPlayingPushGate.keyFor(
      trackId: trackId,
      artist: artist,
      playing: playing,
      liked: liked,
      coverIdentity: coverIdentity,
    );
  }

  group('keyFor', () {
    test('stable for identical inputs', () {
      expect(key(), key());
    });

    test('changes with lyric line, liked, playing and cover identity', () {
      final base = key();
      expect(key(artist: '歌词第二行'), isNot(base));
      expect(key(liked: true), isNot(base));
      expect(key(playing: false), isNot(base));
      expect(key(trackId: 't2'), isNot(base));
      // 封面文件就绪后身份由 URL 变本地路径，必须触发补推。
      expect(key(coverIdentity: '/tmp/media_art/abc.jpg'), isNot(base));
    });
  });

  group('coverIdentity', () {
    test('prefers local path, falls back to url', () {
      expect(
        NowPlayingPushGate.coverIdentity(
          artPath: '/tmp/media_art/abc.jpg',
          coverUrl: 'https://example.com/cover.jpg',
        ),
        '/tmp/media_art/abc.jpg',
      );
      expect(
        NowPlayingPushGate.coverIdentity(
          artPath: '',
          coverUrl: 'https://example.com/cover.jpg',
        ),
        'https://example.com/cover.jpg',
      );
      expect(
        NowPlayingPushGate.coverIdentity(artPath: '', coverUrl: ''),
        '',
      );
    });
  });

  group('decide/commit', () {
    test('key is recorded only on commit, not on decide', () {
      final gate = NowPlayingPushGate();
      final k = key();
      expect(
        gate.decide(key: k, trackId: 't1', positionMs: 10000, playing: true, now: t0),
        isTrue,
      );
      // 没 commit（invoke 失败）时同样的内容必须照样放行重试。
      expect(
        gate.decide(key: k, trackId: 't1', positionMs: 10000, playing: true, now: t0),
        isTrue,
      );
      gate.commit(key: k, trackId: 't1', positionMs: 10000, playing: true, now: t0);
      expect(
        gate.decide(
          key: k,
          trackId: 't1',
          positionMs: 11000,
          playing: true,
          now: t0.add(const Duration(seconds: 1)),
        ),
        isFalse,
      );
    });

    test('force always pushes', () {
      final gate = NowPlayingPushGate();
      final k = key();
      gate.commit(key: k, trackId: 't1', positionMs: 10000, playing: true, now: t0);
      expect(
        gate.decide(
          key: k,
          trackId: 't1',
          positionMs: 10000,
          playing: true,
          force: true,
          now: t0,
        ),
        isTrue,
      );
    });

    test('reset re-allows the same key', () {
      final gate = NowPlayingPushGate();
      final k = key();
      gate.commit(key: k, trackId: 't1', positionMs: 10000, playing: true, now: t0);
      gate.reset();
      expect(
        gate.decide(key: k, trackId: 't1', positionMs: 10000, playing: true, now: t0),
        isTrue,
      );
    });
  });

  group('seek jump detection', () {
    test('position consistent with wall clock does not push', () {
      final gate = NowPlayingPushGate();
      final k = key();
      gate.commit(key: k, trackId: 't1', positionMs: 10000, playing: true, now: t0);
      expect(
        gate.decide(
          key: k,
          trackId: 't1',
          positionMs: 13000,
          playing: true,
          now: t0.add(const Duration(seconds: 3)),
        ),
        isFalse,
      );
      // 1.5 秒以内的漂移在阈值内，不触发。
      expect(
        gate.decide(
          key: k,
          trackId: 't1',
          positionMs: 14500,
          playing: true,
          now: t0.add(const Duration(seconds: 3)),
        ),
        isFalse,
      );
    });

    test('forward and backward jumps push even with unchanged key', () {
      final gate = NowPlayingPushGate();
      final k = key();
      gate.commit(key: k, trackId: 't1', positionMs: 60000, playing: true, now: t0);
      expect(
        gate.decide(
          key: k,
          trackId: 't1',
          positionMs: 93000,
          playing: true,
          now: t0.add(const Duration(seconds: 3)),
        ),
        isTrue,
      );
      expect(
        gate.decide(
          key: k,
          trackId: 't1',
          positionMs: 30000,
          playing: true,
          now: t0.add(const Duration(seconds: 3)),
        ),
        isTrue,
      );
    });

    test('paused position does not extrapolate; seek while paused pushes', () {
      final gate = NowPlayingPushGate();
      final k = key(playing: false);
      gate.commit(key: k, trackId: 't1', positionMs: 10000, playing: false, now: t0);
      expect(
        gate.decide(
          key: k,
          trackId: 't1',
          positionMs: 10000,
          playing: false,
          now: t0.add(const Duration(seconds: 30)),
        ),
        isFalse,
      );
      expect(
        gate.decide(
          key: k,
          trackId: 't1',
          positionMs: 40000,
          playing: false,
          now: t0.add(const Duration(seconds: 30)),
        ),
        isTrue,
      );
    });
  });

  group('heartbeatWanted', () {
    test('only when enabled, has track and playing', () {
      expect(
        NowPlayingPushGate.heartbeatWanted(
          enabled: true,
          hasTrack: true,
          playing: true,
        ),
        isTrue,
      );
      expect(
        NowPlayingPushGate.heartbeatWanted(
          enabled: false,
          hasTrack: true,
          playing: true,
        ),
        isFalse,
      );
      expect(
        NowPlayingPushGate.heartbeatWanted(
          enabled: true,
          hasTrack: false,
          playing: true,
        ),
        isFalse,
      );
      expect(
        NowPlayingPushGate.heartbeatWanted(
          enabled: true,
          hasTrack: true,
          playing: false,
        ),
        isFalse,
      );
    });
  });
}

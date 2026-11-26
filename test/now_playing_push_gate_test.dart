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

  group('NowPlayingTickGate', () {
    bool tick(
      NowPlayingTickGate gate, {
      String trackId = 't1',
      String artist = '歌词第一行',
      bool playing = true,
      bool liked = false,
      required int positionMs,
      required DateTime now,
    }) {
      return gate.shouldEnqueue(
        trackId: trackId,
        artist: artist,
        playing: playing,
        liked: liked,
        positionMs: positionMs,
        now: now,
      );
    }

    test('first tick enqueues; pure position ticks do not', () {
      final gate = NowPlayingTickGate();
      expect(
        tick(gate, positionMs: 10000, now: t0),
        isTrue,
      );
      // 40ms 后位置正常推进、歌词行没变：不进队。
      expect(
        tick(gate, positionMs: 10040, now: t0.add(const Duration(milliseconds: 40))),
        isFalse,
      );
      expect(
        tick(gate, positionMs: 10080, now: t0.add(const Duration(milliseconds: 80))),
        isFalse,
      );
      // 3 秒后位置按墙钟推进、行没变：仍不进队（由心跳兜底）。
      expect(
        tick(gate, positionMs: 13080, now: t0.add(const Duration(seconds: 3))),
        isFalse,
      );
    });

    test('lyric line, playing, liked and track changes enqueue', () {
      final gate = NowPlayingTickGate();
      expect(tick(gate, positionMs: 10000, now: t0), isTrue);
      expect(
        tick(
          gate,
          artist: '歌词第二行',
          positionMs: 12000,
          now: t0.add(const Duration(seconds: 2)),
        ),
        isTrue,
      );
      expect(
        tick(
          gate,
          artist: '歌词第二行',
          playing: false,
          positionMs: 12000,
          now: t0.add(const Duration(seconds: 2, milliseconds: 40)),
        ),
        isTrue,
      );
      expect(
        tick(
          gate,
          artist: '歌词第二行',
          playing: false,
          liked: true,
          positionMs: 12000,
          now: t0.add(const Duration(seconds: 2, milliseconds: 80)),
        ),
        isTrue,
      );
      expect(
        tick(
          gate,
          trackId: 't2',
          artist: '新歌第一行',
          playing: true,
          liked: false,
          positionMs: 0,
          now: t0.add(const Duration(seconds: 3)),
        ),
        isTrue,
      );
    });

    test('seek jumps enqueue; in-threshold drift does not', () {
      final gate = NowPlayingTickGate();
      expect(tick(gate, positionMs: 60000, now: t0), isTrue);
      expect(
        tick(gate, positionMs: 63000, now: t0.add(const Duration(seconds: 3))),
        isFalse,
      );
      // 前跳 30 秒：进队。
      expect(
        tick(gate, positionMs: 93000, now: t0.add(const Duration(seconds: 3))),
        isTrue,
      );
      // 锚点已刷新到 93000；后跳回 30000：进队。
      expect(
        tick(gate, positionMs: 30000, now: t0.add(const Duration(seconds: 3))),
        isTrue,
      );
      // 暂停时位置不动不进队；暂停中 seek 进队。
      final paused = NowPlayingTickGate();
      expect(
        tick(paused, playing: false, positionMs: 10000, now: t0),
        isTrue,
      );
      expect(
        tick(
          paused,
          playing: false,
          positionMs: 10000,
          now: t0.add(const Duration(seconds: 30)),
        ),
        isFalse,
      );
      expect(
        tick(
          paused,
          playing: false,
          positionMs: 40000,
          now: t0.add(const Duration(seconds: 30)),
        ),
        isTrue,
      );
    });

    test('reset re-allows enqueue on the next tick', () {
      final gate = NowPlayingTickGate();
      expect(tick(gate, positionMs: 10000, now: t0), isTrue);
      expect(
        tick(gate, positionMs: 10040, now: t0.add(const Duration(milliseconds: 40))),
        isFalse,
      );
      gate.reset();
      expect(
        tick(gate, positionMs: 10040, now: t0.add(const Duration(milliseconds: 40))),
        isTrue,
      );
    });
  });

  group('NowPlayingArtMemo', () {
    test('miss before store; hit only for same track and url', () {
      final memo = NowPlayingArtMemo();
      expect(memo.lookup('t1', 'https://example.com/cover.jpg'), isNull);
      memo.store('t1', 'https://example.com/cover.jpg', '/tmp/a.jpg');
      expect(
        memo.lookup('t1', 'https://example.com/cover.jpg'),
        '/tmp/a.jpg',
      );
      expect(memo.lookup('t2', 'https://example.com/cover.jpg'), isNull);
      expect(memo.lookup('t1', 'https://example.com/other.jpg'), isNull);
    });

    test('store replaces the previous track entry', () {
      final memo = NowPlayingArtMemo();
      memo.store('t1', 'https://example.com/a.jpg', '/tmp/a.jpg');
      memo.store('t2', 'https://example.com/b.jpg', '/tmp/b.jpg');
      expect(memo.lookup('t1', 'https://example.com/a.jpg'), isNull);
      expect(memo.lookup('t2', 'https://example.com/b.jpg'), '/tmp/b.jpg');
    });
  });
}

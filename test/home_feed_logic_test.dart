import 'package:panghu_music/core/models/enums.dart';
import 'package:panghu_music/core/models/music_info.dart';
import 'package:panghu_music/features/downloads/download_history_entry.dart';
import 'package:panghu_music/features/home/home_feed_logic.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadHistoryEntry _entry(String id, String singer) {
  return DownloadHistoryEntry(
    id: 'test:$id',
    musicId: id,
    name: '歌 $id',
    singer: singer,
    albumName: '测试专辑',
    sourceCode: MusicSource.wy.code,
    qualityCode: Quality.k320.code,
    status: DownloadHistoryStatus.completed,
    createdAt: DateTime.utc(2026, 7, 20),
  );
}

MusicInfo _music(String id, String name, String singer) {
  return MusicInfo.fromJson({
    'id': id,
    'name': name,
    'singer': singer,
    'source': MusicSource.wy.code,
    'interval': '03:30',
    'meta': {
      'songId': id,
      'albumName': '测试专辑',
      'qualitys': [
        {'type': Quality.k320.code, 'size': '1024'},
      ],
    },
  });
}

DailyCandidate _candidate(String board, int rank, String singer) {
  return DailyCandidate(
    entry: _entry('$board-$rank', singer),
    boardKey: board,
    rank: rank,
    boardSize: 10,
  );
}

void main() {
  group('splitArtistNames', () {
    test('splits on every separator and drops blanks', () {
      expect(splitArtistNames('甲、乙/丙 & 丁'), ['甲', '乙', '丙', '丁']);
      expect(splitArtistNames(' 甲 ， '), ['甲']);
      expect(splitArtistNames(''), isEmpty);
    });
  });

  group('buildArtistWeights', () {
    test('main artist counts full, collaborators count half', () {
      final weights = buildArtistWeights(
        recent: [_entry('r1', '甲、乙')],
        liked: [_entry('l1', '甲')],
      );
      expect(weights['甲'], 2.0);
      expect(weights['乙'], 0.5);
    });

    test('uses the full recent and liked lists', () {
      final weights = buildArtistWeights(
        recent: [for (var i = 0; i < 20; i++) _entry('r$i', '甲')],
        liked: [for (var i = 0; i < 15; i++) _entry('l$i', '乙')],
      );
      expect(weights['甲'], 20.0);
      expect(weights['乙'], 15.0);
    });
  });

  group('rankArtists / artistFingerprint', () {
    test('sorts by weight desc, ties keep first-seen order', () {
      final ranked = rankArtists({'乙': 1.0, '甲': 3.0, '丙': 1.0});
      expect(ranked.map((entry) => entry.key), ['甲', '乙', '丙']);
    });

    test('fingerprint is stable for the same profile and changes with it', () {
      final a = artistFingerprint({'甲': 3.0, '乙': 1.0});
      final b = artistFingerprint({'甲': 3.0, '乙': 1.0});
      final c = artistFingerprint({'甲': 4.0, '乙': 1.0});
      expect(a, b);
      expect(a, isNot(c));
    });
  });

  group('isTrackByArtist / hasNonOriginalMarker', () {
    test('matches any credited artist, case-insensitively', () {
      expect(isTrackByArtist('甲、乙', '乙'), isTrue);
      expect(isTrackByArtist('Adele', 'adele'), isTrue);
      expect(isTrackByArtist('甲', '乙'), isFalse);
      expect(isTrackByArtist('甲乙', '乙'), isFalse);
    });

    test('flags instrumentals, covers and ringtones', () {
      expect(hasNonOriginalMarker('某某（伴奏）'), isTrue);
      expect(hasNonOriginalMarker('某某 翻唱版'), isTrue);
      expect(hasNonOriginalMarker('某某手机铃声'), isTrue);
      expect(hasNonOriginalMarker('某某'), isFalse);
    });
  });

  group('selectDailyPicks', () {
    test('no board takes more than a third of the shelf', () {
      final pool = [
        for (final board in ['a', 'b', 'c'])
          for (var rank = 0; rank < 10; rank++) _candidate(board, rank, '歌手'),
      ];
      final picks = selectDailyPicks(pool: pool, weights: const {}, count: 12);
      expect(picks, hasLength(12));
      final perBoard = <String, int>{};
      for (final pick in picks) {
        final board = pick.id.split('-').first.replaceFirst('test:', '');
        perBoard[board] = (perBoard[board] ?? 0) + 1;
      }
      expect(perBoard.values.every((count) => count <= 4), isTrue);
      expect(picks.first.musicId, 'a-0');
    });

    test('taste profile lifts favourite artists above chart rank', () {
      final pool = [
        _candidate('a', 0, '路人'),
        _candidate('a', 5, '本命'),
        _candidate('a', 6, '路人'),
      ];
      final picks = selectDailyPicks(
        pool: pool,
        weights: const {'本命': 10.0},
        count: 3,
      );
      expect(picks.first.singer, '本命');
    });

    test('without a profile the board order is preserved', () {
      final pool = [
        _candidate('a', 0, '甲'),
        _candidate('a', 1, '乙'),
        _candidate('a', 2, '丙'),
      ];
      final picks = selectDailyPicks(pool: pool, weights: const {}, count: 3);
      expect(picks.map((pick) => pick.singer), ['甲', '乙', '丙']);
    });
  });

  group('allocateArtistQuotas', () {
    test('proportional, at least one each, capped, sums to total', () {
      final quotas = allocateArtistQuotas(
        ranked: const [
          MapEntry('甲', 10.0),
          MapEntry('乙', 5.0),
          MapEntry('丙', 1.0),
        ],
        total: 12,
      );
      expect(quotas.values.fold(0, (a, b) => a + b), 12);
      expect(quotas['甲'], 6);
      expect(quotas['乙'], greaterThanOrEqualTo(3));
      expect(quotas['丙'], greaterThanOrEqualTo(1));
      expect(quotas.values.every((quota) => quota <= 6), isTrue);
    });

    test('a single artist cannot exceed the cap', () {
      final quotas = allocateArtistQuotas(
        ranked: const [MapEntry('甲', 10.0)],
        total: 12,
      );
      expect(quotas['甲'], 6);
    });
  });

  group('filterArtistTracks', () {
    test('keeps only the artist\'s own original tracks', () {
      final tracks = [
        _music('1', '本命的歌', '本命'),
        _music('2', '合作曲', '别人、本命'),
        _music('3', '蹭名歌', '别人'),
        _music('4', '本命的歌（伴奏）', '本命'),
        _music('5', '翻唱本命', '本命'),
      ];
      final kept = filterArtistTracks(tracks, '本命');
      expect(kept.map((track) => track.id), ['1', '2']);
    });
  });
}

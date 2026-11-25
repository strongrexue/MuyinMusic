import 'package:flutter_test/flutter_test.dart';

import 'package:muyin_music/core/models/enums.dart';
import 'package:muyin_music/core/ui/app_breakpoints.dart';
import 'package:muyin_music/features/discovery/leaderboards_page.dart';
import 'package:muyin_music/features/discovery/widgets/leaderboard_spotlight.dart';
import 'package:muyin_music/features/discovery/widgets/masonry_playlist_grid.dart';
import 'package:muyin_music/features/home/home_feed.dart';
import 'package:muyin_music/features/songs/songs_page.dart';

void main() {
  group('AppBreakpoints', () {
    test('medium starts at 600', () {
      expect(AppBreakpoints.isMedium(599), isFalse);
      expect(AppBreakpoints.isMedium(600), isTrue);
    });

    test('expanded starts at 840', () {
      expect(AppBreakpoints.isExpanded(839), isFalse);
      expect(AppBreakpoints.isExpanded(840), isTrue);
    });

    test('ultra starts at 1200', () {
      expect(AppBreakpoints.isUltra(1199), isFalse);
      expect(AppBreakpoints.isUltra(1200), isTrue);
    });
  });

  group('home shelf count', () {
    test('12 below expanded, 36 at expanded', () {
      expect(homeShelfCountForWidth(390), 12);
      expect(homeShelfCountForWidth(839), 12);
      expect(homeShelfCountForWidth(840), 36);
      expect(homeShelfCountForWidth(1920), 36);
    });

    test('cache keys are bucketed by count', () {
      expect(
        homeDailyCacheKey(MusicSource.kw, 12),
        'home_daily_picks_kw_v2_c12',
      );
      expect(
        homeDailyCacheKey(MusicSource.kw, 36),
        'home_daily_picks_kw_v2_c36',
      );
      expect(
        homeGuessCacheKey(MusicSource.kw, 'fp', 12),
        'home_guess_kw_fp_c12',
      );
      expect(
        homeGuessCacheKey(MusicSource.kw, 'fp', 36),
        'home_guess_kw_fp_c36',
      );
      expect(homeGuessLastKey(MusicSource.kw, 12), 'home_guess_last_kw_c12');
      expect(homeGuessLastKey(MusicSource.kw, 36), 'home_guess_last_kw_c36');
    });
  });

  group('masonry column count', () {
    test('two columns below 700, three below expanded', () {
      expect(masonryColumnCount(390), 2);
      expect(masonryColumnCount(699), 2);
      expect(masonryColumnCount(700), 3);
      expect(masonryColumnCount(839), 3);
    });

    test('expanded uses the 240 target width formula clamped to 2..10', () {
      expect(masonryColumnCount(840), 3);
      expect(masonryColumnCount(960), 4);
      expect(masonryColumnCount(1200), 5);
      expect(masonryColumnCount(2400), 10);
      expect(masonryColumnCount(4000), 10);
    });
  });

  group('leaderboard grid column count', () {
    test('legacy tiers below expanded', () {
      expect(leaderboardGridColumnCount(390), 2);
      expect(leaderboardGridColumnCount(499), 2);
      expect(leaderboardGridColumnCount(500), 3);
      expect(leaderboardGridColumnCount(719), 3);
      expect(leaderboardGridColumnCount(720), 4);
      expect(leaderboardGridColumnCount(839), 4);
    });

    test('expanded uses the 260 target width formula clamped to 2..10', () {
      expect(leaderboardGridColumnCount(840), 3);
      expect(leaderboardGridColumnCount(1040), 4);
      expect(leaderboardGridColumnCount(1560), 6);
      expect(leaderboardGridColumnCount(2600), 10);
      expect(leaderboardGridColumnCount(4000), 10);
    });
  });

  group('leaderboard spotlight', () {
    test('expanded at 840 with six cards, compact keeps four', () {
      expect(leaderboardSpotlightExpanded(839), isFalse);
      expect(leaderboardSpotlightExpanded(840), isTrue);
      expect(leaderboardSpotlightMaxCards(390), 4);
      expect(leaderboardSpotlightMaxCards(839), 4);
      expect(leaderboardSpotlightMaxCards(840), 6);
    });
  });

  group('songs playlist grid column count', () {
    test('240 target width formula clamped to 2..10', () {
      expect(songsPlaylistGridColumnCount(240), 2);
      expect(songsPlaylistGridColumnCount(480), 2);
      expect(songsPlaylistGridColumnCount(720), 3);
      expect(songsPlaylistGridColumnCount(840), 3);
      expect(songsPlaylistGridColumnCount(1200), 5);
      expect(songsPlaylistGridColumnCount(4000), 10);
    });
  });
}

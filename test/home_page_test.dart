import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:muyin_music/core/api/music_api.dart';
import 'package:muyin_music/core/models/enums.dart';
import 'package:muyin_music/core/models/leaderboard_info.dart';
import 'package:muyin_music/core/models/music_info.dart';
import 'package:muyin_music/core/models/playlist_info.dart';
import 'package:muyin_music/core/models/search_response.dart';
import 'package:muyin_music/core/storage/settings_store.dart';
import 'package:muyin_music/features/downloads/download_history_entry.dart';
import 'package:muyin_music/features/home/home_page.dart';
import 'package:muyin_music/features/home/recent_plays_store.dart';
import 'package:muyin_music/features/home/widgets/home_search_capsule.dart';
import 'package:muyin_music/features/player/player_audio_handler.dart';
import 'package:muyin_music/features/songs/songs_toolbar_state.dart';
import 'package:muyin_music/router.dart';

import 'helpers/prism_test_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('home shows the search capsule, shortcuts and the two shelves', (
    tester,
  ) async {
    // 首页内容比一屏高（搜索胶囊 + 快捷入口 + 两个货架 + 最近播放），
    // 用加高的视口让整页一次布局完，断言不依赖滚动位置。
    await _usePhoneViewport(tester, size: const Size(390, 1400));
    SharedPreferences.setMockInitialValues({
      recentPlaysStorageKey: jsonEncode([_entry('seed', '最近听的歌').toJson()]),
    });
    final prefs = await SharedPreferences.getInstance();
    final audioHandler = PlayerAudioHandler();
    final router = createAppRouter(initialLocation: '/home');
    addTearDown(() {
      router.dispose();
      audioHandler.disposeHandler();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playerAudioHandlerProvider.overrideWithValue(audioHandler),
          musicApiProvider.overrideWithValue(_HomeMusicApi()),
        ],
        child: MaterialApp.router(
          builder: buildPrismTestEnvironment,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          ),
          routerConfig: router,
        ),
      ),
    );
    await _pumpUi(tester);

    expect(find.byType(HomePage), findsOneWidget);
    // 搜索入口在首页，继续播放交给下面的迷你播放条。
    expect(find.byKey(const ValueKey('home-search-capsule')), findsOneWidget);
    expect(find.text(HomeSearchCapsule.hintText), findsOneWidget);
    expect(find.text('每日推荐'), findsOneWidget);
    expect(find.text('猜你喜欢'), findsOneWidget);
    expect(find.text('最近播放'), findsOneWidget);
    expect(find.text('最近听的歌'), findsOneWidget);
    for (final key in [
      'home-quick-liked',
      'home-quick-local',
      'home-quick-playlists',
      'home-quick-downloads',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    // Daily picks come from the fake leaderboard; the rail renders its songs.
    expect(find.text('每日歌 1'), findsOneWidget);
    expect(find.text('猜你喜欢歌 1'), findsOneWidget);

    final fresh = _entry('fresh', '猜你喜欢歌 1');
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomePage)),
    );
    container.read(recentPlaysProvider.notifier).record(fresh);
    await _pumpUi(tester);
    // The same song now shows in both its shelf and 最近播放.
    expect(find.text('猜你喜欢歌 1'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('home-quick-playlists')));
    await _pumpUi(tester);
    expect(
      container.read(songsLibraryTabProvider),
      SongsLibraryTab.playlists,
    );
    expect(router.routeInformationProvider.value.uri.path, '/songs');

    // 胶囊把用户送进首页自己的搜索页并直接打开搜索输入。
    router.go('/home');
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('home-search-capsule')));
    await _pumpUi(tester);
    expect(router.routeInformationProvider.value.uri.path, '/home/search');
    expect(find.byKey(const ValueKey('search-input-slot')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recent plays store keeps one row per song, newest first', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    final notifier = container.read(recentPlaysProvider.notifier);
    notifier.record(_entry('a', '第一首'));
    notifier.record(_entry('b', '第二首'));
    notifier.record(_entry('a', '第一首'));

    final entries = container.read(recentPlaysProvider);
    expect(entries.map((entry) => entry.name), ['第一首', '第二首']);
    expect(prefs.getString(recentPlaysStorageKey), isNotNull);
  });
}

class _HomeMusicApi extends MusicApi {
  @override
  Future<List<LeaderboardSummary>> getLeaderboards(MusicSource source) async {
    return [
      LeaderboardSummary(
        id: '${source.code}__1',
        boardId: '1',
        name: '热歌榜',
        source: source,
      ),
    ];
  }

  @override
  Future<PlaylistInfo> getLeaderboard({
    required MusicSource source,
    required String boardId,
    int? maxTracks,
  }) async {
    return PlaylistInfo(
      id: boardId,
      name: '热歌榜',
      source: source,
      tracks: [
        _music('daily-1', '每日歌 1', '歌手甲'),
        _music('daily-2', '每日歌 2', '歌手乙'),
      ],
    );
  }

  @override
  Future<SearchResponse> searchMusic({
    required String keyword,
    required MusicSource source,
    int page = 1,
    int limit = 30,
  }) async {
    return SearchResponse(
      list: [
        _music('guess-1', '猜你喜欢歌 1', '歌手丙'),
        _music('guess-2', '猜你喜欢歌 2', '歌手丁'),
      ],
      page: page,
      limit: limit,
      allPage: 1,
      total: 2,
      source: source,
    );
  }
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

DownloadHistoryEntry _entry(String id, String name) {
  return DownloadHistoryEntry(
    id: 'home:$id',
    musicId: id,
    name: name,
    singer: '歌手丙',
    albumName: '测试专辑',
    sourceCode: MusicSource.wy.code,
    qualityCode: Quality.k320.code,
    status: DownloadHistoryStatus.completed,
    createdAt: DateTime.utc(2026, 7, 20),
  );
}

Future<void> _pumpUi(WidgetTester tester) async {
  for (var index = 0; index < 12; index++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _usePhoneViewport(
  WidgetTester tester, {
  Size size = const Size(390, 844),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
}

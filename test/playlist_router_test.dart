import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:muyin_music/core/storage/settings_store.dart';
import 'package:muyin_music/core/api/music_api.dart';
import 'package:muyin_music/core/models/enums.dart';
import 'package:muyin_music/core/models/music_info.dart';
import 'package:muyin_music/core/models/playlist_info.dart';
import 'package:muyin_music/features/downloads/download_history_entry.dart';
import 'package:muyin_music/features/player/player_audio_handler.dart';
import 'package:muyin_music/features/player/lyric_parser.dart';
import 'package:muyin_music/features/player/player_controller.dart';
import 'package:muyin_music/features/player/player_page.dart';
import 'package:muyin_music/features/player/flowing_light_background.dart';
import 'package:muyin_music/features/playlists/playlist_detail_page.dart';
import 'package:muyin_music/features/playlists/playlist_models.dart';
import 'package:muyin_music/features/playlists/playlist_store.dart';
import 'package:muyin_music/features/songs/liked_songs_store.dart';
import 'package:muyin_music/router.dart';
import 'package:muyin_music/features/shell/shell_navigation.dart';

import 'helpers/prism_test_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'songs playlist entry preserves management source through player return',
    (tester) async {
      await _usePhoneViewport(tester);
      final prefs = await _prefsWith([
        _playlist(id: 'night', name: 'Night playlist'),
      ]);
      final audioHandler = PlayerAudioHandler();
      final router = createAppRouter(initialLocation: '/songs');
      addTearDown(() {
        router.dispose();
        unawaited(audioHandler.disposeHandler());
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            playerAudioHandlerProvider.overrideWithValue(audioHandler),
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

      expect(router.routeInformationProvider.value.uri.path, '/songs');
      router.go('/playlists');
      await _pumpUi(tester);
      expect(find.text('歌单管理'), findsOneWidget);
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      expect(router.routeInformationProvider.value.uri.path, '/playlists');
      expect(find.text('Night playlist'), findsOneWidget);
      expect(find.byTooltip('返回上一页'), findsOneWidget);

      await tester.tap(find.text('Night playlist'));
      await _pumpUi(tester);
      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/playlists/night?from=manage',
      );

      final detail = tester.widget<PlaylistDetailPage>(
        find.byType(PlaylistDetailPage),
      );
      expect(detail.returnLocation, '/playlists/night?from=manage');
      expect(find.byTooltip('返回上一页'), findsOneWidget);

      openPlayer(
        tester.element(find.byType(PlaylistDetailPage)),
        returnLocation: detail.returnLocation!,
      );
      await _pumpUi(tester);
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(router.routeInformationProvider.value.uri.path, '/player');
      expect(find.byTooltip('返回'), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/playlists/night?from=manage',
      );
      final exitSlide = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect((1 - exitSlide.progress.value), greaterThan(0));
      expect((1 - exitSlide.progress.value), lessThan(1));

      await _pumpUi(tester);
      await tester.pump();
      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/playlists/night?from=manage',
      );
      await _pumpUi(tester);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await _pumpUi(tester);
      expect(router.routeInformationProvider.value.uri.path, '/playlists');
      expect(find.text('Night playlist'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'songs library tabs split local songs, playlists and liked songs',
    (tester) async {
      await _usePhoneViewport(tester);
      final prefs = await _prefsWith([
        _playlist(
          id: 'night',
          name: 'Night playlist',
          tracks: const [
            PlaylistTrack(
              musicId: 'track-1',
              name: 'Nocturne',
              singer: 'Jay Chou',
              albumName: 'November album',
              sourceCode: 'wy',
              qualityCode: 'flac',
            ),
          ],
        ),
      ]);
      final audioHandler = PlayerAudioHandler();
      final router = createAppRouter(initialLocation: '/songs');
      addTearDown(() {
        router.dispose();
        unawaited(audioHandler.disposeHandler());
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            playerAudioHandlerProvider.overrideWithValue(audioHandler),
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

      // 顶部分段控件把喜欢、本地音乐、歌单拆成三个 tab，默认落在喜欢。
      final tabs = find.byKey(const ValueKey('songs-library-tabs'));
      expect(tabs, findsOneWidget);
      expect(find.byTooltip('搜索喜欢的歌曲'), findsOneWidget);

      // 歌单 tab 只列歌单，点开走独立详情路由。
      await tester.tap(find.descendant(of: tabs, matching: find.text('歌单')));
      await _pumpUi(tester);
      expect(
        find.byKey(const ValueKey('songs-playlist-night')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('songs-playlist-night')));
      await _pumpUi(tester);
      expect(router.routeInformationProvider.value.uri.path, '/playlists/night');
      expect(find.text('Nocturne'), findsOneWidget);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await _pumpUi(tester);
      expect(router.routeInformationProvider.value.uri.path, '/songs');

      // 喜欢 tab 空态带爱心图标，并有自己的搜索文案。
      await tester.tap(find.descendant(of: tabs, matching: find.text('喜欢')));
      await _pumpUi(tester);
      expect(find.text('还没有喜欢的歌曲'), findsOneWidget);
      expect(find.byTooltip('搜索喜欢的歌曲'), findsOneWidget);

      // 回到本地音乐后仍保持原有入口。
      await tester.tap(find.descendant(of: tabs, matching: find.text('本地音乐')));
      await _pumpUi(tester);
      expect(find.byTooltip('搜索本地音乐'), findsOneWidget);

      // 歌单 tab 顶部改成三条快捷操作，顶栏不再有歌单管理入口。
      await tester.tap(find.descendant(of: tabs, matching: find.text('歌单')));
      await _pumpUi(tester);
      expect(
        find.byKey(const ValueKey('playlists-quick-create')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('playlists-quick-online')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('playlists-quick-lx')), findsOneWidget);
      expect(find.byTooltip('歌单管理'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('playlist tab removes several playlists in batch mode', (
    tester,
  ) async {
    await _usePhoneViewport(tester);
    final prefs = await _prefsWith([
      _playlist(id: 'alpha', name: 'Alpha list'),
      _playlist(id: 'beta', name: 'Beta list'),
    ]);
    final audioHandler = PlayerAudioHandler();
    final router = createAppRouter(initialLocation: '/songs');
    addTearDown(() {
      router.dispose();
      unawaited(audioHandler.disposeHandler());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playerAudioHandlerProvider.overrideWithValue(audioHandler),
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

    final tabs = find.byKey(const ValueKey('songs-library-tabs'));
    await tester.tap(find.descendant(of: tabs, matching: find.text('歌单')));
    await _pumpUi(tester);

    await tester.tap(find.byTooltip('批量操作'));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const ValueKey('songs-playlist-alpha')));
    await _pumpUi(tester);
    expect(find.text('移除 1 个歌单'), findsOneWidget);

    await tester.tap(find.text('移除 1 个歌单'));
    await _pumpUi(tester);
    expect(find.text('移除已选歌单？'), findsOneWidget);
    await tester.tap(find.text('移除'));
    await _pumpUi(tester);

    expect(find.text('Alpha list'), findsNothing);
    expect(find.text('Beta list'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('playlist tab reorders playlists with a long press drag', (
    tester,
  ) async {
    await _usePhoneViewport(tester);
    final prefs = await _prefsWith([
      _playlist(id: 'alpha', name: 'Alpha list'),
      _playlist(id: 'beta', name: 'Beta list'),
    ]);
    final audioHandler = PlayerAudioHandler();
    final router = createAppRouter(initialLocation: '/songs');
    addTearDown(() {
      router.dispose();
      unawaited(audioHandler.disposeHandler());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playerAudioHandlerProvider.overrideWithValue(audioHandler),
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

    final tabs = find.byKey(const ValueKey('songs-library-tabs'));
    await tester.tap(find.descendant(of: tabs, matching: find.text('歌单')));
    await _pumpUi(tester);

    final alpha = find.byKey(const ValueKey('songs-playlist-alpha'));
    final beta = find.byKey(const ValueKey('songs-playlist-beta'));
    expect(tester.getTopLeft(alpha).dy, lessThan(tester.getTopLeft(beta).dy));

    final start = tester.getCenter(alpha);
    final end = tester.getCenter(beta) + const Offset(0, 30);
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 650));
    for (var step = 1; step <= 8; step++) {
      await gesture.moveTo(
        Offset.lerp(start, end, step / 8)!,
        timeStamp: Duration(milliseconds: 16 * step),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byKey(const ValueKey('songs-playlist-alpha'))).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const ValueKey('songs-playlist-beta'))).dy,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist tile menu updates online playlists only', (
    tester,
  ) async {
    await _usePhoneViewport(tester);
    final online = _playlist(
      id: 'online',
      name: '在线收藏',
      tracks: [PlaylistTrack.fromMusicInfo(_playlistMusic('old', '旧歌曲'))],
      originPlaylistId: '3778678',
      originSourceCode: MusicSource.wy.code,
    );
    final local = _playlist(id: 'local', name: '本地新建');
    final prefs = await _prefsWith([online, local]);
    final audioHandler = PlayerAudioHandler();
    final api = _PlaylistRefreshMusicApi(
      PlaylistInfo(
        id: '3778678',
        name: '线上榜单',
        source: MusicSource.wy,
        tracks: [_playlistMusic('old', '新歌名'), _playlistMusic('new', '新歌曲')],
      ),
    );
    final router = createAppRouter(initialLocation: '/songs');
    addTearDown(() {
      router.dispose();
      unawaited(audioHandler.disposeHandler());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playerAudioHandlerProvider.overrideWithValue(audioHandler),
          musicApiProvider.overrideWithValue(api),
        ],
        child: MaterialApp.router(
          builder: buildPrismTestEnvironment,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          ),
          routerConfig: router,
        ),
      ),
    );
    await _pumpUi(tester);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('songs-library-tabs')),
        matching: find.text('歌单'),
      ),
    );
    await _pumpUi(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('songs-playlist-online')),
        matching: find.byTooltip('歌单选项'),
      ),
    );
    await _pumpUi(tester);
    expect(find.text('更新歌单'), findsOneWidget);
    await tester.tap(find.text('更新歌单'));
    await _pumpUi(tester);
    expect(api.inputs, ['3778678']);
    expect(find.textContaining('导入 · 2 首'), findsOneWidget);

    // 本地歌单没有「更新歌单」入口（歌单 tab 只对在线导入歌单提供更新）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('songs-playlist-local')),
        matching: find.byTooltip('歌单选项'),
      ),
      findsNothing,
    );
    await tester.tapAt(const Offset(1, 1));
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'playlist tab lists long names and scrolls many playlists',
    (tester) async {
      await _usePhoneViewport(tester);
      const longName = '这是一个长度明显超过菜单宽度限制的测试歌单名称';
      final playlists = [
        for (var index = 0; index < 12; index++)
          _playlist(
            id: 'list-$index',
            name: index == 0 ? longName : '歌单 $index',
          ),
      ];
      final prefs = await _prefsWith(playlists);
      final audioHandler = PlayerAudioHandler();
      final router = createAppRouter(initialLocation: '/songs');
      addTearDown(() {
        router.dispose();
        unawaited(audioHandler.disposeHandler());
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            playerAudioHandlerProvider.overrideWithValue(audioHandler),
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

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('songs-library-tabs')),
          matching: find.text('歌单'),
        ),
      );
      await _pumpUi(tester);

      // 歌单 tab 直接铺列表：超长名称单行省略，多歌单可滚动。
      final longLabel = tester.widget<Text>(find.text(longName));
      expect(longLabel.maxLines, 1);
      expect(longLabel.overflow, TextOverflow.ellipsis);
      expect(
        find.byKey(const ValueKey('songs-playlist-list-0')),
        findsOneWidget,
      );
      final scroll = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('songs-playlist-list-11')),
        200,
        scrollable: scroll,
      );
      await _pumpUi(tester);
      expect(
        find.byKey(const ValueKey('songs-playlist-list-11')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('player back closes playback queue before leaving the player', (
    tester,
  ) async {
    await _usePhoneViewport(tester);
    final prefs = await _prefsWith(const []);
    final audioHandler = PlayerAudioHandler();
    final router = createAppRouter(initialLocation: '/player');
    addTearDown(() {
      router.dispose();
      unawaited(audioHandler.disposeHandler());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playerAudioHandlerProvider.overrideWithValue(audioHandler),
          playerControllerProvider.overrideWith(_TestPlayerController.new),
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

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerPage)),
    );
    final controller =
        container.read(playerControllerProvider.notifier)
            as _TestPlayerController;
    controller.seedPlayingTrack();
    await tester.pump();

    await tester.tap(find.byTooltip('播放列表，共 1 首'));
    await _pumpUi(tester);

    expect(find.text('播放列表'), findsOneWidget);
    expect(find.byKey(const ValueKey('playback-queue-popup')), findsOneWidget);

    final playingBars = find.byKey(const ValueKey('playing-bars'));
    expect(playingBars, findsOneWidget);
    final firstBar = find
        .descendant(of: playingBars, matching: find.byType(Transform))
        .first;
    final scaleBefore = tester.widget<Transform>(firstBar).transform.storage[5];
    await tester.pump(const Duration(milliseconds: 140));
    final scaleAfter = tester.widget<Transform>(firstBar).transform.storage[5];
    expect(scaleAfter, isNot(closeTo(scaleBefore, 0.0001)));

    expect(await tester.binding.handlePopRoute(), isTrue);
    await _pumpUi(tester);

    expect(find.text('播放列表'), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/player');

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(router.routeInformationProvider.value.uri.path, '/songs');
    final exitSlide = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect((1 - exitSlide.progress.value), greaterThan(0));
    await _pumpUi(tester);
    await tester.pump();
    expect(router.routeInformationProvider.value.uri.path, '/songs');
    await _pumpUi(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playback queue opens centered on the current track', (
    tester,
  ) async {
    await _usePhoneViewport(tester);
    final prefs = await _prefsWith(const []);
    final audioHandler = PlayerAudioHandler();
    final router = createAppRouter(initialLocation: '/player');
    addTearDown(() {
      router.dispose();
      unawaited(audioHandler.disposeHandler());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playerAudioHandlerProvider.overrideWithValue(audioHandler),
          playerControllerProvider.overrideWith(_TestPlayerController.new),
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

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerPage)),
    );
    final controller =
        container.read(playerControllerProvider.notifier)
            as _TestPlayerController;
    controller.seedPlayingQueue(count: 30, currentIndex: 20);
    await tester.pump();

    await tester.tap(find.byTooltip('播放列表，共 30 首'));
    await _pumpUi(tester);

    final list = find.byKey(const ValueKey('playback-queue-list'));
    final current = find.byKey(const ValueKey('playback-queue-entry-20'));
    expect(find.byKey(const ValueKey('playback-queue-popup')), findsOneWidget);
    expect(list, findsOneWidget);
    expect(current, findsOneWidget);
    expect(tester.getCenter(current).dy, closeTo(tester.getCenter(list).dy, 1));

    // Each queue row carries a heart that toggles the like in place.
    final like = find.byKey(const ValueKey('playback-queue-like-queue-20'));
    expect(like, findsOneWidget);
    expect(find.byTooltip('喜欢'), findsWidgets);
    await tester.tap(like);
    await _pumpUi(tester);
    expect(
      container.read(likedSongsProvider),
      hasLength(1),
    );
    expect(find.byTooltip('取消喜欢'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playback queue reorders, removes and clears entries', (
    tester,
  ) async {
    await _usePhoneViewport(tester);
    final prefs = await _prefsWith(const []);
    final audioHandler = PlayerAudioHandler();
    final router = createAppRouter(initialLocation: '/player');
    addTearDown(() {
      router.dispose();
      unawaited(audioHandler.disposeHandler());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playerAudioHandlerProvider.overrideWithValue(audioHandler),
          playerControllerProvider.overrideWith(_TestPlayerController.new),
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

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerPage)),
    );
    final controller =
        container.read(playerControllerProvider.notifier)
            as _TestPlayerController;
    controller.seedPlayingQueue(count: 6, currentIndex: 2);
    await tester.pump();

    await tester.tap(find.byTooltip('播放列表，共 6 首'));
    await _pumpUi(tester);

    // The header cycles the playback mode on tap.
    expect(find.textContaining('顺序播放'), findsOneWidget);
    await tester.tap(find.text('播放列表'));
    await _pumpUi(tester);
    expect(find.textContaining('随机播放'), findsOneWidget);

    // A row's close button drops that entry and keeps the queue consistent.
    await tester.tap(
      find.byKey(const ValueKey('playback-queue-remove-queue-4')),
    );
    await _pumpUi(tester);
    expect(
      container.read(playerControllerProvider).queue.map((e) => e.id),
      ['queue-0', 'queue-1', 'queue-2', 'queue-3', 'queue-5'],
    );
    expect(container.read(playerControllerProvider).queueIndex, 2);

    // Long-press the first row, then drag it past the second row.
    final first = find.byKey(const ValueKey('playback-queue-entry-0'));
    final second = find.byKey(const ValueKey('playback-queue-entry-1'));
    final start = tester.getCenter(first);
    final end = tester.getCenter(second) + const Offset(0, 20);
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 650));
    for (var step = 1; step <= 8; step++) {
      await gesture.moveTo(
        Offset.lerp(start, end, step / 8)!,
        timeStamp: Duration(milliseconds: 16 * step),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await _pumpUi(tester);
    final reordered = container.read(playerControllerProvider).queue;
    expect(reordered.length, 5);
    expect(reordered.first.id, isNot('queue-0'));

    // Clearing the queue empties it and shows the empty state.
    await tester.tap(find.byKey(const ValueKey('playback-queue-clear')));
    await _pumpUi(tester);
    expect(container.read(playerControllerProvider).queue, isEmpty);
    expect(find.text('还没有正在播放的歌曲'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player applies dark backdrop and dark-theme foreground', (
    tester,
  ) async {
    await _usePhoneViewport(tester);
    final prefs = await _prefsWith(const []);
    final audioHandler = PlayerAudioHandler();
    final router = createAppRouter(initialLocation: '/player');
    final darkScheme = ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: Brightness.dark,
    );
    addTearDown(() {
      router.dispose();
      unawaited(audioHandler.disposeHandler());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playerAudioHandlerProvider.overrideWithValue(audioHandler),
          playerControllerProvider.overrideWith(_TestPlayerController.new),
        ],
        child: MaterialApp.router(
          builder: buildPrismTestEnvironment,
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          theme: ThemeData(useMaterial3: true, colorScheme: darkScheme),
          darkTheme: ThemeData(useMaterial3: true, colorScheme: darkScheme),
          routerConfig: router,
        ),
      ),
    );
    await _pumpUi(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerPage)),
    );
    final controller =
        container.read(playerControllerProvider.notifier)
            as _TestPlayerController;
    controller.seedLyricsTrack();
    await tester.pump();

    // The seeded track carries a cover, so portrait disc mode's
    // backdrop is the blurred cover layer; the flowing light no longer
    // renders behind it.
    expect(
      find.byKey(const ValueKey('player-disc-blur-backdrop')),
      findsOneWidget,
    );
    expect(find.byType(FlowingLightBackground), findsNothing);
    final topMoreIcon = find.descendant(
      of: find.byTooltip('更多'),
      matching: find.byIcon(Icons.more_horiz_rounded),
    );
    expect(tester.widget<Icon>(topMoreIcon).color, darkScheme.onSurface);
    expect(tester.takeException(), isNull);
  });

  testWidgets('floating dock stays fixed and usable while the page scrolls', (
    tester,
  ) async {
    await _usePhoneViewport(tester);
    final prefs = await _prefsWith(const []);
    final audioHandler = PlayerAudioHandler();
    final router = createAppRouter(initialLocation: '/songs');
    addTearDown(() {
      router.dispose();
      unawaited(audioHandler.disposeHandler());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playerAudioHandlerProvider.overrideWithValue(audioHandler),
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

    final dock = find.byKey(const ValueKey('floating-navigation-dock'));
    final initialRect = tester.getRect(dock);
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -120),
    );
    await _pumpUi(tester);
    expect(tester.getRect(dock), initialRect);
    expect(floatingShellTab('设置').hitTestable(), findsOneWidget);
    await tester.tap(floatingShellTab('设置'));
    await _pumpUi(tester);
    expect(router.routeInformationProvider.value.uri.path, '/settings');
    expect(tester.takeException(), isNull);
  });

  testWidgets('shell toolbar fits compact width with large text', (
    tester,
  ) async {
    await _usePhoneViewport(tester, size: const Size(320, 720));
    final prefs = await _prefsWith(const []);
    final audioHandler = PlayerAudioHandler();
    final router = createAppRouter(initialLocation: '/songs');
    addTearDown(() {
      router.dispose();
      unawaited(audioHandler.disposeHandler());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playerAudioHandlerProvider.overrideWithValue(audioHandler),
        ],
        child: MaterialApp.router(
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: Builder(
              builder: (context) => buildPrismTestEnvironment(context, child),
            ),
          ),
          routerConfig: router,
        ),
      ),
    );
    await _pumpUi(tester);

    final dock = tester.getRect(
      find.byKey(const ValueKey('floating-navigation-dock')),
    );
    expect(dock.width, lessThanOrEqualTo(320));
    expect(dock.height, greaterThanOrEqualTo(48));
    for (final label in ['发现', '歌曲', '设置']) {
      expect(floatingShellTab(label).hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}

class _TestPlayerController extends PlayerController {
  _TestPlayerController(super.ref);

  void seedPlayingTrack() {
    state = const PlayerState(
      track: PlayerTrack(
        id: 'test:queue-track',
        kind: PlayerTrackKind.localFile,
        title: '测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        sourceLabel: '本地',
        qualityLabel: 'FLAC',
        localPath: 'test-song.flac',
      ),
      playing: true,
      duration: Duration(minutes: 3),
    );
  }

  void seedPlayingQueue({required int count, required int currentIndex}) {
    final queue = List<DownloadHistoryEntry>.generate(
      count,
      (index) => DownloadHistoryEntry(
        id: 'queue-$index',
        musicId: 'queue-$index',
        name: '队列歌曲 ${index + 1}',
        singer: '测试歌手',
        albumName: '测试专辑',
        sourceCode: 'wy',
        qualityCode: 'flac',
        status: DownloadHistoryStatus.completed,
        createdAt: DateTime.utc(2026, 8, 10),
      ),
    );
    final current = queue[currentIndex];
    state = PlayerState(
      track: PlayerTrack(
        id: current.id,
        kind: PlayerTrackKind.remote,
        title: current.name,
        artist: current.singer,
        album: current.albumName,
        sourceLabel: '网易云音乐',
        qualityLabel: 'FLAC',
      ),
      playing: true,
      duration: const Duration(minutes: 3),
      queue: queue,
      queueIndex: currentIndex,
      canPlayPrevious: true,
      canPlayNext: true,
    );
  }

  @override
  void cyclePlaybackMode() {
    final next = switch (state.playbackMode) {
      PlayerPlaybackMode.sequence => PlayerPlaybackMode.shuffle,
      PlayerPlaybackMode.shuffle => PlayerPlaybackMode.repeatOne,
      PlayerPlaybackMode.repeatOne => PlayerPlaybackMode.sequence,
    };
    state = state.copyWith(playbackMode: next);
  }

  @override
  void reorderQueue(int oldIndex, int newIndex) {
    final queue = List<DownloadHistoryEntry>.of(state.queue);
    if (oldIndex < 0 || oldIndex >= queue.length) return;
    final moved = queue.removeAt(oldIndex);
    queue.insert(newIndex.clamp(0, queue.length), moved);
    state = state.copyWith(
      queue: queue,
      queueIndex: _currentTrackQueueIndex(queue),
    );
  }

  @override
  Future<void> removeFromQueue(int index) async {
    final queue = List<DownloadHistoryEntry>.of(state.queue);
    if (index < 0 || index >= queue.length) return;
    queue.removeAt(index);
    state = state.copyWith(
      queue: queue,
      queueIndex: _currentTrackQueueIndex(queue),
    );
  }

  @override
  Future<void> clearQueue() async {
    state = const PlayerState();
  }

  int _currentTrackQueueIndex(List<DownloadHistoryEntry> queue) {
    final trackId = state.track?.id;
    if (trackId == null) return -1;
    return queue.indexWhere((entry) => entry.id == trackId);
  }

  void seedLyricsTrack() {
    final lines = List<KaraokeLyricLine>.generate(18, (index) {
      final startMs = index * 3000;
      return KaraokeLyricLine(
        startMs: startMs,
        endMs: startMs + 3000,
        text: '第 ${index + 1} 行测试歌词',
        translation: index.isEven ? 'Test lyric line ${index + 1}' : null,
      );
    });
    state = PlayerState(
      track: const PlayerTrack(
        id: 'test:lyrics-track',
        kind: PlayerTrackKind.localFile,
        title: '歌词测试歌曲',
        artist: '测试歌手',
        album: '测试专辑',
        sourceLabel: '本地',
        qualityLabel: 'FLAC',
        coverUrl: 'https://example.com/lyrics-cover.jpg',
        localPath: 'lyrics-test.flac',
      ),
      lyrics: KaraokeLyrics(lines),
      playing: true,
      position: const Duration(seconds: 9),
      duration: const Duration(minutes: 3),
    );
  }

  @override
  Future<void> seek(Duration position) {
    state = state.copyWith(position: position);
    return Future<void>.value();
  }

  void advanceLyrics(Duration position) {
    state = state.copyWith(position: position);
  }
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

Future<SharedPreferences> _prefsWith(List<LocalPlaylist> playlists) async {
  SharedPreferences.setMockInitialValues({
    localPlaylistsStorageKey: [
      for (final playlist in playlists) jsonEncode(playlist.toJson()),
    ],
  });
  return SharedPreferences.getInstance();
}

LocalPlaylist _playlist({
  required String id,
  required String name,
  List<PlaylistTrack> tracks = const [],
  String? originPlaylistId,
  String? originSourceCode,
}) {
  final now = DateTime.utc(2026, 7, 20);
  return LocalPlaylist(
    id: id,
    name: name,
    tracks: tracks,
    createdAt: now,
    updatedAt: now,
    originPlaylistId: originPlaylistId,
    originSourceCode: originSourceCode,
  );
}

MusicInfo _playlistMusic(String id, String name) {
  return MusicInfo.fromJson({
    'id': id,
    'name': name,
    'singer': '在线歌手',
    'source': MusicSource.wy.code,
    'interval': '03:30',
    'meta': {
      'songId': id,
      'albumName': '在线专辑',
      'qualitys': [
        {'type': Quality.k320.code, 'size': '1024'},
      ],
    },
  });
}

class _PlaylistRefreshMusicApi extends MusicApi {
  _PlaylistRefreshMusicApi(this.result);

  final PlaylistInfo result;
  final List<String> inputs = <String>[];

  @override
  Future<PlaylistInfo> parsePlaylist({
    required String input,
    MusicSource source = MusicSource.all,
    int? maxTracks,
  }) async {
    inputs.add(input);
    return result;
  }
}

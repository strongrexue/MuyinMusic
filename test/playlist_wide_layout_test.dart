import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/online_collection_kind.dart';
import 'package:cy_shine_music/core/models/playlist_info.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/discovery/online_playlist_detail_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_detail_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/playlists/widgets/playlist_track_tile.dart';

import 'helpers/prism_test_environment.dart';

const _wideLayoutKey = ValueKey('playlist-wide-layout');
const _infoPaneKey = ValueKey('playlist-wide-info-pane');
const _headerKey = ValueKey('immersive-playlist-header');
const _playAllKey = ValueKey('playlist-play-all');
const _favoriteKey = ValueKey('playlist-favorite');
const _skeletonKey = ValueKey('detail-track-skeleton');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('local detail switches to the wide two-pane layout at 1024x600', (
    tester,
  ) async {
    await _useViewport(tester, const Size(1024, 600));
    await _pumpLocalDetail(tester, playlist: _localPlaylist());

    expect(find.byKey(_wideLayoutKey), findsOneWidget);
    expect(find.byKey(_infoPaneKey), findsOneWidget);
    expect(find.byKey(_headerKey), findsNothing);
    expect(find.byKey(_playAllKey), findsOneWidget);
    // 非在线导入歌单没有「取消收藏」。
    expect(find.byKey(_favoriteKey), findsNothing);
    expect(find.text('First song'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local detail keeps the immersive header on phones', (
    tester,
  ) async {
    await _useViewport(tester, const Size(390, 844));
    await _pumpLocalDetail(tester, playlist: _localPlaylist());

    expect(find.byKey(_headerKey), findsOneWidget);
    expect(find.byKey(_wideLayoutKey), findsNothing);
    expect(find.byKey(_playAllKey), findsOneWidget);
    expect(find.byKey(_favoriteKey), findsNothing);
    // 「添加到下一首播放」已从歌单行移除。
    expect(find.byIcon(Icons.playlist_add_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unfavorite flow confirms, deletes and returns to /playlists', (
    tester,
  ) async {
    await _useViewport(tester, const Size(390, 844));
    final container = _newContainer(
      await _seedPreferences(_localPlaylist(online: true)),
    );
    final router = GoRouter(
      initialLocation: '/playlists/fav',
      routes: [
        GoRoute(
          path: '/playlists',
          builder: (_, _) => const Scaffold(body: Text('Playlist list stub')),
        ),
        GoRoute(
          path: '/playlists/:id',
          builder: (_, state) =>
              PlaylistDetailPage(playlistId: state.pathParameters['id']!),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          builder: buildPrismTestEnvironment,
          theme: _theme(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(_favoriteKey), findsOneWidget);
    expect(find.text('取消收藏'), findsOneWidget);

    // 取消分支：歌单保留、停在详情页。
    await tester.tap(find.byKey(_favoriteKey));
    await tester.pumpAndSettle();
    expect(find.text('取消收藏这个歌单？'), findsOneWidget);
    await tester.tap(find.widgetWithText(prism.TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(container.read(localPlaylistsProvider), hasLength(1));
    expect(router.routeInformationProvider.value.uri.path, '/playlists/fav');

    // 确认分支：删除并回到歌单列表。
    await tester.tap(find.byKey(_favoriteKey));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(prism.AlertDialog),
        matching: find.widgetWithText(prism.FilledButton, '取消收藏'),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(localPlaylistsProvider), isEmpty);
    expect(router.routeInformationProvider.value.uri.path, '/playlists');
    expect(find.text('Playlist list stub'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('online detail renders wide skeleton then data at 1024x600', (
    tester,
  ) async {
    await _useViewport(tester, const Size(1024, 600));
    final fake = _FakePlaylistApi(delayDetail: true);
    final container = _newContainer(
      await SharedPreferences.getInstance(),
      musicApi: fake,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: buildPrismTestEnvironment,
          theme: _theme(),
          home: const OnlinePlaylistDetailPage(
            source: MusicSource.kw,
            playlistId: '1',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(_wideLayoutKey), findsOneWidget);
    expect(find.byKey(_headerKey), findsNothing);
    expect(find.byKey(_skeletonKey), findsNWidgets(8));
    expect(find.byKey(_playAllKey), findsOneWidget);

    fake.completeDetail();
    await tester.pumpAndSettle();

    expect(find.byKey(_wideLayoutKey), findsOneWidget);
    expect(find.byKey(_skeletonKey), findsNothing);
    expect(find.text('Online track'), findsOneWidget);
    expect(find.byKey(_favoriteKey), findsOneWidget);
    // 普通在线歌单不显示名次。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kw:online-1')),
        matching: find.text('1'),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide info pane stacks play/favorite onto two rows', (
    tester,
  ) async {
    await _useViewport(tester, const Size(1024, 600));
    final container = _newContainer(
      await SharedPreferences.getInstance(),
      musicApi: _FakePlaylistApi(),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: buildPrismTestEnvironment,
          theme: _theme(),
          home: const OnlinePlaylistDetailPage(
            source: MusicSource.kw,
            playlistId: '1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 340dp 左列放不下两个并排按钮：收藏按钮换行，且都占满整行宽。
    final playRect = tester.getRect(find.byKey(_playAllKey));
    final favoriteRect = tester.getRect(find.byKey(_favoriteKey));
    expect(favoriteRect.top, greaterThanOrEqualTo(playRect.bottom));
    expect(favoriteRect.width, playRect.width);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone width keeps play/favorite on one row', (tester) async {
    await _useViewport(tester, const Size(390, 844));
    final container = _newContainer(
      await SharedPreferences.getInstance(),
      musicApi: _FakePlaylistApi(),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: buildPrismTestEnvironment,
          theme: _theme(),
          home: const OnlinePlaylistDetailPage(
            source: MusicSource.kw,
            playlistId: '1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final playRect = tester.getRect(find.byKey(_playAllKey));
    final favoriteRect = tester.getRect(find.byKey(_favoriteKey));
    expect(favoriteRect.top, playRect.top);
    expect(favoriteRect.left, greaterThan(playRect.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail skeleton rows match the real row geometry on phones', (
    tester,
  ) async {
    await _useViewport(tester, const Size(390, 844));
    final fake = _FakePlaylistApi(delayDetail: true);
    final container = _newContainer(
      await SharedPreferences.getInstance(),
      musicApi: fake,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: buildPrismTestEnvironment,
          theme: _theme(),
          home: const OnlinePlaylistDetailPage(
            source: MusicSource.kw,
            playlistId: '1',
          ),
        ),
      ),
    );
    await tester.pump();

    final skeletons = find.byKey(_skeletonKey);
    // The lazy list only builds nearby rows; two rows suffice to check geometry.
    expect(skeletons, findsAtLeastNWidgets(2));
    final size = tester.getSize(skeletons.first);
    expect(size.height, 62);
    // SliverPadding 左右各 12，与数据行同宽。
    expect(size.width, 390 - 24);
    expect(
      tester.getTopLeft(skeletons.at(1)).dy -
          tester.getTopLeft(skeletons.first).dy,
      63,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('local detail stays compact at 767 wide', (tester) async {
    await _useViewport(tester, const Size(767, 600));
    await _pumpLocalDetail(tester, playlist: _localPlaylist());
    expect(find.byKey(_headerKey), findsOneWidget);
    expect(find.byKey(_wideLayoutKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local detail splits at 768 wide', (tester) async {
    await _useViewport(tester, const Size(768, 600));
    await _pumpLocalDetail(tester, playlist: _localPlaylist());
    expect(find.byKey(_wideLayoutKey), findsOneWidget);
    expect(find.byKey(_headerKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('track rows fill the available width in compact form', (
    tester,
  ) async {
    await _useViewport(tester, const Size(390, 844));
    await _pumpLocalDetail(tester, playlist: _localPlaylist());

    // 歌曲列左右各 12dp 内边距，未触及 900 上限时用满可用宽。
    expect(tester.getSize(find.byType(PlaylistTrackTile).first).width, 366);
    // 操作区左右各 16dp 内边距，同样用满可用宽。
    final actionsBox = find
        .ancestor(
          of: find.byKey(_playAllKey),
          matching: find.byType(ConstrainedBox),
        )
        .first;
    expect(tester.getSize(actionsBox).width, 390 - 32);
    expect(tester.takeException(), isNull);
  });

  testWidgets('track rows fill the right column in wide form', (
    tester,
  ) async {
    await _useViewport(tester, const Size(1024, 600));
    await _pumpLocalDetail(tester, playlist: _localPlaylist());

    // 右列宽 1024-340=684，歌曲列再减左右 12dp 内边距。
    expect(tester.getSize(find.byType(PlaylistTrackTile).first).width, 660);
    // 操作区落在 340 左列内：列内可用宽 340-20-12=308，不再套 900。
    final actionsBox = find
        .ancestor(
          of: find.byKey(_playAllKey),
          matching: find.byType(ConstrainedBox),
        )
        .first;
    expect(tester.getSize(actionsBox).width, 308);
    expect(tester.takeException(), isNull);
  });

  testWidgets('track rows cap at 900 and center in an ultra-wide column', (
    tester,
  ) async {
    await _useViewport(tester, const Size(1600, 900));
    await _pumpLocalDetail(tester, playlist: _localPlaylist());

    final tile = tester.getRect(find.byType(PlaylistTrackTile).first);
    expect(tile.width, 900);
    // 右列为 [340, 1600]，900 上限的歌曲行在列内居中。
    expect(tile.center.dx, 340 + (1600 - 340) / 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('online detail boundary: 767 compact, 768 wide', (tester) async {
    await _useViewport(tester, const Size(767, 600));
    await _pumpOnlineDetail(tester, api: _FakePlaylistApi());
    await tester.pumpAndSettle();
    expect(find.byKey(_headerKey), findsOneWidget);
    expect(find.byKey(_wideLayoutKey), findsNothing);
    expect(tester.takeException(), isNull);

    await _useViewport(tester, const Size(768, 600));
    await _pumpOnlineDetail(tester, api: _FakePlaylistApi());
    await tester.pumpAndSettle();
    expect(find.byKey(_wideLayoutKey), findsOneWidget);
    expect(find.byKey(_headerKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local and online details split at 800x390 landscape', (
    tester,
  ) async {
    await _useViewport(tester, const Size(800, 390));
    await _pumpLocalDetail(tester, playlist: _localPlaylist());
    expect(find.byKey(_wideLayoutKey), findsOneWidget);
    expect(find.byKey(_headerKey), findsNothing);
    expect(tester.takeException(), isNull);

    await _pumpOnlineDetail(tester, api: _FakePlaylistApi());
    await tester.pumpAndSettle();
    expect(find.byKey(_wideLayoutKey), findsOneWidget);
    expect(find.byKey(_headerKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('online error state matches the data state form', (
    tester,
  ) async {
    await _useViewport(tester, const Size(1024, 600));
    await _pumpOnlineDetail(tester, api: _FakePlaylistApi(failDetail: true));
    await tester.pumpAndSettle();
    expect(find.byKey(_wideLayoutKey), findsOneWidget);
    expect(find.byKey(_headerKey), findsNothing);
    expect(tester.takeException(), isNull);

    await _useViewport(tester, const Size(390, 844));
    await _pumpOnlineDetail(tester, api: _FakePlaylistApi(failDetail: true));
    await tester.pumpAndSettle();
    expect(find.byKey(_wideLayoutKey), findsNothing);
    expect(find.byKey(_headerKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaderboard detail splits at 800 wide and shows ranks', (
    tester,
  ) async {
    await _useViewport(tester, const Size(800, 390));
    await _pumpOnlineDetail(
      tester,
      api: _FakePlaylistApi(leaderboardTotal: 3),
      kind: OnlineCollectionKind.leaderboard,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(_wideLayoutKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kw:rank-1')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kw:rank-3')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaderboard ranks continue across pages', (tester) async {
    await _useViewport(tester, const Size(390, 844));
    await _pumpOnlineDetail(
      tester,
      api: _FakePlaylistApi(leaderboardTotal: 45),
      kind: OnlineCollectionKind.leaderboard,
    );
    await tester.pumpAndSettle();

    // 首行名次为 1。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kw:rank-1')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );

    // 滚动触发第二页加载（首批 40 首 + 追加 5 首），名次延续累计序号。
    for (
      var i = 0;
      i < 10 && find.byKey(const ValueKey('kw:rank-45')).evaluate().isEmpty;
      i++
    ) {
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, -3000),
        6000,
      );
      await tester.pumpAndSettle();
    }
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kw:rank-41')),
        matching: find.text('41'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('kw:rank-45')),
        matching: find.text('45'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

ThemeData _theme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
  );
}

Future<void> _useViewport(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
}

ProviderContainer _newContainer(SharedPreferences prefs, {MusicApi? musicApi}) {
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      if (musicApi != null) musicApiProvider.overrideWithValue(musicApi),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<SharedPreferences> _seedPreferences(LocalPlaylist playlist) async {
  SharedPreferences.setMockInitialValues({
    localPlaylistsStorageKey: [jsonEncode(playlist.toJson())],
  });
  return SharedPreferences.getInstance();
}

Future<ProviderContainer> _pumpLocalDetail(
  WidgetTester tester, {
  required LocalPlaylist playlist,
}) async {
  final container = _newContainer(await _seedPreferences(playlist));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: buildPrismTestEnvironment,
        theme: _theme(),
        home: PlaylistDetailPage(playlistId: playlist.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _pumpOnlineDetail(
  WidgetTester tester, {
  required MusicApi api,
  OnlineCollectionKind kind = OnlineCollectionKind.playlist,
}) async {
  final container = _newContainer(
    await SharedPreferences.getInstance(),
    musicApi: api,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: buildPrismTestEnvironment,
        theme: _theme(),
        home: OnlinePlaylistDetailPage(
          source: MusicSource.kw,
          playlistId: '1',
          kind: kind,
        ),
      ),
    ),
  );
}

LocalPlaylist _localPlaylist({bool online = false}) {
  return LocalPlaylist(
    id: online ? 'fav' : 'plain',
    name: online ? '收藏的歌单' : '本地歌单',
    tracks: [
      PlaylistTrack.fromMusicInfo(_music('track-1', 'First song')),
      PlaylistTrack.fromMusicInfo(_music('track-2', '第二首')),
    ],
    createdAt: DateTime.utc(2026, 8, 1),
    updatedAt: DateTime.utc(2026, 8, 1),
    originPlaylistId: online ? 'origin-1' : null,
    originSourceCode: online ? MusicSource.kw.code : null,
  );
}

MusicInfo _music(String id, String name) {
  return MusicInfo.fromJson({
    'id': id,
    'name': name,
    'singer': 'Test artist',
    'source': MusicSource.kw.code,
    'interval': '03:30',
    'meta': {
      'songId': id,
      'albumName': 'Test album',
      'qualitys': [
        {'type': Quality.k320.code, 'size': '1024'},
      ],
    },
  });
}

class _FakePlaylistApi extends MusicApi {
  _FakePlaylistApi({
    this.delayDetail = false,
    this.failDetail = false,
    this.leaderboardTotal,
  });

  final bool delayDetail;
  final bool failDetail;

  /// 非空时按排行榜返回：共这么多首，parsePlaylist 按 maxTracks 截断，
  /// 模拟分页加载。
  final int? leaderboardTotal;
  final Completer<PlaylistInfo> _detail = Completer<PlaylistInfo>();

  PlaylistInfo get _playlist => PlaylistInfo(
    id: '1',
    name: '在线歌单',
    source: MusicSource.kw,
    creator: '在线作者',
    description: '在线歌单简介',
    playCount: 1200,
    trackCount: 1,
    tracks: [_music('online-1', 'Online track')],
  );

  PlaylistInfo _leaderboard(int? maxTracks) {
    final total = leaderboardTotal!;
    final count = (maxTracks ?? total).clamp(0, total);
    return PlaylistInfo(
      id: '1',
      name: '测试排行榜',
      source: MusicSource.kw,
      trackCount: total,
      tracks: [
        for (var i = 1; i <= count; i++) _music('rank-$i', 'Rank track $i'),
      ],
    );
  }

  void completeDetail() => _detail.complete(_playlist);

  @override
  Future<PlaylistInfo> parsePlaylist({
    required String input,
    MusicSource source = MusicSource.all,
    int? maxTracks,
  }) {
    if (failDetail) {
      return Future.error(StateError('detail failed'));
    }
    return delayDetail ? _detail.future : Future.value(_playlist);
  }

  @override
  Future<PlaylistInfo> getLeaderboard({
    required MusicSource source,
    required String boardId,
    int? maxTracks,
  }) {
    if (failDetail) {
      return Future.error(StateError('detail failed'));
    }
    return Future.value(_leaderboard(maxTracks));
  }
}

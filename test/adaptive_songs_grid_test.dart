import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:panghu_music/core/storage/settings_store.dart';
import 'package:panghu_music/features/player/player_audio_handler.dart';
import 'package:panghu_music/features/playlists/playlist_models.dart';
import 'package:panghu_music/features/playlists/playlist_store.dart';
import 'package:panghu_music/features/playlists/widgets/playlist_library_tile.dart';
import 'package:panghu_music/features/songs/widgets/windows_playlist_cover_card.dart';
import 'package:panghu_music/router.dart';

import 'helpers/prism_test_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('playlists tab uses the cover grid on wide layouts', (
    tester,
  ) async {
    await _useViewport(tester, const Size(1280, 800));
    final harness = await _pumpSongs(tester);
    addTearDown(harness.dispose);

    await _openPlaylistsTab(tester);

    expect(find.byType(WindowsPlaylistCoverCard), findsNWidgets(3));
    expect(find.byType(PlaylistLibraryTile), findsNothing);
    expect(
      find.byKey(const ValueKey('playlists-sort-mode-toggle')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('sort mode switches the wide grid back to the reorderable list', (
    tester,
  ) async {
    await _useViewport(tester, const Size(1280, 800));
    final harness = await _pumpSongs(tester);
    addTearDown(harness.dispose);

    await _openPlaylistsTab(tester);
    expect(find.byType(WindowsPlaylistCoverCard), findsNWidgets(3));

    await tester.tap(find.byKey(const ValueKey('playlists-sort-mode-toggle')));
    await _pumpUi(tester);

    expect(find.byType(WindowsPlaylistCoverCard), findsNothing);
    expect(find.byType(PlaylistLibraryTile), findsNWidgets(3));
    expect(find.byType(ReorderableDelayedDragStartListener), findsNWidgets(3));

    await tester.tap(find.byKey(const ValueKey('playlists-sort-mode-toggle')));
    await _pumpUi(tester);

    expect(find.byType(WindowsPlaylistCoverCard), findsNWidgets(3));
    expect(find.byType(PlaylistLibraryTile), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlists tab keeps the list on narrow layouts', (tester) async {
    await _useViewport(tester, const Size(390, 844));
    final harness = await _pumpSongs(tester);
    addTearDown(harness.dispose);

    await _openPlaylistsTab(tester);

    expect(find.byType(PlaylistLibraryTile), findsNWidgets(3));
    expect(find.byType(WindowsPlaylistCoverCard), findsNothing);
    expect(
      find.byKey(const ValueKey('playlists-sort-mode-toggle')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

class _Harness {
  _Harness(this.router, this.audioHandler);

  final GoRouter router;
  final PlayerAudioHandler audioHandler;

  void dispose() {
    router.dispose();
    unawaited(audioHandler.disposeHandler());
  }
}

Future<_Harness> _pumpSongs(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    localPlaylistsStorageKey: [
      for (var index = 1; index <= 3; index++)
        jsonEncode(_playlist(id: 'p$index', name: '歌单 $index').toJson()),
    ],
  });
  final prefs = await SharedPreferences.getInstance();
  final audioHandler = PlayerAudioHandler();
  final router = createAppRouter(initialLocation: '/songs');

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
  return _Harness(router, audioHandler);
}

Future<void> _openPlaylistsTab(WidgetTester tester) async {
  final tab = find.descendant(
    of: find.byKey(const ValueKey('songs-library-tabs')),
    matching: find.text('歌单'),
  );
  expect(tab, findsOneWidget);
  await tester.tap(tab);
  await _pumpUi(tester);
}

LocalPlaylist _playlist({required String id, required String name}) {
  final now = DateTime.utc(2026, 7, 20);
  return LocalPlaylist(
    id: id,
    name: name,
    tracks: const [],
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> _pumpUi(WidgetTester tester) async {
  for (var index = 0; index < 12; index++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _useViewport(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
}

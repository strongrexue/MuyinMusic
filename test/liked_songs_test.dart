import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/downloads/download_history_store.dart';
import 'package:cy_shine_music/features/songs/liked_songs_store.dart';
import 'package:cy_shine_music/features/songs/widgets/song_row.dart';

import 'helpers/prism_test_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('liked songs keep online metadata and replay identity', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    final online = DownloadHistoryEntry(
      id: 'search:wy:42',
      musicId: '42',
      name: '云端歌曲',
      singer: '云端歌手',
      albumName: '云端专辑',
      sourceCode: MusicSource.wy.code,
      qualityCode: Quality.k320.code,
      status: DownloadHistoryStatus.completed,
      createdAt: DateTime.utc(2026, 8, 10),
      musicJson: const {'id': '42', 'name': '云端歌曲'},
    );
    final notifier = container.read(likedSongsProvider.notifier);

    expect(notifier.isLiked(online), isFalse);
    expect(notifier.toggle(online), isTrue);
    expect(notifier.isLiked(online), isTrue);
    expect(
      container.read(likedSongsProvider).single.musicJson?['id'],
      '42',
    );

    // A freshly built notifier restores the entry from storage.
    final restored = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(restored.dispose);
    await Future<void>.delayed(Duration.zero);
    final reloaded = restored.read(likedSongsProvider);
    expect(reloaded, hasLength(1));
    expect(reloaded.single.name, '云端歌曲');
    expect(reloaded.single.musicInfo?.id, '42');
    expect(
      songIdentityKey(reloaded.single),
      songIdentityKey(online),
    );

    expect(restored.read(likedSongsProvider.notifier).toggle(online), isFalse);
    expect(restored.read(likedSongsProvider), isEmpty);
  });

  testWidgets('song row heart toggles like state', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final entry = DownloadHistoryEntry(
      id: 'local:1',
      musicId: 'local-1',
      name: '本地歌曲',
      singer: '本地歌手',
      albumName: '本地专辑',
      sourceCode: MusicSource.all.code,
      qualityCode: Quality.flac.code,
      status: DownloadHistoryStatus.completed,
      createdAt: DateTime.utc(2026, 8, 10),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          builder: buildPrismTestEnvironment,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final liked = ref.watch(
                  likedSongsProvider.select(
                    (items) => items.any(
                      (row) =>
                          songIdentityKey(row) == songIdentityKey(entry),
                    ),
                  ),
                );
                return SongRow(
                  entry: entry,
                  artworkVersion: null,
                  playing: false,
                  batchMode: false,
                  selected: false,
                  onToggleSelected: () {},
                  onAddNext: () {},
                  onAddToPlaylist: () {},
                  onPlay: () {},
                  onDelete: () {},
                  liked: liked,
                  onToggleLike: () =>
                      ref.read(likedSongsProvider.notifier).toggle(entry),
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('喜欢'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('song-like-local:1')));
    await tester.pumpAndSettle();

    expect(find.byTooltip('取消喜欢'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    expect(ProviderScope.containerOf(
      tester.element(find.byType(SongRow)),
    ).read(likedSongsProvider), hasLength(1));

    // Drain the tooltip / splash timers before the tree is torn down.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}

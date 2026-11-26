import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/icons/icons.dart' as prism_glyph;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:panghu_music/core/models/enums.dart';
import 'package:panghu_music/core/models/music_info.dart';
import 'package:panghu_music/core/storage/settings_store.dart';
import 'package:panghu_music/core/ui/artwork_colors.dart';
import 'package:panghu_music/core/ui/flow_palette.dart';
import 'package:panghu_music/features/player/player_audio_handler.dart';
import 'package:panghu_music/features/player/player_controller.dart';
import 'package:panghu_music/features/player/widgets/player_action_row.dart';
import 'package:panghu_music/features/player/widgets/player_control_color.dart';
import 'package:panghu_music/features/player/widgets/player_palette.dart';
import 'package:panghu_music/features/playlists/playlist_models.dart';
import 'package:panghu_music/features/songs/liked_songs_store.dart';

import 'helpers/prism_test_environment.dart';

const _redArtwork = ArtworkColors(
  baseColor: Colors.red,
  palette: FlowPalette(baseArgb: 0xFFFF0000, accentsArgb: [0xFFFF0000]),
  lyricInk: null,
);

/// The accent [PlayerControlColor] derives from the palette's pure red in
/// a light theme: hue kept, saturation clamped to 0.75, lightness 0.23.
Color get _expectedInk => HSLColor.fromColor(const Color(0xFFFF0000))
    .withSaturation(0.75)
    .withLightness(0.23)
    .toColor();

class _SeededController extends PlayerController {
  _SeededController(
    super.ref,
    PlayerState initialState, {
    this.seededCurrentMusic,
  }) {
    state = initialState;
  }

  final MusicInfo? seededCurrentMusic;

  @override
  MusicInfo? get currentMusic => seededCurrentMusic ?? super.currentMusic;
}

MusicInfo _remoteMusic() => MusicInfo.fromJson({
  'id': 'remote-song',
  'name': '在线歌曲',
  'singer': '歌手',
  'source': MusicSource.tx.code,
  'meta': {
    'songId': 'remote-song',
    'albumName': '测试专辑',
    'qualitys': [
      {'type': Quality.k320.code, 'size': '9.48 MB'},
    ],
  },
});

const _remoteTrack = PlayerTrack(
  id: 'tx:remote-song:remote',
  kind: PlayerTrackKind.remote,
  title: '在线歌曲',
  artist: '歌手',
  album: '测试专辑',
  sourceLabel: 'QQ',
  qualityLabel: '320K',
  remoteUrl: 'https://audio.example/remote-song.mp3',
);

const _localTrack = PlayerTrack(
  id: 'local:test-song',
  kind: PlayerTrackKind.localFile,
  title: '本地歌曲',
  artist: '本地歌手',
  album: '本地专辑',
  sourceLabel: 'QQ',
  qualityLabel: 'FLAC',
  localPath: 'test-song.flac',
);

/// Pumps [child] (the action row by default) next to a [PlayerControlColor]
/// probe and returns the color the probe received — the same dynamic ink
/// the transport bar paints with.
Future<Color> _pumpRow(
  WidgetTester tester, {
  required PlayerState state,
  MusicInfo? currentMusic,
  ArtworkColors? artworkColors,
  Widget child = const PlayerActionRow(),
}) async {
  final preferences = await SharedPreferences.getInstance();
  final audioHandler = PlayerAudioHandler();
  addTearDown(() => unawaited(audioHandler.disposeHandler()));
  late Color probe;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        playerAudioHandlerProvider.overrideWithValue(audioHandler),
        playerControllerProvider.overrideWith(
          (ref) => _SeededController(
            ref,
            state,
            seededCurrentMusic: currentMusic,
          ),
        ),
        playerArtworkColorsProvider.overrideWith(
          (ref) async => artworkColors,
        ),
      ],
      child: MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.light,
          ),
        ),
        builder: (context, appChild) => buildPrismTestEnvironment(
          context,
          MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: true),
            child: appChild ?? const SizedBox.shrink(),
          ),
        ),
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PlayerControlColor(
                  builder: (context, color) {
                    probe = color;
                    return const SizedBox.shrink();
                  },
                ),
                child,
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return probe;
}

Color _glyphColor(WidgetTester tester, String key) {
  final finder = find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(prism_glyph.GlyphIcon),
  );
  return tester.widget<prism_glyph.GlyphIcon>(finder).color!;
}

Color _iconColor(WidgetTester tester, String key, IconData icon) {
  final finder = find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byWidgetPredicate((w) => w is Icon && w.icon == icon),
  );
  return tester.widget<Icon>(finder).color!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('action row follows the artwork accent like the transport bar', (
    tester,
  ) async {
    final ink = await _pumpRow(
      tester,
      state: const PlayerState(track: _remoteTrack),
      currentMusic: _remoteMusic(),
      artworkColors: _redArtwork,
    );

    expect(ink, _expectedInk);
    expect(ink, isNot(kPlayerInk));
    expect(_glyphColor(tester, 'player-action-lyric-settings'), ink);
    expect(_glyphColor(tester, 'player-action-playlist'), ink);
    expect(_glyphColor(tester, 'player-action-download'), ink);
    expect(
      _iconColor(
        tester,
        'player-action-like',
        Icons.favorite_border_rounded,
      ),
      ink,
    );
    expect(
      _iconColor(tester, 'player-action-volume', Icons.volume_up_outlined),
      ink,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('liked state keeps its fixed pink under the artwork accent', (
    tester,
  ) async {
    final music = _remoteMusic();
    final ink = await _pumpRow(
      tester,
      state: const PlayerState(track: _remoteTrack),
      currentMusic: music,
      artworkColors: _redArtwork,
    );
    expect(
      _iconColor(
        tester,
        'player-action-like',
        Icons.favorite_border_rounded,
      ),
      ink,
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerActionRow)),
    );
    final entry = PlaylistTrack.fromMusicInfo(
      music,
    ).toQueueEntry(playlistId: 'player');
    container.read(likedSongsProvider.notifier).toggle(entry!);
    await tester.pumpAndSettle();

    expect(
      _iconColor(tester, 'player-action-like', Icons.favorite_rounded),
      const Color(0xFFFF6382),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled actions dim the accent instead of the muted ink', (
    tester,
  ) async {
    final ink = await _pumpRow(
      tester,
      state: const PlayerState(track: _localTrack),
      artworkColors: _redArtwork,
    );

    final dimmed = ink.withValues(alpha: 0.45);
    expect(_glyphColor(tester, 'player-action-playlist'), dimmed);
    expect(_glyphColor(tester, 'player-action-download'), dimmed);
    expect(
      _iconColor(
        tester,
        'player-action-like',
        Icons.favorite_border_rounded,
      ),
      dimmed,
    );
    // Always-available actions keep the full accent.
    expect(_glyphColor(tester, 'player-action-lyric-settings'), ink);
    expect(
      _iconColor(tester, 'player-action-volume', Icons.volume_up_outlined),
      ink,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('without artwork colors the row falls back to player ink', (
    tester,
  ) async {
    final ink = await _pumpRow(
      tester,
      state: const PlayerState(track: _remoteTrack),
      currentMusic: _remoteMusic(),
    );

    expect(ink, kPlayerInk);
    expect(_glyphColor(tester, 'player-action-lyric-settings'), kPlayerInk);
    expect(_glyphColor(tester, 'player-action-playlist'), kPlayerInk);
    expect(_glyphColor(tester, 'player-action-download'), kPlayerInk);
    expect(
      _iconColor(
        tester,
        'player-action-like',
        Icons.favorite_border_rounded,
      ),
      kPlayerInk,
    );
    expect(
      _iconColor(tester, 'player-action-volume', Icons.volume_up_outlined),
      kPlayerInk,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape leading and trailing sections follow the accent', (
    tester,
  ) async {
    final ink = await _pumpRow(
      tester,
      state: const PlayerState(track: _remoteTrack),
      currentMusic: _remoteMusic(),
      artworkColors: _redArtwork,
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [PlayerActionRow.leading(), PlayerActionRow.trailing()],
      ),
    );

    expect(_glyphColor(tester, 'player-action-lyric-settings'), ink);
    expect(_glyphColor(tester, 'player-action-download'), ink);
    expect(
      _iconColor(
        tester,
        'player-action-like',
        Icons.favorite_border_rounded,
      ),
      ink,
    );
    expect(
      _iconColor(tester, 'player-action-volume', Icons.volume_up_outlined),
      ink,
    );
    expect(tester.takeException(), isNull);
  });
}

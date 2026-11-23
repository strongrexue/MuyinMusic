import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/icons/icons.dart' as prism_glyph;

import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/core/ui/app_toast.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/player/player_controller.dart';
import 'package:cy_shine_music/features/player/lyric_parser.dart';
import 'package:cy_shine_music/features/player/player_page.dart';
import 'package:cy_shine_music/features/player/sleep_timer_controller.dart';
import 'package:cy_shine_music/features/player/widgets/album_cluster.dart';
import 'package:cy_shine_music/features/player/widgets/immersive_background.dart';
import 'package:cy_shine_music/features/player/widgets/karaoke_line_text.dart';
import 'package:cy_shine_music/features/player/widgets/karaoke_lyrics_view.dart';
import 'package:cy_shine_music/features/player/widgets/ktv_lyrics_view.dart';
import 'package:cy_shine_music/features/player/widgets/lyric_line.dart';
import 'package:cy_shine_music/features/player/widgets/lyrics_panel.dart';
import 'package:cy_shine_music/features/player/widgets/playback_queue_sheet.dart';
import 'package:cy_shine_music/features/player/widgets/player_action_row.dart';
import 'package:cy_shine_music/features/player/widgets/player_control_color.dart';
import 'package:cy_shine_music/features/player/widgets/spinning_cover_art.dart';
import 'package:cy_shine_music/features/player/widgets/top_chrome_row.dart';
import 'package:cy_shine_music/features/player/widgets/transport_bar.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/shell/shell_route_utils.dart';
import 'package:cy_shine_music/router.dart';

import 'helpers/prism_test_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('system back from debug returns to debug settings', (
    tester,
  ) async {
    final harness = await _pumpRoutedApp(tester, initialLocation: '/debug');

    expect(harness.router.routeInformationProvider.value.uri.path, '/debug');
    expect(await tester.binding.handlePopRoute(), isTrue);
    await _pumpUi(tester);

    expect(
      harness.router.routeInformationProvider.value.uri.path,
      '/settings/debug',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('music sources remains a valid player return location', (
    tester,
  ) async {
    expect(
      normalizedPlayerReturnLocation('/settings/sources', '/songs'),
      '/settings/sources',
    );

    final harness = await _pumpRoutedApp(tester, initialLocation: '/songs');
    harness.router.go('/player', extra: '/settings/sources');
    await _pumpUi(tester);

    final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(player.active, isTrue);
    expect(player.returnLocation, '/settings/sources');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact remote player shows quality in the top bar and menus for actions',
    (tester) async {
      final controller = await _pumpPlayer(
        tester,
        size: const Size(390, 844),
        currentMusic: _remoteMusic(),
        track: const PlayerTrack(
          id: 'tx:remote-song',
          kind: PlayerTrackKind.remote,
          title: '窄屏在线歌曲',
          artist: '不应在封面下重复的歌手',
          album: '测试专辑',
          sourceLabel: 'QQ',
          qualityLabel: '320k',
          availableQualityOptions: [
            QualityOption(type: Quality.k320, size: '9.48 MB'),
            QualityOption(type: Quality.k192),
            QualityOption(type: Quality.k128, size: '3.82 MB'),
          ],
          remoteUrl: 'https://audio.example/remote-song.mp3',
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerPage)),
      );
      final playlist = await container
          .read(localPlaylistsProvider.notifier)
          .create('在线收藏');
      final music = _remoteMusic();

      expect(
        find.byKey(const ValueKey('player-compact-pager')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('player-wide-layout')), findsNothing);
      expect(find.byType(PageView), findsOneWidget);
      final pager = find.byKey(const ValueKey('player-compact-pager'));
      expect(
        find.byKey(const ValueKey('player-compact-pager-edge-guard')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-compact-album-clip')),
        findsOneWidget,
      );
      expect(tester.widget<PageView>(pager).clipBehavior, Clip.hardEdge);
      final edgeNotification = OverscrollIndicatorNotification(leading: false);
      edgeNotification.dispatch(tester.element(pager));
      expect(edgeNotification.accepted, isFalse);

      // Track metadata belongs to the header on every compact page and must
      // not be repeated below the cover.
      expect(find.text('窄屏在线歌曲'), findsOneWidget);
      expect(find.text('不应在封面下重复的歌手'), findsOneWidget);
      final title = tester.widget<Text>(
        find.byKey(const ValueKey('player-header-title')),
      );
      final artist = tester.widget<Text>(
        find.byKey(const ValueKey('player-header-artist')),
      );
      expect(title.style?.fontWeight, FontWeight.w500);
      expect(artist.style?.fontSize, lessThan(title.style!.fontSize!));
      expect(artist.style?.fontWeight, FontWeight.w400);

      expect(find.byKey(const ValueKey('player-source-chip')), findsNothing);
      // The source and the quality share one tappable label that opens the
      // quality popup.
      final qualityEntry = find.byKey(
        const ValueKey('player-quality-entry-label'),
      );
      expect(tester.widget<Text>(qualityEntry).data, 'QQ 320K');

      // The cover only toggles its artwork shape; the actions moved into the
      // row above the transport bar.
      expect(
        find.byKey(const ValueKey('player-cover-menu-button')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('player-cover-toggle-button')),
        findsOneWidget,
      );
      for (final key in [
        'player-action-lyric-settings',
        'player-action-like',
        'player-action-playlist',
        'player-action-download',
        'player-action-volume',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(_actionEnabled(tester, 'player-action-playlist'), isTrue);
      expect(_actionEnabled(tester, 'player-action-download'), isTrue);

      await tester.tap(find.byKey(const ValueKey('player-action-playlist')));
      await _pumpUi(tester);

      expect(find.byKey(const ValueKey('playlist-add-popup')), findsOneWidget);
      await tester.tap(find.text('在线收藏'));
      await _pumpUi(tester);

      final storedPlaylist = container
          .read(localPlaylistsProvider)
          .singleWhere((candidate) => candidate.id == playlist.id);
      expect(storedPlaylist.tracks, hasLength(1));
      final storedTrack = storedPlaylist.tracks.single;
      expect(storedTrack.musicId, music.id);
      expect(storedTrack.name, music.name);
      expect(storedTrack.singer, music.singer);
      expect(storedTrack.albumName, music.albumName);
      expect(storedTrack.source, music.source);
      expect(storedTrack.qualityCode, music.bestQuality.code);
      expect(storedTrack.localPath, isNull);
      expect(storedTrack.picUrl, music.meta.picUrl);
      expect(storedTrack.musicJson, music.toJson());
      expect(storedTrack.musicInfo?.toJson(), music.toJson());

      // Picking a playlist dismisses the picker and lands back on the player.
      expect(find.text('添加到歌单'), findsNothing);
      expect(find.byKey(const ValueKey('playlist-add-popup')), findsNothing);
      expect(
        find.byKey(const ValueKey('player-compact-pager')),
        findsOneWidget,
      );
      // Quality lives in the top bar entry, not in any cover menu.
      await tester.tap(find.byKey(const ValueKey('player-quality-entry')));
      await _pumpUi(tester);

      expect(
        find.byKey(const ValueKey('player-quality-popup')),
        findsOneWidget,
      );
      expect(find.text('9.48 MB'), findsOneWidget);
      expect(find.text('文件大小未知'), findsNothing);
      expect(find.text('较高品质 192K'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-quality-option-192k')),
        findsOneWidget,
      );
      expect(find.text('3.82 MB'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('player-quality-option-128k')),
      );
      await _pumpUi(tester);

      expect(controller.switchedQuality, Quality.k128);
      expect(find.byKey(const ValueKey('player-quality-popup')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact local player disables inapplicable actions', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'local:test-song',
        kind: PlayerTrackKind.localFile,
        title: '窄屏本地歌曲',
        artist: '本地歌手',
        album: '本地专辑',
        sourceLabel: 'QQ',
        qualityLabel: 'FLAC',
        localPath: 'test-song.flac',
      ),
    );

    expect(find.text('窄屏本地歌曲'), findsOneWidget);
    expect(find.text('本地歌手'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-source-chip')), findsNothing);

    // Local files have nothing to switch to, so the top-bar quality entry is
    // inert and tapping it must not open the sheet.
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('player-quality-entry-label')),
          )
          .data,
      'QQ FLAC',
    );
    await tester.tap(find.byKey(const ValueKey('player-quality-entry')));
    await _pumpUi(tester);
    expect(find.byKey(const ValueKey('player-quality-popup')), findsNothing);

    // Local files have nothing to add to a playlist or download, so those
    // actions are disabled while the lyric one stays usable. The like action
    // needs song metadata, and this bare seeded track carries none.
    expect(_actionEnabled(tester, 'player-action-playlist'), isFalse);
    expect(_actionEnabled(tester, 'player-action-download'), isFalse);
    expect(_actionEnabled(tester, 'player-action-lyric-settings'), isTrue);
    expect(_actionEnabled(tester, 'player-action-like'), isFalse);
    expect(
      find.byKey(const ValueKey('player-cover-toggle-button')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact top bar opens the equalizer instead of the song list', (
    tester,
  ) async {
    final destinations = <String?>[];
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'tx:equalizer-entry',
        kind: PlayerTrackKind.remote,
        title: '迷你歌词测试',
        artist: '测试歌手',
        album: '测试专辑',
        sourceLabel: 'QQ',
        qualityLabel: '320k',
      ),
      onDismissRequested: ([String? target]) => destinations.add(target),
    );

    final moreButton = find.byKey(const ValueKey('player-more-button'));
    expect(moreButton, findsOneWidget);
    expect(find.byTooltip('歌曲列表'), findsNothing);
    expect(find.byTooltip('更多'), findsOneWidget);

    await _pickTopBarMoreItem(tester, '均衡器');

    expect(
      find.byKey(const ValueKey('player-equalizer-popup')),
      findsOneWidget,
    );
    expect(destinations, isEmpty);

    await tester.tap(find.byKey(const ValueKey('player-equalizer-open-page')));
    await _pumpUi(tester);

    expect(destinations, ['/settings/equalizer']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait more menu has no background entry and shows cover', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'tx:no-portrait-background',
        kind: PlayerTrackKind.remote,
        title: '无背景入口测试',
        artist: '测试歌手',
        album: '测试专辑',
        sourceLabel: 'QQ',
        qualityLabel: '320k',
      ),
    );

    // The cover is always shown on the portrait cover page now that the
    // imported portrait background is gone.
    expect(
      find.byKey(const ValueKey('player-cover-toggle-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('player-more-button')));
    await _pumpUi(tester);
    expect(
      find.descendant(
        of: find.byType(prism.PopupMenu),
        matching: find.text('背景'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(prism.PopupMenu),
        matching: find.text('均衡器'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('sleep timer popup stepper starts a custom duration', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'tx:sleep-timer',
        kind: PlayerTrackKind.remote,
        title: '定时关闭',
        artist: '测试歌手',
        album: '测试专辑',
        sourceLabel: 'QQ',
        qualityLabel: '320k',
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerPage)),
    );
    expect(container.read(sleepTimerProvider), isNull);

    await _pickTopBarMoreItem(tester, '定时关闭');
    expect(
      find.byKey(const ValueKey('player-sleep-timer-popup')),
      findsOneWidget,
    );

    // Custom minutes expand an in-card stepper instead of covering the
    // player with the old full-screen sheet.
    await tester.tap(
      find.byKey(const ValueKey('player-sleep-timer-custom-entry')),
    );
    await _pumpUi(tester);
    expect(
      find.byKey(const ValueKey('player-sleep-timer-custom-entry')),
      findsNothing,
    );
    expect(_stepperMinutes(tester), '30 分钟');

    await tester.tap(find.byKey(const ValueKey('player-sleep-timer-plus')));
    await tester.tap(find.byKey(const ValueKey('player-sleep-timer-plus')));
    await _pumpUi(tester);
    expect(_stepperMinutes(tester), '40 分钟');

    await tester.tap(
      find.byKey(const ValueKey('player-sleep-timer-custom-start')),
    );
    await _pumpUi(tester);
    expect(
      find.byKey(const ValueKey('player-sleep-timer-popup')),
      findsNothing,
    );
    expect(container.read(sleepTimerProvider), const Duration(minutes: 40));

    // With a timer running the popup offers a cancel entry.
    await _pickTopBarMoreItem(tester, '定时关闭');
    await tester.tap(
      find.byKey(const ValueKey('player-sleep-timer-cancel-entry')),
    );
    await _pumpUi(tester);
    expect(container.read(sleepTimerProvider), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('top bar quality entry survives a very narrow viewport', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(360, 780),
      currentMusic: _remoteMusic(),
      track: const PlayerTrack(
        id: 'wy:narrow-song',
        kind: PlayerTrackKind.remote,
        title: '开关测试',
        artist: '测试歌手',
        album: '测试专辑',
        sourceLabel: '网易',
        qualityLabel: 'flac24bit',
        availableQualityOptions: [
          QualityOption(type: Quality.flac24bit, size: '38.4 MB'),
          QualityOption(type: Quality.k320, size: '9.48 MB'),
        ],
        remoteUrl: 'https://audio.example/narrow-song.flac',
      ),
    );

    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('player-quality-entry-label')),
          )
          .data,
      '网易 24bit',
    );
    expect(find.byKey(const ValueKey('player-more-button')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact mini lyrics show three lines, scroll, and open lyrics', (
    tester,
  ) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(startMs: 0, endMs: 3000, text: '宽屏第一句'),
      KaraokeLyricLine(startMs: 3000, endMs: 6000, text: '宽屏第二句'),
      KaraokeLyricLine(startMs: 6000, endMs: 9000, text: '宽屏第三句'),
      KaraokeLyricLine(startMs: 9000, endMs: 12000, text: '第四句歌词'),
    ]);
    final controller = await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'tx:mini-lyrics',
        kind: PlayerTrackKind.remote,
        title: '迷你歌词测试',
        artist: '测试歌手',
        album: '测试专辑',
        sourceLabel: 'QQ',
        qualityLabel: '320k',
      ),
      lyrics: lyrics,
      position: const Duration(milliseconds: 3500),
    );

    expect(find.byKey(const ValueKey('player-mini-lyrics')), findsOneWidget);
    expect(
      tester
          .widget<Material>(
            find.byKey(const ValueKey('player-mini-lyrics-surface')),
          )
          .color,
      Colors.transparent,
    );
    expect(
      find.byKey(const ValueKey('player-mini-lyric-line-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-mini-lyric-line-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-mini-lyric-line-2')),
      findsOneWidget,
    );
    final miniViewport = tester.getRect(
      find.byKey(const ValueKey('player-mini-lyrics-scroll')),
    );
    // The fourth line starts exactly at the viewport's bottom edge, so
    // it is either not built at all or entirely below the viewport.
    final fourthLine = find.byKey(const ValueKey('player-mini-lyric-line-3'));
    if (fourthLine.evaluate().isNotEmpty) {
      expect(
        tester.getRect(fourthLine).top,
        greaterThanOrEqualTo(miniViewport.bottom),
      );
    }
    // The active no-word-timing line is a LyricSweepLine (base +
    // accent layers); its base Text carries the line's metrics.
    final activeLineText = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey('player-mini-lyric-line-1')),
            matching: find.byType(Text),
          )
          .first,
    );
    expect(activeLineText.style?.fontWeight, FontWeight.w400);
    expect(activeLineText.style?.fontSize, 19);
    expect(
      tester
          .widget<ImageFiltered>(
            find.byKey(const ValueKey('player-mini-lyric-blur-1')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<ImageFiltered>(
            find.byKey(const ValueKey('player-mini-lyric-blur-0')),
          )
          .enabled,
      isTrue,
    );

    final miniScroll = find.descendant(
      of: find.byKey(const ValueKey('player-mini-lyrics-scroll')),
      matching: find.byType(Scrollable),
    );
    final scrollState = tester.state<ScrollableState>(miniScroll);
    expect(scrollState.position.pixels, 0);

    controller.setStateForTest(
      controller.state.copyWith(position: const Duration(milliseconds: 6500)),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 190));
    expect(scrollState.position.pixels, inExclusiveRange(0, 29));
    await tester.pumpAndSettle();
    expect(scrollState.position.pixels, closeTo(29, 0.01));
    expect(
      tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('player-mini-lyric-line-2')),
                  matching: find.byType(Text),
                )
                .first,
          )
          .style
          ?.fontSize,
      19,
    );
    expect(
      tester
          .widget<ImageFiltered>(
            find.byKey(const ValueKey('player-mini-lyric-blur-2')),
          )
          .enabled,
      isFalse,
    );

    final pageView = tester.widget<PageView>(
      find.byKey(const ValueKey('player-compact-pager')),
    );
    await tester.tap(find.byKey(const ValueKey('player-mini-lyrics')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(pageView.controller!.page, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(pageView.controller!.page, 1);
    expect(find.byType(KaraokeLyricsView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyric settings popup switch hides compact mini lyrics', (
    tester,
  ) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(startMs: 0, endMs: 3000, text: '第一句歌词'),
      KaraokeLyricLine(startMs: 3000, endMs: 6000, text: '第二句歌词'),
      KaraokeLyricLine(startMs: 6000, endMs: 9000, text: '第三句歌词'),
    ]);
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'tx:toggle-mini-lyrics',
        kind: PlayerTrackKind.remote,
        title: '开关测试',
        artist: '测试歌手',
        album: '测试专辑',
        sourceLabel: 'QQ',
        qualityLabel: '320k',
      ),
      lyrics: lyrics,
    );
    expect(find.byKey(const ValueKey('player-mini-lyrics')), findsOneWidget);
    final coverToggle = find.byKey(
      const ValueKey('player-cover-toggle-button'),
    );
    final coverTopWithMiniLyrics = tester.getTopLeft(coverToggle);

    await tester.tap(
      find.byKey(const ValueKey('player-action-lyric-settings')),
    );
    await _pumpUi(tester);

    // The anchored glass card stays open while its toggle applies live.
    final popup = find.byKey(const ValueKey('lyric-settings-popup'));
    expect(popup, findsOneWidget);
    expect(find.text('迷你歌词'), findsOneWidget);

    await tester.tap(find.text('迷你歌词'));
    await tester.pumpAndSettle();

    expect(popup, findsOneWidget);
    expect(find.byKey(const ValueKey('player-mini-lyrics')), findsNothing);
    final coverTopWithoutMiniLyrics = tester.getTopLeft(coverToggle);
    // The compact cover is top-anchored, so toggling mini lyrics no longer
    // shifts it (the old centered layout moved it by the 36dp lift).
    expect(coverTopWithoutMiniLyrics.dy - coverTopWithMiniLyrics.dy, 0);

    await tester.tapAt(const Offset(4, 4));
    await _pumpUi(tester);
    expect(popup, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ktv panel rolls to the active line as playback advances', (
    tester,
  ) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(startMs: 0, endMs: 3000, text: '第一行歌词'),
      KaraokeLyricLine(startMs: 3000, endMs: 6000, text: '第二行歌词'),
    ]);
    final controller = await _pumpKtvPanel(
      tester,
      const PlayerState(lyrics: lyrics),
    );

    expect(find.byType(KtvLyricsView), findsOneWidget);
    Finder bigLine(String text) => find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data == text &&
          (widget.style?.fontSize ?? 0) >= 36,
    );
    // The active line renders two layers (white base + accent sweep),
    // so its text legitimately appears more than once in the tree.
    expect(bigLine('第一行歌词'), findsWidgets);

    controller.setStateForTest(
      const PlayerState(lyrics: lyrics, position: Duration(seconds: 4)),
    );
    await _pumpUi(tester);
    await tester.pump(const Duration(milliseconds: 500));

    expect(bigLine('第二行歌词'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late audio readiness does not remount loaded lyrics', (
    tester,
  ) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(startMs: 0, endMs: 3000, text: '已经加载的歌词'),
    ]);
    final controller = await _pumpLyricsPanel(
      tester,
      const PlayerState(lyrics: lyrics),
    );
    final lyricsView = tester.element(find.byType(KaraokeLyricsView));

    controller.setStateForTest(
      const PlayerState(
        track: PlayerTrack(
          id: 'tx:late-audio:remote',
          kind: PlayerTrackKind.remote,
          title: '高音质歌曲',
          artist: '测试歌手',
          album: '测试专辑',
          sourceLabel: 'QQ',
          qualityLabel: 'hires',
          remoteUrl: 'https://audio.example/late.flac',
        ),
        lyrics: lyrics,
        duration: Duration(minutes: 4),
      ),
    );
    await tester.pump();

    expect(find.byType(KaraokeLyricsView), findsOneWidget);
    expect(tester.element(find.byType(KaraokeLyricsView)), same(lyricsView));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyrics keep their fade but drop it before a pager drag', (
    tester,
  ) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(startMs: 0, endMs: 3000, text: '第一句歌词'),
      KaraokeLyricLine(startMs: 3000, endMs: 6000, text: '第二句歌词'),
      KaraokeLyricLine(startMs: 6000, endMs: 9000, text: '第三句歌词'),
    ]);
    final controller = await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'tx:lyrics-edge-fade',
        kind: PlayerTrackKind.remote,
        title: '歌词边缘测试',
        artist: '测试歌手',
        album: '测试专辑',
        sourceLabel: 'QQ',
        qualityLabel: '320k',
        remoteUrl: 'https://audio.example/lyrics-edge-fade.mp3',
      ),
      lyrics: lyrics,
    );
    await tester.drag(
      find.byKey(const ValueKey('player-compact-pager')),
      const Offset(-360, 0),
    );
    await _pumpUi(tester);

    final viewport = find.byType(KaraokeLyricsView);
    final edgeFade = find.byKey(const ValueKey('karaoke-lyrics-edge-fade'));
    final list = find.byKey(const ValueKey('karaoke-lyrics-list'));
    expect(
      find.byKey(const ValueKey('player-compact-lyrics-clip')),
      findsOneWidget,
    );
    expect(edgeFade, findsOneWidget);
    expect(list, findsOneWidget);
    expect(tester.getRect(edgeFade), tester.getRect(viewport));
    expect(tester.getRect(list), tester.getRect(viewport));
    final fadeRenderObject = tester.renderObject<RenderBox>(edgeFade);
    final lyricsListElement = tester.element(list);
    // The shared lyrics view wraps its list in its own
    // ScrollConfiguration hiding the platform scrollbar (the desktop
    // bar on the panel's edge): the wrap sits inside the view, and
    // the list's effective behaviour returns content from
    // buildScrollbar unwrapped instead of adding a Scrollbar.
    expect(
      find.descendant(of: viewport, matching: find.byType(ScrollConfiguration)),
      findsOneWidget,
    );
    const marker = SizedBox();
    expect(
      identical(
        ScrollConfiguration.of(lyricsListElement).buildScrollbar(
          lyricsListElement,
          marker,
          const ScrollableDetails.vertical(),
        ),
        marker,
      ),
      isTrue,
    );
    expect(
      tester.widget<LyricsPanel>(find.byType(LyricsPanel)).edgeFadeEnabled,
      isTrue,
    );
    expect(
      find.descendant(of: viewport, matching: find.byType(ImageFiltered)),
      findsWidgets,
    );

    final gesture = await tester.startGesture(tester.getCenter(viewport));
    await tester.pump();
    expect(edgeFade, findsOneWidget);
    await gesture.moveBy(const Offset(8, 0));
    await tester.pump();
    expect(edgeFade, findsOneWidget);
    expect(tester.renderObject<RenderBox>(edgeFade), same(fadeRenderObject));
    expect(tester.element(list), same(lyricsListElement));
    expect(
      tester.widget<LyricsPanel>(find.byType(LyricsPanel)).edgeFadeEnabled,
      isFalse,
    );
    await gesture.moveBy(const Offset(72, 0));
    await tester.pump();
    expect(tester.element(list), same(lyricsListElement));
    expect(
      tester.widget<LyricsPanel>(find.byType(LyricsPanel)).edgeFadeEnabled,
      isFalse,
    );
    controller.setStateForTest(
      controller.state.copyWith(position: const Duration(milliseconds: 3500)),
    );
    await tester.pump();
    expect(tester.element(list), same(lyricsListElement));
    expect(
      tester.widget<LyricsPanel>(find.byType(LyricsPanel)).edgeFadeEnabled,
      isFalse,
    );
    await gesture.up();
    await _pumpUi(tester);
    expect(edgeFade, findsOneWidget);
    expect(tester.renderObject<RenderBox>(edgeFade), same(fadeRenderObject));
    expect(tester.element(list), same(lyricsListElement));
    expect(
      tester.widget<LyricsPanel>(find.byType(LyricsPanel)).edgeFadeEnabled,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'lyrics keep the current-line scroll position across page swipes',
    (tester) async {
      final lyrics = _timedLyrics(14);
      await _pumpPlayer(
        tester,
        size: const Size(390, 844),
        track: const PlayerTrack(
          id: 'tx:lyrics-page-position',
          kind: PlayerTrackKind.remote,
          title: '歌词位置测试',
          artist: '测试歌手',
          album: '测试专辑',
          sourceLabel: 'QQ',
          qualityLabel: '320k',
        ),
        lyrics: lyrics,
        position: const Duration(milliseconds: 18000),
      );
      final pager = find.byKey(const ValueKey('player-compact-pager'));
      await tester.drag(pager, const Offset(-360, 0));
      await _pumpUi(tester);

      final scrollPosition = _lyricsScrollPosition(tester);
      final initialOffset = scrollPosition.pixels;
      expect(initialOffset, greaterThan(0));

      await tester.drag(pager, const Offset(360, 0));
      await _pumpUi(tester);
      await tester.drag(pager, const Offset(-360, 0));
      await _pumpUi(tester);

      final restoredPosition = _lyricsScrollPosition(tester);
      expect(restoredPosition.pixels, greaterThan(0));
      expect(restoredPosition.pixels, closeTo(initialOffset, 0.01));
      expect(
        find.byKey(const ValueKey('lyric-focus-scale-18000')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('lyric stagger keeps the relocated scroll offset stable', (
    tester,
  ) async {
    final lyrics = _timedLyrics(14);
    final controller = await _pumpLyricsPanel(
      tester,
      PlayerState(
        lyrics: lyrics,
        position: const Duration(milliseconds: 15000),
      ),
    );
    final scrollPosition = _lyricsScrollPosition(tester);
    final initialOffset = scrollPosition.pixels;

    expect(_lyricFocusScale(tester, 15000), closeTo(1, 0.0001));
    expect(_lyricFocusScale(tester, 18000), closeTo(0.95, 0.0001));

    controller.setStateForTest(
      controller.state.copyWith(position: const Duration(milliseconds: 18000)),
    );
    await tester.pump();
    await tester.pump();

    final relocatedOffset = scrollPosition.pixels;
    expect(relocatedOffset, isNot(closeTo(initialOffset, 0.01)));

    for (final interval in const [
      Duration(milliseconds: 100),
      Duration(milliseconds: 150),
      Duration(milliseconds: 200),
      Duration(milliseconds: 250),
    ]) {
      await tester.pump(interval);
      expect(scrollPosition.pixels, closeTo(relocatedOffset, 0.001));
    }

    expect(_lyricFocusScale(tester, 15000), closeTo(0.95, 0.0001));
    expect(_lyricFocusScale(tester, 18000), closeTo(1, 0.0001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('word-timed lyric keeps its layout height across focus changes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    const longLine = KaraokeLyricLine(
      startMs: 3000,
      endMs: 6000,
      text: '春风穿过旧山河星光落在长街上我们走向晨曦里月色停在窗台前',
      words: [
        KaraokeWordTiming(text: '春风穿过旧山河', startMs: 3000, endMs: 3700),
        KaraokeWordTiming(text: '星光落在长街上', startMs: 3700, endMs: 4400),
        KaraokeWordTiming(text: '我们走向晨曦里', startMs: 4400, endMs: 5100),
        KaraokeWordTiming(text: '月色停在窗台前', startMs: 5100, endMs: 5800),
      ],
    );
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(startMs: 0, endMs: 3000, text: '前一句'),
      longLine,
      KaraokeLyricLine(startMs: 6000, endMs: 9000, text: '后一句'),
    ]);
    final controller = await _pumpLyricsPanel(
      tester,
      const PlayerState(lyrics: lyrics),
    );
    final longLineFinder = find.byKey(const ValueKey('lyric-stagger-3000'));
    final inactiveHeight = tester.getSize(longLineFinder).height;
    expect(inactiveHeight, greaterThan(100));

    controller.setStateForTest(
      controller.state.copyWith(position: const Duration(milliseconds: 3500)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(
      tester.getSize(longLineFinder).height,
      closeTo(inactiveHeight, 0.001),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('word progress keeps elapsed time when a new line activates', (
    tester,
  ) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(
        startMs: 0,
        endMs: 1000,
        text: '前一句',
        words: [KaraokeWordTiming(text: '前一句', startMs: 0, endMs: 1000)],
      ),
      KaraokeLyricLine(
        startMs: 1000,
        endMs: 3000,
        text: '新一句',
        words: [KaraokeWordTiming(text: '新一句', startMs: 1000, endMs: 2000)],
      ),
    ]);
    final controller = await _pumpLyricsPanel(
      tester,
      const PlayerState(lyrics: lyrics, position: Duration(milliseconds: 990)),
    );

    controller.setStateForTest(controller.state.copyWith(playing: true));
    await tester.pump();
    // No position anchor is published here. The line-advance timer activates
    // the second row from wall-clock elapsed time after the 990 ms anchor.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(_activeWordProgress(tester, 1000), greaterThan(0.02));
    expect(tester.takeException(), isNull);
  });

  testWidgets('word progress pauses while buffering and resumes afterwards', (
    tester,
  ) async {
    const lyrics = KaraokeLyrics([
      KaraokeLyricLine(
        startMs: 0,
        endMs: 6000,
        text: '缓冲中的逐字歌词',
        words: [KaraokeWordTiming(text: '缓冲中的逐字歌词', startMs: 0, endMs: 5000)],
      ),
    ]);
    final controller = await _pumpLyricsPanel(
      tester,
      const PlayerState(lyrics: lyrics, position: Duration(milliseconds: 1000)),
    );

    controller.setStateForTest(controller.state.copyWith(playing: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    controller.setStateForTest(
      controller.state.copyWith(
        position: const Duration(milliseconds: 1200),
        processingState: PlayerProcessingState.buffering,
      ),
    );
    await tester.pump();

    final bufferedProgress = _activeWordProgress(tester, 0);
    expect(bufferedProgress, closeTo(0.24, 0.001));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(_activeWordProgress(tester, 0), closeTo(bufferedProgress, 0.0001));

    controller.setStateForTest(
      controller.state.copyWith(processingState: PlayerProcessingState.ready),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(
      _activeWordProgress(tester, 0),
      greaterThan(bufferedProgress + 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('large landscape player uses the floating split layout', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(1024, 600),
      track: const PlayerTrack(
        id: 'wy:wide-song',
        kind: PlayerTrackKind.remote,
        title: '宽屏歌曲',
        artist: '宽屏歌手',
        album: '宽屏专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/wide-song.flac',
      ),
      lyrics: const KaraokeLyrics([
        KaraokeLyricLine(startMs: 0, endMs: 3000, text: '宽屏第一句'),
        KaraokeLyricLine(startMs: 3000, endMs: 6000, text: '宽屏第二句'),
        KaraokeLyricLine(startMs: 6000, endMs: 9000, text: '宽屏第三句'),
      ]),
    );

    // Landscape no longer has a separate wide layout: every landscape
    // size uses the floating split (cover left, lyrics right, unified
    // bottom transport floating over the same plane).
    expect(
      find.byKey(const ValueKey('player-phone-landscape-layout')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('player-wide-layout')), findsNothing);
    expect(find.byKey(const ValueKey('player-compact-pager')), findsNothing);
    expect(find.byType(PageView), findsNothing);
    expect(find.byType(AlbumPage), findsOneWidget);
    expect(find.byType(LyricsPanel), findsOneWidget);
    expect(find.byKey(const ValueKey('player-mini-lyrics')), findsNothing);
    expect(find.byKey(const ValueKey('player-action-volume')), findsOneWidget);
    // The cover is sized by proportion, not by its area: half the
    // 600dp short side.
    final coverRect = tester.getRect(
      find.byKey(const ValueKey('player-cover-toggle-button')),
    );
    expect(coverRect.width, closeTo(300, 0.6));
    expect(coverRect.height, closeTo(300, 0.6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone landscape player uses split layout without pager', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(915, 412),
      track: const PlayerTrack(
        id: 'wy:phone-landscape-song',
        kind: PlayerTrackKind.remote,
        title: '横屏歌曲',
        artist: '横屏歌手',
        album: '横屏专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/phone-landscape-song.flac',
      ),
      lyrics: const KaraokeLyrics([
        KaraokeLyricLine(startMs: 0, endMs: 3000, text: '横屏第一句'),
        KaraokeLyricLine(startMs: 3000, endMs: 6000, text: '横屏第二句'),
        KaraokeLyricLine(startMs: 6000, endMs: 9000, text: '横屏第三句'),
      ]),
    );

    expect(
      find.byKey(const ValueKey('player-phone-landscape-layout')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('player-wide-layout')), findsNothing);
    expect(find.byKey(const ValueKey('player-compact-pager')), findsNothing);
    expect(find.byType(PageView), findsNothing);
    expect(find.byType(AlbumPage), findsOneWidget);
    expect(find.byType(LyricsPanel), findsOneWidget);
    expect(find.byKey(const ValueKey('player-action-volume')), findsOneWidget);
    final albumRect = tester.getRect(
      find.byKey(const ValueKey('player-phone-landscape-album')),
    );
    final coverRect = tester.getRect(
      find.byKey(const ValueKey('player-cover-toggle-button')),
    );

    // The bottom stack floats over the plane: a slim progress line,
    // then one control row holding all ten buttons as a single
    // centred group. There is no standalone full-width action row in
    // this layout.
    expect(find.byType(PlayerActionRow), findsNWidgets(2));
    for (final key in [
      'player-action-lyric-settings',
      'player-action-playlist',
      'player-action-download',
      'player-action-like',
      'player-action-volume',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    final progressRect = tester.getRect(
      find.byKey(const ValueKey('player-phone-landscape-progress')),
    );
    final controlsRect = tester.getRect(
      find.byKey(const ValueKey('player-phone-landscape-controls')),
    );
    final layoutRect = tester.getRect(
      find.byKey(const ValueKey('player-phone-landscape-layout')),
    );
    final lyricsRect = tester.getRect(
      find.byKey(const ValueKey('player-phone-landscape-lyrics')),
    );
    // Single plane: the album and lyrics areas span the layout's full
    // height (the top chrome floats over them instead of taking a band
    // of its own), and the merged bottom stack floats over the same
    // plane, far slimmer than the old action row + transport bar
    // combination.
    expect(albumRect.top, closeTo(layoutRect.top, 0.5));
    expect(albumRect.bottom, closeTo(layoutRect.bottom, 0.5));
    expect(lyricsRect.top, closeTo(layoutRect.top, 0.5));
    expect(lyricsRect.bottom, closeTo(layoutRect.bottom, 0.5));
    expect(progressRect.bottom, lessThanOrEqualTo(controlsRect.top));
    expect(controlsRect.height - progressRect.height, greaterThan(0));
    expect(controlsRect.bottom - progressRect.top, lessThan(110));
    expect(layoutRect.bottom - controlsRect.bottom, closeTo(12, 1));
    // Transport cluster lives inside the merged control row.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('player-phone-landscape-controls')),
        matching: find.byType(TransportBar),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('上一首'), findsOneWidget);
    expect(find.byTooltip('下一首'), findsOneWidget);
    expect(find.byType(PlaybackQueueButton), findsOneWidget);
    // The merged control row is one centred group on a shared pitch:
    // all ten buttons share one row and one button series, with the
    // play button one tier larger.
    final controls = find.byKey(
      const ValueKey('player-phone-landscape-controls'),
    );
    Finder inControls(Finder matching) =>
        find.descendant(of: controls, matching: matching);
    final modeIcon = inControls(
      find.byIcon(Icons.format_list_numbered_rounded),
    );
    final playIcon = inControls(find.byIcon(Icons.play_arrow_rounded));
    final prevIcon = inControls(find.byIcon(Icons.skip_previous_rounded));
    final nextIcon = inControls(find.byIcon(Icons.skip_next_rounded));
    final buttonFinders = <Finder>[
      find.byKey(const ValueKey('player-action-lyric-settings')),
      find.byKey(const ValueKey('player-action-playlist')),
      find.byKey(const ValueKey('player-action-download')),
      find.ancestor(of: modeIcon, matching: find.byType(IconButton)),
      find.ancestor(of: prevIcon, matching: find.byType(IconButton)),
      find.ancestor(of: playIcon, matching: find.byType(InkWell)),
      find.ancestor(of: nextIcon, matching: find.byType(IconButton)),
      inControls(find.byType(PlaybackQueueButton)),
      find.byKey(const ValueKey('player-action-like')),
      find.byKey(const ValueKey('player-action-volume')),
    ];
    final centers = [
      for (final finder in buttonFinders) tester.getCenter(finder),
    ];
    // One row: every centre shares the same y.
    for (final center in centers) {
      expect(center.dy, closeTo(centers.first.dy, 1));
    }
    // Uniform pitch between neighbouring centres.
    for (var i = 1; i < centers.length; i++) {
      expect(
        centers[i].dx - centers[i - 1].dx,
        closeTo(62, 2),
        reason: 'pitch ${i - 1}->$i',
      );
    }
    // The group is centred against the 915dp-wide screen: the first
    // button's left edge (its centre minus half of the 48dp target)
    // mirrors the last button's right edge.
    final leftMargin = centers.first.dx - 24;
    final rightMargin = 915 - (centers.last.dx + 24);
    expect((leftMargin - rightMargin).abs(), lessThanOrEqualTo(4));
    // One series: normal buttons are 48dp targets, play is 72dp.
    for (var i = 0; i < buttonFinders.length; i++) {
      final rect = tester.getRect(buttonFinders[i]);
      final side = i == 5 ? 72.0 : 48.0;
      expect(rect.width, closeTo(side, 1), reason: 'button $i width');
      expect(rect.height, closeTo(side, 1), reason: 'button $i height');
    }
    // One glyph size for every normal button; the play glyph is larger.
    double materialGlyph(Finder finder) => tester.widget<Icon>(finder).size!;
    double prismGlyph(String key) => tester
        .widget<prism_glyph.GlyphIcon>(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(prism_glyph.GlyphIcon),
          ),
        )
        .size!;
    expect(prismGlyph('player-action-lyric-settings'), 26);
    expect(prismGlyph('player-action-playlist'), 26);
    expect(prismGlyph('player-action-download'), 26);
    expect(materialGlyph(modeIcon), 26);
    expect(materialGlyph(prevIcon), 26);
    expect(materialGlyph(nextIcon), 26);
    expect(
      materialGlyph(inControls(find.byIcon(Icons.queue_music_rounded))),
      26,
    );
    expect(
      materialGlyph(
        find.descendant(
          of: find.byKey(const ValueKey('player-action-like')),
          matching: find.byType(Icon),
        ),
      ),
      26,
    );
    expect(
      materialGlyph(
        find.descendant(
          of: find.byKey(const ValueKey('player-action-volume')),
          matching: find.byType(Icon),
        ),
      ),
      26,
    );
    expect(materialGlyph(playIcon), 56);
    expect(materialGlyph(playIcon), greaterThan(26));

    // The cover sits inside its column: no part of it is scrolled or
    // clipped out of the album area. Its vertical centre band runs
    // from below the floating top chrome to the floating bottom
    // stack, so the cover's bottom edge never reaches the progress
    // line and its top edge never slides under the title row.
    expect(coverRect.top, greaterThanOrEqualTo(albumRect.top - 0.5));
    expect(coverRect.top, greaterThanOrEqualTo(albumRect.top + 60 - 0.5));
    expect(coverRect.bottom, lessThanOrEqualTo(albumRect.bottom + 0.5));
    expect(coverRect.bottom, lessThanOrEqualTo(progressRect.top + 0.5));
    expect(
      coverRect.center.dy,
      closeTo((albumRect.top + 60 + progressRect.top) / 2, 0.6),
    );
    // The side follows the proportion rule — half the 412dp short
    // side — not the album area's extent.
    expect(coverRect.width, closeTo(206, 0.6));
    expect(coverRect.height, closeTo(206, 0.6));
    // The album-name line is not rendered in this layout.
    expect(find.text('横屏专辑'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone landscape square cover also fits without album line', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'square_album_cover_enabled': true,
    });
    await _pumpPlayer(
      tester,
      size: const Size(915, 412),
      track: const PlayerTrack(
        id: 'wy:phone-landscape-square-song',
        kind: PlayerTrackKind.remote,
        title: '横屏方封面歌曲',
        artist: '横屏歌手',
        album: '横屏方专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/phone-landscape-square.flac',
      ),
    );

    final albumRect = tester.getRect(
      find.byKey(const ValueKey('player-phone-landscape-album')),
    );
    final coverRect = tester.getRect(
      find.byKey(const ValueKey('player-cover-toggle-button')),
    );
    final progressRect = tester.getRect(
      find.byKey(const ValueKey('player-phone-landscape-progress')),
    );
    expect(coverRect.top, greaterThanOrEqualTo(albumRect.top - 0.5));
    expect(coverRect.top, greaterThanOrEqualTo(albumRect.top + 60 - 0.5));
    expect(coverRect.bottom, lessThanOrEqualTo(albumRect.bottom + 0.5));
    // Same centre band as the disc: the square cover's bottom edge
    // also stays above the floating progress line.
    expect(coverRect.bottom, lessThanOrEqualTo(progressRect.top + 0.5));
    // Square covers follow the same proportion rule as the disc in
    // this layout: half the 412dp short side (206 here), with no
    // extra square scale on top.
    expect(coverRect.width, closeTo(206, 0.6));
    expect(coverRect.height, closeTo(206, 0.6));
    expect(find.text('横屏方专辑'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone landscape cover follows the proportion on large screens', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(1280, 800),
      track: const PlayerTrack(
        id: 'wy:phone-landscape-large-song',
        kind: PlayerTrackKind.remote,
        title: '大屏横屏歌曲',
        artist: '大屏横屏歌手',
        album: '大屏横屏专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/phone-landscape-large.flac',
      ),
    );

    expect(
      find.byKey(const ValueKey('player-phone-landscape-layout')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('player-wide-layout')), findsNothing);
    final albumRect = tester.getRect(
      find.byKey(const ValueKey('player-phone-landscape-album')),
    );
    final coverRect = tester.getRect(
      find.byKey(const ValueKey('player-cover-toggle-button')),
    );
    // The cover follows the same proportion rule as on phones: half
    // the 800dp short side (400), even though the album area could
    // fit far more. Nothing is scrolled or clipped out of the album
    // area.
    expect(coverRect.width, closeTo(400, 0.6));
    expect(coverRect.height, closeTo(400, 0.6));
    expect(coverRect.left, greaterThanOrEqualTo(albumRect.left - 0.5));
    expect(coverRect.right, lessThanOrEqualTo(albumRect.right + 0.5));
    expect(coverRect.top, greaterThanOrEqualTo(albumRect.top - 0.5));
    expect(coverRect.bottom, lessThanOrEqualTo(albumRect.bottom + 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop landscape cover follows the same proportion', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(1500, 844),
      track: const PlayerTrack(
        id: 'wy:phone-landscape-desktop-song',
        kind: PlayerTrackKind.remote,
        title: '桌面横屏歌曲',
        artist: '桌面横屏歌手',
        album: '桌面横屏专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/phone-landscape-desktop.flac',
      ),
    );

    expect(
      find.byKey(const ValueKey('player-phone-landscape-layout')),
      findsOneWidget,
    );
    final coverRect = tester.getRect(
      find.byKey(const ValueKey('player-cover-toggle-button')),
    );
    // Half the 844dp short side: the proportion, not the area,
    // decides at desktop sizes too.
    expect(coverRect.width, closeTo(422, 0.6));
    expect(coverRect.height, closeTo(422, 0.6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait player never uses the phone landscape layout', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'wy:portrait-song',
        kind: PlayerTrackKind.remote,
        title: '竖屏歌曲',
        artist: '竖屏歌手',
        album: '竖屏专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/portrait-song.flac',
      ),
    );

    expect(
      find.byKey(const ValueKey('player-phone-landscape-layout')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('player-wide-layout')), findsNothing);
    expect(find.byKey(const ValueKey('player-compact-pager')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large portrait player stays on the compact pager', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(1024, 1366),
      track: const PlayerTrack(
        id: 'wy:large-portrait-song',
        kind: PlayerTrackKind.remote,
        title: '大屏竖屏歌曲',
        artist: '大屏竖屏歌手',
        album: '大屏竖屏专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/large-portrait-song.flac',
      ),
    );

    // Portrait is compact at every size now: no wide split, no
    // landscape split, just the cover/lyrics pager.
    expect(find.byKey(const ValueKey('player-compact-pager')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-phone-landscape-layout')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('player-wide-layout')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large portrait square cover folds into the integrated background',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'square_album_cover_enabled': true,
      });
      final coverBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAN0lEQVR4nO3QQREAMAgDQYoKZCGxTstUBZ+Ngcvsqb4vFpebcQcIECBAgAABAgQIECBAgACBLzDAagJHFpD83wAAAABJRU5ErkJggg==',
      );
      await _pumpPlayer(
        tester,
        size: const Size(1024, 1366),
        track: PlayerTrack(
          id: 'wy:large-portrait-poster-song',
          kind: PlayerTrackKind.remote,
          title: '大屏竖屏海报歌曲',
          artist: '大屏竖屏海报歌手',
          album: '大屏竖屏海报专辑',
          sourceLabel: '网易',
          qualityLabel: '无损',
          remoteUrl: 'https://audio.example/large-portrait-poster.flac',
          coverBytes: coverBytes,
        ),
        lyrics: _timedLyrics(5),
      );

      // Nothing gates the integrated artwork on large portrait screens
      // any more: it spans the full width from the top, square as the
      // cover itself.
      final artwork = find.byKey(
        const ValueKey('player-integrated-bg-artwork'),
      );
      expect(artwork, findsOneWidget);
      final artworkRect = tester.getRect(artwork);
      expect(artworkRect.left, closeTo(0, 0.5));
      expect(artworkRect.top, closeTo(0, 0.5));
      expect(artworkRect.width, closeTo(1024, 0.5));
      expect(artworkRect.height, closeTo(1024, 0.5));
      expect(find.byKey(const ValueKey('player-compact-pager')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('portrait square cover folds into the integrated background', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'square_album_cover_enabled': true,
    });
    // A dark 48x48 cover (rgb 24, 80, 160) carried by the track itself,
    // so the integrated background carries the cover itself.
    final coverBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAN0lEQVR4nO3QQREAMAgDQYoKZCGxTstUBZ+Ngcvsqb4vFpebcQcIECBAgAABAgQIECBAgACBLzDAagJHFpD83wAAAABJRU5ErkJggg==',
    );
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: PlayerTrack(
        id: 'wy:portrait-poster-song',
        kind: PlayerTrackKind.remote,
        title: '竖屏海报歌曲',
        artist: '竖屏海报歌手',
        album: '竖屏海报专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/portrait-poster.flac',
        coverBytes: coverBytes,
      ),
      lyrics: _timedLyrics(5),
    );

    // No standalone poster layer remains on the cover page.
    expect(find.byKey(const ValueKey('player-portrait-poster')), findsNothing);
    // The cover is part of the background: full-bleed from the very top
    // of the screen, behind the status bar and the top chrome.
    final artwork = find.byKey(const ValueKey('player-integrated-bg-artwork'));
    expect(artwork, findsOneWidget);
    final artworkRect = tester.getRect(artwork);
    expect(artworkRect.left, closeTo(0, 0.5));
    expect(artworkRect.top, closeTo(0, 0.5));
    expect(artworkRect.width, closeTo(390, 0.5));
    // The artwork keeps its native square aspect: exactly as tall as it
    // is wide, so no side of the cover is cropped away.
    expect(artworkRect.height, closeTo(390, 0.5));

    // The artwork loads through the disc's own image path: the raw
    // memory source decoded at 800px, not the backdrop's 192px
    // downsample, so it renders as sharp as the disc's cover.
    final artworkImages = tester.widgetList<Image>(
      find.descendant(of: artwork, matching: find.byType(Image)),
    );
    expect(artworkImages, isNotEmpty);
    for (final image in artworkImages) {
      final provider = image.image;
      expect(provider, isA<ResizeImage>());
      final resize = provider as ResizeImage;
      expect(resize.width, 800);
      expect(resize.height, 800);
      expect(resize.imageProvider, isA<MemoryImage>());
    }

    double artworkOpacity() => tester
        .widget<Opacity>(
          find.descendant(of: artwork, matching: find.byType(Opacity)).first,
        )
        .opacity;
    expect(artworkOpacity(), closeTo(1, 0.001));

    // The tap-to-toggle target keeps the old poster's geometry on the
    // cover page even though the artwork moved into the background.
    final hotZoneRect = tester.getRect(
      find.byKey(const ValueKey('player-cover-toggle-button')),
    );
    final chromeRect = tester.getRect(find.byType(TopChromeRow));
    expect(hotZoneRect.left, closeTo(0, 0.5));
    expect(hotZoneRect.width, closeTo(390, 0.5));
    expect(hotZoneRect.height, closeTo(390, 0.5));
    expect(hotZoneRect.top, closeTo(chromeRect.bottom, 0.5));

    // Swiping to the lyrics page fades the background's artwork
    // component out; only the cover's colour ambience stays behind the
    // lyrics.
    await tester.drag(
      find.byKey(const ValueKey('player-compact-pager')),
      const Offset(-360, 0),
    );
    await _pumpUi(tester);
    expect(
      find.byKey(const ValueKey('player-compact-lyrics-clip')),
      findsOneWidget,
    );
    expect(artworkOpacity(), closeTo(0, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait square mode lifts mini lyrics toward the poster', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'square_album_cover_enabled': true,
    });
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'wy:square-mini-lyrics-lift',
        kind: PlayerTrackKind.remote,
        title: '方形歌词上移歌曲',
        artist: '方形歌词上移歌手',
        album: '方形歌词上移专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/square-mini-lyrics-lift.flac',
      ),
      lyrics: _timedLyrics(5),
    );

    final panel = find.byKey(const ValueKey('player-mini-lyrics'));
    expect(panel, findsOneWidget);
    final panelRect = tester.getRect(panel);
    final coverRect = tester.getRect(
      find.byKey(const ValueKey('player-cover-toggle-button')),
    );
    final pageRect = tester.getRect(find.byType(AlbumPage));
    // The mini lyrics live in the free space between the cover and the
    // album column's 12dp bottom padding. Square mode lifts the block
    // 48dp above that space's centre so it stays close to the poster
    // dissolving above instead of floating in the empty field below.
    final freeCentre = (coverRect.bottom + pageRect.bottom - 12) / 2;
    expect(panelRect.center.dy, closeTo(freeCentre - 48, 1.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait round mode keeps mini lyrics centred', (tester) async {
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'wy:round-mini-lyrics-centred',
        kind: PlayerTrackKind.remote,
        title: '圆盘歌词居中歌曲',
        artist: '圆盘歌词居中歌手',
        album: '圆盘歌词居中专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/round-mini-lyrics-centred.flac',
      ),
      lyrics: _timedLyrics(5),
    );

    final panel = find.byKey(const ValueKey('player-mini-lyrics'));
    expect(panel, findsOneWidget);
    final panelRect = tester.getRect(panel);
    final coverRect = tester.getRect(
      find.byKey(const ValueKey('player-cover-toggle-button')),
    );
    final pageRect = tester.getRect(find.byType(AlbumPage));
    // Round mode is untouched by the square lift: the block stays at
    // the centre of the free space under the disc.
    final freeCentre = (coverRect.bottom + pageRect.bottom - 12) / 2;
    expect(panelRect.center.dy, closeTo(freeCentre, 1.0));
    expect(tester.takeException(), isNull);
  });

  test('integrated artwork dissolve is a smooth bottom-anchored falloff', () {
    final stops = integratedArtworkDissolveStops;
    final alphas = integratedArtworkDissolveAlphas;
    expect(alphas.length, stops.length);
    expect(stops.first, 0);
    expect(stops.last, 1);
    expect(alphas.first, 1);
    expect(alphas.last, 0);
    // The stop table is monotone with no isolated step.
    var maxTableStep = 0.0;
    for (var i = 1; i < alphas.length; i++) {
      expect(alphas[i], lessThanOrEqualTo(alphas[i - 1]));
      maxTableStep = math.max(maxTableStep, alphas[i - 1] - alphas[i]);
    }
    expect(maxTableStep, lessThanOrEqualTo(0.15));
    // Densely sampled, the profile falls monotonically and no single
    // 0.005 sampling step drops more than 0.032 of alpha, so no row of
    // the poster can read as a boundary line. (The dissolve zone is
    // 26% of the layer, so the steepest table segment — 0.148 of alpha
    // over 0.026 of height — bounds a sampling step at ~0.0285.)
    var previous = integratedArtworkDissolveAlphaAt(0);
    expect(previous, 1);
    var maxStep = 0.0;
    for (var i = 1; i <= 200; i++) {
      final alpha = integratedArtworkDissolveAlphaAt(i / 200);
      expect(alpha, lessThanOrEqualTo(previous + 1e-9));
      maxStep = math.max(maxStep, previous - alpha);
      previous = alpha;
    }
    expect(previous, 0);
    expect(maxStep, lessThanOrEqualTo(0.032));
  });

  testWidgets(
    'integrated artwork appears from the track cover alone, independent '
    'of the backdrop and luminance providers',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'square_album_cover_enabled': true,
      });
      // A plain network cover URL and nothing else: no cover bytes, the
      // shared backdrop provider forced to null and the chrome-luminance
      // resolution forced to unknown. The artwork component must still
      // be part of the background — its presence depends only on the
      // track carrying a cover, loaded through the standard image path.
      await _pumpPlayer(
        tester,
        size: const Size(390, 844),
        track: const PlayerTrack(
          id: 'qq:url-only-cover-song',
          kind: PlayerTrackKind.remote,
          title: '网络封面歌曲',
          artist: '网络封面歌手',
          album: '网络封面专辑',
          sourceLabel: 'QQ',
          qualityLabel: '无损',
          remoteUrl: 'https://audio.example/url-only-cover.flac',
          coverUrl: 'https://covers.example.test/url-only-cover.jpg',
        ),
        lyrics: _timedLyrics(5),
        extraOverrides: [
          playerArtworkProvider.overrideWithValue(null),
          playerArtworkTopLuminanceProvider.overrideWith(
            (ref) async => null,
          ),
        ],
      );

      final artwork = find.byKey(
        const ValueKey('player-integrated-bg-artwork'),
      );
      expect(artwork, findsOneWidget);
      final artworkRect = tester.getRect(artwork);
      expect(artworkRect.left, closeTo(0, 0.5));
      expect(artworkRect.top, closeTo(0, 0.5));
      expect(artworkRect.width, closeTo(390, 0.5));
      expect(artworkRect.height, closeTo(390, 0.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('portrait round cover keeps the card and has no poster', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'wy:portrait-round-song',
        kind: PlayerTrackKind.remote,
        title: '竖屏圆盘歌曲',
        artist: '竖屏圆盘歌手',
        album: '竖屏圆盘专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/portrait-round.flac',
      ),
    );

    expect(find.byKey(const ValueKey('player-portrait-poster')), findsNothing);
    // Round mode keeps the flowing-light background only: no artwork
    // component is folded into it.
    expect(
      find.byKey(const ValueKey('player-integrated-bg-artwork')),
      findsNothing,
    );
    // The disc floats in the ambience on its contact shadow alone:
    // no cover-coloured halo around it.
    expect(find.byKey(const ValueKey('player-disc-glow')), findsNothing);
    final coverRect = tester.getRect(
      find.byKey(const ValueKey('player-cover-toggle-button')),
    );
    // The round disc stays an inset card below the top bar.
    expect(coverRect.left, greaterThan(0));
    expect(coverRect.width, lessThan(390));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'portrait round cover with artwork uses the blurred cover backdrop',
    (tester) async {
      final coverBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAN0lEQVR4nO3QQREAMAgDQYoKZCGxTstUBZ+Ngcvsqb4vFpebcQcIECBAgAABAgQIECBAgACBLzDAagJHFpD83wAAAABJRU5ErkJggg==',
      );
      await _pumpPlayer(
        tester,
        size: const Size(390, 844),
        track: PlayerTrack(
          id: 'wy:round-blur-backdrop-song',
          kind: PlayerTrackKind.remote,
          title: '圆盘模糊背景歌曲',
          artist: '圆盘模糊背景歌手',
          album: '圆盘模糊背景专辑',
          sourceLabel: '网易',
          qualityLabel: '无损',
          remoteUrl: 'https://audio.example/round-blur-backdrop.flac',
          coverBytes: coverBytes,
        ),
      );

      // The backdrop is the cover itself, blurred full-screen: the
      // flowing light retires in portrait disc mode when a cover
      // exists, and no integrated artwork layer appears (that is the
      // square mode's treatment).
      final backdrop = find.byKey(
        const ValueKey('player-disc-blur-backdrop'),
      );
      expect(backdrop, findsOneWidget);
      final backdropRect = tester.getRect(backdrop);
      expect(backdropRect.left, closeTo(0, 0.5));
      expect(backdropRect.top, closeTo(0, 0.5));
      expect(backdropRect.width, closeTo(390, 0.5));
      expect(backdropRect.height, closeTo(844, 0.5));
      expect(
        find.byKey(const ValueKey('flowing-light-background')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('player-integrated-bg-artwork')),
        findsNothing,
      );
      expect(
        find.descendant(of: backdrop, matching: find.byType(ImageFiltered)),
        findsOneWidget,
      );
      // The backdrop resolves through the same 800px cover path as the
      // disc itself.
      final backdropImages = tester.widgetList<Image>(
        find.descendant(of: backdrop, matching: find.byType(Image)),
      );
      expect(backdropImages, isNotEmpty);
      for (final image in backdropImages) {
        final provider = image.image;
        expect(provider, isA<ResizeImage>());
        final resize = provider as ResizeImage;
        expect(resize.width, 800);
        expect(resize.height, 800);
        expect(resize.imageProvider, isA<MemoryImage>());
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'portrait disc contact shadow is a static underlay that never '
    'swings above the disc',
    (tester) async {
      final coverBytes = await tester.runAsync(_discShadowProbeCoverBytes);
      final controller = await _pumpPlayer(
        tester,
        size: const Size(390, 844),
        track: PlayerTrack(
          id: 'wy:disc-static-shadow-song',
          kind: PlayerTrackKind.remote,
          title: '圆盘静态阴影歌曲',
          artist: '圆盘静态阴影歌手',
          album: '圆盘静态阴影专辑',
          sourceLabel: '网易',
          qualityLabel: '无损',
          remoteUrl: 'https://audio.example/disc-static-shadow.flac',
          coverBytes: coverBytes,
        ),
      );

      // The shadow is a static disc under the artwork, concentric
      // with it — not a decoration on the spinning artwork itself,
      // whose offset would rotate with the disc.
      final shadowFinder = find.byKey(
        const ValueKey('player-disc-contact-shadow'),
      );
      expect(shadowFinder, findsOneWidget);
      expect(
        find.ancestor(
          of: shadowFinder,
          matching: find.byType(RotationTransition),
        ),
        findsNothing,
      );
      final coverRect = tester.getRect(
        find.byKey(const ValueKey('player-cover-toggle-button')),
      );
      expect(tester.getRect(shadowFinder), coverRect);
      final shadowDecoration =
          tester.widget<Container>(shadowFinder).decoration as BoxDecoration;
      expect(shadowDecoration.shape, BoxShape.circle);
      expect(shadowDecoration.boxShadow, hasLength(1));
      expect(shadowDecoration.boxShadow!.single.blurRadius, 28);
      expect(shadowDecoration.boxShadow!.single.offset, const Offset(0, 18));
      final discDecoration =
          tester
                  .widget<Container>(
                    find
                        .descendant(
                          of: find.byType(SpinningCoverArt),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(discDecoration.boxShadow, isNull);

      // Spin the disc through a full revolution in quarter turns and
      // profile the rows above the disc at each stop. First wait for
      // the artwork to actually decode: the image streams resolve on
      // real async time, and until they do the disc shows its grey
      // placeholder and the backdrop is still empty.
      final top = coverRect.top.round();
      final centerX = coverRect.center.dx.round();
      Future<ByteData> captureBytes() async {
        final image = await tester.runAsync(
          () => captureImage(tester.element(find.byType(PlayerPage))),
        );
        expect(image!.width, 390);
        expect(image.height, 844);
        final bytes = await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        image.dispose();
        return bytes!;
      }

      int pixel(ByteData bytes, int x, int y, int channel) =>
          bytes.getUint8((y * 390 + x) * 4 + channel);
      var artworkReady = false;
      for (var attempt = 0; attempt < 60 && !artworkReady; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        final bytes = await captureBytes();
        final probeY = top + (coverRect.height * 0.25).round();
        // The synthetic cover's upper half is green; the placeholder
        // is neutral grey. Green dominance means the artwork is in.
        artworkReady =
            pixel(bytes, centerX, probeY, 1) -
                    pixel(bytes, centerX, probeY, 0) >
                25 &&
            pixel(bytes, centerX, probeY, 1) -
                    pixel(bytes, centerX, probeY, 2) >
                25;
      }
      expect(artworkReady, isTrue, reason: 'cover artwork never decoded');
      // Let the artwork/backdrop crossfades finish.
      await tester.pump(const Duration(milliseconds: 700));

      // With everything settled, the only thing that changes between
      // captures is the disc's rotation. The rows above the disc
      // must therefore be identical at every angle, and smooth —
      // when the shadow rotated with the disc, the half of the
      // revolution with its offset pointing up swung an extra
      // ~25/255 of darkening into exactly these rows.
      controller.setStateForTest(controller.state.copyWith(playing: true));
      await tester.pump();
      final profiles = <List<double>>[];
      for (var quarter = 0; quarter < 4; quarter++) {
        if (quarter > 0) {
          await tester.pump(const Duration(seconds: 6));
        }
        final bytes = await captureBytes();
        double rowLuminance(int y) {
          var total = 0.0;
          for (var x = centerX - 45; x <= centerX + 45; x++) {
            total +=
                0.2126 * pixel(bytes, x, y, 0) +
                0.7152 * pixel(bytes, x, y, 1) +
                0.0722 * pixel(bytes, x, y, 2);
          }
          return total / 91;
        }

        profiles.add([
          for (var dy = 30; dy >= 2; dy--) rowLuminance(top - dy),
        ]);
      }
      var maxAngleRange = 0.0;
      var maxRowStep = 0.0;
      for (var sample = 0; sample < profiles.first.length; sample++) {
        final values = [for (final profile in profiles) profile[sample]];
        maxAngleRange = math.max(
          maxAngleRange,
          values.reduce(math.max) - values.reduce(math.min),
        );
      }
      for (final profile in profiles) {
        for (var sample = 1; sample < profile.length; sample++) {
          maxRowStep = math.max(
            maxRowStep,
            (profile[sample] - profile[sample - 1]).abs(),
          );
        }
      }
      expect(
        maxAngleRange,
        lessThanOrEqualTo(3.5),
        reason: 'rows above the disc vary with the rotation angle',
      );
      expect(
        maxRowStep,
        lessThanOrEqualTo(3),
        reason: 'a band edge remains in the rows above the disc',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('portrait square cover keeps the integrated artwork and '
      'has no blurred disc backdrop', (tester) async {
    SharedPreferences.setMockInitialValues({
      'square_album_cover_enabled': true,
    });
    final coverBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAN0lEQVR4nO3QQREAMAgDQYoKZCGxTstUBZ+Ngcvsqb4vFpebcQcIECBAgAABAgQIECBAgACBLzDAagJHFpD83wAAAABJRU5ErkJggg==',
    );
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: PlayerTrack(
        id: 'wy:square-no-blur-backdrop-song',
        kind: PlayerTrackKind.remote,
        title: '方形无模糊背景歌曲',
        artist: '方形无模糊背景歌手',
        album: '方形无模糊背景专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/square-no-blur-backdrop.flac',
        coverBytes: coverBytes,
      ),
    );

    expect(
      find.byKey(const ValueKey('player-disc-blur-backdrop')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('player-integrated-bg-artwork')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape round cover has no blurred disc backdrop', (
    tester,
  ) async {
    final coverBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAN0lEQVR4nO3QQREAMAgDQYoKZCGxTstUBZ+Ngcvsqb4vFpebcQcIECBAgAABAgQIECBAgACBLzDAagJHFpD83wAAAABJRU5ErkJggg==',
    );
    await _pumpPlayer(
      tester,
      size: const Size(915, 412),
      track: PlayerTrack(
        id: 'wy:landscape-no-blur-backdrop-song',
        kind: PlayerTrackKind.remote,
        title: '横屏无模糊背景歌曲',
        artist: '横屏无模糊背景歌手',
        album: '横屏无模糊背景专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/landscape-no-blur-backdrop.flac',
        coverBytes: coverBytes,
      ),
    );

    // The blurred cover backdrop is a portrait-disc-only treatment;
    // landscape keeps its existing background.
    expect(
      find.byKey(const ValueKey('player-disc-blur-backdrop')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('player-phone-landscape-layout')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait round backdrop fills the whole screen, status bar '
      'included, while the chrome keeps its safe-area offset', (tester) async {
    // Simulate a device status bar: the UI chrome must respect the
    // inset, the ambience layer must not — it reaches the top of the
    // screen so the chrome floats over the same layer as everything
    // below it, with no flat theme-coloured band in between.
    tester.view.padding = const FakeViewPadding(top: 100);
    addTearDown(() => tester.view.resetPadding());
    final coverBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAN0lEQVR4nO3QQREAMAgDQYoKZCGxTstUBZ+Ngcvsqb4vFpebcQcIECBAgAABAgQIECBAgACBLzDAagJHFpD83wAAAABJRU5ErkJggg==',
    );
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: PlayerTrack(
        id: 'wy:round-backdrop-song',
        kind: PlayerTrackKind.remote,
        title: '圆盘背景歌曲',
        artist: '圆盘背景歌手',
        album: '圆盘背景专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/round-backdrop.flac',
        coverBytes: coverBytes,
      ),
    );
    final backdropRect = tester.getRect(
      find.byKey(const ValueKey('player-backdrop')),
    );
    expect(backdropRect.top, closeTo(0, 0.5));
    expect(backdropRect.height, closeTo(844, 0.5));
    // The track carries a cover, so the backdrop is the blurred cover
    // layer — and it too reaches the top of the screen; the flowing
    // light no longer renders in this mode.
    expect(
      find.byKey(const ValueKey('flowing-light-background')),
      findsNothing,
    );
    final blurRect = tester.getRect(
      find.byKey(const ValueKey('player-disc-blur-backdrop')),
    );
    expect(blurRect.top, closeTo(0, 0.5));
    expect(blurRect.height, closeTo(844, 0.5));
    // The chrome itself still starts below the status bar.
    final chromeRect = tester.getRect(find.byType(TopChromeRow));
    expect(chromeRect.top, closeTo(100, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone landscape lyrics keep neighbouring lines readable', (
    tester,
  ) async {
    // Active line is index 6 (18s into 3s-spaced lines).
    await _pumpPlayer(
      tester,
      size: const Size(915, 412),
      track: const PlayerTrack(
        id: 'wy:landscape-lyrics-song',
        kind: PlayerTrackKind.remote,
        title: '横屏歌词歌曲',
        artist: '横屏歌手',
        album: '横屏专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/landscape-lyrics.flac',
      ),
      lyrics: _timedLyrics(14),
      position: const Duration(milliseconds: 18000),
    );

    // The landscape panel carries its own scoped metrics.
    final view = tester.widget<KaraokeLyricsView>(
      find.byType(KaraokeLyricsView),
    );
    expect(view.edgeFadeExtent, 10);
    // Dead-zoned per-edge fades: each edge's dead zone matches the
    // floating chrome over it (48 + 12 at the top, 12 + 98 at the
    // bottom), so a line's mask alpha is 0 throughout the chrome's
    // span; the extent adds the ramp past the dead zone (50 top, 70
    // bottom) where alpha returns to 1. Profile points: top alpha is
    // 0 at 60dp from the top and 1 at 110dp; bottom alpha is 0 at
    // 110dp from the bottom and 1 at 180dp.
    expect(view.edgeFadeExtentTop, 110);
    expect(view.edgeFadeExtentBottom, 180);
    expect(view.edgeFadeDeadZoneTop, 60);
    expect(view.edgeFadeDeadZoneBottom, 110);
    // The shared lyrics view hides the platform scrollbar in this
    // panel too (the desktop bar visible on the lyrics area's right
    // edge in the Windows screenshot): its own ScrollConfiguration
    // wrap sits inside the view.
    expect(
      find.descendant(
        of: find.byType(KaraokeLyricsView),
        matching: find.byType(ScrollConfiguration),
      ),
      findsOneWidget,
    );
    expect(view.scrollAnchor, 0.5);
    expect(view.lineVerticalPadding, 4);
    expect(view.alignModeOverride, LyricAlignMode.left);

    final panelRect = tester.getRect(
      find.byKey(const ValueKey('player-phone-landscape-lyrics')),
    );
    Rect tileRect(String text) => tester.getRect(
      find
          .ancestor(of: find.text(text), matching: find.byType(LyricLineTile))
          .first,
    );
    // The active line and two lines on each side are fully inside the
    // panel: at least five lines are readable at once.
    var fullyVisible = 0;
    for (final element in find.byType(LyricLineTile).evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      if (rect.top >= panelRect.top - 0.5 &&
          rect.bottom <= panelRect.bottom + 0.5) {
        fullyVisible++;
      }
    }
    expect(fullyVisible, greaterThanOrEqualTo(5));
    for (final index in [4, 5, 6, 7, 8]) {
      final rect = tileRect('第${index + 1}句歌词用于测试平稳切换');
      expect(rect.top, greaterThanOrEqualTo(panelRect.top - 0.5));
      expect(rect.bottom, lessThanOrEqualTo(panelRect.bottom + 0.5));
    }
    // Tightened rows: one line's extent is ~44dp, not the portrait ~58dp.
    final activeRect = tileRect('第7句歌词用于测试平稳切换');
    expect(activeRect.height, closeTo(44, 1.5));

    // A non-active line keeps the portrait page's text alpha (0.3 for
    // word-timing-less lines): the landscape panel does not fade its
    // neighbours out beyond what the portrait page does.
    double lineAlpha() {
      final text = tester.widget<Text>(
        find
            .descendant(
              of: find.byKey(const ValueKey('lyric-focus-scale-15000')),
              matching: find.byType(Text),
            )
            .first,
      );
      return text.style!.color!.a;
    }

    expect(lineAlpha(), closeTo(0.3, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone landscape lyrics follow their own alignment setting', (
    tester,
  ) async {
    TextAlign? landscapeLineAlign() {
      final text = tester.widget<Text>(
        find
            .descendant(
              of: find.byKey(const ValueKey('lyric-focus-scale-15000')),
              matching: find.byType(Text),
            )
            .first,
      );
      return text.textAlign;
    }

    Future<void> pumpLandscape() => _pumpPlayer(
      tester,
      size: const Size(915, 412),
      track: const PlayerTrack(
        id: 'wy:landscape-align-song',
        kind: PlayerTrackKind.remote,
        title: '横屏对齐歌曲',
        artist: '横屏歌手',
        album: '横屏专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/landscape-align.flac',
      ),
      lyrics: _timedLyrics(14),
      position: const Duration(milliseconds: 18000),
    );

    // Portrait setting centred, landscape setting left: the landscape
    // panel follows its own key and stays left-aligned.
    SharedPreferences.setMockInitialValues({
      'lyric_align_mode': 'center',
      'lyric_align_mode_landscape': 'left',
    });
    await pumpLandscape();
    expect(
      tester
          .widget<KaraokeLyricsView>(find.byType(KaraokeLyricsView))
          .alignModeOverride,
      LyricAlignMode.left,
    );
    expect(landscapeLineAlign(), TextAlign.start);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone landscape lyrics centre on their own setting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'lyric_align_mode_landscape': 'center',
    });
    await _pumpPlayer(
      tester,
      size: const Size(915, 412),
      track: const PlayerTrack(
        id: 'wy:landscape-align-song',
        kind: PlayerTrackKind.remote,
        title: '横屏对齐歌曲',
        artist: '横屏歌手',
        album: '横屏专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/landscape-align.flac',
      ),
      lyrics: _timedLyrics(14),
      position: const Duration(milliseconds: 18000),
    );
    expect(
      tester
          .widget<KaraokeLyricsView>(find.byType(KaraokeLyricsView))
          .alignModeOverride,
      LyricAlignMode.center,
    );
    final text = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey('lyric-focus-scale-15000')),
            matching: find.byType(Text),
          )
          .first,
    );
    expect(text.textAlign, TextAlign.center);
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait lyrics ignore the landscape alignment setting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'lyric_align_mode_landscape': 'center',
    });
    await _pumpPlayer(
      tester,
      size: const Size(390, 844),
      track: const PlayerTrack(
        id: 'wy:portrait-align-song',
        kind: PlayerTrackKind.remote,
        title: '竖屏对齐歌曲',
        artist: '竖屏歌手',
        album: '竖屏专辑',
        sourceLabel: '网易',
        qualityLabel: '无损',
        remoteUrl: 'https://audio.example/portrait-align.flac',
      ),
      lyrics: _timedLyrics(14),
      position: const Duration(milliseconds: 18000),
    );
    await tester.drag(
      find.byKey(const ValueKey('player-compact-pager')),
      const Offset(-360, 0),
    );
    await _pumpUi(tester);

    // The portrait page reads only its own key (unset here, so the
    // default left alignment applies) even though the landscape key
    // is centred.
    expect(
      tester
          .widget<KaraokeLyricsView>(find.byType(KaraokeLyricsView))
          .alignModeOverride,
      isNull,
    );
    final text = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey('lyric-focus-scale-15000')),
            matching: find.byType(Text),
          )
          .first,
    );
    expect(text.textAlign, TextAlign.start);
    // Alpha parity with the landscape panel: a non-active,
    // word-timing-less line renders at the same 0.3 alpha here.
    expect(text.style!.color!.a, closeTo(0.3, 0.01));
    expect(tester.takeException(), isNull);
  });
}

class _RouterHarness {
  const _RouterHarness({required this.router});

  final GoRouter router;
}

class _SeededPlayerController extends PlayerController {
  _SeededPlayerController(
    super.ref,
    PlayerState initialState, {
    this.seededCurrentMusic,
  }) {
    state = initialState;
  }

  Quality? switchedQuality;
  final MusicInfo? seededCurrentMusic;

  @override
  MusicInfo? get currentMusic => seededCurrentMusic ?? super.currentMusic;

  void setStateForTest(PlayerState next) => state = next;

  @override
  Future<bool> switchQuality(Quality quality) async {
    switchedQuality = quality;
    return true;
  }
}

Future<_SeededPlayerController> _pumpLyricsPanel(
  WidgetTester tester,
  PlayerState initialState,
) async {
  final preferences = await SharedPreferences.getInstance();
  final audioHandler = PlayerAudioHandler();
  addTearDown(() => unawaited(audioHandler.disposeHandler()));
  late _SeededPlayerController controller;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        playerAudioHandlerProvider.overrideWithValue(audioHandler),
        playerControllerProvider.overrideWith(
          (ref) => controller = _SeededPlayerController(ref, initialState),
        ),
      ],
      child: MaterialApp(
        builder: buildPrismTestEnvironment,
        theme: _theme(),
        home: const Scaffold(body: LyricsPanel()),
      ),
    ),
  );
  await _pumpUi(tester);
  controller.setStateForTest(initialState);
  await _pumpUi(tester);
  return controller;
}

Future<_SeededPlayerController> _pumpKtvPanel(
  WidgetTester tester,
  PlayerState initialState,
) async {
  final preferences = await SharedPreferences.getInstance();
  final audioHandler = PlayerAudioHandler();
  addTearDown(() => unawaited(audioHandler.disposeHandler()));
  late _SeededPlayerController controller;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        playerAudioHandlerProvider.overrideWithValue(audioHandler),
        playerControllerProvider.overrideWith(
          (ref) => controller = _SeededPlayerController(ref, initialState),
        ),
      ],
      child: MaterialApp(
        builder: buildPrismTestEnvironment,
        theme: _theme(),
        home: const Scaffold(body: KtvLyricsPanel()),
      ),
    ),
  );
  await _pumpUi(tester);
  controller.setStateForTest(initialState);
  await _pumpUi(tester);
  return controller;
}

Future<_RouterHarness> _pumpRoutedApp(
  WidgetTester tester, {
  required String initialLocation,
}) async {
  final preferences = await SharedPreferences.getInstance();
  final audioHandler = PlayerAudioHandler();
  final router = createAppRouter(initialLocation: initialLocation);
  addTearDown(router.dispose);
  addTearDown(() => unawaited(audioHandler.disposeHandler()));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        playerAudioHandlerProvider.overrideWithValue(audioHandler),
        playerControllerProvider.overrideWith(
          (ref) => _SeededPlayerController(ref, const PlayerState()),
        ),
      ],
      child: MaterialApp.router(
        builder: buildPrismTestEnvironment,
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        routerConfig: router,
      ),
    ),
  );
  await _pumpUi(tester);
  return _RouterHarness(router: router);
}

/// A synthetic cover for the disc-shadow profile test: solid green
/// over solid pink with an eccentric dark blob, so the blurred
/// backdrop stays vertically smooth above the disc while the disc's
/// rotation remains visible in the artwork itself.
Future<Uint8List> _discShadowProbeCoverBytes() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 200, 110),
    ui.Paint()..color = const ui.Color(0xFF7CB342),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 110, 200, 90),
    ui.Paint()..color = const ui.Color(0xFFEC407A),
  );
  canvas.drawCircle(
    const ui.Offset(52, 44),
    26,
    ui.Paint()..color = const ui.Color(0xFF263238),
  );
  final image = await recorder.endRecording().toImage(200, 200);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<_SeededPlayerController> _pumpPlayer(
  WidgetTester tester, {
  required Size size,
  required PlayerTrack track,
  KaraokeLyrics lyrics = const KaraokeLyrics([]),
  Duration position = Duration.zero,
  MusicInfo? currentMusic,
  List<Override> extraOverrides = const [],
  void Function([String? target]) onDismissRequested = _ignoreDismiss,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  final preferences = await SharedPreferences.getInstance();
  final audioHandler = PlayerAudioHandler();
  addTearDown(() => unawaited(audioHandler.disposeHandler()));
  final initialState = PlayerState(
    track: track,
    duration: const Duration(minutes: 3),
    lyrics: lyrics,
    position: position,
  );
  late _SeededPlayerController controller;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        playerAudioHandlerProvider.overrideWithValue(audioHandler),
        playerControllerProvider.overrideWith(
          (ref) => controller = _SeededPlayerController(
            ref,
            initialState,
            seededCurrentMusic: currentMusic,
          ),
        ),
        ...extraOverrides,
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        builder: (context, child) => buildPrismTestEnvironment(
          context,
          AppToastOverlay(child: child ?? const SizedBox.shrink()),
        ),
        home: PlayerPage(
          returnLocation: '/songs',
          progress: const AlwaysStoppedAnimation<double>(1),
          active: true,
          onDismissRequested: onDismissRequested,
        ),
      ),
    ),
  );
  await _pumpUi(tester);
  controller.setStateForTest(initialState);
  await _pumpUi(tester);
  return controller;
}

/// The visible readout inside the sleep-timer popup's custom stepper.
String _stepperMinutes(WidgetTester tester) {
  return tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('player-sleep-timer-custom-value')),
          matching: find.byType(Text),
        ),
      )
      .data!;
}

KaraokeLyrics _timedLyrics(int count) {
  return KaraokeLyrics([
    for (var index = 0; index < count; index++)
      KaraokeLyricLine(
        startMs: index * 3000,
        endMs: (index + 1) * 3000,
        text: '第${index + 1}句歌词用于测试平稳切换',
      ),
  ]);
}

ScrollPosition _lyricsScrollPosition(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byKey(const ValueKey('karaoke-lyrics-list')),
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable).position;
}

double _lyricFocusScale(WidgetTester tester, int startMs) {
  final transform = tester.widget<Transform>(
    find.byKey(ValueKey('lyric-focus-scale-$startMs')),
  );
  return transform.transform.storage.first;
}

double _activeWordProgress(WidgetTester tester, int lineStartMs) {
  final lyricText = find.descendant(
    of: find.byKey(ValueKey('lyric-focus-scale-$lineStartMs')),
    matching: find.byType(KaraokeLineText),
  );
  final lyric = tester.widget<KaraokeLineText>(lyricText);
  expect(lyric.active, isTrue);
  final word = lyric.line.words.single;
  final positionMs = tester
      .state<KaraokeLineTextState>(lyricText)
      .debugPlaybackPositionMs;
  return ((positionMs - word.startMs) / (word.endMs - word.startMs)).clamp(
    0.0,
    1.0,
  );
}

ThemeData _theme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
  );
}

void _ignoreDismiss([String? target]) {}

/// Whether the action row's button with [key] accepts taps. The keys sit on
/// private wrapper widgets, so read the prism button they render instead.
bool _actionEnabled(WidgetTester tester, String key) {
  final button = find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(prism.IconButton),
  );
  expect(button, findsOneWidget, reason: key);
  return tester.widget<prism.IconButton>(button).onPressed != null;
}

/// Picks [label] from the player top bar's "more" menu.
Future<void> _pickTopBarMoreItem(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('player-more-button')));
  await _pumpUi(tester);
  await tester.tap(
    find.descendant(
      of: find.byType(prism.PopupMenu),
      matching: find.text(label),
    ),
  );
  await _pumpUi(tester);
}

Future<void> _pumpUi(WidgetTester tester) async {
  for (var index = 0; index < 12; index++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

MusicInfo _remoteMusic() => MusicInfo.fromJson({
  'id': 'remote-song',
  'name': '窄屏在线歌曲',
  'singer': '不应在封面下重复的歌手',
  'source': MusicSource.tx.code,
  'meta': {
    'songId': 'remote-song',
    'albumName': '测试专辑',
    'qualitys': [
      {'type': Quality.k320.code, 'size': '9.48 MB'},
      {'type': Quality.k128.code, 'size': '3.82 MB'},
    ],
  },
});

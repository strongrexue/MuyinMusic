import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/player/player_controller.dart';
import 'package:cy_shine_music/features/player/player_page.dart';
import 'package:cy_shine_music/features/settings/settings_page.dart';
import 'package:cy_shine_music/features/shell/app_shell.dart';
import 'package:cy_shine_music/features/shell/player_transition.dart';
import 'package:cy_shine_music/features/shell/widgets/dual_capsule_bottom_navigation.dart';
import 'package:cy_shine_music/features/shell/widgets/mini_player_bar.dart';
import 'package:cy_shine_music/features/songs/songs_toolbar_state.dart';
import 'package:cy_shine_music/router.dart';
import 'package:cy_shine_music/theme/app_theme.dart';

import 'helpers/prism_test_environment.dart';

final _miniPlayer = find.byKey(const ValueKey('native-mini-player'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a left-folded capsule leaves no cover behind on the open player page',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'discovery_source_order': ['kw', 'kg', 'tx', 'wy', 'mg'],
      });
      final prefs = await SharedPreferences.getInstance();
      final audioHandler = PlayerAudioHandler();
      addTearDown(() => unawaited(audioHandler.disposeHandler()));
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playerAudioHandlerProvider.overrideWithValue(audioHandler),
          playerControllerProvider.overrideWith(
            (ref) => _PlayerController(ref, _playing),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) =>
                buildPrismTestEnvironment(context, child!),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: FloatingCapsuleBottomNavigation(
                  location: '/settings',
                  routeLocation: '/settings',
                  showPlayer: true,
                  visible: true,
                  reveal: const AlwaysStoppedAnimation<double>(1),
                  fold: const AlwaysStoppedAnimation<double>(1),
                  isPlayer: true,
                  onFoldedPlayerTap: () {},
                  onFoldedAnchorTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The round cover the folded player capsule collapses into has to fade
      // with the rest of the chrome, or it lingers in the bottom-left corner
      // of the open player page.
      final anchor = find.byKey(const ValueKey('folded-player-anchor'));
      expect(anchor, findsOneWidget);
      expect(
        tester
            .widget<FadeTransition>(
              find
                  .ancestor(of: anchor, matching: find.byType(FadeTransition))
                  .first,
            )
            .opacity
            .value,
        0,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'floating capsule is the only navigation and settings drop the mode card',
    (tester) async {
      final harness = await _pumpApp(
        tester,
        initialLocation: '/settings/appearance',
      );
      expect(find.byType(FloatingCapsuleBottomNavigation), findsOneWidget);
      expect(_miniPlayer.hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('navigation-mode-menu-anchor')),
        findsNothing,
      );
      expect(find.text('导航模式'), findsNothing);

      await _tapTab(tester, '发现');
      expect(harness.location, '/');
      expect(find.byType(FloatingCapsuleBottomNavigation), findsOneWidget);
      expect(_miniPlayer.hitTestable(), findsOneWidget);
      expect(harness.controller.snapshot.track?.id, _track.id);
      expect(harness.controller.snapshot.playing, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4));
    },
  );

  testWidgets('floating navigation renders mini player and dock', (
    tester,
  ) async {
    final harness = await _pumpApp(
      tester,
      initialLocation: '/settings/appearance',
    );
    expect(find.byType(FloatingCapsuleBottomNavigation), findsOneWidget);
    expect(_miniPlayer.hitTestable(), findsOneWidget);
    expect(find.text('发现'), findsOneWidget);
    expect(find.text('歌曲'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(FloatingCapsuleBottomNavigation),
        matching: find.text('设置'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('发现'));
    await _pumpUi(tester);
    expect(harness.location, '/');
    expect(find.byType(FloatingCapsuleBottomNavigation), findsOneWidget);

    await tester.tap(find.byTooltip('打开播放页'));
    await _pumpUi(tester);
    expect(harness.location, '/player');
    expect(
      find
          .descendant(
            of: find.byType(FloatingCapsuleBottomNavigation),
            matching: find.text('发现'),
          )
          .hitTestable(),
      findsNothing,
    );

    await tester.binding.handlePopRoute();
    await _pumpUi(tester);
    expect(harness.location, '/');
    expect(
      find
          .descendant(
            of: find.byType(FloatingCapsuleBottomNavigation),
            matching: find.text('发现'),
          )
          .hitTestable(),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
  });






  testWidgets('capsule morph keeps one cover and the originating page alive', (
    tester,
  ) async {
    final harness = await _pumpApp(tester);
    final originalPage = tester.element(find.byType(SettingsPage));
    final gesture = await tester.startGesture(tester.getCenter(_miniPlayer));
    await tester.pump();
    await tester.pump();
    final transition = tester
        .widget<PlayerTransitionScope>(find.byType(PlayerTransitionScope))
        .transition;
    final source = transition.miniCover!;
    final end = transition.fullCover!;
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(Offset(0, -transition.travel / 2));
    await tester.pump();
    expect(transition.progress.value, closeTo(.5, .001));
    final shared = tester.getRect(
      find.byKey(const ValueKey('player-shared-cover')),
    );
    expect(
      shared.center.dx,
      closeTo(source.center.dx + .75 * (end.center.dx - source.center.dx), .01),
    );
    expect(
      shared.center.dy,
      closeTo(source.center.dy + .25 * (end.center.dy - source.center.dy), .01),
    );
    for (final anchor in tester.widgetList<PlayerCoverAnchor>(
      find.byType(PlayerCoverAnchor),
    )) {
      final opacity = find
          .descendant(of: find.byWidget(anchor), matching: find.byType(Opacity))
          .first;
      expect(tester.widget<Opacity>(opacity).opacity, 0);
    }
    await gesture.up();
    await _pumpUi(tester);
    expect(harness.location, '/player');
    expect(tester.element(find.byType(SettingsPage)), same(originalPage));
    expect(find.byKey(const ValueKey('player-shared-cover')), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(harness.location, '/settings');
    expect(transition.progress.value, inExclusiveRange(0, 1));
    expect(tester.element(find.byType(SettingsPage)), same(originalPage));
    await _pumpUi(tester);
    expect(harness.location, '/settings');
    expect(tester.element(find.byType(SettingsPage)), same(originalPage));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a released closing spring does not capture another list drag', (
    tester,
  ) async {
    final harness = await _pumpApp(tester);
    await tester.tap(find.byTooltip('打开播放页'));
    await _pumpUi(tester);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
    final closingProgress = player.progress.value;
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final before = scrollable.position.pixels;
    final gesture = await tester.startGesture(const Offset(120, 260));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, -220));
    await tester.pump(const Duration(milliseconds: 16));
    expect(scrollable.position.pixels, greaterThan(before));
    expect(player.progress.value, lessThan(closingProgress));
    expect(harness.location, '/settings');
    await gesture.up();
    await _pumpUi(tester);
    expect(harness.location, '/settings');
    expect(
      tester.widget<PlayerPage>(find.byType(PlayerPage)).progress.value,
      0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'visible navigation accepts taps before the closing tail finishes',
    (tester) async {
      final harness = await _pumpApp(tester);
      await tester.tap(find.byTooltip('打开播放页'));
      await _pumpUi(tester);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(player.progress.value, inExclusiveRange(0, .2));
      await tester.tap(
        find.descendant(
          of: find.byType(FloatingCapsuleBottomNavigation),
          matching: find.text('歌曲'),
        ),
      );
      await tester.pump();
      expect(harness.location, '/songs');
      expect(player.progress.value, greaterThan(0));
      await _pumpUi(tester);
      expect(harness.location, '/songs');
      expect(tester.takeException(), isNull);
    },
  );

  {
    testWidgets(
      'a released player drag lets the list scroll through its remaining surface',
      (tester) async {
        final harness = await _pumpApp(tester);
        await tester.tap(find.byTooltip('打开播放页'));
        await _pumpUi(tester);
        final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
        // The cover is the only surface wired to the pull-down handle; its tap
        // gesture loses the arena once the drag clears the touch slop.
        final closing = await tester.startGesture(
          tester.getCenter(
            find.byKey(const ValueKey('player-cover-toggle-button')),
          ),
        );
        await closing.moveBy(const Offset(0, 20));
        await tester.pump();
        await closing.moveBy(const Offset(0, 240));
        await tester.pump(const Duration(milliseconds: 100));
        expect(harness.location, '/player');
        await closing.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 30));
        expect(harness.location, '/settings');
        final beforeProgress = player.progress.value;
        expect(beforeProgress, inExclusiveRange(0, 1));
        final scrollable = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(SettingsPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final beforeOffset = scrollable.position.pixels;
        final newTouch = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('player-shared-cover'))),
        );
        await newTouch.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 16));
        await newTouch.moveBy(const Offset(0, -120));
        await tester.pump(const Duration(milliseconds: 16));
        expect(scrollable.position.pixels, greaterThan(beforeOffset));
        expect(player.progress.value, lessThan(beforeProgress));
        await newTouch.up();
        await _pumpUi(tester);
        expect(player.progress.value, 0);
        expect(harness.location, '/settings');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'closing cover stays opaque above capsule chrome',
      (tester) async {
        final captureKey = GlobalKey();
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAN0lEQVR4nO3QQREAMAgDQYoKZCGxTstUBZ+Ngcvsqb4vFpebcQcIECBAgAABAgQIECBAgACBLzDAagJHFpD83wAAAABJRU5ErkJggg==',
        );
        final state = _playing.copyWith(
          playing: false,
          track: PlayerTrack(
            id: 'opaque-cover',
            kind: PlayerTrackKind.localFile,
            title: '封面测试',
            artist: '测试',
            album: '测试',
            sourceLabel: '本地',
            qualityLabel: 'flac',
            coverBytes: bytes,
          ),
        );
        await _pumpApp(
          tester,
          initialState: state,
          captureKey: captureKey,
        );
        await tester.runAsync(
          () => precacheImage(
            ResizeImage(MemoryImage(bytes), width: 480, height: 480),
            tester.element(find.byType(MiniPlayerBar)),
          ),
        );
        await tester.pump();
        final anchor = find.descendant(
          of: find.byType(MiniPlayerBar),
          matching: find.byType(PlayerCoverAnchor),
        );
        expect(
          await _coverPixel(tester, captureKey, tester.getCenter(anchor)),
          [24, 80, 160, 255],
        );
        await tester.tap(find.byTooltip('打开播放页'));
        await _pumpUi(tester);
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final p = tester
            .widget<PlayerPage>(find.byType(PlayerPage))
            .progress
            .value;
        expect(p, inExclusiveRange(0, .12));
        final flight = find.byKey(const ValueKey('player-shared-cover'));
        expect(
          await _coverPixel(tester, captureKey, tester.getCenter(flight)),
          [24, 80, 160, 255],
        );
        await _pumpUi(tester);
        expect(
          await _coverPixel(tester, captureKey, tester.getCenter(anchor)),
          [24, 80, 160, 255],
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an explicit capsule tap can reopen the player during its closing tail',
    (tester) async {
      final harness = await _pumpApp(tester);
      await tester.tap(find.byTooltip('打开播放页'));
      await _pumpUi(tester);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(player.progress.value, inExclusiveRange(0, .2));
      await tester.tap(find.byTooltip('打开播放页'));
      await _pumpUi(tester);
      expect(harness.location, '/player');
      expect(player.progress.value, 1);
      await tester.binding.handlePopRoute();
      await _pumpUi(tester);
      expect(harness.location, '/settings');
      expect(tester.takeException(), isNull);
    },
  );


}

const _track = PlayerTrack(
  id: 'native-navigation-test',
  kind: PlayerTrackKind.localFile,
  title: '当前歌曲',
  artist: '测试歌手',
  album: '测试专辑',
  sourceLabel: '本地',
  qualityLabel: 'flac',
);
const _playing = PlayerState(
  track: _track,
  playing: true,
  duration: Duration(minutes: 3),
  canPlayPrevious: true,
  canPlayNext: true,
);

class _PlayerController extends PlayerController {
  _PlayerController(super.ref, PlayerState initial) {
    state = initial;
  }

  int nextCalls = 0;
  int previousCalls = 0;
  PlayerState get snapshot => state;
  void seed(PlayerState value) => state = value;

  @override
  Future<void> playNext() async {
    nextCalls++;
  }

  @override
  Future<void> playPrevious() async {
    previousCalls++;
  }
}

class _Harness {
  const _Harness(this.router, this.controller);
  final GoRouter router;
  final _PlayerController controller;
  String get location => router.routeInformationProvider.value.uri.toString();
}

Future<_Harness> _pumpApp(
  WidgetTester tester, {
  String initialLocation = '/settings',
  PlayerState initialState = _playing,
  Size size = const Size(390, 844),
  double textScale = 1,
  GlobalKey? captureKey,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = const FakeViewPadding(bottom: 24);
  tester.view.viewPadding = const FakeViewPadding(bottom: 24);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
    tester.view.resetPadding();
    tester.view.resetViewPadding();
    tester.view.resetViewInsets();
  });
  SharedPreferences.setMockInitialValues({
    'discovery_source_order': ['kw', 'kg', 'tx', 'wy', 'mg'],
  });
  final prefs = await SharedPreferences.getInstance();
  final audioHandler = PlayerAudioHandler();
  final router = createAppRouter(initialLocation: initialLocation);
  late _PlayerController controller;
  addTearDown(() {
    router.dispose();
    unawaited(audioHandler.disposeHandler());
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        playerAudioHandlerProvider.overrideWithValue(audioHandler),
        playerControllerProvider.overrideWith(
          (ref) => controller = _PlayerController(ref, initialState),
        ),
        songsSearchAutoFocusProvider.overrideWith((ref) => false),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Builder(
            builder: (context) => buildPrismTestEnvironment(
              context,
              RepaintBoundary(key: captureKey, child: child!),
            ),
          ),
        ),
        routerConfig: router,
      ),
    ),
  );
  await _pumpUi(tester);
  // Audio-handler initial streams settle before applying the test transport state.
  ProviderScope.containerOf(
    tester.element(find.byType(AppShell)),
  ).read(playerControllerProvider);
  controller.seed(initialState);
  await _pumpUi(tester);
  return _Harness(router, controller);
}

Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(FloatingCapsuleBottomNavigation),
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

Future<List<int>?> _coverPixel(
  WidgetTester tester,
  GlobalKey key,
  Offset global,
) {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final point = boundary.globalToLocal(global);
  return tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
      return List.generate(4, (i) => bytes.getUint8(offset + i));
    } finally {
      image.dispose();
    }
  });
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/playlists/online_playlist_import_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_management_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/playlists/widgets/playlist_library_tile.dart';
import 'package:cy_shine_music/features/settings/settings_page.dart';
import 'package:cy_shine_music/features/settings/settings_section.dart';
import 'package:cy_shine_music/theme/app_theme.dart';

import 'helpers/prism_test_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('settings content stays capped at 640 on wide screens', (
    tester,
  ) async {
    await _useViewport(tester, const Size(1024, 800));
    await _pump(tester, const SettingsPage());

    final box = find.byWidgetPredicate(
      (w) => w is ConstrainedBox && w.constraints.maxWidth == 640,
    );
    expect(box, findsOneWidget);
    expect(tester.getSize(box).width, 640);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings content fills narrow screens below the 640 cap', (
    tester,
  ) async {
    await _useViewport(tester, const Size(390, 844));
    await _pump(tester, const SettingsPage());

    final box = find.byWidgetPredicate(
      (w) => w is ConstrainedBox && w.constraints.maxWidth == 640,
    );
    expect(box, findsOneWidget);
    // 页面左右各 16dp 内边距。
    expect(tester.getSize(box).width, 390 - 32);
    expect(tester.takeException(), isNull);
  });

  testWidgets('appearance section no longer offers car display settings', (
    tester,
  ) async {
    await _useViewport(tester, const Size(1024, 800));
    await _pump(
      tester,
      const SettingsPage(section: SettingsSection.appearance),
    );

    // 先证明外观卡片确实渲染并滚动到底，再断言车机项不存在。
    final scrollable = find.byType(Scrollable).first;
    for (var i = 0; i < 12; i++) {
      await tester.drag(scrollable, const Offset(0, -600));
      await tester.pumpAndSettle();
    }
    expect(
      find.byKey(const ValueKey('flowing-light-setting')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('car-pad-mode-setting')), findsNothing);
    expect(find.byKey(const ValueKey('car-display-setting')), findsNothing);
    expect(find.text('车机/Pad 模式'), findsNothing);
    expect(find.text('车机显示适配'), findsNothing);
    expect(find.text('车机界面大小'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('import form stays capped at 760 regardless of width', (
    tester,
  ) async {
    await _useViewport(tester, const Size(1024, 800));
    await _pump(tester, const OnlinePlaylistImportPage());

    final box = find.byWidgetPredicate(
      (w) => w is ConstrainedBox && w.constraints.maxWidth == 760,
    );
    expect(box, findsOneWidget);
    expect(tester.getSize(box).width, 760);
    expect(tester.takeException(), isNull);
  });

  testWidgets('management tiles widen from 760 to full width at 840', (
    tester,
  ) async {
    await _useViewport(tester, const Size(839, 600));
    await _pumpManagement(tester);
    expect(tester.getSize(find.byType(PlaylistLibraryTile).first).width, 760);

    await _useViewport(tester, const Size(840, 600));
    await _pumpManagement(tester);
    // ≥840 上限放宽到 1040，此时被可用宽（840-32）封顶。
    expect(
      tester.getSize(find.byType(PlaylistLibraryTile).first).width,
      840 - 32,
    );
    expect(tester.takeException(), isNull);
  });
}

ThemeData _theme() => AppTheme.light();

Future<void> _useViewport(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
}

Future<ProviderContainer> _newContainer() async {
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  final container = await _newContainer();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: buildPrismTestEnvironment,
        theme: _theme(),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpManagement(WidgetTester tester) async {
  final playlist = LocalPlaylist(
    id: 'manage-1',
    name: '管理歌单',
    tracks: const [],
    createdAt: DateTime.utc(2026, 8, 1),
    updatedAt: DateTime.utc(2026, 8, 1),
  );
  SharedPreferences.setMockInitialValues({
    localPlaylistsStorageKey: [jsonEncode(playlist.toJson())],
  });
  await _pump(tester, const PlaylistManagementPage());
}

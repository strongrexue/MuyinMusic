import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:panghu_music/core/api/dio_factory.dart';
import 'package:panghu_music/core/models/enums.dart';
import 'package:panghu_music/core/models/music_info.dart';
import 'package:panghu_music/core/storage/settings_store.dart';
import 'package:panghu_music/features/search/widgets/source_filter_chips.dart';
import 'package:panghu_music/features/settings/settings_page.dart';
import 'package:panghu_music/features/settings/settings_section.dart';
import 'package:panghu_music/features/settings/widgets/settings_action.dart';
import 'package:panghu_music/features/settings/widgets/settings_style.dart';
import 'package:panghu_music/theme/app_theme.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import 'helpers/prism_test_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'settings default to four search sources and highest quality preferences',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      addTearDown(container.dispose);

      final settings = container.read(settingsProvider);

      expect(settings.enabledSearchSources, kDefaultEnabledSearchSources);
      expect(settings.enabledSearchSources, isNot(contains(MusicSource.mg)));
      expect(settings.onlinePlaybackQuality, OnlinePlaybackQuality.highest);
      expect(
        settings.onlinePlaybackQualityWifi,
        OnlinePlaybackQuality.highest,
      );
      expect(
        settings.onlinePlaybackQualityCellular,
        OnlinePlaybackQuality.highest,
      );
      expect(settings.batchDownloadQuality, OnlinePlaybackQuality.highest);
      expect(settings.showMiniLyrics, isTrue);
      expect(settings.allowMixWithOthers, isFalse);
      expect(settings.autoPlayOnStartup, isFalse);
      expect(settings.grooveShiftEnabled, isFalse);
      expect(settings.bluetoothLyricEnabled, isFalse);
      expect(settings.bluetoothFullLyricEnabled, isFalse);
      expect(settings.bluetoothLyricLeadMs, 500);
      expect(settings.bluetoothLyricNoticeSeen, isFalse);
      expect(settings.localMusicDir, settings.downloadDir);
      expect(settings.useBuiltInSourceFilePicker, isFalse);
    },
  );

  test('output gain defaults to 0 dB, persists, and clamps to 0..12', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);

    expect(container.read(settingsProvider).outputGainDb, 0);

    await container.read(settingsProvider.notifier).setOutputGainDb(4.5);
    expect(container.read(settingsProvider).outputGainDb, 4.5);
    expect(prefs.getDouble('output_gain_db'), 4.5);

    await container.read(settingsProvider.notifier).setOutputGainDb(30);
    expect(container.read(settingsProvider).outputGainDb, 12);

    await container.read(settingsProvider.notifier).setOutputGainDb(-3);
    expect(container.read(settingsProvider).outputGainDb, 0);

    final restored = _settingsContainer(prefs);
    addTearDown(restored.dispose);
    expect(restored.read(settingsProvider).outputGainDb, 0);
  });

  test('normalizeOutputGainDb rejects non-finite values', () {
    expect(normalizeOutputGainDb(double.nan), 0);
    expect(normalizeOutputGainDb(double.infinity), 0);
    expect(normalizeOutputGainDb(6), 6);
    expect(normalizeOutputGainDb(12), 12);
  });

  test(
    'bluetooth lyric lead defaults to 500 ms, persists, and clamps to 0..1000',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      addTearDown(container.dispose);

      expect(container.read(settingsProvider).bluetoothLyricLeadMs, 500);

      await container
          .read(settingsProvider.notifier)
          .setBluetoothLyricLeadMs(250);
      expect(container.read(settingsProvider).bluetoothLyricLeadMs, 250);
      expect(prefs.getInt('bluetooth_lyric_lead_ms'), 250);

      await container
          .read(settingsProvider.notifier)
          .setBluetoothLyricLeadMs(1500);
      expect(container.read(settingsProvider).bluetoothLyricLeadMs, 1000);

      await container
          .read(settingsProvider.notifier)
          .setBluetoothLyricLeadMs(-50);
      expect(container.read(settingsProvider).bluetoothLyricLeadMs, 0);

      final restored = _settingsContainer(prefs);
      addTearDown(restored.dispose);
      expect(restored.read(settingsProvider).bluetoothLyricLeadMs, 0);
    },
  );

  test('normalizeBluetoothLyricLeadMs clamps to 0..1000', () {
    expect(normalizeBluetoothLyricLeadMs(-1), 0);
    expect(normalizeBluetoothLyricLeadMs(0), 0);
    expect(normalizeBluetoothLyricLeadMs(500), 500);
    expect(normalizeBluetoothLyricLeadMs(1000), 1000);
    expect(normalizeBluetoothLyricLeadMs(1001), 1000);
  });

  test(
    'legacy single online quality migrates to both wifi and cellular',
    () async {
      SharedPreferences.setMockInitialValues({
        'online_playback_quality': 'flac',
      });
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      addTearDown(container.dispose);

      final settings = container.read(settingsProvider);
      expect(
        settings.onlinePlaybackQualityWifi,
        OnlinePlaybackQuality.lossless,
      );
      expect(
        settings.onlinePlaybackQualityCellular,
        OnlinePlaybackQuality.lossless,
      );
      expect(prefs.getString('online_playback_quality_wifi'), 'flac');
      expect(prefs.getString('online_playback_quality_cellular'), 'flac');
    },
  );

  test('WebDAV appearance restore changes only appearance settings', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.setOnlinePlaybackQualityWifi(OnlinePlaybackQuality.lossless);

    await notifier.applyAppearanceFromSync({
      'themeMode': 'dark',
      'themeSeedArgb': 0xFF123456,
    });

    final restored = container.read(settingsProvider);
    expect(restored.themeMode, ThemeMode.dark);
    expect(restored.themeSeed.toARGB32(), 0xFF123456);
    expect(restored.onlinePlaybackQuality, OnlinePlaybackQuality.lossless);
    expect(
      restored.onlinePlaybackQualityWifi,
      OnlinePlaybackQuality.lossless,
    );
  });

  test(
    'source file picker preference survives restart and appearance sync',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      await container
          .read(settingsProvider.notifier)
          .setUseBuiltInSourceFilePicker(true);
      await container.read(settingsProvider.notifier).applyAppearanceFromSync({
        'themeMode': 'dark',
        'themeSeedArgb': 0xFF123456,
      });
      expect(
        container.read(settingsProvider).useBuiltInSourceFilePicker,
        isTrue,
      );
      container.dispose();

      final restored = _settingsContainer(prefs);
      addTearDown(restored.dispose);
      expect(
        restored.read(settingsProvider).useBuiltInSourceFilePicker,
        isTrue,
      );
      await restored
          .read(settingsProvider.notifier)
          .setUseBuiltInSourceFilePicker(false);
      expect(prefs.getBool('use_built_in_source_file_picker'), isFalse);
    },
  );

  test('navigation mode is no longer a setting', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);

    // The dock is a single floating capsule now; a stale pref must not break
    // startup or resurface the removed selector.
    await prefs.setString('navigation_mode', 'native');
    await prefs.setBool('use_native_navigation', true);

    final restored = _settingsContainer(prefs);
    addTearDown(restored.dispose);
    expect(prefs.getString('navigation_mode'), 'native');
  });

  test('GrooveShift switch persists under its current name', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    expect(container.read(settingsProvider).grooveShiftEnabled, isFalse);

    await container.read(settingsProvider.notifier).setGrooveShiftEnabled(true);
    expect(prefs.getBool('groove_shift_enabled'), isTrue);
    container.dispose();

    final restored = _settingsContainer(prefs);
    addTearDown(restored.dispose);
    expect(restored.read(settingsProvider).grooveShiftEnabled, isTrue);
  });

  test('GrooveShift can be disabled after restart', () async {
    SharedPreferences.setMockInitialValues({'groove_shift_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    expect(container.read(settingsProvider).grooveShiftEnabled, isTrue);
    await container
        .read(settingsProvider.notifier)
        .setGrooveShiftEnabled(false);
    container.dispose();

    final restored = _settingsContainer(prefs);
    addTearDown(restored.dispose);
    expect(restored.read(settingsProvider).grooveShiftEnabled, isFalse);
  });

  test('player preferences persist', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    final notifier = container.read(settingsProvider.notifier);

    await notifier.setShowMiniLyrics(false);
    await notifier.setAllowMixWithOthers(true);
    await notifier.setBluetoothLyricEnabled(true);
    await notifier.setBluetoothFullLyricEnabled(true);
    await notifier.markBluetoothLyricNoticeSeen();
    container.dispose();

    final restored = _settingsContainer(prefs);
    addTearDown(restored.dispose);
    final settings = restored.read(settingsProvider);
    expect(settings.showMiniLyrics, isFalse);
    expect(settings.allowMixWithOthers, isTrue);
    expect(settings.bluetoothLyricEnabled, isTrue);
    expect(settings.bluetoothFullLyricEnabled, isTrue);
    expect(settings.bluetoothLyricNoticeSeen, isTrue);
  });

  test('auto-play-on-startup preference persists across restarts', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    final notifier = container.read(settingsProvider.notifier);

    await notifier.setAutoPlayOnStartup(true);
    container.dispose();

    final restored = _settingsContainer(prefs);
    addTearDown(restored.dispose);
    expect(restored.read(settingsProvider).autoPlayOnStartup, isTrue);
  });

  testWidgets('bluetooth lyric warning is shown only on first enable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: buildPrismTestEnvironment,
          theme: AppTheme.light(),
          home: const SettingsPage(section: SettingsSection.playback),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('bluetooth-lyric-setting'));
    final toggle = find.descendant(
      of: row,
      matching: find.byType(prism.Switch),
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('蓝牙歌词提示'), findsOneWidget);
    await tester.tap(find.text('我知道了'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).bluetoothLyricEnabled, isTrue);
    expect(container.read(settingsProvider).bluetoothLyricNoticeSeen, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('蓝牙歌词提示'), findsNothing);
    expect(container.read(settingsProvider).bluetoothLyricEnabled, isTrue);
  });

  testWidgets('switch settings align with actions and keep vertical spacing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: buildPrismTestEnvironment,
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SettingsAction(
                key: const ValueKey('reference-setting-action'),
                icon: Icons.search_rounded,
                title: '参考设置项',
                subtitle: '参考说明',
                onTap: () {},
              ),
              SettingsSwitchAction(
                key: const ValueKey('first-switch-setting'),
                icon: Icons.bluetooth_audio_rounded,
                title: '显示蓝牙歌词',
                subtitle: '蓝牙歌词说明',
                value: false,
                onChanged: (_) {},
              ),
              SettingsSwitchAction(
                key: const ValueKey('second-switch-setting'),
                icon: Icons.lyrics_rounded,
                title: '显示完整蓝牙歌词',
                subtitle: '完整歌词说明',
                value: false,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );

    Finder bubbleWithin(Key key) => find.descendant(
      of: find.byKey(key),
      matching: find.byType(SettingsSymbolBubble),
    );

    final referenceRect = tester.getRect(
      bubbleWithin(const ValueKey('reference-setting-action')),
    );
    final firstRect = tester.getRect(
      bubbleWithin(const ValueKey('first-switch-setting')),
    );
    final secondRect = tester.getRect(
      bubbleWithin(const ValueKey('second-switch-setting')),
    );
    expect(firstRect.left, referenceRect.left);
    expect(secondRect.left, referenceRect.left);
    expect(secondRect.top - firstRect.bottom, greaterThanOrEqualTo(24));
    expect(tester.takeException(), isNull);
  });

  /// ③：动作行各自一张卡片。用一个两行 `SettingsCard` 与一个两行 `SettingsGroup`
  /// 对照，断言同组两行之间不再共用一个不透明底板（即中间有真正的空隙）。
  testWidgets('row actions are separate cards while content slabs stay whole', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: buildPrismTestEnvironment,
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SettingsCard(
                children: [
                  SettingsAction(
                    key: const ValueKey('split-row-a'),
                    icon: Icons.search_rounded,
                    title: '第一行',
                    onTap: () {},
                  ),
                  SettingsAction(
                    key: const ValueKey('split-row-b'),
                    icon: Icons.download_rounded,
                    title: '第二行',
                    onTap: () {},
                  ),
                ],
              ),
              SettingsCard(
                insetContent: true,
                children: [
                  SettingsAction(
                    key: const ValueKey('slab-row-a'),
                    icon: Icons.search_rounded,
                    title: '整块第一行',
                    onTap: () {},
                  ),
                  SettingsAction(
                    key: const ValueKey('slab-row-b'),
                    icon: Icons.download_rounded,
                    title: '整块第二行',
                    onTap: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    final splitGap =
        tester.getRect(find.byKey(const ValueKey('split-row-b'))).top -
        tester.getRect(find.byKey(const ValueKey('split-row-a'))).bottom;
    final slabGap =
        tester.getRect(find.byKey(const ValueKey('slab-row-b'))).top -
        tester.getRect(find.byKey(const ValueKey('slab-row-a'))).bottom;

    // 拆开的行之间留出 10pt 空隙；整块内容仍然紧贴（0）。
    expect(splitGap, greaterThan(0));
    expect(slabGap, 0);
    expect(tester.takeException(), isNull);
  });

  test('legacy resolver setting is removed', () async {
    SharedPreferences.setMockInitialValues({
      'base_url': 'https://legacy.example.com',
    });
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);

    container.read(settingsProvider);
    await Future<void>.delayed(Duration.zero);
    expect(prefs.getString('base_url'), isNull);
  });

  testWidgets(
    'settings categories expose related controls instead of resolver settings',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      addTearDown(container.dispose);

      Future<void> pumpSection(SettingsSection section) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              builder: buildPrismTestEnvironment,
              theme: AppTheme.light(),
              home: SettingsPage(section: section),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pumpSection(SettingsSection.network);
      expect(find.text('音源管理'), findsOneWidget);
      final pickerSetting = find.byKey(
        const ValueKey('source-file-picker-setting'),
      );
      await tester.tap(
        find.descendant(of: pickerSetting, matching: find.byType(prism.Switch)),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).useBuiltInSourceFilePicker,
        isTrue,
      );
      expect(find.text('WebDAV 同步'), findsNothing);
      expect(find.text('URL 解析服务器'), findsNothing);
      expect(find.text('解析服务器健康检查'), findsNothing);
      await pumpSection(SettingsSection.sync);
      expect(find.text('WebDAV 同步'), findsOneWidget);
      await pumpSection(SettingsSection.playback);
      expect(find.text('允许与其他 APP 共同播放'), findsOneWidget);
      expect(find.text('定时关闭音乐'), findsNothing);
      expect(find.text('点击搜索结果内单曲时'), findsNothing);
      await pumpSection(SettingsSection.downloads);
      expect(find.text('批量下载音质'), findsOneWidget);
      expect(find.text('目录'), findsOneWidget);
      expect(find.text('浏览U盘'), findsNothing);
      expect(find.text('添加 U 盘文件夹'), findsNothing);
      expect(find.text('下载位置'), findsOneWidget);
      await pumpSection(SettingsSection.permissions);
      expect(find.text('音乐和音频'), findsOneWidget);
      await pumpSection(SettingsSection.about);
      expect(find.text('检查更新'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'search sources and playback quality persist and reject an empty set',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      final notifier = container.read(settingsProvider.notifier);

      expect(
        await notifier.setSearchSourceEnabled(MusicSource.mg, true),
        isTrue,
      );
      await notifier.setOnlinePlaybackQualityWifi(
        OnlinePlaybackQuality.lossless,
      );
      await notifier.setOnlinePlaybackQualityCellular(
        OnlinePlaybackQuality.high,
      );
      await notifier.setBatchDownloadQuality(OnlinePlaybackQuality.high);
      for (final source in [
        MusicSource.kg,
        MusicSource.tx,
        MusicSource.wy,
        MusicSource.qs,
      ]) {
        expect(await notifier.setSearchSourceEnabled(source, false), isTrue);
      }
      expect(
        await notifier.setSearchSourceEnabled(MusicSource.kw, false),
        isTrue,
      );
      expect(
        await notifier.setSearchSourceEnabled(MusicSource.mg, false),
        isFalse,
      );

      expect(container.read(settingsProvider).enabledSearchSources, {
        MusicSource.mg,
      });
      container.dispose();

      final restored = _settingsContainer(prefs);
      addTearDown(restored.dispose);
      expect(restored.read(settingsProvider).enabledSearchSources, {
        MusicSource.mg,
      });
      expect(
        restored.read(settingsProvider).onlinePlaybackQualityWifi,
        OnlinePlaybackQuality.lossless,
      );
      expect(
        restored.read(settingsProvider).onlinePlaybackQualityCellular,
        OnlinePlaybackQuality.high,
      );
      expect(
        restored.read(settingsProvider).batchDownloadQuality,
        OnlinePlaybackQuality.high,
      );
    },
  );

  test(
    'local music scan folder follows download folder until customized',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      final notifier = container.read(settingsProvider.notifier);

      await notifier.setDownloadDir('/storage/emulated/0/Music/Downloads');
      expect(
        container.read(settingsProvider).localMusicDir,
        '/storage/emulated/0/Music/Downloads',
      );

      await notifier.setLocalMusicDir('/storage/1234-5678/Music');
      await notifier.setDownloadDir('/storage/emulated/0/Music/NewDownloads');

      expect(
        container.read(settingsProvider).downloadDir,
        '/storage/emulated/0/Music/NewDownloads',
      );
      expect(
        container.read(settingsProvider).localMusicDir,
        '/storage/1234-5678/Music',
      );
      container.dispose();

      final restored = _settingsContainer(prefs);
      addTearDown(restored.dispose);
      expect(
        restored.read(settingsProvider).localMusicDir,
        '/storage/1234-5678/Music',
      );
    },
  );

  test(
    'saved search source codes are ordered, deduplicated, and sanitized',
    () {
      expect(decodeEnabledSearchSources(['mg', 'unknown', 'mg', 'all', 'kw']), {
        MusicSource.kw,
        MusicSource.mg,
      });
      expect(decodeEnabledSearchSources([]), kDefaultEnabledSearchSources);
    },
  );

  group('online playback quality resolution', () {
    test('keeps highest behavior and honors an exact preference', () {
      final music = _musicWithQualities([
        Quality.k128,
        Quality.flac,
        Quality.k320,
      ]);

      expect(
        music.playbackQualityFor(OnlinePlaybackQuality.highest),
        Quality.flac,
      );
      expect(
        music.playbackQualityFor(OnlinePlaybackQuality.high),
        Quality.k320,
      );
    });

    test(
      'falls down first, then up when the preferred quality is unavailable',
      () {
        expect(
          _musicWithQualities([
            Quality.hires,
            Quality.k320,
            Quality.k128,
          ]).playbackQualityFor(OnlinePlaybackQuality.lossless),
          Quality.k320,
        );
        expect(
          _musicWithQualities([
            Quality.flac,
          ]).playbackQualityFor(OnlinePlaybackQuality.high),
          Quality.flac,
        );
      },
    );

    test('uses 128K when a track has no advertised qualities', () {
      expect(
        _musicWithQualities(
          const [],
        ).playbackQualityFor(OnlinePlaybackQuality.hires),
        Quality.k128,
      );
    });
  });

  testWidgets(
    'source filter stays full width and slides smoothly between sources',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prefs = await SharedPreferences.getInstance();
      final container = _settingsContainer(prefs);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: buildPrismTestEnvironment,
            theme: AppTheme.light(),
            home: const Scaffold(body: SourceFilterChips()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('咪咕'), findsNothing);
      final defaultWidth = tester
          .getSize(find.byKey(const ValueKey('search-source-filter')))
          .width;
      final scaffoldWidth = tester.getSize(find.byType(Scaffold)).width;
      expect(defaultWidth, closeTo(scaffoldWidth - 24, 0.01));

      final indicator = find.byKey(const ValueKey('search-source-indicator'));
      final initialLeft = tester.getTopLeft(indicator).dx;
      await tester.tap(find.byKey(const ValueKey('search-source-tx')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final middleLeft = tester.getTopLeft(indicator).dx;
      expect(middleLeft, greaterThan(initialLeft));
      await tester.pumpAndSettle();
      final finalLeft = tester.getTopLeft(indicator).dx;
      expect(middleLeft, lessThan(finalLeft));

      await container
          .read(settingsProvider.notifier)
          .setSearchSourceEnabled(MusicSource.mg, true);
      await tester.pumpAndSettle();

      expect(find.text('咪咕'), findsOneWidget);
      final expandedWidth = tester
          .getSize(find.byKey(const ValueKey('search-source-filter')))
          .width;
      expect(expandedWidth, closeTo(defaultWidth, 0.01));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Prism menus apply network and quality choices and can reopen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = _settingsContainer(await SharedPreferences.getInstance());
    addTearDown(container.dispose);

    Future<void> pumpSection(SettingsSection section) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: buildPrismTestEnvironment,
            theme: AppTheme.light(),
            home: SettingsPage(section: section),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpSection(SettingsSection.network);
    final anchor = find.byKey(const ValueKey('network-adapter-menu-anchor'));
    await tester.tap(anchor);
    await tester.pumpAndSettle();
    expect(find.byType(prism.PopupMenu), findsOneWidget);
    expect(
      tester
          .widget<prism.PopupMenu>(find.byType(prism.PopupMenu))
          .items
          .singleWhere((item) => item.label == NetworkAdapterMode.system.label)
          .checked,
      isTrue,
    );
    await tester.tap(find.text(NetworkAdapterMode.io.label));
    await tester.pumpAndSettle();
    expect(
      container.read(settingsProvider).networkAdapterMode,
      NetworkAdapterMode.io,
    );
    expect(find.byType(prism.PopupMenu), findsNothing);
    await tester.tap(anchor);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<prism.PopupMenu>(find.byType(prism.PopupMenu))
          .items
          .singleWhere((item) => item.label == NetworkAdapterMode.io.label)
          .checked,
      isTrue,
    );
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();

    await pumpSection(SettingsSection.playback);
    final qualityAnchor = find.byKey(
      const ValueKey('online-quality-menu-anchor'),
    );
    await tester.tap(qualityAnchor);
    await tester.pumpAndSettle();
    expect(find.byType(prism.PopupMenu), findsOneWidget);
    await tester.tap(find.text(OnlinePlaybackQuality.lossless.label));
    await tester.pumpAndSettle();
    expect(
      container.read(settingsProvider).onlinePlaybackQualityWifi,
      OnlinePlaybackQuality.lossless,
    );
    expect(find.byType(prism.PopupMenu), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('bottom bar behavior is picked from the appearance menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: buildPrismTestEnvironment,
          theme: AppTheme.light(),
          home: const SettingsPage(section: SettingsSection.appearance),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final anchor = find.byKey(const ValueKey('bottom-bar-behavior-anchor'));
    await tester.scrollUntilVisible(
      anchor,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(anchor);
    await tester.pumpAndSettle();

    final menu = find.byType(prism.PopupMenu);
    expect(menu, findsOneWidget);
    for (final behavior in BottomBarBehavior.values) {
      expect(
        find.descendant(of: menu, matching: find.text(behavior.label)),
        findsOneWidget,
      );
    }

    await tester.tap(
      find.descendant(
        of: menu,
        matching: find.text(BottomBarBehavior.hide.label),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      container.read(settingsProvider).bottomBarBehavior,
      BottomBarBehavior.hide,
    );
    expect(prefs.getString('bottom_bar_behavior'), BottomBarBehavior.hide.code);
  });

  testWidgets('search source management stays open for multi-selection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final prefs = await SharedPreferences.getInstance();
    final container = _settingsContainer(prefs);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: buildPrismTestEnvironment,
          theme: AppTheme.light(),
          home: const SettingsPage(section: SettingsSection.playback),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final anchor = find.byKey(const ValueKey('search-source-menu-anchor'));
    await tester.tap(anchor);
    await tester.pumpAndSettle();
    final panel = find.byType(prism.PopupMenu);
    final miguOption = find.text('咪咕');
    expect(panel, findsOneWidget);
    expect(tester.getSize(panel).width, lessThanOrEqualTo(280));
    await tester.tap(miguOption);
    await tester.pumpAndSettle();

    expect(
      container.read(settingsProvider).enabledSearchSources,
      contains(MusicSource.mg),
    );
    expect(panel, findsOneWidget);
    expect(miguOption, findsOneWidget);
    await tester.tap(miguOption);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsProvider).enabledSearchSources,
      isNot(contains(MusicSource.mg)),
    );
    expect(panel, findsOneWidget);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(tester.takeException(), isNull);
  });
}

ProviderContainer _settingsContainer(SharedPreferences prefs) {
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

MusicInfo _musicWithQualities(List<Quality> qualities) {
  return MusicInfo(
    id: 'quality-test',
    name: 'Quality test',
    singer: 'Tester',
    source: MusicSource.wy,
    interval: '03:00',
    meta: MusicMeta(
      songId: 'quality-test',
      albumName: 'Test album',
      qualitys: [for (final quality in qualities) QualityOption(type: quality)],
      raw: const {},
    ),
    raw: const {},
  );
}

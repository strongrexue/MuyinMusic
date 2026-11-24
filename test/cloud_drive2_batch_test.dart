import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/models/music_url.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/cloud/cloud_drive2_client.dart';
import 'package:cy_shine_music/features/cloud/cloud_library.dart';
import 'package:cy_shine_music/features/cloud/cloud_song_path.dart';
import 'package:cy_shine_music/features/cloud/cloud_song_scanner.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/settings/cloud_drive2_settings_page.dart';
import 'package:cy_shine_music/features/songs/local_song_scan_cache.dart';
import 'package:cy_shine_music/router.dart';

import 'helpers/prism_test_environment.dart';

CloudFileItem _item(String path, {bool dir = false}) {
  final name = path.split('/').last;
  return CloudFileItem(
    id: path,
    name: name,
    fullPathName: path,
    isDirectory: dir,
    sizeBytes: dir ? 0 : 100,
    createdAt: DateTime.utc(2026),
    modifiedAt: DateTime.utc(2026),
  );
}

Map<String, List<CloudFileItem>> _tree() => {
  '/': [
    _item('/Music', dir: true),
    _item('/Other', dir: true),
    _item('/Cloud Song.flac'),
  ],
  '/Music': [_item('/Music/Nested Cloud.mp3')],
  '/Other': [_item('/Other/Other Song.mp3')],
};

class _FakeClient implements CloudDrive2Client {
  _FakeClient(this.tree, {this.probeResult = _connectedProbe});

  final Map<String, List<CloudFileItem>> tree;
  final CloudConnectionResult probeResult;

  static const _connectedProbe = CloudConnectionResult(
    status: CloudConnectionStatus.connected,
    userName: 'nas-user',
    isLogin: true,
  );

  @override
  Future<List<CloudFileItem>> listFiles(String path) async =>
      tree[path] ?? const [];

  @override
  // Dead loopback port: tag hydration fails fast (connection refused)
  // instead of hanging on real network timeouts.
  Future<MusicUrl> resolvePlayback(String remotePath) async =>
      MusicUrl(url: 'http://127.0.0.1:1$remotePath');

  @override
  Future<bool> checkConnection() async => probeResult.ok;

  @override
  Future<CloudConnectionResult> probeConnection() async => probeResult;

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('music root setting', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to all files and normalizes on save', () async {
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      expect(container.read(settingsProvider).cloudDrive2MusicRoot, '');
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setCloudDrive2MusicRoot('/Music/');
      expect(container.read(settingsProvider).cloudDrive2MusicRoot, '/Music');
      expect(prefs.getString('cloud_drive2_music_root'), '/Music');
      await notifier.setCloudDrive2MusicRoot('/');
      expect(container.read(settingsProvider).cloudDrive2MusicRoot, '');
    });

    test('root path helpers map the empty setting to the token root', () {
      expect(cloudScanRootPath(''), '/');
      expect(cloudScanRootPath('/Music'), '/Music');
      expect(cloudMusicRootLabel(''), '全部文件');
      expect(cloudMusicRootLabel('/'), '全部文件');
      expect(cloudMusicRootLabel('/Music/Rock'), 'Rock');
    });
  });

  group('root-scoped enumeration', () {
    test('only enumerates below the selected root', () async {
      final rows = await enumerateCloudSongs(
        _FakeClient(_tree()),
        rootPath: '/Music',
      );
      expect(rows.map((row) => row.path), [
        'cloud://cd2/Music/Nested Cloud.mp3',
      ]);
    });
  });

  group('library refresh with a selected root', () {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    late Directory support;
    late LocalSongScanCache cache;
    late ProviderContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'cloud_drive2_enabled': true,
        'cloud_drive2_server': '192.168.1.10:19798',
        'cloud_drive2_api_token': 'token-123',
      });
      support = await Directory.systemTemp.createTemp('muyin-cd2-batch-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (_) async => support.path,
          );
      final prefs = await SharedPreferences.getInstance();
      container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      cache = LocalSongScanCache();
    });

    tearDown(() async {
      cache.dispose();
      container.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      await support.delete(recursive: true);
    });

    test('switching roots drops rows outside the new root', () async {
      final library = CloudDrive2Library(
        settings: () => container.read(settingsProvider),
        scanCache: () => cache,
        clientFactory: (_) => _FakeClient(_tree()),
      );
      addTearDown(library.dispose);

      await library.refresh();
      var cloudPaths = [
        for (final file in cache.snapshot!.files)
          if (isCloudSongPath(file.path)) file.path,
      ];
      expect(cloudPaths, contains('cloud://cd2/Other/Other Song.mp3'));
      expect(cloudPaths, contains('cloud://cd2/Music/Nested Cloud.mp3'));
      expect(cloudPaths, contains('cloud://cd2/Cloud Song.flac'));

      await container
          .read(settingsProvider.notifier)
          .setCloudDrive2MusicRoot('/Music');
      await library.refresh();
      cloudPaths = [
        for (final file in cache.snapshot!.files)
          if (isCloudSongPath(file.path)) file.path,
      ];
      expect(cloudPaths, ['cloud://cd2/Music/Nested Cloud.mp3']);
    });

    test('testConnection probes with the typed values', () async {
      CloudDrive2Config? seenConfig;
      final library = CloudDrive2Library(
        settings: () => container.read(settingsProvider),
        scanCache: () => cache,
        clientFactory: (config) {
          seenConfig = config;
          return _FakeClient(_tree());
        },
      );
      addTearDown(library.dispose);

      final result = await library.testConnection(
        server: 'nas.local:21000',
        token: 'typed-token',
      );
      expect(result.ok, isTrue);
      expect(result.message, '连接成功 · 账号 nas-user');
      expect(seenConfig?.host, 'nas.local');
      expect(seenConfig?.port, 21000);
      expect(seenConfig?.token, 'typed-token');

      final invalid = await library.testConnection(server: ' ', token: 'x');
      expect(invalid.ok, isFalse);
      expect(invalid.status, CloudConnectionStatus.unreachable);
    });
  });

  group('songs page cloud tab', () {
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );

    Future<({ProviderContainer container, GoRouter router})> pumpSongsPage(
      WidgetTester tester, {
      required bool cloudEnabled,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // 真实文件 IO 必须在 runAsync 里做：在 testWidgets 的 fake-async
      // 区里直接 await 文件操作会永远等不到完成事件。
      final support = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('muyin-cd2-ui-'),
      ))!;
      addTearDown(() => support.delete(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (_) async => support.path,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null),
      );
      final musicDir = Directory(p.join(support.path, 'music'));
      await tester.runAsync(() async {
        await musicDir.create();
        await File(p.join(musicDir.path, 'Local Song.mp3')).writeAsString('x');
      });

      SharedPreferences.setMockInitialValues({
        'local_music_dirs': [musicDir.path],
        'cloud_drive2_enabled': cloudEnabled,
        'cloud_drive2_server': '192.168.1.10:19798',
        'cloud_drive2_api_token': 'token-123',
      });
      final prefs = await SharedPreferences.getInstance();
      late ProviderContainer container;
      final library = CloudDrive2Library(
        settings: () => container.read(settingsProvider),
        scanCache: () => container.read(localSongScanCacheProvider),
        clientFactory: (_) => _FakeClient(_tree()),
      );
      final audioHandler = PlayerAudioHandler();
      addTearDown(() => unawaited(audioHandler.disposeHandler()));
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playerAudioHandlerProvider.overrideWithValue(audioHandler),
          cloudDrive2LibraryProvider.overrideWith((_) => library),
        ],
      );
      addTearDown(container.dispose);
      // 预置扫描索引清单：本地行与云端行直接进快照，绕开 fake-async
      // 环境里真实文件扫描的不确定性；云端行随后会被库的 refresh
      // 用同一 fake 树重新枚举替换，集合不变。
      final manifest = LocalSongScanSnapshot(
        // 快照里的 directories 是扫描侧归一化后的口径，页面种子与变更
        // 监听都按它比对，必须存归一化结果而不是设置侧的原始列表。
        directories: normalizeScanDirectories(
          container.read(settingsProvider).scanDirectories,
        ),
        cachedAt: DateTime.utc(2026),
        files: [
          LocalSongFileSnapshot(
            path: p.join(musicDir.path, 'Local Song.mp3'),
            fileName: 'Local Song.mp3',
            extension: 'mp3',
            createdAt: DateTime.utc(2026),
            modifiedAt: DateTime.utc(2026),
            sizeBytes: 3,
            directory: musicDir.path,
          ),
          cloudFileToSnapshot(_item('/Cloud Song.flac'))!,
          cloudFileToSnapshot(_item('/Music/Nested Cloud.mp3'))!,
          cloudFileToSnapshot(_item('/Other/Other Song.mp3'))!,
        ],
      );
      await tester.runAsync(
        () => File(
          p.join(support.path, 'local_song_scan_v1.json'),
        ).writeAsString(jsonEncode(manifest.toJson())),
      );
      // 在真实异步区里把清单载入内存快照：页面 initState 的种子逻辑
      // 命中内存快照即可，不依赖 fake-async 区里的文件 IO 完成时机。
      await tester.runAsync(
        () => container.read(localSongScanCacheProvider).ensureLoaded(),
      );
      final router = createAppRouter(initialLocation: '/songs');
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
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
      // 页面 initState 的扫描初始化挂着真实异步（文件/通道），在
      // fake-async 区里不会自己落地；给它一段真实异步时间在 widget
      // 仍挂载时完成，免得测试结束后才恢复执行、踩已 dispose 的 ref。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await _pumpUi(tester);
      return (container: container, router: router);
    }

    testWidgets('keeps three tabs while CloudDrive2 is not configured', (
      tester,
    ) async {
      await pumpSongsPage(tester, cloudEnabled: false);
      final tabs = find.byKey(const ValueKey('songs-library-tabs'));
      expect(tabs, findsOneWidget);
      expect(
        find.descendant(of: tabs, matching: find.text('本地音乐')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tabs, matching: find.text('歌单')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tabs, matching: find.text('云端音乐')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('cloud tab shows only cloud songs, local tab only local', (
      tester,
    ) async {
      final harness = await pumpSongsPage(tester, cloudEnabled: true);
      final tabs = find.byKey(const ValueKey('songs-library-tabs'));
      expect(
        find.descendant(of: tabs, matching: find.text('云端音乐')),
        findsOneWidget,
      );

      await tester.tap(find.descendant(of: tabs, matching: find.text('本地音乐')));
      await _pumpUi(tester);
      expect(find.textContaining('Local Song'), findsWidgets);
      expect(find.textContaining('Cloud Song'), findsNothing);
      expect(find.textContaining('Other Song'), findsNothing);

      await tester.tap(find.descendant(of: tabs, matching: find.text('云端音乐')));
      await _pumpUi(tester);
      expect(find.textContaining('Cloud Song'), findsWidgets);
      expect(find.textContaining('Nested Cloud'), findsWidgets);
      expect(find.textContaining('Other Song'), findsWidgets);
      expect(find.textContaining('Local Song'), findsNothing);
      // 文件夹快捷行：未选根时 chip 显示「全部文件」，旁边是总数。
      expect(find.byKey(const ValueKey('cloud-folder-picker')), findsOneWidget);
      expect(find.text('全部文件'), findsOneWidget);
      expect(find.text('3 首'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cloud-refresh-button')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(harness.container.read(settingsProvider).cloudDrive2MusicRoot, '');
    });

    testWidgets('folder picker stores the selected root', (tester) async {
      final harness = await pumpSongsPage(tester, cloudEnabled: true);
      harness.router.push('/songs/cloud-folders');
      await _pumpUi(tester);

      // 根层：文件夹可点、文件灰显。
      expect(find.byKey(const ValueKey('cloud-folder-/Music')), findsOneWidget);
      final fileTile = tester.widget<ListTile>(
        find.byKey(const ValueKey('cloud-file-/Cloud Song.flac')),
      );
      expect(fileTile.enabled, isFalse);

      await tester.tap(find.byKey(const ValueKey('cloud-folder-/Music')));
      await _pumpUi(tester);
      expect(
        find.byKey(const ValueKey('cloud-file-/Music/Nested Cloud.mp3')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('cloud-folder-select-current')),
      );
      await _pumpUi(tester);
      expect(
        harness.container.read(settingsProvider).cloudDrive2MusicRoot,
        '/Music',
      );
      expect(harness.router.routeInformationProvider.value.uri.path, '/songs');
      expect(tester.takeException(), isNull);
      // 选择成功的 toast 有 3 秒自动消失计时器，泵过去免得残留。
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('cloud drive2 settings page', () {
    Future<ProviderContainer> pumpSettingsPage(
      WidgetTester tester, {
      required CloudConnectionResult probeResult,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'cloud_drive2_server': '192.168.1.10:19798',
        'cloud_drive2_api_token': 'token-123',
      });
      final prefs = await SharedPreferences.getInstance();
      late ProviderContainer container;
      final cache = LocalSongScanCache();
      addTearDown(cache.dispose);
      final library = CloudDrive2Library(
        settings: () => container.read(settingsProvider),
        scanCache: () => cache,
        clientFactory: (_) => _FakeClient(_tree(), probeResult: probeResult),
      );
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          cloudDrive2LibraryProvider.overrideWith((_) => library),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: buildPrismTestEnvironment,
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            ),
            home: const CloudDrive2SettingsPage(),
          ),
        ),
      );
      await _pumpUi(tester);
      return container;
    }

    testWidgets('test connection shows server info on success', (tester) async {
      await pumpSettingsPage(
        tester,
        probeResult: const CloudConnectionResult(
          status: CloudConnectionStatus.connected,
          userName: 'nas-user',
          isLogin: true,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('cloud-drive2-test-button')));
      await _pumpUi(tester);
      expect(
        find.byKey(const ValueKey('cloud-drive2-test-result')),
        findsOneWidget,
      );
      expect(find.text('连接成功 · 账号 nas-user'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // 成功 toast 有 3 秒自动消失计时器，泵过去免得残留 pending timer。
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('test connection shows the failure reason', (tester) async {
      await pumpSettingsPage(
        tester,
        probeResult: const CloudConnectionResult(
          status: CloudConnectionStatus.unauthorized,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('cloud-drive2-test-button')));
      await _pumpUi(tester);
      expect(find.text('API 令牌无效或无访问权限'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

Future<void> _pumpUi(WidgetTester tester) async {
  for (var index = 0; index < 12; index++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

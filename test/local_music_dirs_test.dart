import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/storage/settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'legacy scan folder migrates into a normalized persistent folder list',
    () async {
      SharedPreferences.setMockInitialValues({
        'download_dir': '/downloads',
        'local_music_dir': '/music/legacy',
      });
      final prefs = await SharedPreferences.getInstance();
      ProviderContainer createContainer() => ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      final container = createContainer();
      addTearDown(container.dispose);
      expect(container.read(settingsProvider).localMusicDirs, [
        '/music/legacy',
      ]);

      final notifier = container.read(settingsProvider.notifier);
      await notifier.setLocalMusicDirs([
        '/music/a/',
        ' ',
        '/music/a',
        ' /music/./b ',
      ]);
      expect(container.read(settingsProvider).localMusicDirs, [
        '/music/a',
        '/music/b',
      ]);
      expect(prefs.getStringList('local_music_dirs'), ['/music/a', '/music/b']);
      expect(prefs.getString('local_music_dir'), '/music/a');
      await notifier.setDownloadDir('/new-downloads');
      expect(container.read(settingsProvider).localMusicDirs, [
        '/music/a',
        '/music/b',
      ]);
      // 下载目录作为隐含扫描根出现在 scanDirectories，但不落盘。
      expect(container.read(settingsProvider).scanDirectories, [
        '/music/a',
        '/music/b',
        '/new-downloads',
      ]);
      expect(prefs.getStringList('local_music_dirs'), ['/music/a', '/music/b']);

      final restored = createContainer();
      addTearDown(restored.dispose);
      expect(restored.read(settingsProvider).localMusicDirs, [
        '/music/a',
        '/music/b',
      ]);
      await notifier.setLocalMusicDirs([]);
      expect(container.read(settingsProvider).localMusicDirs, [
        '/new-downloads',
      ]);
      await notifier.setLocalMusicDir('/single');
      expect(container.read(settingsProvider).localMusicDirs, ['/single']);
    },
  );

  test(
    'changing the download folder never rewrites the scan folder list',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      final defaultDir = container.read(settingsProvider).downloadDir;
      expect(container.read(settingsProvider).localMusicDirs, [defaultDir]);
      expect(container.read(settingsProvider).scanDirectories, [defaultDir]);

      // 出厂同值情形：改下载目录也不再连带改写扫描目录。
      await notifier.setDownloadDir('/downloads');
      expect(container.read(settingsProvider).localMusicDirs, [defaultDir]);
      // 扫描列表从未被写盘：local_music_dirs 仍不存在。
      expect(prefs.getStringList('local_music_dirs'), isNull);
      // 下载目录只作为隐含根参与扫描集合，不写进 local_music_dirs。
      expect(container.read(settingsProvider).scanDirectories, [
        defaultDir,
        '/downloads',
      ]);

      await notifier.setLocalMusicDirs(['/downloads', '/other']);
      await notifier.setDownloadDir('/new-downloads');
      expect(container.read(settingsProvider).localMusicDirs, [
        '/downloads',
        '/other',
      ]);
      expect(container.read(settingsProvider).scanDirectories, [
        '/downloads',
        '/other',
        '/new-downloads',
      ]);
      expect(prefs.getStringList('local_music_dirs'), [
        '/downloads',
        '/other',
      ]);
    },
  );

  test('build preserves a stored external download directory', () async {
    SharedPreferences.setMockInitialValues({
      'download_dir': '/external/Downloads',
      'local_music_dirs': ['/music'],
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final settings = container.read(settingsProvider);
    expect(settings.downloadDir, '/external/Downloads');
    expect(settings.localMusicDirs, ['/music']);
    expect(settings.scanDirectories, ['/music', '/external/Downloads']);
  });

  test(
    'scan roots deduplicate a download folder already in the scan list',
    () async {
      SharedPreferences.setMockInitialValues({
        'download_dir': '/music',
        'local_music_dirs': ['/music', '/other'],
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      expect(container.read(settingsProvider).scanDirectories, [
        '/music',
        '/other',
      ]);
    },
  );

  test('ignored local song paths persist across provider rebuilds', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer createContainer() => ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    final container = createContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    expect(container.read(settingsProvider).ignoredLocalSongPaths, isEmpty);

    await notifier.ignoreLocalSongPaths([
      '/music/a.mp3',
      '/music/b.flac',
      '/music/a.mp3',
    ]);
    expect(container.read(settingsProvider).ignoredLocalSongPaths, [
      '/music/a.mp3',
      '/music/b.flac',
    ]);
    expect(prefs.getStringList('local_music_ignored_paths'), [
      '/music/a.mp3',
      '/music/b.flac',
    ]);

    // 模拟重启：新容器从同一份 prefs 读回名单。
    final restored = createContainer();
    addTearDown(restored.dispose);
    expect(restored.read(settingsProvider).ignoredLocalSongPaths, [
      '/music/a.mp3',
      '/music/b.flac',
    ]);

    await restored.read(settingsProvider.notifier).unignoreLocalSongPaths([
      '/music/a.mp3',
    ]);
    expect(restored.read(settingsProvider).ignoredLocalSongPaths, [
      '/music/b.flac',
    ]);
    expect(prefs.getStringList('local_music_ignored_paths'), ['/music/b.flac']);
  });
}

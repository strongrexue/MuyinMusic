import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:muyin_music/core/storage/settings_store.dart';

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
    'default scan folder follows the download folder until multiple roots are configured',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      expect(container.read(settingsProvider).localMusicDirs, [
        container.read(settingsProvider).downloadDir,
      ]);
      await notifier.setDownloadDir('/downloads');
      expect(container.read(settingsProvider).localMusicDirs, ['/downloads']);
      await notifier.setLocalMusicDirs(['/downloads', '/other']);
      await notifier.setDownloadDir('/new-downloads');
      expect(container.read(settingsProvider).localMusicDirs, [
        '/downloads',
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

  test('ignored records carry display info and prune on restore', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer createContainer() => ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    final container = createContainer();
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);

    const contentPath = 'content://media/external_primary/audio/media/154346';
    await notifier.ignoreLocalSongs(const [
      IgnoredLocalSongRecord(
        path: contentPath,
        title: '麦恩莉',
        singer: '方大同',
        location: '/storage/emulated/0/Music/麦恩莉.mp3',
      ),
      IgnoredLocalSongRecord(
        path: '/music/plain.mp3',
        title: 'Plain',
        location: '/music/plain.mp3',
      ),
    ]);
    // 路径集合语义不变：扫描过滤消费的仍是这两个路径。
    expect(container.read(settingsProvider).ignoredLocalSongPaths, [
      contentPath,
      '/music/plain.mp3',
    ]);
    expect(container.read(settingsProvider).ignoredLocalSongRecords, [
      const IgnoredLocalSongRecord(
        path: contentPath,
        title: '麦恩莉',
        singer: '方大同',
        location: '/storage/emulated/0/Music/麦恩莉.mp3',
      ),
      const IgnoredLocalSongRecord(
        path: '/music/plain.mp3',
        title: 'Plain',
        location: '/music/plain.mp3',
      ),
    ]);

    // 模拟重启：记录与路径一起读回。
    final restored = createContainer();
    addTearDown(restored.dispose);
    expect(restored.read(settingsProvider).ignoredLocalSongRecords, [
      const IgnoredLocalSongRecord(
        path: contentPath,
        title: '麦恩莉',
        singer: '方大同',
        location: '/storage/emulated/0/Music/麦恩莉.mp3',
      ),
      const IgnoredLocalSongRecord(
        path: '/music/plain.mp3',
        title: 'Plain',
        location: '/music/plain.mp3',
      ),
    ]);

    await restored.read(settingsProvider.notifier).unignoreLocalSongPaths([
      contentPath,
    ]);
    expect(restored.read(settingsProvider).ignoredLocalSongPaths, [
      '/music/plain.mp3',
    ]);
    expect(restored.read(settingsProvider).ignoredLocalSongRecords, [
      const IgnoredLocalSongRecord(
        path: '/music/plain.mp3',
        title: 'Plain',
        location: '/music/plain.mp3',
      ),
    ]);
  });

  test('legacy path-only ignored list loads without records', () async {
    SharedPreferences.setMockInitialValues({
      'local_music_ignored_paths': ['/music/legacy.mp3'],
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    expect(container.read(settingsProvider).ignoredLocalSongPaths, [
      '/music/legacy.mp3',
    ]);
    expect(container.read(settingsProvider).ignoredLocalSongRecords, isEmpty);

    // 存量条目照常可恢复。
    await container.read(settingsProvider.notifier).unignoreLocalSongPaths([
      '/music/legacy.mp3',
    ]);
    expect(container.read(settingsProvider).ignoredLocalSongPaths, isEmpty);
  });
}

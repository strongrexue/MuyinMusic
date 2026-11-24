import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart'
    show TestWidgetsFlutterBinding, TestDefaultBinaryMessengerBinding;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:cy_shine_music/features/songs/local_song_scan_cache.dart';
import 'package:cy_shine_music/features/songs/local_song_scanner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('round-trips the persisted local song manifest', () {
    final snapshot = LocalSongScanSnapshot(
      directory: '/music/downloads',
      cachedAt: DateTime.utc(2026, 7, 21, 8, 30),
      files: [
        LocalSongFileSnapshot(
          path: '/music/downloads/artist - title.flac',
          fileName: 'artist - title.flac',
          extension: 'flac',
          createdAt: DateTime.utc(2026, 7, 20),
          modifiedAt: DateTime.utc(2026, 7, 21),
          sizeBytes: 1024,
        ),
      ],
      error: null,
    );

    final restored = LocalSongScanSnapshot.fromJson(snapshot.toJson());

    expect(restored.directory, snapshot.directory);
    expect(restored.cachedAt, snapshot.cachedAt);
    expect(restored.files, hasLength(1));
    expect(restored.files.single.path, snapshot.files.single.path);
    expect(restored.files.single.modifiedAt, snapshot.files.single.modifiedAt);
    expect(restored.files.single.sizeBytes, 1024);
  });

  test('ignores malformed manifest rows without failing the cache', () {
    final restored = LocalSongScanSnapshot.fromJson({
      'directory': '/music/downloads',
      'cachedAt': '2026-07-21T08:30:00Z',
      'files': [
        {'path': '', 'fileName': ''},
        {'path': '/music/downloads/song.mp3', 'fileName': 'song.mp3'},
      ],
    });

    expect(restored.files, hasLength(1));
    expect(restored.files.single.path, '/music/downloads/song.mp3');
  });

  group('multiple scan folders', () {
    late Directory root;
    late Directory parent;
    late Directory nested;
    late Directory extra;
    late Directory support;
    late LocalSongScanCache cache;
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );

    setUp(() async {
      root = await Directory.systemTemp.createTemp('muyin-scan-cache-test-');
      parent = await Directory(p.join(root.path, 'music')).create();
      nested = await Directory(p.join(parent.path, 'nested')).create();
      extra = await Directory(p.join(root.path, 'extra')).create();
      support = Directory(p.join(root.path, 'cache'));
      await File(p.join(parent.path, 'one.mp3')).writeAsString('1');
      await File(p.join(nested.path, 'two.FLAC')).writeAsString('2');
      await File(p.join(extra.path, 'three.m4a')).writeAsString('3');
      await File(p.join(extra.path, 'ignored.txt')).writeAsString('4');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (_) async => support.path,
          );
      cache = LocalSongScanCache();
    });

    tearDown(() async {
      cache.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      expect(p.isWithin(Directory.systemTemp.path, root.path), isTrue);
      expect(p.basename(root.path), startsWith('muyin-scan-cache-test-'));
      await root.delete(recursive: true);
    });

    test(
      'aggregates parents and children once and restores the whole cached set',
      () async {
        final selected = [
          nested.path,
          parent.path,
          extra.path,
          '${extra.path}${p.separator}',
        ];
        await cache.refresh(directories: selected);
        expect(cache.snapshot!.files, hasLength(3));
        expect(cache.snapshot!.directories, hasLength(3));
        expect(cache.snapshot!.matchesDirectories(selected), isTrue);
        final restored = LocalSongScanCache();
        addTearDown(restored.dispose);
        await restored.ensureLoaded();
        expect(restored.snapshot!.files, hasLength(3));
        expect(restored.snapshot!.matchesDirectories(selected), isTrue);
      },
    );

    test(
      'an unreadable folder preserves songs from the remaining folders',
      () async {
        final unreadable = p.join(root.path, 'unreadable');
        await IOOverrides.runZoned(
          () => cache.refresh(directories: [unreadable, extra.path]),
          createDirectory: (path) {
            if (path == unreadable) return _UnreadableDirectory(path);
            if (path == extra.path) return extra;
            if (path == support.path) return support;
            throw StateError('Unexpected directory: $path');
          },
        );
        expect(cache.snapshot!.files.single.fileName, 'three.m4a');
        // 有歌时单根失败不写整页 error，只进扫描日志。
        expect(cache.snapshot!.error, isNull);
      },
    );

    test('an unreadable folder alone still reports an error', () async {
      final unreadable = p.join(root.path, 'unreadable');
      await IOOverrides.runZoned(
        () => cache.refresh(directories: [unreadable]),
        createDirectory: (path) {
          if (path == unreadable) return _UnreadableDirectory(path);
          if (path == support.path) return support;
          throw StateError('Unexpected directory: $path');
        },
      );
      expect(cache.snapshot!.files, isEmpty);
      expect(cache.snapshot!.error, contains(unreadable));
    });

    test('refreshing after a folder is removed drops its old songs', () async {
      await cache.refresh(directories: [parent.path, extra.path]);
      expect(cache.snapshot!.files, hasLength(3));
      await cache.refresh(directories: [extra.path]);
      expect(cache.snapshot!.directories, [extra.path]);
      expect(cache.snapshot!.files.single.fileName, 'three.m4a');
    });

    test('scan skips ignored files without deleting them, and '
        'unignoring brings them back on rescan', () async {
      final ignored = <String>[p.join(parent.path, 'one.mp3')];
      final ignoringCache = LocalSongScanCache(
        ignoredPaths: () => ignored,
      );
      addTearDown(ignoringCache.dispose);
      await ignoringCache.refresh(directories: [parent.path, extra.path]);
      expect(
        ignoringCache.snapshot!.files.map((file) => file.fileName),
        unorderedEquals(['two.FLAC', 'three.m4a']),
      );
      // 仅从列表移除不删文件：被忽略的歌曲仍在设备上。
      expect(await File(p.join(parent.path, 'one.mp3')).exists(), isTrue);

      ignored.clear();
      await ignoringCache.refresh(directories: [parent.path, extra.path]);
      expect(ignoringCache.snapshot!.files, hasLength(3));
    });

    test('persisted index rows for ignored files are filtered on load',
        () async {
      await cache.refresh(directories: [parent.path, extra.path]);
      expect(cache.snapshot!.files, hasLength(3));
      final restored = LocalSongScanCache(
        ignoredPaths: () => [p.join(nested.path, 'two.FLAC')],
      );
      addTearDown(restored.dispose);
      await restored.ensureLoaded();
      expect(
        restored.snapshot!.files.map((file) => file.fileName),
        unorderedEquals(['one.mp3', 'three.m4a']),
      );
    });

    const safTree =
        'content://com.android.externalstorage.documents/'
        'tree/primary%3AMuyinMusic';

    test('an unresolvable SAF root next to a good folder is dropped and '
        'the scan stays error-free', () async {
      await cache.refresh(directories: [safTree, parent.path]);
      expect(
        cache.snapshot!.files.map((file) => file.fileName),
        unorderedEquals(['one.mp3', 'two.FLAC']),
      );
      expect(cache.snapshot!.directories, [parent.path]);
      expect(cache.snapshot!.error, isNull);
    });

    test('a scan with only an unresolvable SAF root produces no error',
        () async {
      await cache.refresh(directories: [safTree]);
      expect(cache.snapshot?.error, isNull);
    });

    test('a resolvable SAF root is scanned through its local path',
        () async {
      final resolvingCache = LocalSongScanCache(
        contentRootResolver: (location) async =>
            location == safTree ? extra.path : null,
      );
      addTearDown(resolvingCache.dispose);
      await resolvingCache.refresh(directories: [safTree]);
      expect(resolvingCache.snapshot!.files.single.fileName, 'three.m4a');
      expect(resolvingCache.snapshot!.directories, [extra.path]);
      expect(resolvingCache.snapshot!.error, isNull);
    });
  });

  test('scanner silently skips content roots instead of erroring', () async {
    final result = await LocalSongScanner.scan(
      const [
        'content://com.android.externalstorage.documents/'
            'tree/primary%3AMusic',
      ],
      const {},
      () => false,
    );
    expect(result.files, isEmpty);
    expect(result.errors, isEmpty);
  });

  group('media fallback roots', () {
    const local = '/storage/emulated/0/Music';
    const other = '/storage/emulated/0/Other';
    const content =
        'content://com.android.externalstorage.documents/'
        'tree/primary%3AMusic';

    Future<List<String>> decide(
      List<String> directories, {
      Set<String> hitRoots = const {},
      bool wide = false,
      Set<String> existing = const {},
    }) => LocalSongScanner.mediaFallbackRoots(
      directories,
      hitRoots: hitRoots,
      wide: wide,
      directoryExists: (root) async => existing.contains(root),
    );

    test('zero-hit local root falls back without wide access when it exists',
        () async {
      expect(
        await decide(const [local], existing: const {local}),
        [local],
      );
    });

    test('zero-hit local root is skipped without wide access when missing',
        () async {
      expect(await decide(const [local]), isEmpty);
    });

    test('zero-hit local root always falls back with wide access', () async {
      expect(await decide(const [local], wide: true), [local]);
    });

    test('roots with media hits never fall back', () async {
      expect(
        await decide(
          const [local, other],
          hitRoots: const {local},
          wide: true,
          existing: const {local, other},
        ),
        [other],
      );
    });

    test('content roots are always selected for the fallback pass', () async {
      expect(await decide(const [content]), [content]);
    });
  });
}

class _UnreadableDirectory implements Directory {
  _UnreadableDirectory(this.path);

  @override
  final String path;

  @override
  Future<bool> exists() async => true;

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => Stream.error(FileSystemException('Access denied', path));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

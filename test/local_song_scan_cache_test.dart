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
    const safMusicTree =
        'content://com.android.externalstorage.documents/'
        'tree/primary%3AMusic';
    const safSongDocUri =
        'content://com.android.externalstorage.documents/'
        'tree/primary%3AMusic/document/primary%3AMusic%2FSub%2Fsong.mp3';

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

    test('a SAF root invisible to raw paths is enumerated through its '
        'tree grant', () async {
      // safLocal 在磁盘上是空目录：原始遍历扫不出任何东西，索引里的
      // 两首歌只能来自 SAF 通道枚举。
      final safLocal = await Directory(p.join(root.path, 'safmusic')).create();
      String? scannedTree;
      final safCache = LocalSongScanCache(
        contentRootResolver: (location) async =>
            location == safMusicTree ? safLocal.path : null,
        safTreeScanner: (uri) async {
          scannedTree = uri;
          return [
            {
              'id': 'primary:Music/Sub/song.mp3',
              'path': safSongDocUri,
              'fileName': 'song.mp3',
              'mimeType': 'audio/mpeg',
              'sizeBytes': 1234,
              'modifiedMs': 1700000000000,
            },
            {
              'id': 'primary:Music/top.flac',
              'path': 'content://com.android.externalstorage.documents/'
                  'tree/primary%3AMusic/document/primary%3AMusic%2Ftop.flac',
              'fileName': 'top.flac',
              'mimeType': 'audio/flac',
              'sizeBytes': 55,
              'modifiedMs': 1700000001000,
            },
          ];
        },
      );
      addTearDown(safCache.dispose);
      await safCache.refresh(directories: [safMusicTree]);
      expect(scannedTree, safMusicTree);
      expect(safCache.snapshot!.directories, [safLocal.path]);
      expect(safCache.snapshot!.error, isNull);
      final files = safCache.snapshot!.files;
      expect(files, hasLength(2));
      final song = files.singleWhere((file) => file.fileName == 'song.mp3');
      expect(song.path, p.join(safLocal.path, 'Sub', 'song.mp3'));
      expect(song.contentUri, safSongDocUri);
      expect(song.playbackPath, safSongDocUri);
      expect(song.aliases, contains(safSongDocUri));
      expect(song.directory, safLocal.path);
      expect(song.sizeBytes, 1234);
    });

    test('a failing SAF enumeration leaves the rest of the scan intact',
        () async {
      final safLocal = await Directory(p.join(root.path, 'safmusic')).create();
      final safCache = LocalSongScanCache(
        contentRootResolver: (location) async =>
            location == safMusicTree ? safLocal.path : null,
        safTreeScanner: (uri) async => throw StateError('grant revoked'),
      );
      addTearDown(safCache.dispose);
      await safCache.refresh(directories: [safMusicTree, parent.path]);
      expect(
        safCache.snapshot!.files.map((file) => file.fileName),
        unorderedEquals(['one.mp3', 'two.FLAC']),
      );
      expect(safCache.snapshot!.error, isNull);
    });

    test('a deleted song is not revived while enumeration keeps reporting '
        'it, and the guard heals once enumeration stops', () async {
      final target = p.join(parent.path, 'one.mp3');
      await cache.refresh(directories: [parent.path]);
      expect(cache.snapshot!.files.map((file) => file.path), contains(target));

      cache.removePaths([target]);
      await cache.flush();
      expect(
        cache.snapshot!.files.map((file) => file.path),
        isNot(contains(target)),
      );

      // 枚举源仍产出这首歌（模拟 MediaStore 陈旧行：实体在删除后被滞后
      // 枚举到）——下一轮扫描落盘仍不得包含它。
      await cache.refresh(directories: [parent.path]);
      expect(
        cache.snapshot!.files.map((file) => file.path),
        isNot(contains(target)),
      );

      // 实体真正消失、枚举不再产出：待确认删除自愈清除。
      await File(target).delete();
      await cache.refresh(directories: [parent.path]);
      expect(
        cache.snapshot!.files.map((file) => file.path),
        isNot(contains(target)),
      );

      // 自愈后同名文件重新出现应正常入库，不被旧的删除记录误杀。
      await File(target).writeAsString('1');
      await cache.refresh(directories: [parent.path]);
      expect(cache.snapshot!.files.map((file) => file.path), contains(target));
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

  group('media row existence gate', () {
    test('drops local rows whose file is gone and keeps the rest', () async {
      final rows = <Map<String, dynamic>>[
        {'path': '/music/gone.mp3'},
        {'path': '/music/here.mp3'},
        {'path': 'content://media/external/audio/media/7'},
      ];
      final kept = await LocalSongScanner.existingMediaRows(
        rows,
        fileExists: (path) async => path.endsWith('here.mp3'),
      );
      expect(kept.map((row) => row['path']), [
        '/music/here.mp3',
        'content://media/external/audio/media/7',
      ]);
    });

    test('keeps a row when the existence check itself fails', () async {
      final rows = <Map<String, dynamic>>[
        {'path': '/music/song.mp3'},
      ];
      final kept = await LocalSongScanner.existingMediaRows(
        rows,
        fileExists: (_) async => throw const FileSystemException('io'),
      );
      expect(kept, hasLength(1));
    });
  });

  group('saf scan roots', () {
    const local = '/storage/emulated/0/Music';
    const other = '/storage/emulated/0/Other';
    const tree =
        'content://com.android.externalstorage.documents/'
        'tree/primary%3AMusic';

    test('paired zero-hit roots are selected', () {
      expect(
        LocalSongScanner.safScanRoots(
          const [local, other],
          contentRoots: const {local: tree},
          hitRoots: const {},
        ),
        [local],
      );
    });

    test('paired roots with media hits are not selected', () {
      expect(
        LocalSongScanner.safScanRoots(
          const [local],
          contentRoots: const {local: tree},
          hitRoots: const {local},
        ),
        isEmpty,
      );
    });

    test('roots without a tree grant are not selected', () {
      expect(
        LocalSongScanner.safScanRoots(
          const [local],
          contentRoots: const {},
          hitRoots: const {},
        ),
        isEmpty,
      );
    });
  });

  group('saf tree file mapping', () {
    const tree =
        'content://com.android.externalstorage.documents/'
        'tree/primary%3AMusic';
    const rootPath = '/storage/emulated/0/Music';

    test('derives nested and root-level local paths', () {
      expect(
        LocalSongScanner.safDocumentLocalPath(
          treeUri: tree,
          rootPath: rootPath,
          documentId: 'primary:Music/Sub/song.mp3',
        ),
        '/storage/emulated/0/Music/Sub/song.mp3',
      );
      expect(
        LocalSongScanner.safDocumentLocalPath(
          treeUri: tree,
          rootPath: rootPath,
          documentId: 'primary:Music/top.flac',
        ),
        '/storage/emulated/0/Music/top.flac',
      );
    });

    test('rejects documents outside the tree or on another volume', () {
      expect(
        LocalSongScanner.safDocumentLocalPath(
          treeUri: tree,
          rootPath: rootPath,
          documentId: 'primary:Other/song.mp3',
        ),
        isNull,
      );
      expect(
        LocalSongScanner.safDocumentLocalPath(
          treeUri: tree,
          rootPath: rootPath,
          documentId: 'ABCD-1234:Music/song.mp3',
        ),
        isNull,
      );
    });

    test('builds a snapshot with local identity and document playback', () {
      const docUri =
          'content://com.android.externalstorage.documents/'
          'tree/primary%3AMusic/document/primary%3AMusic%2FSub%2Fsong.mp3';
      final file = LocalSongScanner.safTreeFile(
        const {
          'id': 'primary:Music/Sub/song.mp3',
          'path': docUri,
          'fileName': 'song.mp3',
          'sizeBytes': 99,
          'modifiedMs': 1700000000000,
        },
        root: rootPath,
        treeUri: tree,
      );
      expect(file, isNotNull);
      expect(file!.path, '/storage/emulated/0/Music/Sub/song.mp3');
      expect(file.contentUri, docUri);
      expect(file.playbackPath, docUri);
      expect(file.aliases, [docUri]);
      expect(file.directory, rootPath);
      expect(file.sizeBytes, 99);
      expect(file.metadataRead, isFalse);
    });

    test('drops rows whose document is outside the tree', () {
      expect(
        LocalSongScanner.safTreeFile(
          const {
            'id': 'primary:Elsewhere/song.mp3',
            'path': 'content://com.android.externalstorage.documents/'
                'tree/primary%3AMusic/document/primary%3AElsewhere%2Fsong.mp3',
            'fileName': 'song.mp3',
          },
          root: rootPath,
          treeUri: tree,
        ),
        isNull,
      );
    });
  });

  group('saf channel enumeration', () {
    late Directory root;
    const tree =
        'content://com.android.externalstorage.documents/'
        'tree/primary%3AMusic';

    setUp(() async {
      root = await Directory.systemTemp.createTemp('muyin-saf-scan-test-');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test('enumerates a paired root through the SAF channel', () async {
      final result = await LocalSongScanner.scan(
        [root.path],
        const {},
        () => false,
        contentRoots: {root.path: tree},
        safScan: (uri) async {
          expect(uri, tree);
          return [
            {
              'id': 'primary:Music/Sub/song.mp3',
              'path': 'content://com.android.externalstorage.documents/'
                  'tree/primary%3AMusic/document/primary%3AMusic%2FSub%2Fsong.mp3',
              'fileName': 'song.mp3',
              'sizeBytes': 7,
              'modifiedMs': 1700000000000,
            },
          ];
        },
      );
      expect(result.errors, isEmpty);
      final file = result.files.values.single;
      expect(file.path, p.join(root.path, 'Sub', 'song.mp3'));
      expect(file.playbackPath, startsWith('content://'));
      expect(file.directory, root.path);
    });

    test('a failing SAF enumeration yields zero files without failing '
        'the scan', () async {
      final result = await LocalSongScanner.scan(
        [root.path],
        const {},
        () => false,
        contentRoots: {root.path: tree},
        safScan: (uri) async => throw StateError('grant revoked'),
      );
      expect(result.files, isEmpty);
      expect(result.errors, isEmpty);
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

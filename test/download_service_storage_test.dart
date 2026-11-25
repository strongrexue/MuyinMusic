import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:muyin_music/core/api/api_client.dart';
import 'package:muyin_music/core/models/enums.dart';
import 'package:muyin_music/core/models/music_info.dart';
import 'package:muyin_music/core/models/music_url.dart';
import 'package:muyin_music/core/music_sources/music_source_models.dart';
import 'package:muyin_music/core/music_sources/music_url_resolver.dart';
import 'package:muyin_music/core/services/app_logger.dart';
import 'package:muyin_music/core/services/download_service.dart';
import 'package:muyin_music/core/storage/settings_store.dart';
import 'package:muyin_music/features/downloads/download_history_store.dart';
import 'package:muyin_music/features/downloads/download_progress.dart';

const _withoutMetadata = EmbedRequest(
  embedCover: false,
  embedLyric: false,
  embedTranslatedLyric: false,
  embedRomanLyric: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Initialize best-effort logging without retaining a fixture directory.
  setUpAll(AppLogger.flush);

  test('six concurrent downloads all land in the selected directory', () async {
    final fixture = await _fixture();
    final results = await fixture.service.downloadMany(
      musics: [for (var i = 0; i < 6; i++) _music('song-$i')],
      embed: _withoutMetadata,
    );

    expect(results, hasLength(6));
    expect(results.every((result) => result.success), isTrue);
    expect(
      results.map((result) => p.dirname(result.result!.path)),
      everyElement(fixture.downloads.path),
    );
    expect(fixture.downloads.listSync().whereType<File>(), hasLength(6));
    expect(fixture.documents.listSync(), isEmpty);
    expect(fixture.cache.listSync(), isEmpty);
    expect(fixture.container.read(downloadHistoryProvider), hasLength(6));
    expect(
      fixture.container
          .read(downloadProgressProvider)
          .tasks
          .map((t) => t.stage),
      everyElement(DownloadStage.done),
    );
  });

  test('concurrent same-name files never overwrite each other', () async {
    final fixture = await _fixture(sameFileName: true);
    final existing = File(p.join(fixture.downloads.path, 'shared.mp3'));
    await existing.writeAsString('existing audio');

    final results = await fixture.service.downloadMany(
      musics: [for (var i = 0; i < 6; i++) _music('song-$i')],
      embed: _withoutMetadata,
    );

    expect(results.every((result) => result.success), isTrue);
    final paths = results.map((result) => result.result!.path).toSet();
    expect(paths, hasLength(6));
    expect(fixture.downloads.listSync().whereType<File>(), hasLength(7));
    expect(await existing.readAsString(), 'existing audio');
    for (final result in results) {
      expect(
        await File(result.result!.path).readAsString(),
        'ID3${result.music.id}',
      );
    }
  });

  test(
    'pausing a transfer cancels IO without failure history or partial files',
    () async {
      final adapter = _HoldingAudioAdapter();
      final fixture = await _fixture(adapter: adapter);
      final received = Completer<void>();
      fixture.container.listen(downloadProgressProvider, (_, progress) {
        if (!received.isCompleted &&
            progress.tasks.any((task) => task.received > 0)) {
          received.complete();
        }
      });
      final token = CancelToken();
      final download = fixture.service.downloadOne(
        music: _music('paused-song'),
        embed: _withoutMetadata,
        cancelToken: token,
        batchTaskId: 'batch-pause-test',
      );
      final cancelled = expectLater(
        download,
        throwsA(isA<DownloadCancelledException>()),
      );
      await received.future.timeout(const Duration(seconds: 5));
      expect(
        fixture.container
            .read(downloadProgressProvider)
            .tasks
            .single
            .batchTaskId,
        'batch-pause-test',
      );
      token.cancel('paused');
      await cancelled;

      expect(fixture.container.read(downloadProgressProvider).tasks, isEmpty);
      expect(fixture.container.read(downloadHistoryProvider), isEmpty);
      expect(fixture.downloads.listSync(), isEmpty);
      expect(fixture.cache.listSync(), isEmpty);
    },
  );

  test('cancelTask aborts a standalone download by its task id', () async {
    final adapter = _HoldingAudioAdapter();
    final fixture = await _fixture(adapter: adapter);
    final received = Completer<void>();
    fixture.container.listen(downloadProgressProvider, (_, progress) {
      if (!received.isCompleted &&
          progress.tasks.any((task) => task.received > 0)) {
        received.complete();
      }
    });

    final download = fixture.service.downloadOne(
      music: _music('standalone-song'),
      embed: _withoutMetadata,
    );
    final cancelled = expectLater(
      download,
      throwsA(isA<DownloadCancelledException>()),
    );
    await received.future.timeout(const Duration(seconds: 5));

    final task = fixture.container.read(downloadProgressProvider).tasks.single;
    expect(fixture.service.isTaskCancellable(task.id), isTrue);
    expect(fixture.service.cancelTask(task.id), isTrue);
    await cancelled;

    expect(fixture.service.isTaskCancellable(task.id), isFalse);
    expect(fixture.container.read(downloadProgressProvider).tasks, isEmpty);
    expect(fixture.container.read(downloadHistoryProvider), isEmpty);
    expect(fixture.downloads.listSync(), isEmpty);
    expect(fixture.cache.listSync(), isEmpty);
  });

  test(
    'pauseTask keeps the row and resumeTask starts a fresh transfer',
    () async {
      final adapter = _HoldingAudioAdapter();
      final fixture = await _fixture(adapter: adapter);
      final received = Completer<void>();
      fixture.container.listen(downloadProgressProvider, (_, progress) {
        if (!received.isCompleted &&
            progress.tasks.any((task) => task.received > 0)) {
          received.complete();
        }
      });

      final download = fixture.service.downloadOne(
        music: _music('paused-resumable'),
        embed: _withoutMetadata,
      );
      final paused = expectLater(
        download,
        throwsA(isA<DownloadPausedException>()),
      );
      await received.future.timeout(const Duration(seconds: 5));

      final task = fixture.container.read(downloadProgressProvider).tasks.single;
      expect(fixture.service.isTaskRunning(task.id), isTrue);
      expect(fixture.service.pauseTask(task.id), isTrue);
      await paused;

      final parked = fixture.container
          .read(downloadProgressProvider)
          .tasks
          .single;
      expect(parked.id, task.id);
      expect(parked.isPaused, isTrue);
      expect(parked.isActive, isTrue);
      expect(fixture.service.isTaskResumable(task.id), isTrue);
      expect(fixture.container.read(downloadHistoryProvider), isEmpty);

      // Resuming re-downloads from scratch; the holding adapter keeps the new
      // transfer open, so abort it instead of waiting for it to finish.
      expect(fixture.service.resumeTask(task.id), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final rows = fixture.container.read(downloadProgressProvider).tasks;
      expect(rows.length, 1);
      expect(rows.single.musicId, 'paused-resumable');
      expect(rows.single.isPaused, isFalse);
      expect(fixture.downloads.listSync(), isEmpty);

      expect(fixture.service.isTaskRunning(rows.single.id), isTrue);
      expect(fixture.service.cancelTask(rows.single.id), isTrue);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (fixture.container.read(downloadProgressProvider).tasks.isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(fixture.container.read(downloadProgressProvider).tasks, isEmpty);
    },
  );

  test('cancelTask drops a paused task and its row', () async {
    final adapter = _HoldingAudioAdapter();
    final fixture = await _fixture(adapter: adapter);
    final received = Completer<void>();
    fixture.container.listen(downloadProgressProvider, (_, progress) {
      if (!received.isCompleted &&
          progress.tasks.any((task) => task.received > 0)) {
        received.complete();
      }
    });

    final download = fixture.service.downloadOne(
      music: _music('paused-then-cancelled'),
      embed: _withoutMetadata,
    );
    final paused = expectLater(
      download,
      throwsA(isA<DownloadPausedException>()),
    );
    await received.future.timeout(const Duration(seconds: 5));

    final task = fixture.container.read(downloadProgressProvider).tasks.single;
    expect(fixture.service.pauseTask(task.id), isTrue);
    await paused;
    expect(
      fixture.container.read(downloadProgressProvider).tasks.single.isPaused,
      isTrue,
    );

    // A paused task no longer owns a live token, but cancelling it must still
    // succeed and remove the row (the downloads page shows "取消下载").
    expect(fixture.service.cancelTask(task.id), isTrue);
    expect(fixture.container.read(downloadProgressProvider).tasks, isEmpty);
    expect(fixture.service.isTaskResumable(task.id), isFalse);
    expect(fixture.downloads.listSync(), isEmpty);
    expect(fixture.container.read(downloadHistoryProvider), isEmpty);

    // The id is gone now, so a second cancel reports nothing to do.
    expect(fixture.service.cancelTask(task.id), isFalse);
  });
}

Future<
  ({
    ProviderContainer container,
    DownloadService service,
    Directory downloads,
    Directory documents,
    Directory cache,
  })
>
_fixture({bool sameFileName = false, HttpClientAdapter? adapter}) async {
  final root = await Directory.systemTemp.createTemp(
    'muyin-download-storage-',
  );
  final downloads = await Directory(p.join(root.path, 'music')).create();
  final documents = await Directory(p.join(root.path, 'documents')).create();
  final cache = await Directory(p.join(root.path, 'cache')).create();
  addTearDown(() => root.delete(recursive: true));

  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    return switch (call.method) {
      'getTemporaryDirectory' => cache.path,
      'getApplicationDocumentsDirectory' => documents.path,
      _ => null,
    };
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

  SharedPreferences.setMockInitialValues({'download_dir': downloads.path});
  final preferences = await SharedPreferences.getInstance();
  final dio = Dio()..httpClientAdapter = adapter ?? _AudioAdapter();
  addTearDown(() => dio.close(force: true));
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      apiClientProvider.overrideWithValue(dio),
      musicUrlResolverProvider.overrideWithValue(
        _StorageResolver(sameFileName: sameFileName),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (
    container: container,
    service: container.read(downloadServiceProvider),
    downloads: downloads,
    documents: documents,
    cache: cache,
  );
}

class _AudioAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final audio = 'ID3${options.uri.pathSegments.last}';
    return ResponseBody.fromString(
      audio,
      200,
      headers: {
        Headers.contentTypeHeader: ['audio/mpeg'],
        Headers.contentLengthHeader: ['${audio.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _HoldingAudioAdapter implements HttpClientAdapter {
  // One controller per transfer: a resumed download opens a second request, and
  // a single-subscription stream cannot be listened to twice.
  final _streams = <StreamController<Uint8List>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final stream = StreamController<Uint8List>();
    _streams.add(stream);
    stream.add(Uint8List.fromList([0x49, 0x44, 0x33]));
    return ResponseBody(
      stream.stream,
      200,
      headers: {
        Headers.contentLengthHeader: ['100'],
      },
    );
  }

  @override
  void close({bool force = false}) {
    for (final stream in _streams) {
      unawaited(stream.close());
    }
  }
}

class _StorageResolver implements MusicUrlResolver {
  _StorageResolver({required this.sameFileName});

  final bool sameFileName;
  final _source = MusicSourceRecord(
    id: 'storage-test',
    name: 'Storage test source',
    description: '',
    author: 'test',
    homepage: '',
    version: '1',
    origin: 'test',
    importedAt: DateTime.utc(2026, 10, 27),
    updatedAt: DateTime.utc(2026, 10, 27),
    capabilities: const {
      MusicSource.wy: [Quality.k128],
    },
  );

  @override
  Future<Quality> highestQualityFor(MusicInfo music) async => Quality.k128;

  @override
  Future<MusicUrl> resolve({
    required MusicInfo music,
    required Quality quality,
  }) async => MusicUrl(
    url: 'https://audio.test/${music.id}',
    type: quality,
    fileName: sameFileName ? 'shared.mp3' : '${music.id}.mp3',
  );

  @override
  Future<MusicSourceFallbackResult<T>> useFirstAvailable<T>({
    required MusicInfo music,
    required Quality quality,
    required MusicSourceUrlConsumer<T> use,
    Set<String> excludedSourceIds = const <String>{},
    bool Function()? isCancelled,
    bool Function(Object error)? shouldFallbackOnConsumerError,
  }) async => MusicSourceFallbackResult(
    source: _source,
    value: await use(_source, await resolve(music: music, quality: quality)),
    attemptedSourceIds: [_source.id],
  );
}

MusicInfo _music(String id) => MusicInfo.fromJson({
  'id': id,
  'name': '歌曲 $id',
  'singer': '歌手',
  'source': MusicSource.wy.code,
  'interval': '03:00',
  'meta': {
    'songId': id,
    'qualitys': [
      {'type': Quality.k128.code, 'size': '16'},
    ],
  },
});

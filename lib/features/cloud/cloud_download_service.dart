import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/api/api_client.dart';
import '../../core/models/enums.dart';
import '../../core/services/local_audio_library_events.dart';
import '../../core/services/media_library.dart';
import '../../core/services/saf_storage.dart';
import '../../core/services/storage_location.dart';
import '../../core/storage/settings_store.dart';
import '../downloads/download_history_store.dart';
import '../songs/local_song_scan_models.dart';
import '../songs/scanned_song_file.dart';
import 'cloud_library.dart';

/// Downloads one cloud song into the local download directory, following
/// the same land-and-register pattern as `DownloadService`: stream to a
/// temp file, move into the download root, register a history entry and
/// fire the library-saved event so the file becomes an ordinary local song.
class CloudDownloadService {
  CloudDownloadService(this._ref);

  final Ref _ref;

  Future<String> downloadToLocal(LocalSongFileSnapshot file) async {
    final library = _ref.read(cloudDrive2LibraryProvider);
    final resolved = await library.resolve(file.path);
    if (resolved.url.isEmpty) throw StateError('CloudDrive2 没有返回下载地址');

    final settings = _ref.read(settingsProvider);
    // Same destination rule as DownloadService: on iOS the download root is
    // derived from the scan root so the saved event always lands in-library.
    final downloadRoot = Platform.isIOS
        ? p.join(
            normalizeStorageLocation(settings.localMusicDir),
            'MuyinMusic',
          )
        : settings.downloadDir;

    final tempRoot = await getTemporaryDirectory();
    final tempDir = await tempRoot.createTemp('muyin-cloud-download-');
    try {
      final tempPath = p.join(tempDir.path, file.fileName);
      final dio = _ref.read(apiClientProvider);
      await dio.download(
        resolved.url,
        tempPath,
        options: Options(headers: resolved.headers),
      );
      final finalPath = await _moveToTarget(
        tempPath,
        downloadRoot,
        file.fileName,
      );
      final scanned = ScannedSongFile.fromSnapshot(file);
      await LocalAudioLibraryEvents.saved(finalPath, tags: file.tags);
      await _ref
          .read(downloadHistoryProvider.notifier)
          .addRawEntry(
            DownloadHistoryEntry(
              id: 'cloud-${DateTime.now().microsecondsSinceEpoch}',
              musicId: file.key,
              name: _preferTag(file.tags?.title, scanned.title),
              singer: _preferTag(file.tags?.artist, scanned.artist),
              albumName: file.tags?.album ?? '',
              sourceCode: MusicSource.all.code,
              qualityCode: file.extension,
              status: DownloadHistoryStatus.completed,
              createdAt: DateTime.now(),
              savedPath: finalPath,
              sizeBytes: file.sizeBytes,
            ),
          );
      return finalPath;
    } finally {
      try {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      } catch (_) {
        // Temp cleanup is best-effort.
      }
    }
  }

  Future<String> _moveToTarget(
    String tempPath,
    String destination,
    String fileName,
  ) async {
    if (isContentLocation(destination)) {
      return SafStorage.saveFile(destination, tempPath, fileName);
    }
    if (await MediaLibrary.canSave(destination)) {
      return MediaLibrary.save(destination, tempPath, fileName);
    }
    final destDir = Directory(destination);
    await destDir.create(recursive: true);
    final destPath = p.join(destDir.path, _dedupedName(destDir, fileName));
    final temp = File(tempPath);
    try {
      return (await temp.rename(destPath)).path;
    } on FileSystemException {
      await temp.copy(destPath);
      await temp.delete();
      return destPath;
    }
  }

  String _dedupedName(Directory dir, String fileName) {
    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    var attempt = fileName;
    var i = 1;
    while (File(p.join(dir.path, attempt)).existsSync()) {
      attempt = '$base ($i)$ext';
      i++;
    }
    return attempt;
  }
}

final cloudDownloadServiceProvider = Provider<CloudDownloadService>(
  CloudDownloadService.new,
);

String _preferTag(String? tagValue, String fallback) {
  final trimmed = tagValue?.trim();
  return trimmed == null || trimmed.isEmpty ? fallback : trimmed;
}

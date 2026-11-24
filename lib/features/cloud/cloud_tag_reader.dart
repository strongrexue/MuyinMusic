import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/models/music_url.dart';
import '../../core/services/tagger.dart';
import '../songs/local_song_scan_models.dart';
import 'cloud_song_path.dart';

/// Reads embedded tags of cloud files through the existing [Tagger]: the
/// file head is fetched with an HTTP Range request, landed in a temporary
/// file (the tag pipeline only accepts file paths — the same trick the
/// Android native layer uses for `content://` sources), then parsed.
/// Tags that live outside the fetched head simply yield no tags; the entry
/// falls back to its file name instead of failing the batch.
class CloudTagReader {
  CloudTagReader({
    required this.resolveUrl,
    Dio Function()? dioFactory,
    this.headBytes = 8 * 1024 * 1024,
  }) : _dioFactory = dioFactory ?? Dio.new;

  /// Resolves a playable URL (+headers) for a CloudDrive2 remote path.
  final Future<MusicUrl> Function(String remotePath) resolveUrl;
  final Dio Function() _dioFactory;

  /// How much of the file head to fetch. ID3v2 / FLAC / most MP4 metadata
  /// lives well inside this window.
  final int headBytes;

  final _cache = <String, EmbeddedAudioTags?>{};

  Future<EmbeddedAudioTags?> readTags(LocalSongFileSnapshot file) async {
    final cacheKey = '${file.key}\u0000${file.fingerprint}';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey];
    final tags = await _readTagsUncached(file);
    if (_cache.length > 512) _cache.clear();
    _cache[cacheKey] = tags;
    return tags;
  }

  Future<EmbeddedAudioTags?> _readTagsUncached(
    LocalSongFileSnapshot file,
  ) async {
    File? tempFile;
    try {
      final resolved = await resolveUrl(cloudDrive2RemotePath(file.path));
      if (resolved.url.isEmpty) return null;
      final bytes = await _fetchHead(resolved);
      if (bytes == null || bytes.isEmpty) return null;
      final tempDir = await getTemporaryDirectory();
      final dir = Directory(p.join(tempDir.path, 'cloud_tags'));
      await dir.create(recursive: true);
      // Keep the original file name: platform taggers key off the extension.
      tempFile = File(p.join(dir.path, _safeFileName(file.fileName)));
      await tempFile.writeAsBytes(bytes, flush: true);
      return await Tagger.readEmbeddedTags(tempFile.path);
    } catch (_) {
      return null;
    } finally {
      try {
        await tempFile?.delete();
      } catch (_) {
        // A leftover temp file is harmless; the OS reclaims the temp dir.
      }
    }
  }

  Future<List<int>?> _fetchHead(MusicUrl resolved) async {
    final dio = _dioFactory();
    final cancelToken = CancelToken();
    try {
      final response = await dio.get<ResponseBody>(
        resolved.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            ...?resolved.headers,
            'Range': 'bytes=0-${headBytes - 1}',
          },
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
        cancelToken: cancelToken,
      );
      final body = response.data;
      if (body == null) return null;
      final bytes = <int>[];
      await for (final chunk in body.stream) {
        bytes.addAll(chunk);
        if (bytes.length >= headBytes) {
          cancelToken.cancel('head complete');
          break;
        }
      }
      return bytes.length > headBytes ? bytes.sublist(0, headBytes) : bytes;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) return null;
      rethrow;
    } finally {
      dio.close(force: true);
    }
  }

  static String _safeFileName(String name) {
    final sanitized = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return sanitized.isEmpty ? 'cloud_audio' : sanitized;
  }
}

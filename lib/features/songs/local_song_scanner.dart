import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/services/app_logger.dart';
import '../../core/services/embedded_audio_tags.dart';
import '../../core/services/media_library.dart';
import '../../core/services/permission_service.dart';
import '../../core/services/saf_storage.dart';
import '../../core/services/storage_location.dart';
import 'local_song_scan_models.dart';

const _audioExtensions = {
  'mp3',
  'flac',
  'm4a',
  'aac',
  'ogg',
  'wav',
  'ape',
  'wma',
};

class LocalSongScanResult {
  LocalSongScanResult(this.backend);
  String backend;
  final files = <String, LocalSongFileSnapshot>{};
  final errors = <String>[];
}

LocalSongFileSnapshot mediaLibraryFile(
  Map<String, dynamic> row, {
  String? directory,
}) {
  final name = row['fileName'] as String;
  return LocalSongFileSnapshot(
    path: row['path'] as String,
    contentUri: row['contentUri'] as String?,
    aliases:
        (row['aliases'] as List?)?.whereType<String>().toList() ?? const [],
    fileName: name,
    extension: p.extension(name).replaceFirst('.', ''),
    modifiedAt: DateTime.fromMillisecondsSinceEpoch(
      (row['modifiedMs'] as num?)?.toInt() ?? 0,
    ),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (row['createdMs'] as num?)?.toInt() ?? 0,
    ),
    sizeBytes: (row['sizeBytes'] as num?)?.toInt() ?? 0,
    directory: directory,
    metadataRead: true,
    tags: EmbeddedAudioTags(
      title: row['title'] as String?,
      artist: row['artist'] as String?,
      album: row['album'] as String?,
    ),
  );
}

class LocalSongScanner {
  static Future<LocalSongScanResult> scan(
    List<String> directories,
    Map<String, LocalSongFileSnapshot> previous,
    bool Function() cancelled,
  ) async {
    final result = LocalSongScanResult(
      Platform.isAndroid ? 'media' : 'filesystem',
    );
    final zeroHitRoots = <String>{};
    var fallback = directories;
    if (Platform.isAndroid) {
      try {
        final query = await MediaLibrary.query(directories);
        if (cancelled()) return result;
        for (final row in query.files) {
          final path = row['path'] as String;
          final owner = directories
              .where((root) => isFileInScanDirectory(path, root))
              .firstOrNull;
          if (owner == null) continue;
          final file = mediaLibraryFile(row, directory: owner);
          result.files[file.key] = file.withAliases([
            ...?previous[file.key]?.aliases,
            ...file.aliases,
          ]);
        }
        for (final root in query.unavailable) {
          result.errors.add('$root：存储设备暂不可用');
        }
        _preserve(result, previous, query.unavailable);
        // Broad access is an optional fallback for unindexed USB/legacy roots.
        // A healthy indexed root never triggers a second filesystem walk.
        final wide = await PermissionService.hasExternalStorageWrite();
        final hitRoots = <String>{
          for (final root in directories)
            if (!isContentLocation(root) &&
                result.files.values.any(
                  (file) => isFileInScanDirectory(file.path, root),
                ))
              root,
        };
        zeroHitRoots.addAll(
          directories.where(
            (root) => !isContentLocation(root) && !hitRoots.contains(root),
          ),
        );
        fallback = await mediaFallbackRoots(
          directories,
          hitRoots: hitRoots,
          wide: wide,
          directoryExists: (root) => Directory(root).exists(),
        );
      } catch (error) {
        if (cancelled()) return result;
        if (!await PermissionService.hasExternalStorageWrite()) {
          result.errors.add('$error');
          _preserve(result, previous, directories);
          return result;
        }
        result.backend = 'compatibility';
      }
    }
    final completed = <String>[];
    for (final root in [
      ...fallback,
    ]..sort((a, b) => a.length.compareTo(b.length))) {
      if (cancelled()) return result;
      if (completed.any((parent) => isFileInScanDirectory(root, parent))) {
        continue;
      }
      try {
        if (isContentLocation(root)) {
          // 调用方本应先把 content 根解析成本地路径或剔除（见
          // LocalSongScanCache 的根准备）；走到这里直接跳过，不再让
          // 单个授权文件夹把整个列表打成错误态。
          continue;
        }
        final directory = Directory(root);
        if (!await directory.exists()) {
          throw FileSystemException('文件夹不存在或暂不可用', root);
        }
        await for (final item in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (cancelled()) return result;
          if (item is! File) continue;
          final name = p.basename(item.path);
          final extension = p.extension(name).replaceFirst('.', '');
          if (!_audioExtensions.contains(extension.toLowerCase())) continue;
          final stat = await item.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          final file = LocalSongFileSnapshot(
            path: item.path,
            fileName: name,
            extension: extension,
            createdAt: stat.changed,
            modifiedAt: stat.modified,
            sizeBytes: stat.size,
            directory: root,
          );
          result.files.putIfAbsent(
            file.key,
            () => file.retainingMetadata(previous[file.key], retryEmpty: true),
          );
        }
        completed.add(root);
      } catch (error) {
        result.errors.add('${SafStorage.label(root)}：$error');
        _preserve(result, previous, [root]);
      }
    }
    // MediaStore 零命中的本地根留一条痕：下次实机复现时能直接区分
    // 「未被系统索引、靠兜底扫出」与「兜底也没读到」。
    for (final root in zeroHitRoots) {
      final count = result.files.values
          .where((file) => isFileInScanDirectory(file.path, root))
          .length;
      unawaited(
        AppLogger.write(
          'local-library',
          'mediastore zero-hit root=$root fallbackFiles=$count',
        ),
      );
    }
    return result;
  }

  /// MediaStore 查询后决定哪些根还要走文件系统枚举：content 根恒入选
  /// （枚举循环里会跳过，保持既有语义）；本地根已有命中时不入选；
  /// 零命中的本地根——有全盘权限（wide）时无条件入选，只授媒体权限时
  /// 要求目录实际存在才入选，避免对已消失的目录反复报错。
  @visibleForTesting
  static Future<List<String>> mediaFallbackRoots(
    List<String> directories, {
    required Set<String> hitRoots,
    required bool wide,
    required Future<bool> Function(String root) directoryExists,
  }) async {
    final roots = <String>[];
    for (final root in directories) {
      if (isContentLocation(root)) {
        roots.add(root);
        continue;
      }
      if (hitRoots.contains(root)) continue;
      if (wide || await directoryExists(root)) roots.add(root);
    }
    return roots;
  }

  static void _preserve(
    LocalSongScanResult result,
    Map<String, LocalSongFileSnapshot> previous,
    List<String> roots,
  ) {
    for (final old in previous.values) {
      if (roots.any(
        (root) =>
            old.directory == root ||
            isFileInScanDirectory(old.path, root) ||
            (isContentLocation(root) && old.directory == null),
      )) {
        result.files.putIfAbsent(old.key, () => old);
      }
    }
  }
}

/// Resolve just the saved file. MediaStore writes are indexed before returning;
/// SAF and older private-file downloads keep their existing access handle.
Future<LocalSongFileSnapshot?> savedLibraryFile(
  String location,
  List<String> directories,
) async {
  Map<String, dynamic>? media;
  try {
    media = await MediaLibrary.find(location);
  } catch (_) {
    /* Some old providers cannot map documents. */
  }
  final path =
      media?['path'] as String? ??
      await SafStorage.resolveLocalPath(location, requireReadable: false);
  if (path == null) return null;
  final owner = directories
      .where((root) => isFileInScanDirectory(path, root))
      .firstOrNull;
  if (owner == null) return null;
  if (media != null) {
    final file = mediaLibraryFile(media, directory: owner);
    return file.withAliases([...file.aliases, if (location != path) location]);
  }
  final metadata = await SafStorage.metadata(location);
  if (metadata == null) return null;
  final name = metadata['fileName'] as String;
  return LocalSongFileSnapshot(
    path: path,
    fileName: name,
    contentUri: isContentLocation(location) ? location : null,
    aliases: [if (location != path) location],
    directory: owner,
    extension: p.extension(name).replaceFirst('.', ''),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (metadata['createdMs'] as num?)?.toInt() ?? 0,
    ),
    modifiedAt: DateTime.fromMillisecondsSinceEpoch(
      (metadata['modifiedMs'] as num?)?.toInt() ?? 0,
    ),
    sizeBytes: (metadata['sizeBytes'] as num?)?.toInt() ?? 0,
  );
}

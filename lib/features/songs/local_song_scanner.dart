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
    bool Function() cancelled, {
    Map<String, String> contentRoots = const {},
    Future<List<Map<String, dynamic>>> Function(String uri)? safScan,
  }) async {
    final result = LocalSongScanResult(
      Platform.isAndroid ? 'media' : 'filesystem',
    );
    final zeroHitRoots = <String>{};
    var hitRoots = <String>{};
    var fallback = directories;
    if (Platform.isAndroid) {
      try {
        final query = await MediaLibrary.query(directories);
        if (cancelled()) return result;
        for (final row in await existingMediaRows(query.files)) {
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
        hitRoots = <String>{
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
    // MediaStore 零命中且带 SAF 树授权的根：原始路径通道（dart:io 与
    // MediaStore）都读不到授权目录，改走 SafStorage.scan 用授权枚举。
    // 枚举失败（授权失效等）按零产出处理并留日志，不让整轮扫描失败。
    final safRoots = <String>{};
    if (contentRoots.isNotEmpty) {
      final candidates =
          safScanRoots(
              directories,
              contentRoots: contentRoots,
              hitRoots: hitRoots,
            ).toList()
            ..sort((a, b) => a.length.compareTo(b.length));
      for (final root in candidates) {
        if (cancelled()) return result;
        if (safRoots.any((parent) => isFileInScanDirectory(root, parent))) {
          safRoots.add(root);
          continue;
        }
        final treeUri = contentRoots[root]!;
        try {
          final rows = await (safScan ?? SafStorage.scan)(treeUri);
          for (final row in rows) {
            if (cancelled()) return result;
            final file = safTreeFile(row, root: root, treeUri: treeUri);
            if (file == null) continue;
            final merged = file.retainingMetadata(
              previous[file.key],
              retryEmpty: true,
            );
            result.files.putIfAbsent(
              file.key,
              () => merged.withAliases({...file.aliases, ...merged.aliases}),
            );
          }
          safRoots.add(root);
        } catch (error) {
          unawaited(
            AppLogger.write(
              'local-library',
              'saf scan failed root=$root error=$error',
            ),
          );
        }
      }
      if (safRoots.isNotEmpty) {
        fallback = fallback
            .where((root) => !safRoots.contains(root))
            .toList();
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
    // 「未被系统索引、靠兜底扫出」与「兜底也没读到」，并标明最终是
    // 哪条通道产出的（saf 授权枚举 / filesystem 原始遍历 / 都没走）。
    for (final root in zeroHitRoots) {
      final count = result.files.values
          .where((file) => isFileInScanDirectory(file.path, root))
          .length;
      final channel = safRoots.contains(root)
          ? 'saf'
          : fallback.contains(root)
          ? 'filesystem'
          : 'none';
      unawaited(
        AppLogger.write(
          'local-library',
          'mediastore zero-hit root=$root channel=$channel files=$count',
        ),
      );
    }
    return result;
  }

  /// MediaStore 会残留已删文件的陈旧行（实体经 SAF 删除时行不一定同步
  /// 清掉）。本地路径形态的命中行先做存在性复核，实体不存在的不进结果；
  /// content 形态的行没有本地实体语义，不查。复核本身抛错时保守保留，
  /// 避免校验故障误杀真实歌曲。
  @visibleForTesting
  static Future<List<Map<String, dynamic>>> existingMediaRows(
    List<Map<String, dynamic>> rows, {
    Future<bool> Function(String path)? fileExists,
  }) async {
    final exists = fileExists ?? ((path) => File(path).exists());
    final keep = List<bool>.filled(rows.length, true);
    final pending = <int>[
      for (var i = 0; i < rows.length; i++)
        if (rows[i]['path'] is String &&
            !isContentLocation(rows[i]['path'] as String))
          i,
    ];
    for (var start = 0; start < pending.length; start += 64) {
      await Future.wait([
        for (final i in pending.skip(start).take(64))
          exists(rows[i]['path'] as String).then(
            (present) => keep[i] = present,
            onError: (_) => keep[i] = true,
          ),
      ]);
    }
    return [
      for (var i = 0; i < rows.length; i++)
        if (keep[i]) rows[i],
    ];
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

  /// 哪些根走 SAF 通道枚举：带原始 content URI（成对根）且 MediaStore
  /// 零命中的根。MediaStore 有命中的根不重复枚举；无 URI 的纯本地根
  /// 保持文件系统兜底逻辑，不进此列。
  @visibleForTesting
  static List<String> safScanRoots(
    List<String> directories, {
    required Map<String, String> contentRoots,
    required Set<String> hitRoots,
  }) => [
    for (final root in directories)
      if (contentRoots.containsKey(root) && !hitRoots.contains(root)) root,
  ];

  /// 把一行 SAF 树枚举结果映射成索引行：身份 path 用拼出的本地路径
  /// （与 MediaStore / saved 事件行同形态，归属与合并口径一致），
  /// playbackPath/contentUri 用文档 URI。拼不出本地路径的行（文档 id
  /// 与树根对不上）直接跳过。createdAt 与 saved 事件的 SAF 行一致，
  /// 原生枚举不给创建时间，记为 epoch。
  @visibleForTesting
  static LocalSongFileSnapshot? safTreeFile(
    Map<String, dynamic> row, {
    required String root,
    required String treeUri,
  }) {
    final documentId = row['id'] as String?;
    final documentUri = row['path'] as String?;
    final name = row['fileName'] as String?;
    if (documentId == null || documentUri == null || name == null) {
      return null;
    }
    final local = safDocumentLocalPath(
      treeUri: treeUri,
      rootPath: root,
      documentId: documentId,
    );
    if (local == null || !isFileInScanDirectory(local, root)) return null;
    final modifiedMs = (row['modifiedMs'] as num?)?.toInt() ?? 0;
    return LocalSongFileSnapshot(
      path: local,
      contentUri: documentUri,
      aliases: [documentUri],
      fileName: name,
      extension: p.extension(name).replaceFirst('.', ''),
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(modifiedMs),
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      sizeBytes: (row['sizeBytes'] as num?)?.toInt() ?? 0,
      directory: root,
    );
  }

  /// 由文档 id 拼本地路径：外部存储文档 id 形如 `primary:Music/a.mp3`，
  /// 树 id 形如 `primary:Music`；卷名一致时，文档相对路径去掉树相对
  /// 前缀后拼到根的本地路径下即得。与原生 resolveLocalPath 的拼法对齐。
  @visibleForTesting
  static String? safDocumentLocalPath({
    required String treeUri,
    required String rootPath,
    required String documentId,
  }) {
    final segments = Uri.tryParse(treeUri)?.pathSegments ?? const [];
    final treeIndex = segments.indexOf('tree');
    if (treeIndex < 0 || treeIndex + 1 >= segments.length) return null;
    final treeId = segments[treeIndex + 1];
    final treeColon = treeId.indexOf(':');
    final docColon = documentId.indexOf(':');
    if (treeColon < 0 || docColon < 0) return null;
    if (treeId.substring(0, treeColon) !=
        documentId.substring(0, docColon)) {
      return null;
    }
    final treeRelative = treeId.substring(treeColon + 1);
    final docRelative = documentId.substring(docColon + 1);
    final String relative;
    if (treeRelative.isEmpty) {
      relative = docRelative;
    } else if (docRelative.startsWith('$treeRelative/')) {
      relative = docRelative.substring(treeRelative.length + 1);
    } else {
      return null;
    }
    if (relative.isEmpty) return null;
    return normalizeStorageLocation(p.posix.join(rootPath, relative));
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

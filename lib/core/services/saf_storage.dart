import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'storage_location.dart';
import 'storage_browser_service.dart';
import 'local_audio_library_events.dart';
import 'windows_folder_picker.dart';

/// The stored location is either a legacy filesystem path or an opaque SAF URI.
class SafStorage {
  static const _channel = MethodChannel('cy_shine_music/saf_storage');
  static final Map<String, String> _labels = {};
  static const _labelPrefix = 'saf_directory_label:';

  static void loadLabels(SharedPreferences prefs) {
    for (final key in prefs.getKeys().where(
      (k) => k.startsWith(_labelPrefix),
    )) {
      _labels[key.substring(_labelPrefix.length)] = prefs.getString(key)!;
    }
  }

  static String label(String location) =>
      _labels[location] ?? storageLocationLabel(location);

  static Future<String?> pickDirectory({
    required bool writable,
    String? initialLocation,
  }) async {
    if (Platform.isWindows) {
      // Windows：file_picker 纯 Dart 实现，弹原生目录选择框。
      // 默认下载目录由 main.dart 用正斜杠拼成 C:\...\Documents/MuyinMusic，
      // file_picker 的 SHCreateItemFromParsingName 原样解析混合斜杠会返回
      // E_INVALIDARG 并抛 WindowsException（并非 PlatformException，上层
      // catch 不到），弹框根本不会打开。传入前把正斜杠统一成反斜杠，
      // 只保留存在的绝对路径作为起始目录，避免混合斜杠与不存在路径两种异常。
      final candidate = initialLocation?.replaceAll('/', r'\');
      final initialDir = candidate != null &&
              p.isAbsolute(candidate) &&
              Directory(candidate).existsSync()
          ? candidate
          : null;
      final picked = await pickWindowsFolder(
        initialDirectory: initialDir,
        dialogTitle: '选择文件夹',
      );
      if (picked == null) {
        unawaited(AppLogger.write('picker', 'outcome=cancelled'));
        return null;
      }
      final name = p.basename(picked);
      unawaited(AppLogger.write('picker', 'outcome=selected name=$name'));
      _labels[picked] = name;
      await (await SharedPreferences.getInstance()).setString(
        '$_labelPrefix$picked',
        name,
      );
      return picked;
    }
    if (!Platform.isAndroid) {
      // iOS：走 storage_browser 通道，弹出系统文档选择器并持久化 bookmark，
      // 返回沙盒外目录的绝对路径（会话内已持有 security scope）。
      final picked = await const StorageBrowserService().pickDirectory();
      if (picked == null) return null;
      final path = picked['path']!;
      final name = picked['name'] ?? path;
      _labels[path] = name;
      await (await SharedPreferences.getInstance()).setString(
        '$_labelPrefix$path',
        name,
      );
      return path;
    }
    final Map<String, dynamic>? selected;
    try {
      selected = await _channel.invokeMapMethod<String, dynamic>(
        'pickDirectory',
        {'writable': writable, 'initialUri': initialLocation},
      );
    } on PlatformException catch (error) {
      unawaited(AppLogger.write('picker', 'outcome=error code=${error.code}'));
      rethrow;
    }
    if (selected == null) {
      unawaited(AppLogger.write('picker', 'outcome=cancelled'));
      return null;
    }
    final uri = selected['uri'] as String;
    final name = selected['name'] as String;
    unawaited(AppLogger.write('picker', 'outcome=selected name=$name'));
    _labels[uri] = name;
    await (await SharedPreferences.getInstance()).setString(
      '$_labelPrefix$uri',
      name,
    );
    return uri;
  }

  static Future<void> validateDirectory(
    String location, {
    required bool writable,
  }) async {
    if (isContentLocation(location)) {
      await _channel.invokeMethod<void>('validateDirectory', {
        'uri': location,
        'writable': writable,
      });
      return;
    }
    final directory = Directory(location);
    if (!await directory.exists()) throw const FileSystemException('目录不存在');
    if (!writable) {
      await directory.list(followLinks: false).take(1).drain<void>();
      return;
    }
    final probe = await directory.createTemp('.muyin-probe-');
    try {
      await File('${probe.path}/write-test').writeAsString('ok');
    } finally {
      await probe.delete(recursive: true);
    }
  }

  static Future<List<Map<String, dynamic>>> scan(String uri) async {
    final rows = await _channel.invokeListMethod<dynamic>('scan', {'uri': uri});
    return [
      for (final row in rows ?? []) Map<String, dynamic>.from(row as Map),
    ];
  }

  /// Only the system external-storage provider has a known local mapping.
  /// Other providers remain opaque and cannot filter the local media library.
  static Future<String?> resolveLocalPath(
    String location, {
    bool requireReadable = true,
  }) async {
    if (!isContentLocation(location)) return normalizeStorageLocation(location);
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('resolveLocalPath', {
        'uri': location,
        'requireReadable': requireReadable,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> metadata(String location) async {
    if (isContentLocation(location)) {
      return _channel.invokeMapMethod<String, dynamic>('metadata', {
        'uri': location,
      });
    }
    final stat = await File(location).stat();
    if (stat.type != FileSystemEntityType.file) return null;
    return {
      'fileName': File(location).uri.pathSegments.last,
      'sizeBytes': stat.size,
      'modifiedMs': stat.modified.millisecondsSinceEpoch,
      'createdMs': stat.changed.millisecondsSinceEpoch,
    };
  }

  static Future<String> saveFile(
    String tree,
    String source,
    String name, {
    String? subdirectory,
  }) async => (await _channel.invokeMethod<String>('saveFile', {
    'uri': tree,
    'source': source,
    'name': name,
    'subdirectory': ?subdirectory,
  }))!;

  static Future<bool> exists(String location) async {
    if (!isContentLocation(location)) return File(location).exists();
    return await _channel.invokeMethod<bool>('exists', {'uri': location}) ??
        false;
  }

  static Future<int> size(String location) async {
    if (!isContentLocation(location)) return File(location).length();
    return await _channel.invokeMethod<int>('size', {'uri': location}) ?? 0;
  }

  /// Android 走系统 MediaStore 删除确认；iOS/桌面 的本地音频是 App 沙盒内的
  /// 普通文件（外部目录已在启动时持有 security scope），直接物理删除。
  /// 取消与部分成功分开返回，调用方据此保留未删除记录。
  static Future<FileDeletionResult> deleteFiles(
    Iterable<String> locations,
  ) async {
    final paths = locations.where((p) => p.isNotEmpty).toSet().toList();
    if (paths.isEmpty) {
      return const FileDeletionResult(
        deletedPaths: <String>{},
        failed: <String, String>{},
        cancelled: false,
      );
    }
    final FileDeletionResult deletion;
    if (Platform.isAndroid) {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'deleteFiles',
        {'paths': paths},
      );
      if (result == null) throw StateError('未收到删除结果');
      deletion = FileDeletionResult(
        deletedPaths: Set<String>.from(
          result['deletedPaths'] as List? ?? const [],
        ),
        failed: Map<String, String>.from(result['failed'] as Map? ?? const {}),
        cancelled: result['cancelled'] == true,
      );
    } else {
      final deleted = <String>{};
      final removedFromListOnly = <String>{};
      final failed = <String, String>{};
      for (final path in paths) {
        try {
          final file = File(path);
          if (await file.exists()) {
            await file.delete();
            deleted.add(path);
          } else {
            // 物理文件不存在或当前 scope 访问不到：不假报"已删除"，
            // 仅从列表移除（上层照常清索引/历史），单独统计以便如实提示。
            removedFromListOnly.add(path);
          }
        } catch (e) {
          final file = File(path);
          if (await file.exists().catchError((_) => false)) {
            // 删除抛异常但文件仍在：算真失败，保留列表记录。
            failed[path] = e.toString();
          } else {
            // 异常源于访问不到（scope 失效）：仅从列表移除。
            removedFromListOnly.add(path);
          }
        }
      }
      deletion = FileDeletionResult(
        deletedPaths: {...deleted, ...removedFromListOnly},
        failed: failed,
        cancelled: false,
        removedFromListOnly: removedFromListOnly,
      );
    }
    await LocalAudioLibraryEvents.deleted(deletion.deletedPaths);
    return deletion;
  }
}

class FileDeletionResult {
  const FileDeletionResult({
    required this.deletedPaths,
    required this.failed,
    required this.cancelled,
    this.removedFromListOnly = const <String>{},
  });

  final Set<String> deletedPaths;
  final Map<String, String> failed;
  final bool cancelled;

  /// 物理文件删不掉（外部目录 scope 失效 / 路径已变），仅从列表移除的路径。
  /// 这些路径仍在 [deletedPaths] 中以便上层刷新列表，但不计入"已删除文件数"。
  final Set<String> removedFromListOnly;
}

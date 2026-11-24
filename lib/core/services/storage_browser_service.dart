import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_logger.dart';

final storageBrowserServiceProvider = Provider<StorageBrowserService>(
  (ref) => const StorageBrowserService(),
);

@immutable
class StorageBrowserEntry {
  const StorageBrowserEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.isRoot,
    required this.canRead,
    required this.canWrite,
    required this.totalBytes,
    required this.freeBytes,
    this.isRemovable,
    this.state,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final bool isRoot;
  final bool canRead;
  final bool canWrite;
  final int totalBytes;
  final int freeBytes;
  final bool? isRemovable;
  final String? state;

  bool get isReadOnly => canRead && !canWrite;

  factory StorageBrowserEntry.fromMap(Map<Object?, Object?> raw) {
    return StorageBrowserEntry(
      path: raw['path'] as String? ?? '',
      name: raw['name'] as String? ?? '',
      isDirectory: raw['isDirectory'] as bool? ?? false,
      isRoot: raw['isRoot'] as bool? ?? false,
      canRead: raw['canRead'] as bool? ?? false,
      canWrite: raw['canWrite'] as bool? ?? false,
      totalBytes: _intValue(raw['totalBytes']),
      freeBytes: _intValue(raw['freeBytes']),
      isRemovable: raw['isRemovable'] as bool?,
      state: raw['state'] as String?,
    );
  }

  static int _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }
}

class StorageBrowserService {
  const StorageBrowserService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'cy_shine_music/storage_browser';

  final MethodChannel _channel;

  bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// 弹出系统目录选择器并建立 security-scoped bookmark 持久授权（iOS）。
  /// 返回 {path, name}；用户取消返回 null。
  /// 每次结局（选定/取消/错误码）写一条日志，下次实机复现可与原生侧
  /// picker 记录对齐定位；只记目录名，不记完整路径。
  Future<Map<String, String>?> pickDirectory() async {
    if (!Platform.isIOS) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'pickDirectory',
      );
      final path = raw?['path'] as String?;
      if (raw == null || path == null || path.isEmpty) {
        unawaited(AppLogger.write('picker', 'outcome=cancelled'));
        return null;
      }
      final name = raw['name'] as String? ?? path;
      unawaited(AppLogger.write('picker', 'outcome=selected name=$name'));
      return {'path': path, 'name': name};
    } on PlatformException catch (error) {
      unawaited(AppLogger.write('picker', 'outcome=error code=${error.code}'));
      rethrow;
    }
  }

  /// 启动时对全部已授权 bookmark 根持续持有 security scope（iOS）。
  /// 返回成功持有 scope 的根数量。
  Future<int> acquireAllAccess() async {
    if (!Platform.isIOS) return 0;
    return await _channel.invokeMethod<int>('acquireAllAccess') ?? 0;
  }

  /// 该路径本身是否已有 security-scoped bookmark 授权（iOS）。
  /// 先按路径键查，再回退解析存量条目比对解析出的路径（兼容旧版按
  /// 文件夹名存键的 bookmark）。
  Future<bool> hasBookmark(String path) async {
    if (!Platform.isIOS) return false;
    return await _channel.invokeMethod<bool>('hasBookmark', {
          'path': path,
        }) ??
        false;
  }

  Future<List<StorageBrowserEntry>> listRoots() async {
    if (!isSupported) return const [];
    final raw = await _channel.invokeListMethod<Object?>('listRoots');
    return _decodeEntries(raw);
  }

  Future<List<StorageBrowserEntry>> listChildren(
    String path, {
    Set<String>? fileExtensions,
  }) async {
    if (!isSupported) return const [];
    final raw = await _channel.invokeListMethod<Object?>('listChildren', {
      'path': path,
      'includeFiles': fileExtensions != null,
    });
    final extensions = fileExtensions
        ?.map((value) => value.toLowerCase())
        .toSet();
    return List.unmodifiable(
      _decodeEntries(raw).where((entry) {
        if (entry.isDirectory) return true;
        final name = entry.name.toLowerCase();
        return extensions?.any((extension) => name.endsWith('.$extension')) ??
            false;
      }),
    );
  }

  List<StorageBrowserEntry> _decodeEntries(List<Object?>? raw) {
    if (raw == null) return const [];
    final entries = <StorageBrowserEntry>[];
    for (final item in raw) {
      if (item is Map<Object?, Object?>) {
        final entry = StorageBrowserEntry.fromMap(item);
        if (entry.path.isNotEmpty && entry.name.isNotEmpty) {
          entries.add(entry);
        }
      }
    }
    return List.unmodifiable(entries);
  }
}

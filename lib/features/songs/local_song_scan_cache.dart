import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/services/app_logger.dart';
import '../../core/services/artwork_disk_cache.dart';
import '../../core/services/embedded_artwork_cache.dart';
import '../../core/services/local_audio_library_events.dart';
import '../../core/services/permission_service.dart';
import '../../core/services/saf_storage.dart';
import '../../core/services/storage_location.dart';
import '../../core/storage/settings_store.dart';
import '../cloud/cloud_song_path.dart';
import 'local_song_scan_models.dart';
import 'local_song_scanner.dart';

export 'local_song_scan_models.dart';

/// A durable library index. Only first import, folder changes and explicit
/// refresh enumerate storage; downloads and deletions update individual rows.
class LocalSongScanCache extends ChangeNotifier {
  LocalSongScanCache({
    List<String> Function()? directories,
    List<String> Function()? ignoredPaths,
    Future<String?> Function(String location)? contentRootResolver,
    Future<List<Map<String, dynamic>>> Function(String uri)? safTreeScanner,
  }) : _directories = directories,
       _ignoredPaths = ignoredPaths,
       _contentRootResolver = contentRootResolver,
       _safTreeScanner = safTreeScanner {
    _stopListening = LocalAudioLibraryEvents.listen(_handleFileChange);
  }

  static const _fileName = 'local_song_scan_v1.json';
  final List<String> Function()? _directories;
  final List<String> Function()? _ignoredPaths;
  final Future<String?> Function(String location)? _contentRootResolver;
  final Future<List<Map<String, dynamic>>> Function(String uri)?
  _safTreeScanner;
  late final void Function() _stopListening;
  final _mutations = <String, ({int revision, LocalSongFileSnapshot? file})>{};
  // 待确认删除键：removePaths 记下的删除在每轮扫描落盘前再兜底剔除一次，
  // 防止陈旧枚举源（如 MediaStore 残留行）把已删歌曲写回快照；某轮枚举
  // 本身已不再产出该键时才移除（实体确已消失，自愈）。纯内存态即可：
  // 落盘的快照已是剔除后的状态，重启后由枚举侧的存在性复核兜底。
  final _pendingDeletionKeys = <String>{};
  final _eventRevisions = <String, int>{};
  final _aliases = <String, String>{};
  LocalSongScanSnapshot? _snapshot;
  Future<void>? _loadFuture;
  Future<void>? _scanFuture;
  Future<void>? _metadataFuture;
  Future<void> _writeFuture = Future.value();
  List<String>? _scanDirectories;
  Timer? _saveTimer;
  Timer? _notifyTimer;
  int _scanGeneration = 0;
  int _revision = 0;
  bool _disposed = false;

  LocalSongScanSnapshot? get snapshot => _snapshot;

  String pathKey(String path) {
    final key = localSongPathKey(path);
    return _aliases[key] ?? key;
  }

  /// 「仅从本地列表移除」的忽略名单按路径键匹配：歌曲的本地路径、播放
  /// 路径（SAF 的 content URI）与别名任一命中即视为被忽略，与扫描管线
  /// 实际使用的路径形态保持一致。
  Set<String> _ignoredKeys() => {
    for (final path in _ignoredPaths?.call() ?? const <String>[])
      if (path.trim().isNotEmpty) localSongPathKey(path),
  };

  bool _isIgnored(LocalSongFileSnapshot file, Set<String> ignoredKeys) {
    if (ignoredKeys.isEmpty) return false;
    return ignoredKeys.contains(file.key) ||
        ignoredKeys.contains(pathKey(file.playbackPath)) ||
        file.aliases.any((alias) => ignoredKeys.contains(pathKey(alias)));
  }

  Future<void> ensureLoaded() => _loadFuture ??= _load();

  Future<void> _load() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (_disposed) return;
      if (decoded is Map) {
        _snapshot = LocalSongScanSnapshot.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        final ignoredKeys = _ignoredKeys();
        if (ignoredKeys.isNotEmpty) {
          // 持久化索引可能还留着已忽略歌曲的行（例如名单是在别的入口
          // 写入的），恢复时先过滤，避免它们在首次扫描前回到列表。
          _snapshot = _snapshot!.withFiles([
            for (final file in _snapshot!.files)
              if (!_isIgnored(file, ignoredKeys)) file,
          ]);
        }
        _registerArtwork();
        notifyListeners();
        if (!Platform.isAndroid || _snapshot!.backend == 'compatibility') {
          _warmMetadata();
        }
        unawaited(
          AppLogger.write(
            'local-library',
            'restore files=${_snapshot!.files.length}',
          ),
        );
      }
    } catch (_) {
      // A damaged index is rebuilt once. Failed scans preserve known rows.
    }
  }

  Future<void> ensureScan({
    String? directory,
    List<String>? directories,
  }) async {
    final prepared = await _prepareScanRoots(directory, directories);
    final selected = prepared.directories;
    await ensureLoaded();
    if (_disposed || selected.isEmpty) return;
    final current = _snapshot;
    if (current != null &&
        current.initialized &&
        current.matchesDirectories(selected)) {
      final upgrade =
          Platform.isAndroid &&
          current.backend == 'filesystem' &&
          (await PermissionService.hasAudioLibraryRead() ||
              await PermissionService.hasExternalStorageWrite());
      if (!upgrade) {
        _warmMetadata();
        return;
      }
    }
    await _refreshPrepared(prepared);
  }

  Future<void> refresh({String? directory, List<String>? directories}) async {
    final prepared = await _prepareScanRoots(directory, directories);
    await _refreshPrepared(prepared);
  }

  Future<void> _refreshPrepared(_PreparedScanRoots prepared) async {
    final selected = prepared.directories;
    await ensureLoaded();
    if (_disposed) return;
    if (selected.isEmpty) {
      // 全部扫描根都是无法解析的授权文件夹：没有可扫的根，保留现有
      // 索引不动，也不制造错误态。
      return;
    }
    final running = _scanFuture;
    if (running != null && listEquals(_scanDirectories, selected)) {
      return running;
    }
    final generation = ++_scanGeneration;
    final startedRevision = _revision;
    _scanDirectories = selected;
    final future = _scanDirectoryContents(
      selected,
      generation,
      startedRevision,
      contentRoots: prepared.contentUris,
    );
    _scanFuture = future;
    await future;
  }

  /// 扫描器只认本地路径，content 根（SAF 授权文件夹）必须先解析。
  /// 所有稳态扫描入口都经过 [ensureScan]/[refresh]，在此一处统一准备：
  /// content 根解析成功换成本地路径并与原始 URI 成对保留（扫描器对
  /// MediaStore 零命中的授权根要靠 URI 走 SAF 通道枚举），失败（null）
  /// 则剔除——不送进扫描器、不产生用户可见 error。目录身份（比对、
  /// 落盘）始终以解析后的本地路径为准，成对信息不改变短路语义。
  Future<_PreparedScanRoots> _prepareScanRoots(
    String? directory,
    List<String>? directories,
  ) async {
    final normalized = _scanRoots(directory, directories);
    if (!normalized.any(isContentLocation)) {
      return _PreparedScanRoots(normalized, const {});
    }
    final resolve =
        _contentRootResolver ??
        ((String location) =>
            SafStorage.resolveLocalPath(location, requireReadable: false));
    final prepared = <String>{};
    final contentUris = <String, String>{};
    for (final root in normalized) {
      if (!isContentLocation(root)) {
        prepared.add(root);
        continue;
      }
      final local = await resolve(root);
      if (local != null && local.trim().isNotEmpty) {
        final localRoot = normalizeStorageLocation(local);
        prepared.add(localRoot);
        contentUris[localRoot] = root;
      } else {
        unawaited(
          AppLogger.write(
            'local-library',
            'scan root dropped, cannot resolve ${SafStorage.label(root)}',
          ),
        );
      }
    }
    return _PreparedScanRoots(
      List.unmodifiable(prepared),
      Map.unmodifiable(contentUris),
    );
  }

  Future<void> _scanDirectoryContents(
    List<String> directories,
    int generation,
    int startedRevision, {
    Map<String, String> contentRoots = const {},
  }) async {
    final watch = Stopwatch()..start();
    final previous = {
      for (final file in _snapshot?.files ?? const <LocalSongFileSnapshot>[])
        file.key: file,
    };
    try {
      final result = await LocalSongScanner.scan(
        directories,
        previous,
        () => _disposed || generation != _scanGeneration,
        contentRoots: contentRoots,
        safScan: _safTreeScanner,
      );
      if (_disposed || generation != _scanGeneration) return;
      final files = result.files;
      final errors = result.errors;
      // Retain metadata completed during enumeration, then merge file operations
      // newer than this scan. A successful deletion always wins over old rows.
      final latest = {
        for (final row in _snapshot?.files ?? const <LocalSongFileSnapshot>[])
          row.key: row,
      };
      for (final entry in files.entries.toList()) {
        if (entry.value.contentUri == null) {
          files[entry.key] = entry.value.retainingMetadata(
            latest[entry.key],
            retryEmpty: true,
          );
        }
      }
      for (final entry in _mutations.entries) {
        final file = entry.value.file;
        if (entry.value.revision <= startedRevision) {
          if (file == null ||
              files.containsKey(entry.key) ||
              !directories.any(
                (root) => isFileInScanDirectory(file.path, root),
              )) {
            continue;
          }
          try {
            if (await SafStorage.exists(file.playbackPath)) {
              files[entry.key] = file;
            }
          } catch (_) {
            /* Keep the scan result if this old handle is unavailable. */
          }
          continue;
        }
        if (file == null) {
          files.remove(entry.key);
        } else if (directories.any(
          (root) => isFileInScanDirectory(file.path, root),
        )) {
          files[entry.key] = file;
        }
      }
      // 云端行由 CloudDrive2 枚举单独维护，本地枚举不产出它们；把上一份
      // 快照里的云端行原样带过来，避免一次本地扫描把云端音乐冲掉。忽略
      // 名单过滤在下面统一执行，云端行同样受约束。
      for (final old in previous.values) {
        if (isCloudSongPath(old.path) && !files.containsKey(old.key)) {
          files[old.key] = old;
        }
      }
      for (final old in previous.values) {
        final next = files[old.key];
        if (next == null || next.fingerprint != old.fingerprint) {
          EmbeddedArtworkCache.evictPath(old.path);
        }
      }
      // 忽略名单最后兜底：枚举结果与增量变更合并后统一过滤，名单内
      // 文件不落盘、不进本地库。
      final ignoredKeys = _ignoredKeys();
      if (ignoredKeys.isNotEmpty) {
        files.removeWhere((_, file) => _isIgnored(file, ignoredKeys));
      }
      // 删除防复活兜底：待确认删除的键，只要本轮枚举仍在产出它，落盘
      // 前一律剔除；枚举已不再产出的键从待确认集合移除（自愈）。同一
      // 路径被重新下载/保存时，saved 事件会提前清掉待确认键，不受影响。
      if (_pendingDeletionKeys.isNotEmpty) {
        for (final key in _pendingDeletionKeys.toList()) {
          if (result.files.containsKey(key)) {
            files.remove(key);
          } else {
            _pendingDeletionKeys.remove(key);
          }
        }
      }
      final enumerationMs = watch.elapsedMilliseconds;
      await save(
        directories: directories,
        files: files.values.toList(),
        // 单根失败只进日志：只要本次扫描还有歌，列表就不进错误态；
        // error 只在列表为空时保留，供空态页提示。
        error: errors.isEmpty || files.isNotEmpty
            ? null
            : '无法读取本地音乐文件夹：${errors.join('\n')}',
        backend: result.backend,
      );
      _warmMetadata();
      await _metadataFuture;
      if (!_disposed && generation == _scanGeneration) await flush();
      unawaited(
        AppLogger.write(
          'local-library',
          'scan backend=${result.backend} files=${files.length} errors=${errors.length} enumerationMs=$enumerationMs totalMs=${watch.elapsedMilliseconds}',
        ),
      );
    } finally {
      if (generation == _scanGeneration) _scanFuture = null;
    }
  }

  Future<void> _handleFileChange(LocalAudioLibraryChange event) async {
    if (event.deletedPaths.isNotEmpty) {
      final revision = ++_revision;
      for (final path in event.deletedPaths) {
        _eventRevisions[localSongPathKey(path)] = revision;
      }
      if (_snapshot == null) await ensureLoaded();
      removePaths(
        event.deletedPaths.where(
          (path) => _eventRevisions[localSongPathKey(path)] == revision,
        ),
        revision: revision,
      );
      await flush();
      return;
    }
    if (event.path.isEmpty) return;
    // 忽略名单内的文件即使有保存事件也不重新入库。
    if (_ignoredKeys().contains(localSongPathKey(event.path))) return;
    final eventKey = localSongPathKey(event.path);
    final revision = ++_revision;
    _eventRevisions[eventKey] = revision;
    try {
      await ensureLoaded();
      if (_disposed || _eventRevisions[eventKey] != revision) return;
      final directories = normalizeScanDirectories(
        _directories?.call() ?? _snapshot?.directories ?? [],
      );
      final file = await savedLibraryFile(event.path, directories);
      if (file == null) {
        // 增量归属判断失败（下载根与扫描根路径形态不一致 / owner==null /
        // metadata 读取失败）。iOS 无系统媒体扫描，saved 事件是唯一的入库
        // 机会；此前这里静默 return，加上 ensureScan 在目录未变时跳过全扫，
        // 新文件就永久进不了索引——表现为「下载成功但扫描不到」。
        // 兜底触发一次全扫：全扫按扫描根物理枚举，不依赖路径字符串归属。
        unawaited(
          AppLogger.write(
            'local-library',
            'incremental miss for ${event.path}, falling back to full refresh',
          ),
        );
        unawaited(refresh(directories: directories));
        return;
      }
      if (_isIgnored(file, _ignoredKeys())) return;
      if (_disposed ||
          _eventRevisions[eventKey] != revision ||
          (_mutations[file.key]?.revision ?? 0) > revision) {
        return;
      }
      final key = file.key;
      final row = event.tags == null ? file : file.withMetadata(event.tags);
      // 同一路径重新出现（重新下载/保存）：待确认删除作废，别再误删。
      _pendingDeletionKeys.remove(key);
      _mutations[key] = (revision: revision, file: row);
      for (final alias in row.aliases) {
        _aliases[localSongPathKey(alias)] = key;
      }
      final old = _snapshot;
      final files = {
        for (final f in old?.files ?? const <LocalSongFileSnapshot>[]) f.key: f,
      };
      files[key] = row;
      _snapshot = LocalSongScanSnapshot(
        directories: old?.directories ?? directories,
        cachedAt: old?.cachedAt ?? DateTime.now(),
        files: List.unmodifiable(files.values),
        error: old?.error,
        initialized: old?.initialized ?? false,
        pathsLinked: old?.pathsLinked ?? false,
        backend: old?.backend ?? 'filesystem',
      );
      _registerFile(row);
      if (event.tags?.hasArtwork == true) {
        await EmbeddedArtworkCache.seed(
          row.playbackPath,
          event.tags!.artworkBytes!,
          version: row.fingerprint,
        );
      } else {
        await EmbeddedArtworkCache.load(
          row.playbackPath,
          version: row.fingerprint,
        );
      }
      if (_disposed) return;
      notifyListeners();
      await flush();
      _warmMetadata();
    } catch (error) {
      unawaited(AppLogger.write('local-library', 'file update failed: $error'));
    }
  }

  /// Replaces every cloud row in the index with [cloudFiles], the latest
  /// CloudDrive2 enumeration. Local rows are untouched; ignored cloud rows
  /// are filtered with the same path-key rule as local files.
  Future<void> mergeCloudFiles(List<LocalSongFileSnapshot> cloudFiles) async {
    await ensureLoaded();
    if (_disposed) return;
    final current = _snapshot;
    final rows = <String, LocalSongFileSnapshot>{
      for (final file in current?.files ?? const <LocalSongFileSnapshot>[])
        if (!isCloudSongPath(file.path)) file.key: file,
    };
    final ignoredKeys = _ignoredKeys();
    for (final file in cloudFiles) {
      if (_isIgnored(file, ignoredKeys)) continue;
      rows[file.key] = file;
    }
    _snapshot = LocalSongScanSnapshot(
      directories: current?.directories ?? const [],
      cachedAt: current?.cachedAt ?? DateTime.now(),
      files: List.unmodifiable(rows.values),
      error: current?.error,
      initialized: current?.initialized ?? false,
      pathsLinked: current?.pathsLinked ?? false,
      backend: current?.backend ?? 'filesystem',
    );
    _registerArtwork();
    notifyListeners();
    _scheduleSave();
  }

  /// Applies tags read for one cloud row (whose metadata is hydrated by the
  /// cloud library, not by the local metadata warmer).
  void applyExternalMetadata(LocalSongFileSnapshot file) {
    if (_disposed) return;
    final current = _snapshot;
    if (current == null) return;
    final index = current.files.indexWhere((row) => row.key == file.key);
    if (index < 0 || current.files[index].fingerprint != file.fingerprint) {
      return;
    }
    final files = [...current.files];
    files[index] = file;
    _snapshot = current.withFiles(files);
    notifyListeners();
    _scheduleSave();
  }

  void removePaths(Iterable<String> paths, {int? revision}) {
    if (_disposed) return;
    final keys = paths.map(pathKey).toSet();
    _pendingDeletionKeys.addAll(keys);
    final current = _snapshot;
    for (final key in keys) {
      _mutations[key] = (revision: revision ?? ++_revision, file: null);
    }
    if (current == null) return;
    final files = current.files.where((file) {
      if (!keys.contains(file.key)) return true;
      EmbeddedArtworkCache.evictPath(file.path);
      return false;
    }).toList();
    _snapshot = current.withFiles(files);
    notifyListeners();
    _scheduleSave();
  }

  void _registerFile(LocalSongFileSnapshot file) {
    EmbeddedArtworkCache.registerVersion(file.path, file.fingerprint);
    EmbeddedArtworkCache.registerVersion(
      file.playbackPath,
      file.fingerprint,
      identity: file.path,
    );
    for (final alias in [...file.aliases, file.playbackPath]) {
      _aliases[localSongPathKey(alias)] = file.key;
    }
  }

  void _registerArtwork() {
    for (final file in _snapshot?.files ?? const <LocalSongFileSnapshot>[]) {
      _registerFile(file);
    }
  }

  void _warmMetadata() {
    if (_disposed || _metadataFuture != null) return;
    _metadataFuture = _hydrateMetadata().whenComplete(() {
      _metadataFuture = null;
      if (!_disposed &&
          (_snapshot?.files.any(
                (file) =>
                    !file.metadataRead &&
                    !isContentLocation(file.path) &&
                    !isCloudSongPath(file.path),
              ) ??
              false)) {
        _warmMetadata();
      }
    });
  }

  Future<void> _hydrateMetadata() async {
    final watch = Stopwatch()..start();
    var read = 0;
    while (!_disposed) {
      final pending =
          _snapshot?.files
              .where(
                (file) =>
                    !file.metadataRead &&
                    !isContentLocation(file.path) &&
                    !isCloudSongPath(file.path),
              )
              .take(2)
              .toList() ??
          [];
      if (pending.isEmpty) break;
      await Future.wait(
        pending.map((file) async {
          final tags = await EmbeddedArtworkCache.readForIndex(
            file.path,
            version: file.fingerprint,
          );
          if (_disposed) return;
          final current = _snapshot;
          if (current == null) return;
          final index = current.files.indexWhere((row) => row.key == file.key);
          if (index < 0 ||
              current.files[index].fingerprint != file.fingerprint ||
              current.files[index].metadataRead) {
            return;
          }
          final files = [...current.files];
          files[index] = current.files[index].withMetadata(tags);
          _snapshot = current.withFiles(files);
          read++;
          _notifyTimer ??= Timer(const Duration(milliseconds: 120), () {
            _notifyTimer = null;
            if (!_disposed) notifyListeners();
          });
          _scheduleSave();
        }),
      );
    }
    if (read > 0) {
      unawaited(
        AppLogger.write(
          'local-library',
          'metadata files=$read elapsedMs=${watch.elapsedMilliseconds}',
        ),
      );
    }
  }

  Future<void> save({
    String? directory,
    List<String>? directories,
    required List<LocalSongFileSnapshot> files,
    String? error,
    String backend = 'filesystem',
  }) async {
    if (_disposed) return;
    _snapshot = LocalSongScanSnapshot(
      directories: _scanRoots(directory, directories),
      cachedAt: DateTime.now(),
      files: List.unmodifiable(files),
      error: error,
      backend: backend,
    );
    _registerArtwork();
    notifyListeners();
    await flush();
  }

  void _scheduleSave() {
    _saveTimer ??= Timer(const Duration(milliseconds: 250), () {
      _saveTimer = null;
      unawaited(flush());
    });
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _writeFuture = _writeFuture.then((_) async {
      if (_disposed || _snapshot == null) return;
      try {
        final file = await _cacheFile();
        if (_disposed) return;
        final serialized = jsonEncode(_snapshot!.toJson());
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(serialized, flush: true);
        await temporary.rename(file.path);
      } catch (_) {
        // Preserve the last complete index if a write is interrupted.
      }
    });
    return _writeFuture;
  }

  /// Link older SAF download records to the same files in the direct index.
  /// Resolved aliases are persisted, so subsequent starts perform no lookups.
  Future<void> linkKnownPaths(Iterable<String> paths) async {
    if (_snapshot?.pathsLinked ?? false) return;
    final added = <String, List<String>>{};
    for (final path in paths.toSet()) {
      if (!isContentLocation(path) ||
          _aliases.containsKey(localSongPathKey(path))) {
        continue;
      }
      final local = await SafStorage.resolveLocalPath(
        path,
        requireReadable: false,
      );
      if (_disposed) return;
      if (local == null) continue;
      final key = localSongPathKey(local);
      if (!(_snapshot?.files.any((file) => file.key == key) ?? false)) continue;
      _aliases[localSongPathKey(path)] = key;
      (added[key] ??= []).add(path);
    }
    final current = _snapshot;
    if (current == null || _disposed) return;
    _snapshot = current.withFiles([
      for (final file in current.files)
        if (added.containsKey(file.key))
          file.withAliases([...file.aliases, ...added[file.key]!])
        else
          file,
    ], pathsLinked: true);
    if (added.isNotEmpty) notifyListeners();
    await flush();
  }

  Future<File> _cacheFile() async {
    final support = await getApplicationSupportDirectory();
    ArtworkDiskCache.configure(support.path);
    return File(p.join(support.path, _fileName));
  }

  @override
  void dispose() {
    _disposed = true;
    _scanGeneration++;
    _saveTimer?.cancel();
    _notifyTimer?.cancel();
    _stopListening();
    super.dispose();
  }
}

List<String> _scanRoots(String? directory, List<String>? directories) {
  final normalized = normalizeScanDirectories(directories ?? [?directory]);
  if (normalized.isEmpty) throw ArgumentError('至少需要一个本地音乐文件夹');
  return normalized;
}

/// 根准备结果：[directories] 是解析后的本地路径列表（目录身份口径）；
/// [contentUris] 把源自 content URI 的根与其原始树 URI 成对保留，
/// 供扫描器对 MediaStore 零命中的授权根走 SAF 通道枚举。
class _PreparedScanRoots {
  const _PreparedScanRoots(this.directories, this.contentUris);

  final List<String> directories;
  final Map<String, String> contentUris;
}

final localSongScanCacheProvider = ChangeNotifierProvider<LocalSongScanCache>(
  (ref) => LocalSongScanCache(
    directories: () => ref.read(settingsProvider).scanDirectories,
    ignoredPaths: () => ref.read(settingsProvider).ignoredLocalSongPaths,
  ),
);

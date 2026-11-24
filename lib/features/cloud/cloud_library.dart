import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/music_url.dart';
import '../../core/services/app_logger.dart';
import '../../core/services/embedded_artwork_cache.dart';
import '../../core/services/embedded_audio_tags.dart';
import '../../core/storage/settings_store.dart';
import '../songs/local_song_scan_cache.dart';
import 'cloud_drive2_client.dart';
import 'cloud_song_path.dart';
import 'cloud_song_scanner.dart';
import 'cloud_tag_reader.dart';

/// Resolves a cloud song's virtual path to a playable URL at play time.
/// Implemented by [CloudDrive2Library]; the player depends only on this
/// interface so tests can substitute a fake.
abstract interface class CloudPlaybackResolver {
  Future<MusicUrl> resolve(String virtualPath);
}

/// Owns the CloudDrive2 source: builds the API client from settings,
/// enumerates the cloud into the shared local-song index, and hydrates
/// cloud rows' tags. When CloudDrive2 is not configured the library is
/// inert and the app behaves exactly as before the feature existed.
class CloudDrive2Library extends ChangeNotifier
    implements CloudPlaybackResolver {
  CloudDrive2Library({
    required AppSettings Function() settings,
    required LocalSongScanCache Function() scanCache,
    CloudDrive2Client Function(CloudDrive2Config config)? clientFactory,
  }) : _settings = settings,
       _scanCache = scanCache,
       _clientFactory = clientFactory ?? GrpcCloudDrive2Client.new;

  final AppSettings Function() _settings;
  final LocalSongScanCache Function() _scanCache;
  final CloudDrive2Client Function(CloudDrive2Config config) _clientFactory;

  CloudDrive2Client? _client;
  String? _clientKey;
  CloudTagReader? _tagReader;
  List<LocalSongFileSnapshot> _rows = const [];
  Future<void>? _refreshFuture;
  bool _disposed = false;

  bool get configured => _activeConfig() != null;

  CloudDrive2Config? _activeConfig() {
    final settings = _settings();
    if (!settings.cloudDrive2Configured) return null;
    return parseCloudDrive2Config(
      settings.cloudDrive2Server,
      settings.cloudDrive2Token,
    );
  }

  CloudDrive2Client? _ensureClient() {
    final config = _activeConfig();
    if (config == null) return null;
    final key =
        '${config.origin}|${config.token.hashCode}|${config.useTls}';
    if (_client != null && _clientKey == key) return _client;
    final old = _client;
    if (old != null) unawaited(old.close());
    _client = _clientFactory(config);
    _clientKey = key;
    _tagReader = CloudTagReader(
      resolveUrl: (remotePath) => _client!.resolvePlayback(remotePath),
    );
    return _client;
  }

  /// Re-enumerates the cloud and merges the result into the shared index.
  /// Concurrent calls share one run; failures keep the previous rows so a
  /// network hiccup never empties the library.
  Future<void> refresh() {
    final running = _refreshFuture;
    if (running != null) return running;
    final future = _refresh();
    _refreshFuture = future.whenComplete(() {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    });
    return _refreshFuture!;
  }

  Future<void> _refresh() async {
    final client = _ensureClient();
    if (client == null) {
      _rows = const [];
      await _scanCache().mergeCloudFiles(const []);
      return;
    }
    final List<LocalSongFileSnapshot> enumerated;
    try {
      enumerated = await enumerateCloudSongs(client);
    } catch (error) {
      unawaited(
        AppLogger.write('cloud-drive2', 'enumerate failed: $error'),
      );
      return;
    }
    if (_disposed) return;
    final previousByKey = {for (final row in _rows) row.key: row};
    final rows = [
      for (final file in enumerated)
        file.retainingMetadata(previousByKey[file.key], retryEmpty: true),
    ];
    _rows = rows;
    await _scanCache().mergeCloudFiles(rows);
    if (_disposed) return;
    unawaited(
      AppLogger.write('cloud-drive2', 'enumerated files=${rows.length}'),
    );
    await _hydrateTags(rows);
  }

  Future<void> _hydrateTags(List<LocalSongFileSnapshot> rows) async {
    final reader = _tagReader;
    if (reader == null) return;
    final pending = rows.where((row) => !row.metadataRead).toList();
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < pending.length && !_disposed) {
        final file = pending[cursor++];
        final tags = await reader.readTags(file);
        if (_disposed) return;
        if (tags?.hasArtwork ?? false) {
          await EmbeddedArtworkCache.seed(
            file.path,
            tags!.artworkBytes!,
            version: file.fingerprint,
          );
        }
        final updated = file.withMetadata(tags);
        final index = _rows.indexWhere((row) => row.key == file.key);
        if (index >= 0 && _rows[index].fingerprint == file.fingerprint) {
          final next = [..._rows];
          next[index] = updated;
          _rows = next;
        }
        _scanCache().applyExternalMetadata(updated);
      }
    }

    await Future.wait([worker(), worker()]);
  }

  @override
  Future<MusicUrl> resolve(String virtualPath) async {
    final client = _ensureClient();
    if (client == null) {
      throw StateError('CloudDrive2 未配置或未启用');
    }
    return client.resolvePlayback(cloudDrive2RemotePath(virtualPath));
  }

  /// Full embedded tags (incl. lyrics/artwork) for one cloud song, used by
  /// the player for embedded lyrics. Best-effort: null on any failure.
  Future<EmbeddedAudioTags?> tagsFor(String virtualPath) async {
    if (_ensureClient() == null) return null;
    final reader = _tagReader;
    if (reader == null) return null;
    final row = _rows
        .where((row) => row.key == localSongPathKey(virtualPath))
        .firstOrNull;
    final file =
        row ??
        LocalSongFileSnapshot(
          path: virtualPath,
          fileName: virtualPath.split('/').last,
          extension: '',
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(0),
          sizeBytes: 0,
        );
    try {
      return await reader.readTags(file);
    } catch (_) {
      return null;
    }
  }

  Future<bool> checkConnection() async {
    final client = _ensureClient();
    if (client == null) return false;
    return client.checkConnection();
  }

  @override
  void dispose() {
    _disposed = true;
    final client = _client;
    _client = null;
    if (client != null) unawaited(client.close());
    super.dispose();
  }
}

final cloudDrive2LibraryProvider =
    ChangeNotifierProvider<CloudDrive2Library>((ref) {
      final library = CloudDrive2Library(
        settings: () => ref.read(settingsProvider),
        scanCache: () => ref.read(localSongScanCacheProvider),
      );
      ref.listen(settingsProvider, (previous, next) {
        final configChanged =
            previous?.cloudDrive2Enabled != next.cloudDrive2Enabled ||
            previous?.cloudDrive2Server != next.cloudDrive2Server ||
            previous?.cloudDrive2Token != next.cloudDrive2Token;
        final ignoredChanged = !listEquals(
          previous?.ignoredLocalSongPaths,
          next.ignoredLocalSongPaths,
        );
        if (configChanged || ignoredChanged) {
          unawaited(library.refresh());
        }
      });
      return library;
    });

final cloudPlaybackResolverProvider = Provider<CloudPlaybackResolver>(
  (ref) => ref.watch(cloudDrive2LibraryProvider),
);

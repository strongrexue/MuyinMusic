import '../../models/catalog_result.dart';
import '../../models/enums.dart';
import '../../models/music_info.dart';
import '../../models/playlist_info.dart';
import '../../models/playlist_summary.dart';
import '../../models/search_category.dart';
import '../internal/sdk_http.dart';
import '../playlist_adapters/kg_playlist_adapter.dart';
import 'catalog_helpers.dart';

/// Kugou's mobile gateway carries singer/album/playlist search next to the song
/// one, which is what the LX client uses for its extra search tabs.
class KgCatalog {
  static const String _mobile = 'http://mobilecdn.kugou.com/api/v3';

  /// Singer/album details only take an id, but some endpoints want the name, so
  /// the search pass remembers what it saw.
  static final Map<String, String> _names = {};

  static Future<CatalogResult> search(
    String keyword,
    SearchCategory category,
    int page,
    int limit, {
    SdkJsonLoader? loader,
  }) async {
    
    final word = Uri.encodeComponent(keyword);
    if (category == SearchCategory.artists) {
      final body = await catalogJson(
        '$_mobile/search/singer?format=json&keyword=$word&page=$page&pagesize=$limit',
      );
      final rows = catalogMaps(body['data']);
      final items = <CatalogItem>[];
      for (final row in rows) {
        final id = row['singerid']?.toString() ?? '';
        final name = catalogText(row['singername']);
        if (id.isEmpty || name.isEmpty) continue;
        _names['artist:$id'] = name;
        items.add(
          CatalogItem(
            category: category,
            summary: PlaylistSummary(
              id: id,
              name: name,
              source: MusicSource.kg,
              coverUrl: catalogImage(row['imgurl']?.toString()),
            ),
            subtitle: '歌手',
          ),
        );
      }
      return CatalogResult(
        items: items.take(limit).toList(),
        total: items.length,
        hasMore: items.length >= limit,
      );
    }

    final path = category == SearchCategory.albums ? 'album' : 'special';
    final body = await catalogJson(
      '$_mobile/search/$path?format=json&keyword=$word&page=$page&pagesize=$limit',
    );
    final data = body['data'];
    final rows = catalogMaps(data is Map ? data['info'] : null);
    final total = data is Map ? catalogInt(data['total']) : rows.length;
    final items = <CatalogItem>[];
    for (final row in rows) {
      if (category == SearchCategory.albums) {
        final id = row['albumid']?.toString() ?? '';
        final name = catalogText(row['albumname']);
        if (id.isEmpty || name.isEmpty) continue;
        _names['album:$id'] = name;
        items.add(
          CatalogItem(
            category: category,
            summary: PlaylistSummary(
              id: id,
              name: name,
              source: MusicSource.kg,
              coverUrl: catalogImage(row['imgurl']?.toString()),
              creator: catalogText(row['singername']),
              playCount: catalogInt(row['playcount']),
              trackCount: catalogInt(row['songcount']),
            ),
            subtitle: [
              catalogText(row['singername']),
              '${catalogInt(row['songcount'])} 首',
            ].where((part) => part.isNotEmpty).join(' · '),
          ),
        );
      } else {
        final id = row['specialid']?.toString() ?? '';
        final name = catalogText(row['specialname']);
        if (id.isEmpty || name.isEmpty) continue;
        _names['playlist:$id'] = name;
        items.add(
          CatalogItem(
            category: category,
            summary: PlaylistSummary(
              id: id,
              name: name,
              source: MusicSource.kg,
              coverUrl: catalogImage(row['imgurl']?.toString()),
              creator: catalogText(row['nickname']),
              playCount: catalogInt(row['playcount']),
              trackCount: catalogInt(row['songcount']),
            ),
            subtitle: [
              catalogText(row['nickname']),
              '${catalogInt(row['songcount'])} 首',
            ].where((part) => part.isNotEmpty).join(' · '),
          ),
        );
      }
    }
    return CatalogResult(
      items: items.take(limit).toList(),
      total: total == 0 ? items.length : total,
      hasMore: page * limit < (total == 0 ? items.length : total),
    );
  }

  static Future<PlaylistInfo> detail(
    String id, {
    required bool artist,
    int? maxTracks,
    SdkJsonLoader? loader,
  }) async {
    if (artist || _names.containsKey('artist:$id')) {
      final name = _names['artist:$id'] ?? '';
      final tracks = await _songs(
        '$_mobile/singer/song?format=json&singerid=$id&page=',
        maxTracks: maxTracks,
        loader: loader,
      );
      return PlaylistInfo(
        id: id,
        name: name.isEmpty ? '歌手' : name,
        source: MusicSource.kg,
        tracks: tracks,
        trackCount: tracks.length,
      );
    }
    if (_names.containsKey('album:$id')) {
      final tracks = await _songs(
        '$_mobile/album/song?format=json&albumid=$id&page=',
        maxTracks: maxTracks,
        loader: loader,
      );
      return PlaylistInfo(
        id: id,
        name: _names['album:$id'] ?? '专辑',
        source: MusicSource.kg,
        tracks: tracks,
        trackCount: tracks.length,
      );
    }
    final tracks = await _songs(
      '$_mobile/special/song?format=json&specialid=$id&page=',
      maxTracks: maxTracks,
      loader: loader,
    );
    return PlaylistInfo(
      id: id,
      name: _names['playlist:$id'] ?? '歌单',
      source: MusicSource.kg,
      tracks: tracks,
      trackCount: tracks.length,
    );
  }

  static Future<List<MusicInfo>> _songs(
    String pagePrefix, {
    int? maxTracks,
    SdkJsonLoader? loader,
  }) async {
    
    final target = maxTracks ?? 200;
    final pageSize = target < 100 ? target : 100;
    final songs = <MusicInfo>[];
    for (var page = 1; songs.length < target; page++) {
      final body = await catalogJson(
        '$pagePrefix$page&pagesize=$pageSize',
        loader: loader,
      );
      final data = body['data'];
      final rows = catalogMaps(data is Map ? data['info'] : null);
      if (rows.isEmpty) break;
      for (final row in rows) {
        final song = KgPlaylistAdapter.parseTrack(row);
        if (song != null) songs.add(song);
        if (songs.length >= target) break;
      }
      final total = data is Map ? catalogInt(data['total']) : 0;
      if (total > 0 && songs.length >= total) break;
      if (rows.length < pageSize) break;
    }
    return songs.take(target).toList(growable: false);
  }

  /// Kugou track payloads share one shape across search, album and singer lists.
  static MusicInfo? parseSong(Map raw) => KgPlaylistAdapter.parseTrack(raw);
}

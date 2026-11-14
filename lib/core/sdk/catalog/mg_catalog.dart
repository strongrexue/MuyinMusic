import '../../models/catalog_result.dart';
import '../../models/enums.dart';
import '../../models/music_info.dart';
import '../../models/playlist_info.dart';
import '../../models/playlist_summary.dart';
import '../../models/search_category.dart';
import '../internal/sdk_http.dart';
import '../mg_sdk.dart';
import '../playlist_adapters/mg_playlist_adapter.dart';
import 'catalog_helpers.dart';

/// Migu's search gateway returns singers, albums and song lists side by side;
/// its dedicated detail endpoints reject third-party callers, so albums and
/// singers are filled in from a follow-up song search.
class MgCatalog {
  static const String _search =
      'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do';

  static final Map<String, String> _names = {};

  static Future<CatalogResult> search(
    String keyword,
    SearchCategory category,
    int page,
    int limit, {
    SdkJsonLoader? loader,
  }) async {
    final body = await catalogJson(
      '$_search?isCopyright=1&isCorrect=1&pageNo=$page&pageSize=$limit'
      '&sort=0&text=${Uri.encodeComponent(keyword)}'
      '&searchSwitch=${Uri.encodeComponent(_switchFor(category))}',
      loader: loader,
    );

    if (category == SearchCategory.artists) {
      final rows = catalogMaps(catalogMap(body['singerResultData'])['result']);
      final items = <CatalogItem>[];
      for (final row in rows) {
        final id = row['id']?.toString() ?? '';
        final name = catalogText(row['name']);
        if (id.isEmpty || name.isEmpty) continue;
        _names['artist:$id'] = name;
        items.add(
          CatalogItem(
            category: category,
            summary: PlaylistSummary(
              id: id,
              name: name,
              source: MusicSource.mg,
              coverUrl: catalogImage(row['img']?.toString()),
            ),
            subtitle: '歌手',
          ),
        );
      }
      final total = catalogInt(catalogMap(body['singerResultData'])['totalCount']);
      return CatalogResult(
        items: items,
        total: total == 0 ? items.length : total,
        hasMore: items.length >= limit,
      );
    }

    if (category == SearchCategory.albums) {
      final data = catalogMap(body['albumResultData']);
      final rows = catalogMaps(data['result']);
      final items = <CatalogItem>[];
      for (final row in rows) {
        final id = row['id']?.toString() ?? '';
        final name = catalogText(row['name']);
        if (id.isEmpty || name.isEmpty) continue;
        _names['album:$id'] = name;
        items.add(
          CatalogItem(
            category: category,
            summary: PlaylistSummary(
              id: id,
              name: name,
              source: MusicSource.mg,
              coverUrl: _firstImage(row['imgItems']),
              creator: catalogText(row['singer']),
            ),
            subtitle: [catalogText(row['singer']), catalogText(row['publishDate'])]
                .where((part) => part.isNotEmpty)
                .join(' · '),
          ),
        );
      }
      final total = catalogInt(data['totalCount']);
      return CatalogResult(
        items: items,
        total: total == 0 ? items.length : total,
        hasMore: items.length >= limit,
      );
    }

    final data = catalogMap(body['songListResultData']);
    final rows = catalogMaps(data['result']);
    final items = <CatalogItem>[];
    for (final row in rows) {
      final id = row['id']?.toString() ?? '';
      final name = catalogText(row['name']);
      if (id.isEmpty || name.isEmpty) continue;
      _names['playlist:$id'] = name;
      items.add(
        CatalogItem(
          category: category,
          summary: PlaylistSummary(
            id: id,
            name: name,
            source: MusicSource.mg,
            coverUrl: _firstImage(row['imgItems']),
            trackCount: catalogInt(row['musicNum']),
            playCount: catalogInt(row['playNum']),
          ),
          subtitle: '${catalogInt(row['musicNum'])} 首',
        ),
      );
    }
    final total = catalogInt(data['totalCount']);
    return CatalogResult(
      items: items,
      total: total == 0 ? items.length : total,
      hasMore: items.length >= limit,
    );
  }

  static Future<PlaylistInfo> detail(
    String id, {
    required bool artist,
    int? maxTracks,
    SdkJsonLoader? loader,
  }) async {
    final name = _names[(artist ? 'artist:' : 'album:') + id] ?? '';
    if (!artist && name.isEmpty) {
      // Song lists have a working detail endpoint of their own.
      return MgPlaylistAdapter.parse(id, maxTracks: maxTracks);
    }
    final tracks = <MusicInfo>[];
    final target = maxTracks ?? 100;
    for (var page = 1; tracks.length < target; page++) {
      final pageSongs = await MgSdk.search(name, page: page, limit: 40);
      if (pageSongs.isEmpty) break;
      for (final song in pageSongs) {
        final match = artist
            ? song.singer.contains(name)
            : song.meta.albumName == name;
        if (match) tracks.add(song);
        if (tracks.length >= target) break;
      }
      if (pageSongs.length < 40) break;
      if (page >= 10) break;
    }
    return PlaylistInfo(
      id: id,
      name: name.isEmpty ? (artist ? '歌手' : '专辑') : name,
      source: MusicSource.mg,
      tracks: tracks.take(target).toList(growable: false),
      trackCount: tracks.length,
    );
  }

  static String _switchFor(SearchCategory category) {
    const base = {
      'song': 0,
      'album': 0,
      'singer': 0,
      'tagSong': 0,
      'mvSong': 0,
      'songlist': 0,
      'bestShow': 0,
    };
    final key = switch (category) {
      SearchCategory.artists => 'singer',
      SearchCategory.albums => 'album',
      _ => 'songlist',
    };
    final switchMap = {...base, key: 1};
    return '{${switchMap.entries.map((e) => '"${e.key}":${e.value}').join(',')}}';
  }

  static String? _firstImage(Object? value) {
    final rows = catalogMaps(value);
    for (final row in rows) {
      final url = catalogImage(row['img'] ?? row['imgUrl']);
      if (url != null) return url;
    }
    return null;
  }
}
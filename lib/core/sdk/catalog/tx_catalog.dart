import '../../models/catalog_result.dart';
import '../../models/enums.dart';
import '../../models/music_info.dart';
import '../../models/playlist_info.dart';
import '../../models/playlist_summary.dart';
import '../../models/search_category.dart';
import '../internal/sdk_http.dart';
import '../playlist_sdk.dart';
import '../tx_sdk.dart';
import 'catalog_helpers.dart';

class TxCatalog {
  static const headers = {'Referer': 'https://y.qq.com/'};

  /// QQ has no public artist track endpoint left, so the search pass
  /// keeps the name and the detail page rebuilds the list from songs.
  static final Map<String, String> _names = {};

  static Future<CatalogResult> search(
    String keyword,
    SearchCategory category,
    int page,
    int limit, {
    SdkJsonLoader? loader,
  }) async {
    if (category == SearchCategory.playlists) {
      final data = await TxSdk.searchCatalog(keyword, 3, page, limit);
      final body = catalogMap(data['body'] ?? data);
      final raw = body['item_songlist'] ?? catalogMap(body['songlist'])['list'];
      if (raw is! List) throw Exception('QQ 歌单搜索暂时不可用');
      final items = catalogMaps(raw)
          .map((i) {
            final creator = catalogText(
              catalogMap(i['creator'])['name'] ?? i['nickname'],
            );
            return CatalogItem(
              category: category,
              summary: PlaylistSummary(
                id: '${i['dissid'] ?? i['diss_id'] ?? i['tid'] ?? ''}',
                name: catalogText(
                  i['dissname'] ?? i['diss_name'] ?? i['title'],
                ),
                source: MusicSource.tx,
                coverUrl: catalogImage(i['imgurl'] ?? i['logo'] ?? i['pic']),
                creator: creator,
                trackCount: catalogInt(i['song_count'] ?? i['songnum']),
                playCount: catalogInt(i['listennum'] ?? i['listen_num']),
              ),
              subtitle: creator,
            );
          })
          .where((i) => i.summary.id.isNotEmpty)
          .toList();
      final total = catalogInt(catalogMap(data['meta'])['sum']);
      return CatalogResult(
        items: items,
        total: total,
        hasMore: items.isNotEmpty && page * limit < total,
      );
    }
    final artist = category == SearchCategory.artists;
    // The signed mobile endpoint is the only QQ search that still answers;
    // its singer/album buckets are plain lists (sometimes wrapped in `list`).
    final data = await TxSdk.searchCatalog(keyword, artist ? 1 : 2, page, limit);
    final body = catalogMap(data['body'] ?? data);
    var rows = const <Map>[];
    for (final key in artist
        ? const ['singer', 'item_singer']
        : const ['album', 'item_album']) {
      rows = _rows(body[key]);
      if (rows.isNotEmpty) break;
    }
    final items = <CatalogItem>[];
    for (final row in rows) {
      final id = (row[artist ? 'singerMID' : 'albumMID'] ??
              row[artist ? 'singerMid' : 'albumMid'] ??
              row[artist ? 'singermid' : 'albummid'] ??
              row['mid'] ??
              '')
          .toString();
      final name = catalogText(
        row[artist ? 'singerName' : 'albumName'] ??
            row[artist ? 'singername' : 'albumname'] ??
            row['name'] ??
            row['title'],
      );
      if (id.isEmpty || name.isEmpty) continue;
      _names['${artist ? 'artist' : 'album'}:$id'] = name;
      final creator = catalogText(
        row['singerName'] ?? row['singername'] ?? row['singer'],
      );
      final count = catalogInt(
        row[artist ? 'songNum' : 'song_count'] ??
            row[artist ? 'songnum' : 'song_count'] ??
            row['songnum'],
      );
      items.add(
        CatalogItem(
          category: category,
          summary: PlaylistSummary(
            id: id,
            name: name,
            source: MusicSource.tx,
            coverUrl: catalogImage(
              row[artist ? 'singerPic' : 'albumPic'] ??
                  row[artist ? 'singerpic' : 'albumpic'] ??
                  row['pic'],
            ),
            creator: artist || creator.isEmpty ? null : creator,
            trackCount: count,
          ),
          subtitle: artist
              ? [
                  if (count > 0) '$count 首歌曲',
                  if (catalogInt(row['albumNum']) > 0)
                    '${catalogInt(row['albumNum'])} 张专辑',
                ].join(' · ')
              : [
                  creator,
                  catalogText(row['publicTime'] ?? row['publish_time']),
                ].where((part) => part.isNotEmpty).join(' · '),
        ),
      );
    }
    return CatalogResult(
      items: items,
      total: items.length,
      hasMore: items.length >= limit,
    );
  }

  /// QQ returns either a list or `{list: [...]}` depending on the endpoint.
  static List<Map> _rows(Object? node) {
    if (node is List) return catalogMaps(node);
    if (node is Map) return catalogMaps(node['list']);
    return const [];
  }

  static Future<PlaylistInfo> detail(
    String id, {
    required bool artist,
    int? maxTracks,
    SdkJsonLoader? loader,
  }) async {
    if (!artist) {
      final body = await catalogJson(
        'https://c.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg?albummid=${Uri.encodeComponent(id)}&format=json',
        loader: loader,
        headers: headers,
      );
      if (body['code'] != 0) throw Exception('QQ 专辑暂时不可用');
      final data = catalogMap(body['data']);
      final tracks = catalogMaps(
        data['list'],
      ).map(PlaylistSdk.parseTxSong).whereType<MusicInfo>().toList();
      return PlaylistInfo(
        id: id,
        name: catalogText(data['name']),
        source: MusicSource.tx,
        coverUrl: 'https://y.gtimg.cn/music/photo_new/T002R500x500M000$id.jpg',
        creator: catalogText(data['singername']),
        description: catalogText(data['desc']),
        trackCount: tracks.length,
        tracks: tracks.take(maxTracks ?? tracks.length).toList(),
      );
    }
    final name = _names['artist:$id'] ?? '';
    final tracks = <MusicInfo>[];
    final fallback = <MusicInfo>[];
    final target = maxTracks ?? 100;
    if (name.isNotEmpty) {
      for (var page = 1; tracks.length < target && page <= 6; page++) {
        final batch = await TxSdk.search(name, page: page, limit: 30);
        if (batch.isEmpty) break;
        for (final song in batch) {
          if (song.singer.contains(name)) {
            tracks.add(song);
          } else if (fallback.length < target) {
            fallback.add(song);
          }
          if (tracks.length >= target) break;
        }
        if (batch.length < 30) break;
      }
    }
    if (tracks.isEmpty) tracks.addAll(fallback);
    return PlaylistInfo(
      id: id,
      name: name.isEmpty ? '歌手' : name,
      source: MusicSource.tx,
      coverUrl: 'https://y.gtimg.cn/music/photo_new/T001R500x500M000$id.jpg',
      trackCount: tracks.length,
      tracks: tracks.take(target).toList(),
    );
  }
}

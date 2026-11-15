import 'package:dio/dio.dart';

import '../../models/catalog_result.dart';
import '../../models/enums.dart';
import '../../models/music_info.dart';
import '../../models/playlist_info.dart';
import '../../models/playlist_summary.dart';
import '../../models/search_category.dart';
import '../internal/sdk_http.dart';
import '../playlist_sdk.dart';
import 'catalog_helpers.dart';

class WyCatalog {
  static const headers = {
    'Referer': 'https://music.163.com/',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0 Safari/537.36',
    'Cookie': 'appver=2.0.2; os=pc',
  };

  /// The legacy `/api/search/get/web` endpoint answers `405` for artists now,
  /// so every category goes through the cloud search API.
  static Future<Map> _cloudSearch(
    String keyword,
    int type,
    int page,
    int limit,
  ) async {
    final response = await SdkHttp.fetch<dynamic>(
      'https://music.163.com/api/cloudsearch/pc',
      method: 'POST',
      headers: headers,
      form: {
        's': keyword,
        'type': '$type',
        'limit': '$limit',
        'offset': '${(page - 1) * limit}',
      },
      responseType: ResponseType.plain,
    );
    final body = response.body;
    final decoded = body is String ? catalogJsonDecode(body) : body;
    if (decoded is! Map) {
      throw const FormatException('网易云返回了无法识别的数据，请稍后重试');
    }
    return decoded;
  }

  static Future<CatalogResult> search(
    String keyword,
    SearchCategory category,
    int page,
    int limit, {
    SdkJsonLoader? loader,
  }) async {
    final (type, field, count) = switch (category) {
      SearchCategory.artists => (100, 'artists', 'artistCount'),
      SearchCategory.albums => (10, 'albums', 'albumCount'),
      SearchCategory.playlists => (1000, 'playlists', 'playlistCount'),
      _ => throw ArgumentError.value(category),
    };
    final body = await _cloudSearch(keyword, type, page, limit);
    if (catalogInt(body['code']) != 200) {
      throw Exception('网易云搜索暂时不可用');
    }
    final result = catalogMap(body['result']);
    final items = catalogMaps(result[field]).where((i) => i['id'] != null).map((
      i,
    ) {
      final artist = catalogMap(i['artist']);
      final creator = catalogText(catalogMap(i['creator'])['nickname']);
      final songs = catalogInt(i['musicSize'] ?? i['trackCount'] ?? i['size']);
      final name = catalogText(i['name']);
      return CatalogItem(
        category: category,
        summary: PlaylistSummary(
          id: '${i['id']}',
          name: name,
          source: MusicSource.wy,
          coverUrl: catalogImage(
            i['picUrl'] ?? i['coverImgUrl'] ?? i['blurPicUrl'],
          ),
          creator: category == SearchCategory.albums
              ? catalogText(artist['name'])
              : creator,
          description: catalogText(i['description']),
          trackCount: songs,
          playCount: category == SearchCategory.playlists
              ? catalogInt(i['playCount'])
              : null,
        ),
        subtitle: switch (category) {
          SearchCategory.artists =>
            '$songs 首歌曲 · ${catalogInt(i['albumSize'])} 张专辑',
          SearchCategory.albums => [
            catalogText(artist['name']),
            catalogDate(i['publishTime']),
          ].where((s) => s.isNotEmpty).join(' · '),
          _ => [creator, '$songs 首'].where((s) => s.isNotEmpty).join(' · '),
        },
      );
    }).toList();
    final total = catalogInt(result[count]);
    return CatalogResult(
      items: items,
      total: total,
      hasMore: items.isNotEmpty && page * limit < total,
    );
  }

  static Future<PlaylistInfo> detail(
    String id, {
    required bool artist,
    int? maxTracks,
    SdkJsonLoader? loader,
  }) async {
    // `/api/album/{id}` is behind a login gate now; `?ext=true` still answers
    // and keeps the legacy song shape that the shared parser understands.
    final url = artist
        ? 'https://music.163.com/api/artist/${Uri.encodeComponent(id)}'
        : 'https://music.163.com/api/album/${Uri.encodeComponent(id)}?ext=true';
    final body = await catalogJson(url, loader: loader, headers: headers);
    if (catalogInt(body['code']) != 200) {
      final code = catalogInt(body['code']);
      throw Exception(
        code == -462 || code == -460
            ? '网易云暂时限制了此内容的访问，请稍后重试或切换音乐平台'
            : '网易云详情暂时不可用',
      );
    }
    final info = catalogMap(body[artist ? 'artist' : 'album']);
    // The public artist endpoint supplies the curated hot-song list, not every
    // released song. Report that range honestly instead of advertising musicSize.
    final raw = catalogMaps(
      artist ? body['hotSongs'] : (body['songs'] ?? info['songs']),
    );
    final tracks = raw
        .map(PlaylistSdk.parseWySong)
        .whereType<MusicInfo>()
        .toList();
    return PlaylistInfo(
      id: id,
      name: catalogText(info['name']),
      source: MusicSource.wy,
      coverUrl: catalogImage(info['picUrl']),
      creator: artist
          ? '热门歌曲'
          : catalogText(catalogMap(info['artist'])['name']),
      description: catalogText(info[artist ? 'briefDesc' : 'description']),
      trackCount: tracks.length,
      tracks: tracks.take(maxTracks ?? tracks.length).toList(),
    );
  }
}

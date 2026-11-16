import 'dart:convert';

import '../models/enums.dart';
import '../models/playlist_category.dart';
import '../models/playlist_summary.dart';
import '../models/playlist_tag.dart';
import 'internal/format.dart';
import 'internal/sdk_http.dart';
import 'qs_sdk.dart';

class PlaylistCatalogSdk {
  const PlaylistCatalogSdk._();

  static const _desktopHeaders = {
    'Referer': 'https://y.qq.com/',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        'Chrome/120.0.0.0 Safari/537.36',
  };

  static const _miguHeaders = {
    'Referer': 'https://m.music.migu.cn/',
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 11.0.0) AppleWebKit/537.36 Mobile Safari/537.36',
  };

  static Future<List<PlaylistSummary>> featured(
    MusicSource source, {
    int page = 1,
    int limit = 20,
    String? categoryId,
    String? tagId,
    SdkJsonLoader? jsonLoader,
  }) async {
    if (source == MusicSource.all) {
      throw ArgumentError.value(source, 'source', '必须指定发现页平台');
    }
    final requestedPage = page < 1 ? 1 : page;
    final tag = playlistTagFor(source, tagId);
    final requestedCategory = _resolveCategory(source, categoryId);
    final load = jsonLoader ?? SdkHttp.getJson;
    final list = switch (source) {
      MusicSource.kw => await _featuredKw(
        requestedPage,
        limit,
        requestedCategory,
        tag,
        load,
      ),
      MusicSource.kg => await _featuredKg(
        requestedPage,
        limit,
        requestedCategory,
        tag,
        load,
      ),
      MusicSource.tx => await _featuredTx(
        requestedPage,
        limit,
        requestedCategory,
        tag,
        load,
      ),
      MusicSource.wy => await _featuredWy(
        requestedPage,
        limit,
        requestedCategory,
        tag,
        load,
      ),
      MusicSource.mg =>
        tag == null
            ? await _featuredMg(requestedPage, limit, requestedCategory, load)
            : await _featuredMgByTag(requestedPage, limit, tag, load),
      MusicSource.qs =>
        tag != null && tag.isKeyword
            ? await _featuredQsByKeyword(requestedPage, limit, tag.keyword!)
            : await _featuredQs(requestedPage, limit),
      MusicSource.all => const <PlaylistSummary>[],
    };
    final seen = <String>{};
    return [
      for (final item in list)
        if (item.id.isNotEmpty && item.name.isNotEmpty && seen.add(item.key))
          item,
    ].take(limit).toList(growable: false);
  }

  /// 排序参数只在当前可选集合内生效；集合外的取值（例如换了标签后仍留着旧
  /// 排序）一律回落到第一项，避免把无效参数发给服务端。
  static String _resolveCategory(MusicSource source, String? categoryId) {
    final options = playlistSortOptionsFor(source);
    if (options.isEmpty) return categoryId ?? '';
    return options.any((item) => item.id == categoryId)
        ? categoryId!
        : options.first.id;
  }

  static Future<List<PlaylistSummary>> _featuredKw(
    int page,
    int limit,
    String categoryId,
    PlaylistTag? tag,
    SdkJsonLoader load,
  ) async {
    // 有标签时端点换成 getTagPlayList（它忽略 order），无标签仍是推荐流。
    final url = tag == null
        ? 'http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList'
              '?loginUid=0&loginSid=0&appUid=76039576&pn=$page&rn=$limit'
              '&order=$categoryId'
        : 'https://wapi.kuwo.cn/api/pc/classify/playlist/getTagPlayList'
              '?loginUid=0&loginSid=0&appUid=76039576&pn=$page&rn=$limit'
              '&id=${tag.id}';
    final body = await load(url);
    final data = body is Map ? body['data'] : null;
    final items = data is Map ? data['data'] : null;
    if (body is! Map || body['code'] != 200 || items is! List) {
      throw Exception('酷我精选歌单加载失败');
    }
    return [
      for (final item in items.whereType<Map>())
        PlaylistSummary(
          id: item['id']?.toString() ?? '',
          name: item['name']?.toString() ?? '',
          source: MusicSource.kw,
          coverUrl: _image(item['img']),
          creator: _text(item['uname']),
          description: _text(item['desc']),
          trackCount: _int(item['total']),
          playCount: _int(item['listencnt']),
        ),
    ];
  }

  static Future<List<PlaylistSummary>> _featuredKg(
    int page,
    int limit,
    String categoryId,
    PlaylistTag? tag,
    SdkJsonLoader load,
  ) async {
    // t 是排序、c 是分类，两者可叠加。
    final body = await load(
      'http://www2.kugou.kugou.com/yueku/v9/special/getSpecial'
      '?is_ajax=1&cdn=cdn&t=$categoryId&c=${tag?.id ?? ''}&p=$page',
      headers: _desktopHeaders,
    );
    final items = body is Map ? body['special_db'] : null;
    if (body is! Map || body['status'] != 1 || items is! List) {
      throw Exception('酷狗精选歌单加载失败');
    }
    return [
      for (final item in items.whereType<Map>())
        PlaylistSummary(
          id: item['specialid']?.toString() ?? '',
          name: item['specialname']?.toString() ?? '',
          source: MusicSource.kg,
          coverUrl: _image(item['img'] ?? item['imgurl']),
          creator: _text(item['nickname']),
          description: _text(item['intro']),
          trackCount: _int(item['songcount']),
          playCount: _int(item['playcount'] ?? item['play_count']),
        ),
    ].take(limit).toList(growable: false);
  }

  static Future<List<PlaylistSummary>> _featuredTx(
    int page,
    int limit,
    String categoryId,
    PlaylistTag? tag,
    SdkJsonLoader load,
  ) async {
    // 标签轴与排序轴共用同一个 titleid/category_id：选中标签时它被标签 id
    // 占用，因此只有无标签的「推荐」才走榜单广场。
    final tagId = tag == null ? null : int.tryParse(tag.id);
    final category = tagId ?? int.tryParse(categoryId) ?? -1;
    final recommend = tag == null && category == -1;
    final request = {
      'comm': {'cv': 1602, 'ct': 20},
      'playlist': recommend
          ? {
              'module': 'music.playlist.PlaylistSquare',
              'method': 'GetRecommendWhole',
              'param': {
                'IsReqFeed': true,
                'FeedReq': {'From': (page - 1) * limit, 'Size': limit},
              },
            }
          : {
              'module': 'playlist.PlayListCategoryServer',
              'method': 'get_category_content',
              'param': {
                'titleid': category,
                'caller': '0',
                'category_id': category,
                'size': limit,
                'page': page - 1,
                'use_page': 1,
              },
            },
    };
    final uri = Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg', {
      'loginUin': '0',
      'hostUin': '0',
      'format': 'json',
      'inCharset': 'utf-8',
      'outCharset': 'utf-8',
      'notice': '0',
      'platform': 'wk_v15.json',
      'needNewCode': '0',
      'data': jsonEncode(request),
    });
    final body = await load(uri.toString(), headers: _desktopHeaders);
    final playlist = body is Map ? body['playlist'] : null;
    final data = playlist is Map ? playlist['data'] : null;
    final content = data is Map
        ? data[recommend ? 'FeedRsp' : 'content']
        : null;
    final items = content is Map
        ? content[recommend ? 'List' : 'v_item'] ?? const []
        : null;
    if (body is! Map ||
        body['code'] != 0 ||
        playlist is! Map ||
        playlist['code'] != 0 ||
        items is! List) {
      throw Exception('QQ 精选歌单加载失败');
    }
    final out = <PlaylistSummary>[];
    for (final item in items.whereType<Map>()) {
      final entry = recommend ? item['Playlist'] : item;
      final basic = entry is Map ? entry['basic'] : null;
      if (basic is! Map) continue;
      final cover = basic['cover'] as Map?;
      out.add(
        PlaylistSummary(
          id: basic['tid']?.toString() ?? '',
          name: decodeName(basic['title']),
          source: MusicSource.tx,
          coverUrl: _image(
            _text(cover?['medium_url']) ?? cover?['default_url'],
          ),
          creator: _text(decodeName((basic['creator'] as Map?)?['nick'])),
          description: _text(
            decodeName(basic['desc']).replaceAll(RegExp(r'<br\s*/?>'), '\n'),
          ),
          trackCount: _int(basic['song_cnt']),
          playCount: _int(basic['play_cnt']),
        ),
      );
    }
    return out;
  }

  static Future<List<PlaylistSummary>> _featuredWy(
    int page,
    int limit,
    String categoryId,
    PlaylistTag? tag,
    SdkJsonLoader load,
  ) async {
    // cat 收中文标签名，order 只认 hot（new 返回空列表）。
    final uri = Uri.https('music.163.com', '/api/playlist/list', {
      'cat': tag?.id ?? '全部',
      'order': tag == null ? categoryId : 'hot',
      'limit': '$limit',
      'offset': '${(page - 1) * limit}',
    });
    final body = await load(
      uri.toString(),
      headers: const {
        'Referer': 'https://music.163.com/',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36',
      },
    );
    final items = body is Map ? body['playlists'] : null;
    if (body is! Map || body['code'] != 200 || items is! List) {
      throw Exception('网易云精品歌单加载失败');
    }
    return [
      for (final item in items.whereType<Map>())
        PlaylistSummary(
          id: item['id']?.toString() ?? '',
          name: item['name']?.toString() ?? '',
          source: MusicSource.wy,
          coverUrl: _image(item['coverImgUrl']),
          creator: _text((item['creator'] as Map?)?['nickname']),
          description: _text(item['description']),
          trackCount: _int(item['trackCount']),
          playCount: _int(item['playCount']),
        ),
    ];
  }

  static Future<List<PlaylistSummary>> _featuredQs(int page, int limit) {
    // The feed is a recommendation stream, so the SDK keeps a de-duplicated
    // pool and hands the grid consecutive slices of it.
    return QsSdk.featuredPlaylistsPaged(page: page, limit: limit);
  }

  static Future<List<PlaylistSummary>> _featuredMg(
    int page,
    int limit,
    String categoryId,
    SdkJsonLoader load,
  ) async {
    final body = await load(
      'https://app.c.nf.migu.cn/pc/bmw/page-data/'
      'playlist-square-recommend/v1.0?templateVersion=2&pageNo=$page',
      headers: _miguHeaders,
    );
    final data = body is Map ? body['data'] : null;
    if (body is! Map || body['code'] != '000000' || data is! Map) {
      throw Exception('咪咕精选歌单加载失败');
    }
    final out = <PlaylistSummary>[];
    void visit(Object? node) {
      if (out.length >= limit) return;
      if (node is List) {
        for (final child in node) {
          visit(child);
          if (out.length >= limit) break;
        }
        return;
      }
      if (node is! Map) return;
      if (node['resType']?.toString() == '2021') {
        out.add(
          PlaylistSummary(
            id: node['resId']?.toString() ?? '',
            name: node['txt']?.toString() ?? '',
            source: MusicSource.mg,
            coverUrl: _image(node['img']),
            description: _text(node['txt2']),
          ),
        );
      }
      visit(node['contents']);
    }

    visit(data['contents']);
    return out;
  }

  /// 标签歌单走另一套模板：`contentItemList[].itemList[]` 里每个宫格项的
  /// id 藏在 `actionUrl` 的查询串中。
  static Future<List<PlaylistSummary>> _featuredMgByTag(
    int page,
    int limit,
    PlaylistTag tag,
    SdkJsonLoader load,
  ) async {
    final body = await load(
      'https://app.c.nf.migu.cn/pc/v1.0/template/'
      'musiclistplaza-listbytag/release?pageNumber=$page'
      '&templateVersion=2&tagId=${tag.id}',
      headers: _miguHeaders,
    );
    final data = body is Map ? body['data'] : null;
    final blocks = data is Map ? data['contentItemList'] : null;
    if (body is! Map || body['code'] != '000000' || blocks is! List) {
      throw Exception('咪咕分类歌单加载失败');
    }
    final out = <PlaylistSummary>[];
    for (final block in blocks.whereType<Map>()) {
      final items = block['itemList'];
      if (items is! List) continue;
      for (final item in items.whereType<Map>()) {
        if (out.length >= limit) break;
        final id = _queryValue(_text(item['actionUrl']), 'id');
        final name = _text(item['title']);
        if (id == null || name == null) continue;
        final bars = item['barList'];
        out.add(
          PlaylistSummary(
            id: id,
            name: name,
            source: MusicSource.mg,
            coverUrl: _image(item['imageUrl']),
            playCount: _playCount(
              bars is List && bars.isNotEmpty && bars.first is Map
                  ? (bars.first as Map)['title']
                  : null,
            ),
          ),
        );
      }
      if (out.length >= limit) break;
    }
    return out;
  }

  /// 汽水没有分类端点，标签退化为歌单关键词搜索。
  static Future<List<PlaylistSummary>> _featuredQsByKeyword(
    int page,
    int limit,
    String keyword,
  ) async {
    final result = await QsSdk.searchPlaylistPage(
      keyword,
      cursor: (page - 1) * limit,
      count: limit,
    );
    return result.items;
  }

  static String? _queryValue(String? url, String key) {
    if (url == null) return null;
    final query = Uri.tryParse(url)?.queryParameters;
    final value = query?[key]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// 咪咕把热度写成「93.2万」这样的字符串。
  static int? _playCount(Object? raw) {
    final text = _text(raw);
    if (text == null) return null;
    final match = RegExp(r'([\d.]+)\s*(万|亿)?').firstMatch(text);
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!);
    if (value == null) return null;
    final unit = match.group(2);
    final scale = switch (unit) {
      '万' => 10000,
      '亿' => 100000000,
      _ => 1,
    };
    return (value * scale).round();
  }

  static String? _text(Object? raw) {
    final value = raw?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  static int? _int(Object? raw) => raw is num
      ? raw.toInt()
      : int.tryParse(raw?.toString().replaceAll(RegExp(r'[^0-9]'), '') ?? '');

  static String? _image(Object? raw) {
    var value = _text(raw);
    if (value == null) return null;
    value = value.replaceAll('{size}', '480');
    final candidate = value.startsWith('//') ? 'http:$value' : value;
    final host = Uri.tryParse(candidate)?.host.toLowerCase() ?? '';
    final keepHttp = host == 'kwcdn.kuwo.cn' || host.endsWith('.kwcdn.kuwo.cn');
    if (value.startsWith('//')) {
      value = '${keepHttp ? 'http' : 'https'}:$value';
    } else if (value.startsWith('http://') && !keepHttp) {
      value = value.replaceFirst('http://', 'https://');
    }
    return value;
  }
}

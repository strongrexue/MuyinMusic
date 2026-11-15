import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/catalog_result.dart';
import '../models/enums.dart';
import '../models/leaderboard_info.dart';
import '../models/lyric_info.dart';
import '../models/music_info.dart';
import '../models/playlist_info.dart';
import '../models/playlist_summary.dart';
import '../models/search_category.dart';
import '../services/app_logger.dart';
import 'internal/builders.dart';
import 'internal/crypto_util.dart';
import 'internal/format.dart';
import 'internal/sdk_http.dart';

/// Thrown when the gateway answers 200 with an empty body. It is a normal
/// answer for a throttled read, so callers retry instead of failing.
class QsEmptyResponseException implements Exception {
  const QsEmptyResponseException();

  @override
  String toString() => '汽水音乐暂时没有返回数据，请稍后重试';
}

/// Soda music (汽水音乐) is read through ByteDance's "luna" API using the
/// Windows client's public parameters.
///
/// Catalogue and lyrics only: playback is resolved by imported JS music
/// sources, so nothing here signs play requests any more.
class QsSdk {
  const QsSdk._();

  static const String _base = 'https://api.qishui.com';
  static const int _pageSize = 20;

  static const Map<String, String> _commonParams = {
    'aid': '386088',
    'app_name': 'luna_pc',
    'region': 'cn',
    'geo_region': 'cn',
    'os_region': 'cn',
    'version_name': '3.7.0',
    'version_code': '3.7.0',
    'channel': 'official',
    'build_mode': 'master',
    'ac': 'wifi',
    'tz_name': 'Asia/Shanghai',
    'device_platform': 'windows',
    'device_type': 'Windows',
    'os_version': 'Windows 10 Pro',
  };

  static const Map<String, String> _headers = {
    'User-Agent': 'LunaPC/3.7.0(official)',
    'Accept': 'application/json',
    'x-luna-is-local-user': '0',
  };

  // ------------------------------------------------------- device + throttle

  /// The catalogue gateway throttles clients it does not recognise, so the
  /// first read registers a throw-away desktop device and every later read
  /// carries its identity.
  static Future<Map<String, String>>? _device;
  static Future<void> _requestTail = Future<void>.value();
  static DateTime? _lastRead;

  /// Reads are queued behind the previous one and spaced 600 ms apart: the
  /// gateway answers an empty 200 to concurrent calls, and an empty answer is
  /// retried because it is throttling noise rather than a real result.
  static Future<Map> _get(
    String path, {
    Map<String, String> query = const {},
  }) {
    final result = _requestTail.then((_) async {
      final device = await (_device ??= _registerDevice());
      final elapsed = _lastRead == null
          ? 600
          : DateTime.now().difference(_lastRead!).inMilliseconds;
      if (elapsed < 600) {
        await Future<void>.delayed(Duration(milliseconds: 600 - elapsed));
      }
      try {
        for (var attempt = 0; ; attempt++) {
          try {
            return await _request(path, query: {...device, ...query});
          } on QsEmptyResponseException {
            if (attempt >= 2) rethrow;
            await Future<void>.delayed(
              Duration(milliseconds: 600 * (attempt + 1)),
            );
          }
        }
      } finally {
        _lastRead = DateTime.now();
      }
    });
    _requestTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// The homepage and playlist replies are POSTs; they share the read queue so
  /// they cannot trip the same throttle.
  static Future<Map> _post(
    String path, {
    Map<String, Object?>? body = const {},
  }) {
    final result = _requestTail.then(
      (_) => _request(path, body: body ?? const {}),
    );
    _requestTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  static Future<Map> _request(
    String path, {
    Map<String, String> query = const {},
    Map<String, Object?>? body,
    bool withCommonParams = true,
  }) async {
    final payload = body == null ? null : jsonEncode(body);
    // Keep empty values as `key=`: the search gateway rejects a bare key.
    final params = withCommonParams ? {..._commonParams, ...query} : query;
    final encoded = params.entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}='
              '${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&');
    final response = await SdkHttp.fetch<dynamic>(
      '$_base$path?$encoded',
      method: payload == null ? 'GET' : 'POST',
      headers: {
        ..._headers,
        if (payload != null) ...{
          'Content-Type': 'application/json; charset=utf-8',
          'x-ss-stub': CryptoUtil.md5Hex(payload).toUpperCase(),
        },
      },
      body: payload,
      responseType: ResponseType.plain,
    );
    final raw = response.body;
    if (raw == null || (raw is String && raw.trim().isEmpty)) {
      throw const QsEmptyResponseException();
    }
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! Map) throw Exception('汽水音乐返回了无效数据');
    final code = _intOrNull(decoded['status_code']) ?? 0;
    if (code != 0) throw Exception('汽水音乐请求失败（$code）');
    return decoded;
  }

  static Future<Map<String, String>> _registerDevice() async {
    try {
      // Registration answers `device_id: 0` when the PC identity parameters are
      // also present, so this one call goes out with only its own query.
      final data = await _request(
        '/service/2/desktop/device_register/',
        withCommonParams: false,
        query: {
          'device_platform': 'PC',
          'os': 'Windows',
          'app_version': '3.7.0',
        },
        body: {
          'header': {
            'device_id': '',
            'install_id': '',
            'os': 'Windows',
            'device_platform': 'PC',
            'sdk_version': '1.0',
            'sdk_version_code': 1,
            'aid': 386088,
            'mc': '00:00:00:00:00:00',
            'channel': 'official',
            'package': 'com.soda.music',
            'language': 'zh-CN',
            'app_version': '3.7.0',
            'os_version': 'Windows 10: 10.0',
            'device_model': 'no detected',
            'time_zone': 'Asia/Shanghai',
            'tz_name': 'Asia/Shanghai',
            'tz_offset': 0,
            'resolution': 'no detected',
            'app_region': 'cn',
            'app_language': 'zh-CN',
            'display_name': '汽水音乐',
            'pc_uuid': _uuid(),
            'pc_serial': '',
          },
          'gen_time': DateTime.now().millisecondsSinceEpoch,
          'magic_tag': 'ss_app_log',
        },
      );
      final deviceId = _textOrNull(data['device_id_str']);
      final installId = _textOrNull(data['install_id_str']);
      // A rejected registration answers with the literal id "0".
      if (deviceId == null || installId == null || deviceId == '0') {
        throw Exception('汽水音乐初始化失败');
      }
      return {'device_id': deviceId, 'iid': installId, 'fp': deviceId};
    } catch (_) {
      // A failed registration must not poison the cache: the next read retries.
      _device = null;
      rethrow;
    }
  }

  static String _uuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  // ---------------------------------------------------------------- search

  /// The same page is asked for by the platform tab and the aggregate tab, so
  /// replies are shared for a minute.
  static final Map<String, ({DateTime expires, Future<Map> value})>
  _searchCache = {};

  static Future<Map> _searchData(String keyword, String type, int page) {
    final key = '$type:$page:$keyword';
    final now = DateTime.now();
    final cached = _searchCache[key];
    if (cached != null && cached.expires.isAfter(now)) return cached.value;
    if (_searchCache.length >= 24) _searchCache.remove(_searchCache.keys.first);
    final result = _get(
      '/luna/search/$type',
      query: {
        'q': keyword,
        'cursor': '${((page < 1 ? 1 : page) - 1) * _pageSize}',
        'search_id': _uuid(),
        // `track` is the documented value; `search` answers an empty 200 once
        // the request carries a registered device identity.
        'search_method': 'track',
      },
    );
    _searchCache[key] = (
      expires: now.add(const Duration(minutes: 1)),
      value: result,
    );
    unawaited(
      result.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_searchCache[key]?.value, result)) {
            _searchCache.remove(key);
          }
        },
      ),
    );
    return result;
  }

  /// The gateway answers one `result_groups` entry per entity type; the group
  /// id is the plural of the requested type.
  static ({List<Map> items, bool hasMore}) _searchGroup(Object? body, String type) {
    final groups = body is Map ? body['result_groups'] : null;
    if (groups is! List) return (items: const <Map>[], hasMore: false);
    for (final group in groups) {
      if (group is! Map || group['id']?.toString() != '${type}s') continue;
      final rows = group['data'] ?? group['items'];
      if (rows is! List) continue;
      return (
        items: rows.whereType<Map>().toList(growable: false),
        hasMore: group['has_more'] == true,
      );
    }
    return (items: const <Map>[], hasMore: false);
  }

  static Future<List<MusicInfo>> search(
    String keyword, {
    int page = 1,
    int limit = _pageSize,
  }) async {
    final word = keyword.trim();
    if (word.isEmpty) return const <MusicInfo>[];
    final body = await _searchData(word, 'track', page);
    final tracks = <MusicInfo>[];
    for (final row in _searchGroup(body, 'track').items) {
      final track = _entityTrack(row);
      final info = track == null ? null : _toMusicInfo(track);
      if (info != null) tracks.add(info);
    }
    return dedupeMusic(tracks)
        .take(limit.clamp(1, _pageSize))
        .toList(growable: false);
  }

  static Future<List<String>> tip(String keyword) async {
    final word = keyword.trim();
    if (word.isEmpty) return const <String>[];
    final body = await _get(
      '/luna/pc/sug',
      query: {'q': word, 'sug_scene': 'search_sug', 'sug_search_id': ''},
    );
    final sugs = body['sugs'];
    if (sugs is! List) return const <String>[];
    return {
      for (final item in sugs.whereType<Map>())
        if (_textOrNull(item['suggestion']) case final String text) text,
    }.toList(growable: false);
  }

  static Future<CatalogResult> searchArtists(
    String keyword,
    int page,
    int limit,
  ) async {
    final body = await _searchData(keyword.trim(), 'artist', page);
    final group = _searchGroup(body, 'artist');
    final items = <CatalogItem>[];
    final seen = <String>{};
    for (final row in group.items) {
      final artist = _entityOf(row, 'artist');
      final id = artist['id']?.toString() ?? '';
      final name = decodeName(artist['name']);
      if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
      final avatar = artist['url_avatar'];
      final count = _intOrNull(artist['count_tracks']);
      items.add(
        CatalogItem(
          category: SearchCategory.artists,
          summary: PlaylistSummary(
            id: id,
            name: name,
            source: MusicSource.qs,
            coverUrl: avatar is Map ? _imageUrl(avatar.cast<String, Object?>()) : null,
            trackCount: count,
          ),
          subtitle: [if (count != null) '$count 首歌曲'].join(' · '),
        ),
      );
    }
    return CatalogResult(
      items: items.take(limit.clamp(1, _pageSize)).toList(growable: false),
      total: items.length,
      hasMore: group.hasMore,
    );
  }

  static Future<CatalogResult> searchAlbums(
    String keyword,
    int page,
    int limit,
  ) async {
    final body = await _searchData(keyword.trim(), 'album', page);
    final group = _searchGroup(body, 'album');
    final items = <CatalogItem>[];
    final seen = <String>{};
    for (final row in group.items) {
      final album = _entityOf(row, 'album');
      final id = album['id']?.toString() ?? '';
      final name = decodeName(album['name']);
      if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
      final cover = album['url_cover'];
      final creator = _singers(album);
      final count = _intOrNull(album['count_tracks']);
      items.add(
        CatalogItem(
          category: SearchCategory.albums,
          summary: PlaylistSummary(
            id: id,
            name: name,
            source: MusicSource.qs,
            coverUrl: cover is Map ? _imageUrl(cover.cast<String, Object?>()) : null,
            creator: creator.isEmpty ? null : creator,
            trackCount: count,
          ),
          subtitle: [
            creator,
            if (count != null) '$count 首',
          ].where((part) => part.isNotEmpty).join(' · '),
        ),
      );
    }
    return CatalogResult(
      items: items.take(limit.clamp(1, _pageSize)).toList(growable: false),
      total: items.length,
      hasMore: group.hasMore,
    );
  }

  static Map _entityOf(Map row, String key) {
    final entity = row['entity'];
    final wrapped = entity is Map ? entity : row;
    final value = wrapped[key];
    return value is Map ? value : const {};
  }

  /// Singer detail: the platform exposes the artist endpoint and a cursor over
  /// its tracks, so the list is built from those instead of a name search.
  static Future<PlaylistInfo> artistDetail(String id, {int? maxTracks}) async {
    final limit = maxTracks == null || maxTracks <= 0
        ? 10000
        : maxTracks.clamp(1, 10000);
    final data = await _get('/luna/pc/artists/$id');
    final info = data['artist_info'];
    if (info is! Map) throw Exception('汽水音乐歌手详情加载失败');
    final expected = _intOrNull(info['count_tracks']);
    final tracks = <MusicInfo>[];
    final seen = <String>{};
    final cursors = <String>{};
    var cursor = '0';
    var exhausted = false;
    while (tracks.length < limit && cursors.add(cursor)) {
      final page = await _get(
        '/luna/pc/artists/$id/tracks',
        query: {
          'cursor': cursor,
          'count': '${(limit - tracks.length).clamp(1, 100)}',
        },
      );
      final rows = page['tracks'];
      if (rows is! List) throw Exception('汽水音乐歌手歌曲加载失败');
      final batch = rows.whereType<Map>().toList(growable: false);
      for (final raw in batch) {
        final music = _toMusicInfo(raw);
        if (music != null && seen.add(music.id)) tracks.add(music);
      }
      if (batch.isEmpty ||
          (expected != null && tracks.length >= expected) ||
          page['has_more'] == false) {
        exhausted = true;
        break;
      }
      if (tracks.length >= limit) break;
      final next = _textOrNull(page['next_cursor']);
      if (next == null || cursors.contains(next)) break;
      cursor = next;
    }
    final profile = info['artist_profile'];
    final avatar = info['url_avatar'];
    return PlaylistInfo(
      id: id,
      name: decodeName(info['name']).isEmpty
          ? '汽水音乐'
          : decodeName(info['name']),
      source: MusicSource.qs,
      tracks: tracks.take(limit).toList(growable: false),
      trackCount: exhausted ? tracks.length : expected,
      coverUrl: avatar is Map ? _imageUrl(avatar.cast<String, Object?>()) : null,
      creator: '热门歌曲',
      description: profile is Map
          ? _textOrNull(
              decodeName(profile['intro'] ?? profile['description']),
            )
          : null,
    );
  }

  static Future<PlaylistInfo> albumDetail(String id, {int? maxTracks}) async {
    final data = await _get('/luna/pc/albums/$id');
    final info = data['album_info'];
    if (info is! Map) throw Exception('汽水音乐专辑详情加载失败');
    final rows = data['tracks'];
    if (rows is! List) throw Exception('汽水音乐专辑歌曲加载失败');
    final tracks = <MusicInfo>[];
    for (final raw in rows.whereType<Map>()) {
      final music = _toMusicInfo(raw);
      if (music != null) tracks.add(music);
    }
    final deduped = dedupeMusic(tracks);
    final sliced = maxTracks == null || maxTracks <= 0
        ? deduped
        : deduped.take(maxTracks).toList(growable: false);
    final cover = info['url_cover'];
    return PlaylistInfo(
      id: id,
      name: decodeName(info['name']).isEmpty
          ? '汽水音乐'
          : decodeName(info['name']),
      source: MusicSource.qs,
      tracks: sliced,
      trackCount: sliced.length,
      coverUrl: cover is Map ? _imageUrl(cover.cast<String, Object?>()) : null,
      creator: _singers(info),
      description: _textOrNull(decodeName(info['desc'])),
    );
  }

  static Map? _entityTrack(Object? entry) {
    if (entry is! Map) return null;
    final entity = entry['entity'];
    final wrapped = entity is Map ? entity : entry;
    final wrapper = wrapped['track_wrapper'];
    if (wrapper is Map && wrapper['track'] is Map) {
      return wrapper['track'] as Map;
    }
    if (wrapped['track'] is Map) return wrapped['track'] as Map;
    if (wrapped['id'] != null) return wrapped;
    return null;
  }

  static MusicInfo? _toMusicInfo(Map track) {
    final id = track['id']?.toString();
    if (id == null || id.isEmpty) return null;
    final name = decodeName(track['name'] ?? track['title']);
    final singers = _singers(track);
    final album = track['album'];
    final albumName = album is Map ? decodeName(album['name']) : '';
    final picUrl = _coverUrl(track);
    final qualitys = _qualitys(track);
    final seconds = _durationSeconds(track['duration']);

    return buildMusicInfo(
      name: name.isEmpty ? '未知歌曲' : name,
      singer: singers.isEmpty ? '未知歌手' : singers,
      source: MusicSource.qs,
      songId: id,
      albumName: albumName,
      interval: seconds > 0 ? formatPlayTime(seconds) : '',
      picUrl: picUrl,
      qualitys: qualitys,
    );
  }

  static String _singers(Map track) {
    final artists = track['artists'];
    if (artists is List && artists.isNotEmpty) {
      final names = <String>[];
      for (final artist in artists) {
        if (artist is! Map) continue;
        final user = artist['user_info'];
        final label = user is Map
            ? (user['name'] ?? user['nickname'])
            : artist['name'];
        final text = decodeName(label).trim();
        if (text.isNotEmpty) names.add(text);
      }
      if (names.isNotEmpty) return names.join('、');
    }
    final author = track['author_info'];
    if (author is Map) {
      final text = decodeName(author['name'] ?? author['nickname']).trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static String? _coverUrl(Map track) {
    final cover = track['cover_url'] ?? track['url_cover'];
    if (cover is String && cover.isNotEmpty) return cover;
    if (cover is Map) {
      final built = _imageUrl(cover);
      if (built != null) return built;
    }
    final album = track['album'];
    if (album is Map) {
      final value = album['url_cover'] ?? album['cover_url'];
      if (value is String && value.isNotEmpty) return value;
      if (value is Map) return _imageUrl(value);
    }
    return null;
  }

  /// Builds a downloadable cover from `{urls, uri, template_prefix}`. The CDN
  /// only answers 200 when the resize template is appended.
  static String? _imageUrl(Map cover) {
    final uri = cover['uri']?.toString() ?? '';
    if (uri.isEmpty) return null;
    final urls = cover['urls'];
    if (urls is! List || urls.isEmpty) return null;
    final base = urls.first.toString();
    final template = cover['template_prefix']?.toString() ?? '';
    if (template.isEmpty) return '$base$uri';
    return '$base$uri~$template-resize:500:500.jpg';
  }

  static double _durationSeconds(Object? duration) {
    final value = num.tryParse(duration?.toString() ?? '')?.toDouble() ?? 0;
    if (!value.isFinite || value <= 0) return 0;
    return value > 10000 ? value / 1000 : value;
  }

  /// Soda reports its own tiers, but imported JS sources decide what is
  /// actually playable, so the catalogue declares none: a stale tier list would
  /// make the quality picker offer options no source can serve.
  static List<QualityOption> _qualitys(Map track) => const <QualityOption>[];

  // ---------------------------------------------------------------- lyric

  static Future<LyricInfo> getLyric(MusicInfo info) async {
    final trackId = info.meta.songId.toString();
    if (trackId.isEmpty) throw Exception('汽水音乐缺少歌曲 ID');
    final Map detail;
    try {
      detail = await _seoTrack(trackId);
    } catch (error) {
      AppLogger.write('qs', 'lyric lookup failed id=$trackId: $error');
      return const LyricInfo(lyric: '[00:00.000]暂无歌词，请欣赏');
    }
    final lyric = detail['lyric'];
    if (lyric is! Map) throw Exception('汽水音乐暂无歌词');
    final content = _extractLyricText(lyric['content']);
    if (content.isEmpty) throw Exception('汽水音乐暂无歌词');
    final translated = _extractTranslation(lyric);
    // The player reads plain LRC from [lyric] and per-word timings from
    // [lxlyric], both keyed by `[mm:ss.xxx]` line stamps.
    final karaoke = parseKrcToKaraoke(content);
    if (karaoke == null) {
      final plain = content.trimLeft().startsWith('[')
          ? content
          : '[00:00.000]暂无歌词，请欣赏';
      return LyricInfo(lyric: plain, tlyric: translated);
    }
    return LyricInfo(
      lyric: karaoke.plain,
      lxlyric: karaoke.worded,
      tlyric: translated,
    );
  }

  /// The h5 SEO endpoint returns the same `lyric` block the player needs
  /// without any device identity, so it is the cheaper lyric source.
  static const String _seoBase = 'https://beta-luna.douyin.com';

  static Future<Map> _seoTrack(String trackId) async {
    final uri = Uri.parse('$_seoBase/luna/h5/seo_track').replace(
      queryParameters: {
        'track_id': trackId,
        'device_platform': 'web',
        'aid': '386088',
      },
    );
    final body = await SdkHttp.getJson(
      uri.toString(),
      headers: {'User-Agent': 'Mozilla/5.0'},
    );
    if (body is Map) return body;
    throw Exception('汽水音乐暂无歌词');
  }

  static String _extractLyricText(Object? value) {
    if (value is String) return value;
    if (value is Map) {
      final inner = value['content'] ?? value['lyric'];
      if (inner is String) return inner;
      if (inner is Map) return _extractLyricText(inner);
    }
    return '';
  }

  static String? _extractTranslation(Map lyric) {
    for (final key in ['translations', 'lang_translations']) {
      final group = _decodeMaybeJson(lyric[key]);
      if (group is! Map) continue;
      for (final member in const ['cn', 'zh', 'translation']) {
        final text = _extractLyricText(group[member]);
        if (text.isNotEmpty && !text.trimLeft().startsWith('[')) {
          return parseKrcToQrc(text);
        }
        if (text.trimLeft().startsWith('[')) return text;
      }
      final lang = lyric['lang']?.toString() ?? '';
      for (final entry in group.entries) {
        final code = entry.key.toString().toUpperCase();
        if (code.startsWith('ZH') && code != lang.toUpperCase()) {
          final text = _extractLyricText(entry.value);
          if (text.isNotEmpty) {
            return text.trimLeft().startsWith('[') ? text : parseKrcToQrc(text);
          }
        }
      }
    }
    final direct = _extractLyricText(lyric['translation']);
    if (direct.isEmpty) return null;
    return direct.trimLeft().startsWith('[') ? direct : parseKrcToQrc(direct);
  }

  static Object? _decodeMaybeJson(Object? value) {
    if (value is! String) return value;
    final text = value.trim();
    if (!text.startsWith('{') && !text.startsWith('[')) return value;
    try {
      return jsonDecode(text);
    } catch (_) {
      return value;
    }
  }

  static final RegExp _krcLine = RegExp(r'^\[(\d+),(\d+)\](.*)$');
  static final RegExp _krcWord = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');

  /// KRC keeps per-line `[start,duration]` and per-word `<offset,duration,0>`
  /// marks; the player wants `[mm:ss.xxx]` line stamps, plain text for [lyric]
  /// and `<offset,duration>` word tags for [lxlyric].
  static ({String plain, String worded})? parseKrcToKaraoke(String krc) {
    final plainLines = <String>[];
    final wordedLines = <String>[];
    for (final rawLine in krc.split('\n')) {
      final line = rawLine.replaceAll('\r', '');
      final match = _krcLine.firstMatch(line);
      if (match == null) continue;
      final start = int.parse(match.group(1)!);
      final body = match.group(3)!;
      final words = <String>[];
      final plain = StringBuffer();
      for (final word in _krcWord.allMatches(body)) {
        final offset = int.parse(word.group(1)!);
        final wordDuration = int.parse(word.group(2)!);
        final text = word.group(3)!;
        if (text.isEmpty) continue;
        words.add('<$offset,$wordDuration>$text');
        plain.write(text);
      }
      final lineText = plain.toString();
      if (lineText.trim().isEmpty) continue;
      final stamp = _lineStamp(start);
      plainLines.add('$stamp$lineText');
      wordedLines.add('$stamp${words.join()}');
    }
    if (plainLines.isEmpty) return null;
    return (plain: plainLines.join('\n'), worded: wordedLines.join('\n'));
  }

  static String _lineStamp(int ms) {
    final minutes = ms ~/ 60000;
    final seconds = (ms % 60000) ~/ 1000;
    final millis = ms % 1000;
    return '[${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}]';
  }

  /// The older QRC-only escape hatch kept for reference by downstream callers.
  static String parseKrcToQrc(String krc) {
    final lines = <String>[];
    for (final rawLine in krc.split('\n')) {
      final line = rawLine.replaceAll('\r', '');
      final match = _krcLine.firstMatch(line);
      if (match == null) continue;
      final start = int.parse(match.group(1)!);
      final duration = int.parse(match.group(2)!);
      final words = <String>[];
      for (final word in _krcWord.allMatches(match.group(3)!)) {
        final offset = int.parse(word.group(1)!);
        final wordDuration = int.parse(word.group(2)!);
        final text = word
            .group(3)!
            .replaceAll('(', '（')
            .replaceAll(')', '）');
        if (text.isEmpty) continue;
        words.add('$text(${start + offset},$wordDuration)');
      }
      if (words.isEmpty) continue;
      lines.add('[$start,$duration]${words.join()}');
    }
    if (lines.isEmpty) return '[00:00.000]暂无歌词，请欣赏';
    return lines.join('\n');
  }

  // ----------------------------------------------------------------- hub

  static Future<String?> getPicUrl(MusicInfo info) async {
    final cached = info.meta.picUrl;
    return cached == null || cached.isEmpty ? null : cached;
  }

  // ------------------------------------------------------------ discovery

  static Future<Map>? _pendingDiscover;
  static DateTime _discoverFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static Map? _discoverCache;
  static const Duration _discoverTtl = Duration(minutes: 10);

  /// The homepage reply carries both the recommendation shelf and the
  /// leaderboard shelf, so one call feeds two pages. Concurrent callers share
  /// the in-flight request and the answer is reused while it is fresh.
  static Future<Map> _discover() {
    final cached = _discoverCache;
    if (cached != null &&
        DateTime.now().difference(_discoverFetchedAt) < _discoverTtl) {
      return Future<Map>.value(cached);
    }
    return _pendingDiscover ??= _loadDiscover();
  }

  static Future<Map> _loadDiscover() async {
    try {
      final body = await _post('/luna/pc/discover');
      if (body['blocks'] is! List) throw Exception('汽水音乐发现页加载失败');
      _discoverCache = body;
      _discoverFetchedAt = DateTime.now();
      return body;
    } finally {
      _pendingDiscover = null;
    }
  }

  /// The leaderboard shelf is server-driven, so the directory is read from the
  /// homepage instead of being hard-coded: 汽水 renames and reshuffles charts.
  static Future<List<LeaderboardSummary>> boards() async {
    final home = await _discover();
    final seen = <String>{};
    final out = <LeaderboardSummary>[];
    for (final block in (home['blocks'] as List).whereType<Map>()) {
      if (block['type'] != 'discover_top_song_list') continue;
      for (final inner in _maps(block['inner_block'])) {
        if (inner['type'] != 'discover_track_top_list') continue;
        final id = _textOrNull(inner['inner_block_id']);
        if (id == null || !seen.add(id)) continue;
        final tracks = _rankedTracks(inner['resources']);
        out.add(
          LeaderboardSummary(
            id: '${MusicSource.qs.code}__$id',
            boardId: id,
            name: decodeName(inner['title']).trim().isEmpty
                ? '汽水排行榜'
                : decodeName(inner['title']),
            source: MusicSource.qs,
            coverUrl: tracks.isEmpty ? null : tracks.first.meta.picUrl,
            updateFrequency: _textOrNull(decodeName(inner['desc'])),
            previewTracks: tracks.take(3).toList(growable: false),
          ),
        );
      }
    }
    return List<LeaderboardSummary>.unmodifiable(out);
  }

  static List<MusicInfo> _rankedTracks(Object? resources) {
    if (resources is! List) return const <MusicInfo>[];
    final out = <MusicInfo>[];
    for (final resource in resources.whereType<Map>()) {
      final entity = resource['entity'];
      final ranked = entity is Map ? entity['ranked_track'] : null;
      final track = ranked is Map ? ranked['track'] : null;
      final info = track is Map ? _toMusicInfo(track) : null;
      if (info != null) out.add(info);
    }
    return out;
  }

  /// One leaderboard as a playlist. The reply carries the platform's own title,
  /// blurb and cover, which the local directory cannot know.
  static Future<PlaylistInfo> leaderboard(String id, {int? maxTracks}) async {
    final nativeId = id.startsWith('chart:') ? id.substring(6) : id;
    final body = await _get('/luna/pc/charts/$nativeId');
    final chart = body['chart'];
    final ranks = chart is Map ? chart['track_ranks'] : null;
    if (ranks is! List) throw Exception('汽水音乐排行榜加载失败');
    final tracks = <MusicInfo>[];
    for (final entry in ranks.whereType<Map>()) {
      final track = entry['track'] ?? entry['track_wrapper'];
      final info = track is Map ? _toMusicInfo(track) : null;
      if (info != null) tracks.add(info);
    }
    final style = chart is Map ? chart['style'] : null;
    final cover = chart is Map ? chart['url_cover'] : null;
    return PlaylistInfo(
      // Keep the collection kind when a saved chart is refreshed as a playlist.
      id: 'chart:$nativeId',
      name: chart is Map && decodeName(chart['title']).trim().isNotEmpty
          ? decodeName(chart['title'])
          : '汽水排行榜',
      source: MusicSource.qs,
      tracks: maxTracks == null || maxTracks <= 0
          ? tracks
          : tracks.take(maxTracks).toList(growable: false),
      coverUrl: (cover is Map ? _imageUrl(cover) : _textOrNull(cover)) ??
          (tracks.isEmpty ? null : tracks.first.meta.picUrl),
      creator: '汽水音乐',
      description: style is Map ? _textOrNull(decodeName(style['desc'])) : null,
      trackCount: tracks.length,
    );
  }

  /// Real keyword playlist search: `GET /luna/search/playlist`, 20 per page.
  static Future<({List<PlaylistSummary> items, bool hasMore})>
  searchPlaylistPage(String keyword, {int cursor = 0, int count = 20}) async {
    final body = await _get(
      '/luna/search/playlist',
      query: {
        'q': keyword,
        'cursor': '$cursor',
        'search_id': _uuid(),
        'search_method': 'search',
      },
    );
    final group = _searchGroup(body, 'playlist');
    final out = <PlaylistSummary>[];
    for (final row in group.items) {
      final playlist = _entityOf(row, 'playlist');
      final id = playlist['id']?.toString() ?? '';
      final name = decodeName(playlist['title'] ?? playlist['name']);
      if (id.isEmpty || name.isEmpty) continue;
      out.add(_playlistSummary(playlist));
    }
    return (items: out.take(count).toList(), hasMore: group.hasMore);
  }

  /// The playlist shelf mirrors the LX server's `songList` model: `qs` exposes
  /// one "热门" sort and these eight tags, and each tag is searched by name.
  static const List<(String, String)> playlistTags = [
    ('qs_tag_rege', '热歌'),
    ('qs_tag_liuxing', '流行'),
    ('qs_tag_yaogun', '摇滚'),
    ('qs_tag_dianzi', '电子'),
    ('qs_tag_yingshi', '影视'),
    ('qs_tag_minyao', '民谣'),
    ('qs_tag_shuochang', '说唱'),
    ('qs_tag_qingyinle', '纯音乐'),
  ];

  static final List<String> _discoverKeywords = [
    '热门',
    ...playlistTags.map((tag) => tag.$2),
  ];

  /// 推荐歌单, taken from the homepage feed blocks.
  static Future<List<PlaylistSummary>> featuredPlaylists({
    int limit = 20,
  }) async {
    final body = await _post('/luna/pc/discover');
    final blocks = body['blocks'];
    if (blocks is! List) throw Exception('汽水音乐推荐歌单加载失败');
    final out = <PlaylistSummary>[];
    for (final block in blocks.whereType<Map>()) {
      if (block['type'] != 'discover_feed_playlist') continue;
      final inner = block['inner_block'];
      if (inner is! List) continue;
      for (final group in inner.whereType<Map>()) {
        final resources = group['resources'];
        if (resources is! List) continue;
        for (final resource in resources.whereType<Map>()) {
          final entity = resource['entity'];
          final playlist = entity is Map ? entity['playlist'] : null;
          if (playlist is! Map) continue;
          final id = playlist['id']?.toString() ?? '';
          final name = decodeName(playlist['title'] ?? playlist['name']);
          if (id.isEmpty || name.isEmpty) continue;
          out.add(_playlistSummary(playlist));
          if (out.length >= limit) return out;
        }
      }
    }
    return out;
  }

  // The homepage feed is a recommendation stream: each call returns a handful
  // of blocks and reshuffles, so paging through it means asking again and
  // de-duplicating until the grid has enough rows.
  static final List<PlaylistSummary> _featuredCache = [];
  static DateTime _featuredFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const int _featuredCacheLimit = 240;
  static const String _featuredCacheKey = 'qishui_featured_pool_v1';
  static bool _featuredLoaded = false;

  @visibleForTesting
  static int get debugFeaturedPoolSize => _featuredCache.length;

  /// The feed reshuffles on every call, so the pool has to outlive one launch:
  /// it is persisted and only ever appended to, never reset.
  static Future<void> _loadFeaturedCache() async {
    if (_featuredLoaded) return;
    _featuredLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_featuredCacheKey);
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw);
      if (data is! Map) return;
      final savedAt = data['at'];
      if (savedAt is int) {
        _featuredFetchedAt = DateTime.fromMillisecondsSinceEpoch(savedAt);
      }
      final items = data['items'];
      if (items is! List) return;
      for (final entry in items) {
        if (entry is! Map) continue;
        final id = entry['id'];
        final name = entry['name'];
        if (id is! String || name is! String) continue;
        if (_featuredCache.any((saved) => saved.id == id)) continue;
        _featuredCache.add(
          PlaylistSummary(
            id: id,
            name: name,
            source: MusicSource.qs,
            coverUrl: entry['cover'] is String ? entry['cover'] as String : null,
            creator: entry['creator'] is String
                ? entry['creator'] as String
                : null,
            trackCount: entry['tracks'] is int ? entry['tracks'] as int : null,
          ),
        );
      }
    } catch (_) {
      // A corrupt pool must not fail the page.
    }
  }

  static Future<void> _saveFeaturedCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _featuredCacheKey,
        jsonEncode({
          'at': _featuredFetchedAt.millisecondsSinceEpoch,
          'items': [
            for (final item in _featuredCache)
              {
                'id': item.id,
                'name': item.name,
                'cover': item.coverUrl,
                'creator': item.creator,
                'tracks': item.trackCount,
              },
          ],
        }),
      );
    } catch (_) {
      // Persisting is best effort.
    }
  }

  /// Keyword search fills the playlist tab; an empty keyword browses the
  /// accumulated homepage pool instead.
  static Future<CatalogResult> searchPlaylists(
    String keyword,
    int page,
    int limit,
  ) async {
    final word = keyword.trim();
    if (word.isEmpty) {
      final pool = await featuredPlaylistsPaged(page: page, limit: limit);
      return CatalogResult(
        items: [
          for (final playlist in pool)
            CatalogItem(
              category: SearchCategory.playlists,
              summary: playlist,
              subtitle: [
                playlist.creator ?? '',
                '${playlist.trackCount ?? 0} 首',
              ].where((part) => part.isNotEmpty).join(' · '),
            ),
        ],
        total: _featuredCache.length,
        hasMore: page * limit < _featuredCache.length,
      );
    }
    final result = await searchPlaylistPage(
      word,
      cursor: (page - 1) * limit,
      count: limit,
    );
    return CatalogResult(
      items: [
        for (final playlist in result.items)
          CatalogItem(
            category: SearchCategory.playlists,
            summary: playlist,
            subtitle: [
              playlist.creator ?? '',
              '${playlist.trackCount ?? 0} 首',
            ].where((part) => part.isNotEmpty).join(' · '),
          ),
      ],
      total: (page - 1) * limit + result.items.length,
      hasMore: result.hasMore,
    );
  }

  static Future<List<PlaylistSummary>> featuredPlaylistsPaged({
    required int page,
    int limit = 20,
  }) async {
    if (page < 1) return const <PlaylistSummary>[];
    await _loadFeaturedCache();
    final wanted = (page * limit).clamp(limit, _featuredCacheLimit).toInt();
    final stale =
        DateTime.now().difference(_featuredFetchedAt) > const Duration(hours: 6);
    var attempts = 0;
    // A stale pool only needs one fresh round; asking for every round while the
    // pool is already deep enough turned the first load into ~30 s of throttled
    // reads.
    while ((_featuredCache.length < wanted || (stale && attempts == 0)) &&
        attempts < 24) {
      final keyword = _discoverKeywords[attempts % _discoverKeywords.length];
      final cursor = (attempts ~/ _discoverKeywords.length) * 20;
      attempts++;
      List<PlaylistSummary> batch;
      try {
        batch = (await searchPlaylistPage(keyword, cursor: cursor)).items;
      } catch (_) {
        batch = await featuredPlaylists(limit: 20);
      }
      var added = 0;
      for (final item in batch) {
        if (_featuredCache.any((saved) => saved.id == item.id)) continue;
        _featuredCache.add(item);
        added++;
        if (_featuredCache.length >= _featuredCacheLimit) break;
      }
      if (added == 0) continue;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    _featuredFetchedAt = DateTime.now();
    await _saveFeaturedCache();
    final start = (page - 1) * limit;
    if (start >= _featuredCache.length) return const <PlaylistSummary>[];
    return _featuredCache.sublist(
      start,
      (start + limit).clamp(0, _featuredCache.length),
    );
  }

  /// Full track list of one playlist (the PC endpoint returns everything at once).
  static Future<PlaylistInfo> playlist(String id, {int? maxTracks}) async {
    final body = await _get(
      '/luna/pc/playlist/detail',
      query: {'playlist_id': id, 'cursor': '', 'count': '-1'},
    );
    final playlist = body['playlist'];
    if (playlist is! Map) throw Exception('汽水音乐歌单不存在');
    final resources = body['media_resources'];
    final tracks = <MusicInfo>[];
    if (resources is List) {
      for (final entry in resources) {
        final track = _entityTrack(entry);
        final info = track == null ? null : _toMusicInfo(track);
        if (info != null) tracks.add(info);
      }
    }
    final deduped = dedupeMusic(tracks);
    final sliced = maxTracks == null
        ? deduped
        : deduped.take(maxTracks).toList(growable: false);
    return PlaylistInfo(
      id: id,
      name: decodeName(playlist['title'] ?? playlist['name']),
      source: MusicSource.qs,
      tracks: sliced,
      coverUrl: _playlistCover(playlist),
      creator: _playlistCreator(playlist),
      description: _textOrNull(decodeName(playlist['desc'])),
      trackCount: _intOrNull(playlist['count_tracks']) ?? deduped.length,
    );
  }

  static PlaylistSummary _playlistSummary(Map playlist) {
    final stats = playlist['stats'];
    return PlaylistSummary(
      id: playlist['id']?.toString() ?? '',
      name: decodeName(playlist['title'] ?? playlist['name']),
      source: MusicSource.qs,
      coverUrl: _playlistCover(playlist),
      creator: _playlistCreator(playlist),
      description: _textOrNull(decodeName(playlist['desc'])),
      trackCount: _intOrNull(
        playlist['count_tracks'] ??
            (playlist['resource_cnt'] is Map
                ? (playlist['resource_cnt'] as Map)['track_cnt']
                : null),
      ),
      playCount: _intOrNull(
        stats is Map ? (stats['play_count'] ?? stats['count_collected']) : null,
      ),
    );
  }

  static String? _playlistCover(Map playlist) {
    final cover = playlist['url_cover'];
    if (cover is String && cover.isNotEmpty) return cover;
    if (cover is Map) {
      final urls = cover['urls'];
      final uri = cover['uri']?.toString() ?? '';
      if (uri.isEmpty) return null;
      if (urls is List && urls.isNotEmpty) {
        final template = cover['template_prefix']?.toString() ?? '';
        if (template.isEmpty) return '${urls.first}$uri';
        return '${urls.first}$uri~$template-resize:500:500.jpg';
      }
    }
    final direct = playlist['cover_url'] ?? playlist['coverUrl'];
    return direct is String && direct.isNotEmpty ? direct : null;
  }

  static String? _playlistCreator(Map playlist) {
    final owner = playlist['owner'] ?? playlist['creator'];
    if (owner is Map) {
      final name = decodeName(owner['nickname'] ?? owner['name']);
      return _textOrNull(name);
    }
    return _textOrNull(playlist['creator_name']);
  }

  static String? _textOrNull(Object? raw) {
    final text = raw?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static Iterable<Map> _maps(Object? raw) =>
      raw is List ? raw.whereType<Map>() : const <Map>[];

  static int? _intOrNull(Object? raw) => raw is num
      ? raw.toInt()
      : int.tryParse(raw?.toString().replaceAll(RegExp(r'[^0-9]'), '') ?? '');
}

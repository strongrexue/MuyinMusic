import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/catalog_result.dart';
import '../models/enums.dart';
import '../services/app_logger.dart';
import '../models/lyric_info.dart';
import '../models/music_info.dart';
import '../models/music_url.dart';
import '../models/playlist_info.dart';
import '../models/playlist_summary.dart';
import '../models/search_category.dart';
import 'internal/builders.dart';
import 'internal/crypto_util.dart';
import 'internal/format.dart';
import 'internal/sdk_http.dart';

/// Soda music (汽水音乐) talks to ByteDance's "luna" API. Search/track details
/// are plain Android GETs, but playback needs the signed `track_v2` request:
/// an x-ss-stub (body MD5), an x-khronos timestamp and an x-gorgon blob derived
/// from both plus the query string.
class QishuiSdk {
  const QishuiSdk._();

  static const _androidBase = 'https://api5-lq.qishui.com/luna';
  static const _pcBase = 'https://api.qishui.com/luna/pc';
  /// The bundled session from the reference plugin. It gets drained quickly
  /// once it is used from many devices, so [configureSession] normally installs
  /// a per-install generated id instead.
  static const _sessionId = '3e60f931253128d953e15144ba7105f1';

  /// A user-supplied session takes over once Soda throttles the bundled one.
  static String _sessionOverride = '';

  static void configureSession(String? sessionId) {
    _sessionOverride = (sessionId ?? '').trim();
  }

  static String get _activeSessionId =>
      _sessionOverride.isEmpty ? _sessionId : _sessionOverride;
  static const _pageSize = 20;

  static const Map<String, String> _androidParams = {
    'device_platform': 'android',
    'os': 'android',
    'ssmix': 'a',
    'cdid': '1f6b0830-690a-4804-8a5f-8034df51860a',
    'channel': 'huawei_8478_64',
    'aid': '8478',
    'app_name': 'luna',
    'version_code': '100213030',
    'version_name': '21.3.0',
    'manifest_version_code': '100213030',
    'update_version_code': '100213030',
    'hybrid_version_code': '100213030',
    'resolution': '1080*2338',
    'dpi': '440',
    'device_type': '22041216C',
    'device_model': '22041216C',
    'device_brand': 'Xiaomi',
    'language': 'zh',
    'os_api': '37',
    'os_version': '17',
    'ac': 'wifi',
    'package': 'com.luna.music',
    'tz_name': 'Asia/Shanghai',
    'tz_offset': '28800',
    'output_device_type': 'Phone',
    'iid': '4280870031627546',
    'device_id': '4280870031623450',
  };

  static const Map<String, String> _androidHeaders = {
    'User-Agent': 'okhttp/3.10.0',
    'Content-Type': 'application/json',
  };

  static const Map<String, String> _pcHeaders = {
    'User-Agent': 'LunaPC/3.8.0(467160162)',
  };

  // ---------------------------------------------------------------- search

  static Future<List<MusicInfo>> search(
    String keyword, {
    int page = 1,
    int limit = _pageSize,
  }) async {
    final cursor = (page - 1) * _pageSize;
    var tracks = const <Map>[];
    // Qishui occasionally answers with an empty 200, so retrying belongs to
    // the normal path rather than to an error branch.
    for (var attempt = 0; attempt < 3; attempt++) {
      final body = await _androidGet('/search/track', {
        'q': keyword,
        'cursor': '$cursor',
        'count': '$_pageSize',
        'aid': '386088',
      });
      tracks = _collectTracks(body);
      if (tracks.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    return tracks
        .map(_toMusicInfo)
        .whereType<MusicInfo>()
        .take(limit)
        .toList(growable: false);
  }

  static Future<List<String>> tip(String keyword) async {
    final songs = await search(keyword, limit: 8);
    return songs.map((song) => song.name).where((name) => name.isNotEmpty).toList();
  }

  /// Singer and album ids only become useful through a follow-up track search,
  /// so the search pass remembers what each id was called.
  static final Map<String, String> _catalogNames = {};

  static Future<CatalogResult> searchArtists(
    String keyword,
    int page,
    int limit,
  ) async {
    final body = await _androidGet('/search/artist', {
      'q': keyword,
      'cursor': '${(page - 1) * limit}',
      'count': '$limit',
      'aid': '386088',
    });
    final items = <CatalogItem>[];
    for (final row in _catalogEntities(body, 'artist')) {
      final id = row['id']?.toString() ?? '';
      final name = decodeName(row['name']);
      if (id.isEmpty || name.isEmpty) continue;
      _catalogNames['artist:$id'] = name;
      final avatar = row['url_avatar'];
      items.add(
        CatalogItem(
          category: SearchCategory.artists,
          summary: PlaylistSummary(
            id: id,
            name: name,
            source: MusicSource.qishui,
            coverUrl: avatar is Map ? _imageUrl(avatar.cast<String, Object?>()) : null,
            trackCount: _intOrNull(row['count_tracks']),
          ),
          subtitle: '歌手',
        ),
      );
    }
    return CatalogResult(
      items: items,
      total: items.length,
      hasMore: items.length >= limit,
    );
  }

  static Future<CatalogResult> searchAlbums(
    String keyword,
    int page,
    int limit,
  ) async {
    final body = await _androidGet('/search/album', {
      'q': keyword,
      'cursor': '${(page - 1) * limit}',
      'count': '$limit',
      'aid': '386088',
    });
    final items = <CatalogItem>[];
    for (final row in _catalogEntities(body, 'album')) {
      final id = row['id']?.toString() ?? '';
      final name = decodeName(row['name']);
      if (id.isEmpty || name.isEmpty) continue;
      _catalogNames['album:$id'] = name;
      final cover = row['url_cover'];
      final artists = row['artists'];
      final creator = artists is List
          ? artists
                .whereType<Map>()
                .map((artist) => decodeName(artist['name']))
                .where((value) => value.isNotEmpty)
                .join('、')
          : '';
      final tracks = _intOrNull(row['count_tracks']) ?? 0;
      items.add(
        CatalogItem(
          category: SearchCategory.albums,
          summary: PlaylistSummary(
            id: id,
            name: name,
            source: MusicSource.qishui,
            coverUrl: cover is Map ? _imageUrl(cover.cast<String, Object?>()) : null,
            creator: creator.isEmpty ? null : creator,
            trackCount: tracks,
          ),
          subtitle: [
            creator,
            if (tracks > 0) '$tracks 首',
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

  static List<Map> _catalogEntities(Object? body, String key) {
    final groups = body is Map ? body['result_groups'] : null;
    if (groups is! List) return const [];
    final rows = <Map>[];
    for (final group in groups) {
      if (group is! Map) continue;
      final data = group['data'];
      if (data is! List) continue;
      for (final entry in data) {
        if (entry is! Map) continue;
        final entity = entry['entity'];
        if (entity is! Map) continue;
        final item = entity[key];
        if (item is Map) rows.add(item);
      }
    }
    return rows;
  }

  /// Qishui exposes no public artist/album track endpoint, so both details are
  /// rebuilt from a track search on the remembered name.
  static Future<PlaylistInfo> artistDetail(String id, {int? maxTracks}) =>
      _catalogDetail(id, artist: true, maxTracks: maxTracks);

  static Future<PlaylistInfo> albumDetail(String id, {int? maxTracks}) =>
      _catalogDetail(id, artist: false, maxTracks: maxTracks);

  static Future<PlaylistInfo> _catalogDetail(
    String id, {
    required bool artist,
    int? maxTracks,
  }) async {
    final name = _catalogNames[(artist ? 'artist:' : 'album:') + id] ?? '';
    final target = maxTracks ?? 60;
    final tracks = <MusicInfo>[];
    final fallback = <MusicInfo>[];
    if (name.isNotEmpty) {
      for (var page = 1; tracks.length < target && page <= 8; page++) {
        final batch = await search(name, page: page, limit: 20);
        if (batch.isEmpty) break;
        for (final song in batch) {
          final match = artist
              ? song.singer.contains(name)
              : song.meta.albumName == name;
          if (match) {
            tracks.add(song);
          } else if (fallback.length < target) {
            // Qishui's search is fuzzy, so keep its own ranking as a fallback
            // instead of showing an empty page for a real artist.
            fallback.add(song);
          }
          if (tracks.length >= target) break;
        }
        if (batch.length < 20) break;
      }
    }
    if (tracks.isEmpty) tracks.addAll(fallback);
    return PlaylistInfo(
      id: id,
      name: name.isEmpty ? (artist ? '歌手' : '专辑') : name,
      source: MusicSource.qishui,
      tracks: tracks,
      trackCount: tracks.length,
    );
  }

  static List<Map> _collectTracks(Object? body) {
    if (body is! Map) return const [];
    final groups = body['result_groups'];
    if (groups is! List) return const [];
    final out = <Map>[];
    for (final group in groups) {
      if (group is! Map) continue;
      final data = group['data'];
      if (data is! List) continue;
      for (final entry in data) {
        final track = _entityTrack(entry);
        if (track != null) out.add(track);
      }
    }
    return out;
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
      source: MusicSource.qishui,
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

  static List<QualityOption> _qualitys(Map track) {
    final out = <QualityOption>[];
    final seen = <Quality>{};
    final bitRates = track['bit_rates'];
    if (bitRates is List) {
      for (final entry in bitRates) {
        if (entry is! Map) continue;
        final quality = _qualityFor(entry['quality']?.toString() ?? '');
        if (quality == null || !seen.add(quality)) continue;
        final size = num.tryParse(entry['size']?.toString() ?? '')?.toInt() ?? 0;
        out.add(QualityOption(type: quality, size: size <= 0 ? null : '$size'));
      }
    }
    return out;
  }

  static Quality? _qualityFor(String raw) {
    switch (raw) {
      case 'medium':
        return Quality.k128;
      case 'higher':
        return Quality.k192;
      case 'highest':
        return Quality.k320;
      case 'lossless':
        return Quality.flac;
      case 'hi_res':
      case 'hires':
        return Quality.hires;
      case 'spatial':
        return Quality.atmos;
    }
    return Quality.tryFromCode(raw);
  }

  // ------------------------------------------------------------- playback

  /// Soda bills `track_v2` per call and drops requests when asked too often, so
  /// a resolved URL is reused for a short while.
  static final Map<String, ({String url, DateTime at})> _urlCache = {};
  static const Duration _urlCacheTtl = Duration(minutes: 5);

  /// Relay used by the reference LX source: it resolves the play URL on its own
  /// servers, which side-steps the session throttling the direct endpoint hits.
  static const String _relayUrl = 'https://source.shiqianjiang.cn/api/music/url';
  static const String _relayApiKey =
      'CERU_KEY-F47AEA27-8798-46CB-B0E6-4C1E2951C1B3';

  /// The relay answers `500` for tracks that have no file in the requested
  /// quality (hi-res/atmos often do not), so walk down until one is served.
  /// Tracks advertise their own bit rates, and asking for a missing one costs a
  /// full round trip, so unavailable entries are dropped up front.
  static List<String> _relayQualities(MusicInfo music, Quality quality) {
    final declared = <String>{
      for (final option in music.meta.qualitys) option.type.code,
    };
    final ladder = switch (quality) {
      Quality.k128 => const ['128k'],
      Quality.k192 => const ['256k', '128k'],
      Quality.k320 => const ['320k', '256k', '128k'],
      _ => const ['flac', '320k', '256k', '128k'],
    };
    final allowed = <String>[];
    for (final candidate in ladder) {
      if (candidate == '320k' ||
          candidate == '256k' ||
          candidate == '128k' ||
          declared.any(
            (code) =>
                code == 'flac' ||
                code == 'flac24bit' ||
                code == 'wav' ||
                code == 'ape' ||
                code == 'hires' ||
                code == 'atmos' ||
                code == 'atmos_plus' ||
                code == 'master',
          )) {
        if (!allowed.contains(candidate)) allowed.add(candidate);
      }
    }
    return allowed.isEmpty ? const ['320k', '128k'] : allowed;
  }

  static Future<String?> _relayOnce(String trackId, String quality) async {
    try {
      final uri = Uri.parse(_relayUrl).replace(
        queryParameters: {
          'source': 'qs',
          'songId': trackId,
          'quality': quality,
        },
      );
      final body = await SdkHttp.getJson(
        uri.toString(),
        headers: {
          'X-API-Key': _relayApiKey,
          'Content-Type': 'application/json',
          'User-Agent': 'lx-music-mobile/2.0.0',
        },
      );
      if (body is Map) {
        final url = body['url'];
        if (url is String && url.startsWith('http')) return url;
      }
    } catch (_) {
      // Treated as "not served in this quality".
    }
    return null;
  }

  /// Returns the first usable URL, ignoring failures and nulls.
  static Future<String?> _firstSuccess(Iterable<Future<String?>> requests) async {
    final futures = requests.toList();
    if (futures.isEmpty) return null;
    final winner = Completer<String?>();
    var pending = futures.length;
    for (final future in futures) {
      future.then((value) {
        if (value != null && !winner.isCompleted) winner.complete(value);
      }).catchError((Object _) {}).whenComplete(() {
        pending--;
        if (pending == 0 && !winner.isCompleted) winner.complete(null);
      });
    }
    return winner.future;
  }

  static Future<String?> _resolveViaRelay(
    String trackId,
    MusicInfo music,
    Quality quality,
  ) async {
    final candidates = _relayQualities(music, quality);
    // A missing quality answers 500 after a beat, so ask for the top two at
    // once and take whichever comes back usable first.
    final fast = await _firstSuccess([
      for (final candidate in candidates.take(2))
        _relayOnce(trackId, candidate),
    ]);
    if (fast != null) return fast;
    for (final candidate in candidates.skip(2)) {
      final url = await _relayOnce(trackId, candidate);
      if (url != null) return url;
    }
    return null;
  }

  static Future<MusicUrl> resolveUrl(MusicInfo music, Quality quality) async {
    final trackId = music.meta.songId.toString();
    if (trackId.isEmpty) throw Exception('汽水音乐缺少歌曲 ID');

    // Cached per track (not per quality): the relay serves whatever bit rate is
    // available, so a warmed entry is always reusable by the next request.
    final cached = _urlCache[trackId];
    if (cached != null &&
        DateTime.now().difference(cached.at) < _urlCacheTtl) {
      return MusicUrl(url: cached.url, type: quality);
    }

    final relayed = await _resolveViaRelay(trackId, music, quality);
    if (relayed != null) {
      _urlCache[trackId] = (url: relayed, at: DateTime.now());
      return MusicUrl(url: relayed, type: quality);
    }

    final detail = await _trackDetail(trackId);
    final playList = _playInfoList(detail);
    if (playList.isEmpty) throw Exception('汽水音乐没有可用的播放地址');

    final picked = _pickPlayInfo(playList, quality);
    final url = (picked['main_url'] ?? picked['backup_url'])?.toString() ?? '';
    if (!url.startsWith('http')) throw Exception('汽水音乐没有可用的播放地址');
    _urlCache[trackId] = (url: url, at: DateTime.now());
    return MusicUrl(url: url, type: quality);
  }

  /// Warms the cache for [music] without surfacing failures; used to prepare the
  /// next queue entry so track changes start instantly.
  static Future<void> prefetch(MusicInfo music, {Quality quality = Quality.k320}) async {
    final trackId = music.meta.songId.toString();
    if (trackId.isEmpty) return;
    final cached = _urlCache[trackId];
    if (cached != null &&
        DateTime.now().difference(cached.at) < _urlCacheTtl) {
      return;
    }
    try {
      await resolveUrl(music, quality);
    } catch (_) {
      // Playback will retry with the full ladder when the track is reached.
    }
  }

  static ({String url, Map<String, String> headers, String body})
  _signedTrackRequest(String trackId) {
    final rticket = DateTime.now().millisecondsSinceEpoch.toString();
    final body = '{"track_id":"$trackId"}';
    final query = _encodeQuery({..._androidParams, '_rticket': rticket});
    final stub = CryptoUtil.md5HexBytes(Uint8List.fromList(utf8.encode(body)))
        .toUpperCase();
    return (
      url: '$_androidBase/track_v2?$query',
      headers: {
        ..._androidHeaders,
        'Accept-Encoding': 'gzip',
        'Cookie': 'sessionid=$_activeSessionId',
        'x-ss-stub': stub,
        'x-khronos': '${int.parse(rticket) ~/ 1000}',
        'x-gorgon': _gorgon(query: query, stub: stub, rticket: rticket),
      },
      body: body,
    );
  }

  /// Test hook: the exact request the SDK would send for [trackId].
  @visibleForTesting
  static ({String url, Map<String, String> headers, String body})
  debugSignedTrackRequest(String trackId) => _signedTrackRequest(trackId);

  /// Posts [body] with a fixed `Content-Length`. The signed Qishui endpoints
  /// silently drop chunked request bodies.
  static Future<String> _postSigned(
    String url,
    Map<String, String> headers,
    String body,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(Uri.parse(url));
      headers.forEach(request.headers.set);
      final payload = utf8.encode(body);
      request.contentLength = payload.length;
      request.add(payload);
      final response = await request.close();
      final bytes = await response.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map> _trackDetail(String trackId) async {
    // The endpoint drops roughly every other call from the same session (it
    // answers an empty 200), so each attempt re-signs and retries.
    Map? decoded;
    for (var attempt = 0; attempt < 3; attempt++) {
      final request = _signedTrackRequest(trackId);
      // Track detail is the one call that only survives with a real
      // Content-Length header, so it goes through HttpClient directly.
      final text = await _postSigned(
        request.url,
        request.headers,
        request.body,
      );
      final json = _decodeJson(text);
      if (json is Map) {
        decoded = json;
        break;
      }
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
    }
    if (decoded == null) {
      throw Exception('汽水音乐暂时没有响应，请稍后再试');
    }
    final data = decoded['data'];
    if (data is! Map) {
      final status = decoded['status_info'];
      final message = status is Map ? status['status_msg']?.toString() : null;
      throw Exception(message?.isNotEmpty == true ? message : '汽水音乐解析失败');
    }
    return data;
  }

  static List<Map> _playInfoList(Map detail) {
    final track = detail['track'];
    final player = detail['track_player'];
    final model = player is Map ? player['video_model'] : null;
    final root = _decodeMaybeJson(model) ??
        _decodeMaybeJson(track is Map ? track['video_model'] : null);
    if (root is! Map) return const [];
    final list = root['video_list'];
    if (list is! List) return const [];
    final out = <Map>[];
    for (final item in list) {
      if (item is! Map) continue;
      final meta = item['video_meta'];
      final quality = meta is Map ? meta['quality']?.toString() ?? '' : '';
      out.add({
        'quality': quality,
        'main_url': item['main_url'] ?? item['MainPlayUrl'],
        'backup_url': item['backup_url'] ?? item['BackupPlayUrl'],
        'bitrate': meta is Map ? (meta['bitrate'] ?? 0) : 0,
        'size': meta is Map ? (meta['size'] ?? 0) : 0,
      });
    }
    return out;
  }

  static Object? _decodeJson(Object? body) {
    if (body is Map || body is List) return body;
    if (body is String && body.trim().isNotEmpty) {
      try {
        return jsonDecode(body);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Object? _decodeMaybeJson(Object? value) {
    if (value is Map || value is List) return value;
    if (value is String && value.trim().startsWith('{')) {
      try {
        return jsonDecode(value);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Map _pickPlayInfo(List<Map> list, Quality quality) {
    Quality? qualityOf(Map item) => _qualityFor(item['quality']?.toString() ?? '');
    for (final item in list) {
      if (qualityOf(item) == quality) return item;
    }
    const order = [
      Quality.k128,
      Quality.k192,
      Quality.k320,
      Quality.flac,
      Quality.hires,
      Quality.atmos,
      Quality.atmosPlus,
    ];
    final wanted = order.indexOf(quality);
    if (wanted >= 0) {
      for (final candidate in order.skip(wanted)) {
        for (final item in list) {
          if (qualityOf(item) == candidate) return item;
        }
      }
    }
    return list.last;
  }

  static String _encodeQuery(Map<String, String> params) {
    return params.entries
        .map(
          (entry) =>
              '${_quoteComponent(entry.key)}=${_quoteComponent(entry.value)}',
        )
        .join('&');
  }

  /// Percent-encodes a query component the way the reference client does:
  /// letters, digits and `-_.~` stay literal, spaces become `+`, and everything
  /// else (including `*`, `!`, `'`, `(` and `)`) is escaped. The `x-gorgon`
  /// digest is computed over the exact query string that goes on the wire, so
  /// this has to match byte for byte or the server drops the call.
  static String _quoteComponent(String value) {
    final buffer = StringBuffer();
    for (final byte in utf8.encode(value)) {
      final char = String.fromCharCode(byte);
      final keep = (byte >= 0x30 && byte <= 0x39) ||
          (byte >= 0x41 && byte <= 0x5A) ||
          (byte >= 0x61 && byte <= 0x7A) ||
          char == '_' ||
          char == '.' ||
          char == '-' ||
          char == '~';
      if (keep) {
        buffer.write(char);
      } else if (byte == 0x20) {
        buffer.write('+');
      } else {
        buffer.write(
          '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }
    }
    return buffer.toString();
  }

  /// x-gorgon: a 26-byte blob (6-byte prefix + 20 signed bytes) as hex.
  static String _gorgon({
    required String query,
    required String stub,
    required String rticket,
    int? fixedPointer,
  }) {
    final khronos = int.parse(rticket) ~/ 1000;
    final random = Random();
    const word = 0x0404;
    final pointer = fixedPointer ?? (random.nextDouble() * 4096).toInt() << 4;

    final data = Uint8List(20);
    final queryHash = CryptoUtil.md5HexBytes(
      Uint8List.fromList(utf8.encode(query.split('#').first)),
    );
    final queryBytes = _hexToBytes(queryHash);
    final stubBytes = _hexToBytes(stub);
    for (var i = 0; i < 4; i++) {
      data[i] = queryBytes[i];
      data[4 + i] = stubBytes[i];
    }
    data[12] = 0;
    data[13] = 9;
    data[14] = 9;
    data[15] = 4;
    final khronosBytes = ByteData(4)..setUint32(0, khronos, Endian.big);
    for (var i = 0; i < 4; i++) {
      data[16 + i] = khronosBytes.getUint8(i);
    }

    final key = <int>[
      0x4a,
      word & 0xff,
      0x16,
      (pointer >> 8) & 0xff,
      0x47,
      0x6c,
      (word >> 8) & 0xff,
      pointer & 0xff,
    ];
    final state = List<int>.generate(256, (i) => i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + state[i] + key[i & 7]) & 0xff;
      final swapped = state[j];
      state[i] = swapped;
      state[j] = swapped;
    }
    for (var n = 0; n < 20; n++) {
      final i = n + 1;
      j = (j + state[i]) & 0xff;
      final sel = state[j];
      state[i] = sel;
      state[j] = sel;
      data[n] = data[n] ^ state[(sel + sel) & 0xff];
    }

    for (var n = 0; n < 20; n++) {
      var value = _swapNibbles(data[n]);
      // The wrap-around reads data[0] after it was already rewritten.
      value ^= n + 1 < 20 ? data[n + 1] : data[0];
      data[n] = 20 ^ (~_reverseBits8(value) & 0xff);
    }

    final out = BytesBuilder()
      ..add([0x84, 0x04, pointer & 0xff, (pointer >> 8) & 0xff, word & 0xff, (word >> 8) & 0xff])
      ..add(data);
    return out.toBytes().map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Deterministic [x-gorgon] for tests: the pointer is fixed so the output is
  /// reproducible and can be compared against a reference implementation.
  @visibleForTesting
  static String gorgonVector({
    required String query,
    required String stub,
    required String rticket,
    required int pointer,
  }) => _gorgon(
    query: query,
    stub: stub,
    rticket: rticket,
    fixedPointer: pointer,
  );

  static int _swapNibbles(int value) =>      ((value & 0x0f) << 4) | ((value & 0xf0) >> 4);

  static int _reverseBits8(int value) {
    var v = value & 0xff;
    v = ((v & 0x55) << 1) | ((v & 0xaa) >> 1);
    v = ((v & 0x33) << 2) | ((v & 0xcc) >> 2);
    v = ((v & 0x0f) << 4) | ((v & 0xf0) >> 4);
    return v & 0xff;
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  // ---------------------------------------------------------------- lyric

  static Future<LyricInfo> getLyric(MusicInfo info) async {
    final trackId = info.meta.songId.toString();
    if (trackId.isEmpty) throw Exception('汽水音乐缺少歌曲 ID');
    final Map detail;
    try {
      detail = await _seoTrack(trackId);
    } catch (error) {
      AppLogger.write('qishui', 'lyric lookup failed id=$trackId: $error');
      // Playback already resolved through the relay; a throttled lyric call
      // should not turn that into a failure.
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

  /// The h5 SEO endpoint returns the same `lyric` block as `track_v2` without
  /// the signed POST, so it is the cheaper and more reliable lyric source.
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

  /// 汽水 exposes three charts; the ids were confirmed against the platform.
  static const List<(String, String)> chartIds = [
    ('7036274230471712007', '热歌榜'),
    ('7060812597884869927', '新歌榜'),
    ('7061475546400005410', '欧美榜'),
  ];

  /// Tracks of one chart, in rank order.
  static Future<List<MusicInfo>> chart(String boardId, {int limit = 50}) async {
    final body = await _androidGet('/charts/$boardId', {
      'charge': '0',
      'cursor': '0',
      'count': '$limit',
    });
    final chart = body is Map ? body['chart'] : null;
    final ranks = chart is Map ? chart['track_ranks'] : null;
    if (ranks is! List) throw Exception('汽水音乐排行榜加载失败');
    final out = <MusicInfo>[];
    for (final entry in ranks) {
      if (entry is! Map) continue;
      final track = entry['track'] ?? entry['track_wrapper'];
      final info = track is Map ? _toMusicInfo(track) : null;
      if (info != null) out.add(info);
    }
    return out.take(limit).toList(growable: false);
  }

  /// Web client params the playlist catalogue endpoint expects.
  static const Map<String, String> _pcWebParams = {
    'aid': '386088',
    'device_platform': 'web',
    'channel': 'pc_web',
  };

  /// Real keyword playlist search: `GET /luna/search/playlist`, 20 per page.
  static Future<({List<PlaylistSummary> items, bool hasMore})> searchPlaylistPage(
    String keyword, {
    int cursor = 0,
    int count = 20,
  }) async {
    final query = _encodeQuery({
      ..._pcWebParams,
      'q': keyword,
      'cursor': '$cursor',
      'search_method': 'input',
    });
    final body = await SdkHttp.getJson(
      '$_pcBase/search/playlist?$query',
      headers: _pcHeaders,
    );
    if (body is! Map) throw Exception('汽水音乐歌单搜索失败');
    final groups = body['result_groups'];
    if (groups is! List || groups.isEmpty) {
      return (items: const <PlaylistSummary>[], hasMore: false);
    }
    final group = groups.first;
    final rows = group is Map ? group['data'] : null;
    final out = <PlaylistSummary>[];
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map) continue;
        final entity = row['entity'];
        final playlist = entity is Map ? entity['playlist'] : null;
        if (playlist is! Map) continue;
        final id = playlist['id']?.toString() ?? '';
        final name = decodeName(playlist['title'] ?? playlist['name']);
        if (id.isEmpty || name.isEmpty) continue;
        out.add(
          PlaylistSummary(
            id: id,
            name: name,
            source: MusicSource.qishui,
            coverUrl: _playlistCover(playlist),
            creator: _playlistCreator(playlist),
            description: _textOrNull(decodeName(playlist['desc'])),
            trackCount: _intOrNull(playlist['count_tracks']),
            playCount: _intOrNull(
              playlist['stats'] is Map
                  ? (playlist['stats'] as Map)['play_count']
                  : null,
            ),
          ),
        );
      }
    }
    final hasMore = group is Map && group['has_more'] == true;
    return (items: out.take(count).toList(), hasMore: hasMore);
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

  /// 推荐歌单, taken from the home feed blocks.
  static Future<List<PlaylistSummary>> featuredPlaylists({
    int limit = 20,
  }) async {
    final body = await _androidPost('/discover/mix', '{}');
    final blocks = body is Map ? body['inner_block'] : null;
    if (blocks is! List) throw Exception('汽水音乐推荐歌单加载失败');
    final out = <PlaylistSummary>[];
    for (final block in blocks) {
      if (block is! Map) continue;
      final resources = block['resources'];
      if (resources is! List) continue;
      for (final resource in resources) {
        if (resource is! Map) continue;
        final entity = resource['entity'];
        final playlist = entity is Map ? entity['playlist'] : null;
        if (playlist is! Map) continue;
        final id = playlist['id']?.toString() ?? '';
        final name = decodeName(playlist['title'] ?? playlist['name']);
        if (id.isEmpty || name.isEmpty) continue;
        final stats = playlist['stats'];
        out.add(
          PlaylistSummary(
            id: id,
            name: name,
            source: MusicSource.qishui,
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
              stats is Map ? stats['count_collected'] : null,
            ),
          ),
        );
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  // The discover feed is a recommendation stream: each call returns ~6 blocks
  // and has_more stays true, so paging through it means asking again and
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
            source: MusicSource.qishui,
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

  /// Qishui has no keyword playlist search, so the playlist tab browses the
  /// same featured feed the discovery page uses and narrows it locally.
  static Future<CatalogResult> searchPlaylists(
    String keyword,
    int page,
    int limit,
  ) async {
    final word = keyword.trim();
    if (word.isEmpty) {
      // No keyword: browse the accumulated discovery pool instead.
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
    while ((_featuredCache.length < wanted || stale) && attempts < 24) {
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
    final query = _encodeQuery({
      'playlist_id': id,
      'cursor': '',
      'count': '-1',
    });
    final body = await SdkHttp.getJson(
      '$_pcBase/playlist/detail?$query',
      headers: _pcHeaders,
    );
    if (body is! Map) throw Exception('汽水音乐歌单加载失败');
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
    final sliced = maxTracks == null
        ? tracks
        : tracks.take(maxTracks).toList(growable: false);
    return PlaylistInfo(
      id: id,
      name: decodeName(playlist['title'] ?? playlist['name']),
      source: MusicSource.qishui,
      tracks: sliced,
      coverUrl: _playlistCover(playlist),
      creator: _playlistCreator(playlist),
      description: _textOrNull(decodeName(playlist['desc'])),
      trackCount: _intOrNull(playlist['count_tracks']) ?? tracks.length,
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
      final name = decodeName(owner['name'] ?? owner['nickname']);
      return _textOrNull(name);
    }
    return _textOrNull(playlist['creator_name']);
  }

  static String? _textOrNull(Object? raw) {
    final text = raw?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static int? _intOrNull(Object? raw) => raw is num
      ? raw.toInt()
      : int.tryParse(raw?.toString().replaceAll(RegExp(r'[^0-9]'), '') ?? '');

  // -------------------------------------------------------------- helpers

  static Future<Object?> _androidPost(String path, String body) async {
    final query = _encodeQuery({
      ..._androidParams,
      '_rticket': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    final response = await SdkHttp.fetch<dynamic>(
      '$_androidBase$path?$query',
      method: 'POST',
      headers: {
        ..._androidHeaders,
        'Cookie': 'sessionid=$_activeSessionId',
      },
      body: body,
      responseType: ResponseType.plain,
    );
    return _decodeJson(response.body);
  }

  static Future<Object?> _androidGet(
    String path,
    Map<String, String> params,
  ) async {
    final query = _encodeQuery({
      ..._androidParams,
      ...params,
      '_rticket': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    return SdkHttp.getJson(
      '$_androidBase$path?$query',
      headers: {..._androidHeaders, 'Cookie': 'sessionid=$_activeSessionId'},
    );
  }
}

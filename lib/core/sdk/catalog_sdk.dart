import '../models/catalog_result.dart';
import '../models/enums.dart';
import '../models/playlist_info.dart';
import '../models/search_category.dart';
import 'catalog/kg_catalog.dart';
import 'catalog/kw_catalog.dart';
import 'catalog/mg_catalog.dart';
import 'catalog/tx_catalog.dart';
import 'catalog/wy_catalog.dart';
import 'qishui_sdk.dart';

class CatalogSdk {
  static bool supports(MusicSource source, SearchCategory category) {
    if (category == SearchCategory.songs || category == SearchCategory.all) {
      return true;
    }
    // Qishui offers singers, albums and a browsable playlist feed.
    if (source == MusicSource.qishui) {
      return true;
    }
    return const {
      MusicSource.wy,
      MusicSource.tx,
      MusicSource.kw,
      MusicSource.kg,
      MusicSource.mg,
    }.contains(source);
  }

  static Future<CatalogResult> search(
    String keyword,
    MusicSource source,
    SearchCategory category,
    int page,
    int limit,
  ) => switch (source) {
    MusicSource.wy => WyCatalog.search(keyword, category, page, limit),
    MusicSource.kw => KwCatalog.search(keyword, category, page, limit),
    MusicSource.tx => TxCatalog.search(keyword, category, page, limit),
    MusicSource.kg => KgCatalog.search(keyword, category, page, limit),
    MusicSource.mg => MgCatalog.search(keyword, category, page, limit),
    MusicSource.qishui => switch (category) {
      SearchCategory.artists => QishuiSdk.searchArtists(keyword, page, limit),
      SearchCategory.albums => QishuiSdk.searchAlbums(keyword, page, limit),
      _ => QishuiSdk.searchPlaylists(keyword, page, limit),
    },
    _ => throw UnsupportedError('${source.label}暂不支持${category.label}搜索'),
  };

  static Future<PlaylistInfo> detail(
    MusicSource source,
    String id, {
    required bool artist,
    int? maxTracks,
  }) => switch (source) {
    MusicSource.wy => WyCatalog.detail(
      id,
      artist: artist,
      maxTracks: maxTracks,
    ),
    MusicSource.kw => KwCatalog.detail(
      id,
      artist: artist,
      maxTracks: maxTracks,
    ),
    MusicSource.tx => TxCatalog.detail(
      id,
      artist: artist,
      maxTracks: maxTracks,
    ),
    MusicSource.qishui => artist
        ? QishuiSdk.artistDetail(id, maxTracks: maxTracks)
        : QishuiSdk.albumDetail(id, maxTracks: maxTracks),
    MusicSource.kg => KgCatalog.detail(
      id,
      artist: artist,
      maxTracks: maxTracks,
    ),
    MusicSource.mg => MgCatalog.detail(
      id,
      artist: artist,
      maxTracks: maxTracks,
    ),
    _ => throw UnsupportedError('${source.label}暂不支持此类详情'),
  };
}

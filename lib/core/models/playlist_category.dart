import 'enums.dart';

class PlaylistCatalogCategory {
  const PlaylistCatalogCategory({required this.id, required this.label});

  final String id;
  final String label;
}

const _kuwoPlaylistCategories = <PlaylistCatalogCategory>[
  PlaylistCatalogCategory(id: 'new', label: '最新'),
  PlaylistCatalogCategory(id: 'hot', label: '最热'),
];

const _kugouPlaylistCategories = <PlaylistCatalogCategory>[
  PlaylistCatalogCategory(id: '5', label: '推荐'),
  PlaylistCatalogCategory(id: '6', label: '最热'),
  PlaylistCatalogCategory(id: '7', label: '最新'),
  PlaylistCatalogCategory(id: '3', label: '热藏'),
  PlaylistCatalogCategory(id: '8', label: '飙升'),
];

const _qqPlaylistCategories = <PlaylistCatalogCategory>[
  PlaylistCatalogCategory(id: '-1', label: '推荐'),
  PlaylistCatalogCategory(id: '3', label: '最热'),
  PlaylistCatalogCategory(id: '2', label: '最新'),
];

const _neteasePlaylistCategories = <PlaylistCatalogCategory>[
  PlaylistCatalogCategory(id: 'hot', label: '最热'),
];

const _miguPlaylistCategories = <PlaylistCatalogCategory>[
  PlaylistCatalogCategory(id: '15127315', label: '推荐'),
];

const _qsPlaylistCategories = <PlaylistCatalogCategory>[
  PlaylistCatalogCategory(id: 'mix', label: '推荐'),
];

List<PlaylistCatalogCategory> playlistCatalogCategoriesFor(
  MusicSource source,
) => switch (source) {
  MusicSource.kw => _kuwoPlaylistCategories,
  MusicSource.kg => _kugouPlaylistCategories,
  MusicSource.tx => _qqPlaylistCategories,
  MusicSource.wy => _neteasePlaylistCategories,
  MusicSource.mg => _miguPlaylistCategories,
  MusicSource.qs => _qsPlaylistCategories,
  MusicSource.all => const <PlaylistCatalogCategory>[],
};

PlaylistCatalogCategory defaultPlaylistCatalogCategoryFor(MusicSource source) {
  final categories = playlistCatalogCategoriesFor(source);
  if (categories.isEmpty) {
    throw ArgumentError.value(source, 'source', '必须指定歌单平台');
  }
  return categories.first;
}

/// 排序名读取失败时的兜底，只给胶囊显示一个中性的名字。
const playlistDefaultCategory = PlaylistCatalogCategory(
  id: 'default',
  label: '默认',
);

/// 排序轴的可选集合，永远是平台自己的排序项。
///
/// 排序与标签是两个独立的轴，但只有酷狗的接口能同时接下两者（`t` 排序、
/// `c` 分类）；其余平台上标签会占掉排序参数的位置（QQ 的 `category_id`、
/// 酷我的整条标签端点），所以选中标签时排序不生效——由调用方在用户挑排序
/// 时清掉标签，而不是把排序项藏起来。
List<PlaylistCatalogCategory> playlistSortOptionsFor(MusicSource source) {
  return playlistCatalogCategoriesFor(source);
}

/// 平台的接口能否同时接下排序与标签两个参数。
///
/// 不能时，两轴互斥：挑排序就清标签，挑标签就回落到默认排序。
bool playlistSortsStackWithTags(MusicSource source) => source == MusicSource.kg;

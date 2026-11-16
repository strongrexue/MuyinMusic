import 'enums.dart';

/// 平台歌单标签轴（主题 / 风格 / 语种 / 场景 …）里的一项。
///
/// 与 [PlaylistCatalogCategory] 的排序轴互不相关：排序轴决定「怎么排」，
/// 标签轴决定「取哪一批」。两个轴可以同时存在，也可以各自单独存在。
class PlaylistTag {
  const PlaylistTag({required this.id, required this.label, this.keyword});

  /// 平台歌单接口认识的取值。网易云要的是中文标签名，其余平台是数字 id。
  final String id;

  final String label;

  /// 平台没有服务端标签轴时，标签退化为搜索词（汽水音乐）。非空即表示该
  /// 标签要送去歌单搜索接口，而不是作为分类参数。
  final String? keyword;

  bool get isKeyword => keyword != null;
}

class PlaylistTagGroup {
  const PlaylistTagGroup({
    required this.id,
    required this.label,
    required this.tags,
  });

  final String id;
  final String label;
  final List<PlaylistTag> tags;
}

/// 「全部」不参与任何参数传递，由调用方用 `null` 表示。
List<PlaylistTagGroup> playlistTagGroupsFor(MusicSource source) =>
    switch (source) {
      MusicSource.wy => _wyTagGroups,
      MusicSource.kg => _kgTagGroups,
      MusicSource.kw => _kwTagGroups,
      MusicSource.tx => _txTagGroups,
      MusicSource.mg => _mgTagGroups,
      MusicSource.qs => _qsTagGroups,
      MusicSource.all => const <PlaylistTagGroup>[],
    };

PlaylistTag? playlistTagFor(MusicSource source, String? tagId) {
  if (tagId == null) return null;
  for (final group in playlistTagGroupsFor(source)) {
    for (final tag in group.tags) {
      if (tag.id == tagId) return tag;
    }
  }
  return null;
}

// ---------------------------------------------------------------- 网易云
// GET /api/playlist/highquality/tags → 33 个标签，按 category 0..4 分组。
// 取歌单用 /api/playlist/list?cat=<中文标签名>，因此 id 直接存名字。
const _wyTagGroups = <PlaylistTagGroup>[
  PlaylistTagGroup(
    id: '0',
    label: '语种',
    tags: [
      PlaylistTag(id: '华语', label: '华语'),
      PlaylistTag(id: '欧美', label: '欧美'),
      PlaylistTag(id: '韩语', label: '韩语'),
      PlaylistTag(id: '日语', label: '日语'),
      PlaylistTag(id: '粤语', label: '粤语'),
      PlaylistTag(id: '小语种', label: '小语种'),
    ],
  ),
  PlaylistTagGroup(
    id: '1',
    label: '风格',
    tags: [
      PlaylistTag(id: '流行', label: '流行'),
      PlaylistTag(id: '摇滚', label: '摇滚'),
      PlaylistTag(id: '民谣', label: '民谣'),
      PlaylistTag(id: '电子', label: '电子'),
      PlaylistTag(id: '说唱', label: '说唱'),
      PlaylistTag(id: '轻音乐', label: '轻音乐'),
      PlaylistTag(id: '爵士', label: '爵士'),
      PlaylistTag(id: '乡村', label: '乡村'),
      PlaylistTag(id: 'R&B/Soul', label: 'R&B/Soul'),
      PlaylistTag(id: '蓝调', label: '蓝调'),
      PlaylistTag(id: '古典', label: '古典'),
      PlaylistTag(id: '古风', label: '古风'),
      PlaylistTag(id: '后摇', label: '后摇'),
      PlaylistTag(id: '英伦', label: '英伦'),
      PlaylistTag(id: '世界音乐', label: '世界音乐'),
      PlaylistTag(id: '另类/独立', label: '另类/独立'),
    ],
  ),
  PlaylistTagGroup(
    id: '2',
    label: '场景',
    tags: [
      PlaylistTag(id: '学习', label: '学习'),
      PlaylistTag(id: '夜晚', label: '夜晚'),
      PlaylistTag(id: '运动', label: '运动'),
    ],
  ),
  PlaylistTagGroup(
    id: '3',
    label: '情感',
    tags: [
      PlaylistTag(id: '怀旧', label: '怀旧'),
      PlaylistTag(id: '浪漫', label: '浪漫'),
      PlaylistTag(id: '快乐', label: '快乐'),
      PlaylistTag(id: '性感', label: '性感'),
    ],
  ),
  PlaylistTagGroup(
    id: '4',
    label: '主题',
    tags: [
      PlaylistTag(id: '经典', label: '经典'),
      PlaylistTag(id: '影视原声', label: '影视原声'),
      PlaylistTag(id: 'ACG', label: 'ACG'),
      PlaylistTag(id: '器乐', label: '器乐'),
    ],
  ),
];

// ---------------------------------------------------------------- 酷狗
// 标签树随 getSpecial?is_smarty=1&cdn=cdn&t=5&c= 的 data.tagids 一起返回，
// 六组 82 项。取歌单仍走 getSpecial，标签填 c=，排序填 t=。
const _kgTagGroups = <PlaylistTagGroup>[
  PlaylistTagGroup(
    id: '主题',
    label: '主题',
    tags: [
      PlaylistTag(id: '1084', label: '精选'),
      PlaylistTag(id: '12', label: '经典'),
      PlaylistTag(id: '35', label: '网络'),
      PlaylistTag(id: '17', label: 'DJ热碟'),
      PlaylistTag(id: '68', label: '情歌对唱'),
      PlaylistTag(id: '74', label: '游戏'),
      PlaylistTag(id: '10', label: '舞曲'),
      PlaylistTag(id: '72', label: 'KTV'),
      PlaylistTag(id: '79', label: '影视'),
      PlaylistTag(id: '638', label: '翻唱'),
      PlaylistTag(id: '77', label: 'ACG'),
      PlaylistTag(id: '680', label: '现场'),
      PlaylistTag(id: '80', label: '综艺'),
      PlaylistTag(id: '1111', label: '厂牌音乐'),
      PlaylistTag(id: '1112', label: 'BGM'),
      PlaylistTag(id: '1110', label: '儿童'),
      PlaylistTag(id: '682', label: '器乐演奏'),
      PlaylistTag(id: '1085', label: '官方歌单'),
      PlaylistTag(id: '605', label: '草原风'),
      PlaylistTag(id: '628', label: '广场舞'),
    ],
  ),
  PlaylistTagGroup(
    id: '语种',
    label: '语种',
    tags: [
      PlaylistTag(id: '84', label: '国语'),
      PlaylistTag(id: '20', label: '英语'),
      PlaylistTag(id: '19', label: '粤语'),
      PlaylistTag(id: '21', label: '日语'),
      PlaylistTag(id: '23', label: '韩语'),
      PlaylistTag(id: '22', label: '闽南语'),
      PlaylistTag(id: '24', label: '小语种'),
      PlaylistTag(id: '570', label: '法语'),
    ],
  ),
  PlaylistTagGroup(
    id: '风格',
    label: '风格',
    tags: [
      PlaylistTag(id: '9', label: '流行'),
      PlaylistTag(id: '574', label: '古风'),
      PlaylistTag(id: '33', label: '电子'),
      PlaylistTag(id: '83', label: '民谣'),
      PlaylistTag(id: '27', label: '摇滚'),
      PlaylistTag(id: '31', label: '嘻哈'),
      PlaylistTag(id: '1079', label: '后摇'),
      PlaylistTag(id: '11', label: '中国风'),
      PlaylistTag(id: '30', label: 'R&B'),
      PlaylistTag(id: '28', label: '古典'),
      PlaylistTag(id: '15', label: '乡村'),
      PlaylistTag(id: '32', label: '爵士'),
      PlaylistTag(id: '650', label: '新世纪'),
      PlaylistTag(id: '94', label: '布鲁斯'),
      PlaylistTag(id: '1057', label: '拉丁'),
      PlaylistTag(id: '34', label: '轻音乐'),
      PlaylistTag(id: '1108', label: '中国传统'),
      PlaylistTag(id: '29', label: '金属'),
      PlaylistTag(id: '92', label: '雷鬼'),
    ],
  ),
  PlaylistTagGroup(
    id: '年代',
    label: '年代',
    tags: [
      PlaylistTag(id: '13', label: '70后'),
      PlaylistTag(id: '14', label: '80后'),
      PlaylistTag(id: '76', label: '90后'),
      PlaylistTag(id: '571', label: '00后'),
    ],
  ),
  PlaylistTagGroup(
    id: '心情',
    label: '心情',
    tags: [
      PlaylistTag(id: '1107', label: '怀旧'),
      PlaylistTag(id: '578', label: '伤感'),
      PlaylistTag(id: '44', label: '安静'),
      PlaylistTag(id: '50', label: '兴奋'),
      PlaylistTag(id: '577', label: '轻松'),
      PlaylistTag(id: '780', label: '治愈'),
      PlaylistTag(id: '49', label: '快乐'),
      PlaylistTag(id: '47', label: '甜蜜'),
      PlaylistTag(id: '42', label: '寂寞'),
      PlaylistTag(id: '48', label: '感动'),
      PlaylistTag(id: '642', label: '小清新'),
      PlaylistTag(id: '81', label: '励志'),
      PlaylistTag(id: '643', label: '减压'),
      PlaylistTag(id: '684', label: '失恋'),
    ],
  ),
  PlaylistTagGroup(
    id: '场景',
    label: '场景',
    tags: [
      PlaylistTag(id: '587', label: '学习'),
      PlaylistTag(id: '660', label: '工作'),
      PlaylistTag(id: '1104', label: '通勤'),
      PlaylistTag(id: '69', label: '运动'),
      PlaylistTag(id: '67', label: '校园'),
      PlaylistTag(id: '585', label: '旅途'),
      PlaylistTag(id: '61', label: '咖啡厅'),
      PlaylistTag(id: '581', label: '店铺'),
      PlaylistTag(id: '668', label: '清晨'),
      PlaylistTag(id: '670', label: '下午茶'),
      PlaylistTag(id: '1105', label: '夜晚'),
      PlaylistTag(id: '583', label: '睡前'),
      PlaylistTag(id: '586', label: '派对'),
      PlaylistTag(id: '1106', label: '宅家'),
      PlaylistTag(id: '63', label: '车载'),
      PlaylistTag(id: '64', label: '夜店'),
      PlaylistTag(id: '88', label: '婚礼'),
    ],
  ),
];

// ---------------------------------------------------------------- 酷我
// getTagList 返回 8 组；有标签时必须换 getTagPlayList&id=，且该端点忽略
// order，所以选中标签后排序轴只剩「默认」。专区和有声系列与歌单页语义
// 不符，不收录。
const _kwTagGroups = <PlaylistTagGroup>[
  PlaylistTagGroup(
    id: '5',
    label: '主题',
    tags: [
      PlaylistTag(id: '2189', label: '短视频'),
      PlaylistTag(id: '1265', label: '经典'),
      PlaylistTag(id: '2200', label: '情歌'),
      PlaylistTag(id: '2199', label: 'BGM'),
      PlaylistTag(id: '2212', label: '演唱会'),
      PlaylistTag(id: '1877', label: '游戏'),
      PlaylistTag(id: '155', label: '怀旧'),
      PlaylistTag(id: '2201', label: '合唱'),
      PlaylistTag(id: '621', label: '网络'),
      PlaylistTag(id: '171', label: '儿童'),
      PlaylistTag(id: '181', label: 'ACG'),
      PlaylistTag(id: '180', label: '影视'),
      PlaylistTag(id: '1879', label: '网红'),
      PlaylistTag(id: '2190', label: '春节'),
      PlaylistTag(id: '1848', label: '翻唱'),
      PlaylistTag(id: '241', label: '轻音助眠'),
    ],
  ),
  PlaylistTagGroup(
    id: '1',
    label: '心情',
    tags: [
      PlaylistTag(id: '146', label: '伤感'),
      PlaylistTag(id: '62', label: '解压'),
      PlaylistTag(id: '58', label: '励志'),
      PlaylistTag(id: '143', label: '开心'),
      PlaylistTag(id: '137', label: '甜蜜'),
      PlaylistTag(id: '139', label: '兴奋'),
      PlaylistTag(id: '67', label: '安静'),
      PlaylistTag(id: '160', label: '思念'),
    ],
  ),
  PlaylistTagGroup(
    id: '3',
    label: '场景',
    tags: [
      PlaylistTag(id: '376', label: '开车'),
      PlaylistTag(id: '366', label: '运动'),
      PlaylistTag(id: '354', label: '睡眠'),
      PlaylistTag(id: '378', label: '跳舞'),
      PlaylistTag(id: '1876', label: '学习'),
      PlaylistTag(id: '353', label: '清晨'),
      PlaylistTag(id: '361', label: 'KTV'),
      PlaylistTag(id: '263', label: '店铺专用'),
      PlaylistTag(id: '382', label: '校园'),
      PlaylistTag(id: '375', label: '旅行'),
      PlaylistTag(id: '386', label: '工作'),
      PlaylistTag(id: '334', label: '广场舞'),
      PlaylistTag(id: '2202', label: '通勤'),
      PlaylistTag(id: '2203', label: '宅家'),
      PlaylistTag(id: '2214', label: 'Citywalk'),
      PlaylistTag(id: '2213', label: '露营'),
    ],
  ),
  PlaylistTagGroup(
    id: '143',
    label: '年代',
    tags: [
      PlaylistTag(id: '637', label: '70后'),
      PlaylistTag(id: '638', label: '80后'),
      PlaylistTag(id: '639', label: '90后'),
      PlaylistTag(id: '640', label: '00后'),
    ],
  ),
  PlaylistTagGroup(
    id: '8',
    label: '曲风流派',
    tags: [
      PlaylistTag(id: '393', label: '流行'),
      PlaylistTag(id: '168', label: 'DJ'),
      PlaylistTag(id: '127', label: '古风'),
      PlaylistTag(id: '220', label: '佛乐'),
      PlaylistTag(id: '173', label: '轻音乐'),
      PlaylistTag(id: '577', label: '纯音乐'),
      PlaylistTag(id: '391', label: '电子'),
      PlaylistTag(id: '216', label: '喊麦'),
      PlaylistTag(id: '1366', label: '3D'),
      PlaylistTag(id: '578', label: '器乐'),
      PlaylistTag(id: '389', label: '摇滚'),
      PlaylistTag(id: '1921', label: '民歌'),
      PlaylistTag(id: '392', label: '民谣'),
      PlaylistTag(id: '390', label: '古典'),
      PlaylistTag(id: '387', label: '嘻哈'),
      PlaylistTag(id: '399', label: '乡村'),
      PlaylistTag(id: '397', label: '爵士'),
      PlaylistTag(id: '394', label: 'R&B'),
    ],
  ),
  PlaylistTagGroup(
    id: '6',
    label: '语言',
    tags: [
      PlaylistTag(id: '37', label: '华语'),
      PlaylistTag(id: '35', label: '欧美'),
      PlaylistTag(id: '1093', label: '韩语'),
      PlaylistTag(id: '13', label: '粤语'),
      PlaylistTag(id: '1091', label: '日语'),
      PlaylistTag(id: '12', label: '小语种'),
    ],
  ),
];

// ---------------------------------------------------------------- QQ
// get_all_categories 返回 7 组 73 项；get_category_content 的 titleid 与
// category_id 都填标签 id。
const _txTagGroups = <PlaylistTagGroup>[
  PlaylistTagGroup(
    id: '1',
    label: '热门',
    tags: [
      PlaylistTag(id: '3317', label: '官方歌单'),
      PlaylistTag(id: '3418', label: '免费热歌'),
    ],
  ),
  PlaylistTagGroup(
    id: '2',
    label: '主题',
    tags: [
      PlaylistTag(id: '64', label: 'KTV金曲'),
      PlaylistTag(id: '3056', label: '网络歌曲'),
      PlaylistTag(id: '95', label: '现场音乐'),
      PlaylistTag(id: '107', label: '背景音乐'),
      PlaylistTag(id: '59', label: '经典老歌'),
      PlaylistTag(id: '71', label: '情歌'),
      PlaylistTag(id: '3200', label: '儿歌'),
      PlaylistTag(id: '3202', label: 'ACG'),
      PlaylistTag(id: '3201', label: '影视'),
      PlaylistTag(id: '3256', label: '综艺'),
      PlaylistTag(id: '73', label: '游戏'),
      PlaylistTag(id: '3204', label: '乐器'),
      PlaylistTag(id: '93', label: '城市'),
      PlaylistTag(id: '3361', label: '戏曲'),
      PlaylistTag(id: '3357', label: 'DJ神曲'),
      PlaylistTag(id: '60', label: 'MC喊麦'),
      PlaylistTag(id: '3401', label: '佛教音乐'),
      PlaylistTag(id: '3320', label: '厂牌专区'),
      PlaylistTag(id: '136', label: '人气音乐节'),
      PlaylistTag(id: '3819', label: '精品'),
    ],
  ),
  PlaylistTagGroup(
    id: '3',
    label: '场景',
    tags: [
      PlaylistTag(id: '32', label: '夜店'),
      PlaylistTag(id: '3248', label: '学习工作'),
      PlaylistTag(id: '3215', label: '咖啡馆'),
      PlaylistTag(id: '132', label: '运动'),
      PlaylistTag(id: '27', label: '睡前'),
      PlaylistTag(id: '36', label: '旅行'),
      PlaylistTag(id: '3216', label: '跳舞'),
      PlaylistTag(id: '33', label: '派对'),
      PlaylistTag(id: '3214', label: '婚礼'),
      PlaylistTag(id: '35', label: '约会'),
      PlaylistTag(id: '39', label: '校园'),
    ],
  ),
  PlaylistTagGroup(
    id: '4',
    label: '心情',
    tags: [
      PlaylistTag(id: '74', label: '伤感'),
      PlaylistTag(id: '3142', label: '快乐'),
      PlaylistTag(id: '13', label: '安静'),
      PlaylistTag(id: '16', label: '励志'),
      PlaylistTag(id: '7', label: '治愈'),
      PlaylistTag(id: '10', label: '思念'),
      PlaylistTag(id: '20', label: '甜蜜'),
      PlaylistTag(id: '9', label: '寂寞'),
      PlaylistTag(id: '17', label: '宣泄'),
    ],
  ),
  PlaylistTagGroup(
    id: '9',
    label: '年代',
    tags: [
      PlaylistTag(id: '144', label: '00年代'),
      PlaylistTag(id: '142', label: '90年代'),
      PlaylistTag(id: '141', label: '80年代'),
      PlaylistTag(id: '140', label: '70年代'),
    ],
  ),
  PlaylistTagGroup(
    id: '5',
    label: '流派',
    tags: [
      PlaylistTag(id: '3152', label: '流行'),
      PlaylistTag(id: '45', label: '电子'),
      PlaylistTag(id: '49', label: '轻音乐'),
      PlaylistTag(id: '48', label: '民谣'),
      PlaylistTag(id: '42', label: '说唱'),
      PlaylistTag(id: '41', label: '摇滚'),
      PlaylistTag(id: '46', label: '爵士'),
      PlaylistTag(id: '43', label: 'R&B'),
      PlaylistTag(id: '51', label: '布鲁斯'),
      PlaylistTag(id: '47', label: '古典'),
      PlaylistTag(id: '3217', label: '后摇'),
      PlaylistTag(id: '61', label: '古风'),
      PlaylistTag(id: '68', label: '中国风'),
      PlaylistTag(id: '44', label: '乡村'),
      PlaylistTag(id: '3065', label: '金属'),
      PlaylistTag(id: '53', label: '新世纪'),
      PlaylistTag(id: '3066', label: '世界音乐'),
      PlaylistTag(id: '3176', label: '中国传统'),
    ],
  ),
  PlaylistTagGroup(
    id: '6',
    label: '语种',
    tags: [
      PlaylistTag(id: '1', label: '国语'),
      PlaylistTag(id: '3', label: '英语'),
      PlaylistTag(id: '146', label: '粤语'),
      PlaylistTag(id: '4', label: '韩语'),
      PlaylistTag(id: '5', label: '日语'),
      PlaylistTag(id: '113', label: '闽南语'),
      PlaylistTag(id: '6', label: '小语种'),
      PlaylistTag(id: '149', label: '法语'),
      PlaylistTag(id: '3205', label: '拉丁语'),
    ],
  ),
];

// ---------------------------------------------------------------- 咪咕
// musiclistplaza-taglist 返回 6 组 75 项；有标签走 listbytag&tagId=。
const _mgTagGroups = <PlaylistTagGroup>[
  PlaylistTagGroup(
    id: '热门',
    label: '热门',
    tags: [
      PlaylistTag(id: '1001076096', label: '网络热歌'),
      PlaylistTag(id: '1000001672', label: '流行'),
      PlaylistTag(id: '1000001635', label: '经典老歌'),
      PlaylistTag(id: '1003449976', label: '官方'),
      PlaylistTag(id: '1000001675', label: '国风'),
      PlaylistTag(id: '1000001775', label: '民谣'),
      PlaylistTag(id: '1000001827', label: 'KTV金曲'),
      PlaylistTag(id: '1000001777', label: '欧美'),
      PlaylistTag(id: '1000001780', label: '儿歌'),
      PlaylistTag(id: '1003449727', label: '厂牌'),
      PlaylistTag(id: '1000001795', label: '伤感'),
      PlaylistTag(id: '1001076080', label: '电影'),
      PlaylistTag(id: '1000001696', label: '怀旧'),
      PlaylistTag(id: '1000001831', label: '翻唱'),
    ],
  ),
  PlaylistTagGroup(
    id: '风格',
    label: '风格',
    tags: [
      PlaylistTag(id: '1000001672', label: '流行'),
      PlaylistTag(id: '1000001682', label: '电子'),
      PlaylistTag(id: '1000001675', label: '国风'),
      PlaylistTag(id: '1000001681', label: '爵士'),
      PlaylistTag(id: '1000001683', label: '乡村'),
      PlaylistTag(id: '1000001851', label: '蓝调'),
      PlaylistTag(id: '1000001775', label: '民谣'),
      PlaylistTag(id: '1000001807', label: '纯音乐'),
      PlaylistTag(id: '1000001783', label: '古典'),
      PlaylistTag(id: '1000001674', label: '摇滚'),
      PlaylistTag(id: '1000001809', label: '嘻哈'),
      PlaylistTag(id: '1000001808', label: 'R&B'),
    ],
  ),
  PlaylistTagGroup(
    id: '语种',
    label: '语种',
    tags: [
      PlaylistTag(id: '1000001762', label: '国语'),
      PlaylistTag(id: '1000001763', label: '粤语'),
      PlaylistTag(id: '1000001766', label: '英语'),
      PlaylistTag(id: '1000001767', label: '日语'),
      PlaylistTag(id: '1000001599', label: '韩语'),
      PlaylistTag(id: '1003449724', label: '小语种'),
    ],
  ),
  PlaylistTagGroup(
    id: '场景',
    label: '场景',
    tags: [
      PlaylistTag(id: '1003449209', label: '运动'),
      PlaylistTag(id: '1000587692', label: '瑜伽'),
      PlaylistTag(id: '1003450093', label: '学习'),
      PlaylistTag(id: '1000587688', label: '睡前安眠'),
      PlaylistTag(id: '1000093923', label: '驾车'),
      PlaylistTag(id: '1000001749', label: '旅行'),
      PlaylistTag(id: '1000587686', label: '夜店'),
      PlaylistTag(id: '1002600606', label: '派对'),
      PlaylistTag(id: '1003449723', label: '下午茶'),
      PlaylistTag(id: '1003449726', label: '读书'),
    ],
  ),
  PlaylistTagGroup(
    id: '主题',
    label: '主题',
    tags: [
      PlaylistTag(id: '1001076083', label: '综艺'),
      PlaylistTag(id: '1000001827', label: 'KTV金曲'),
      PlaylistTag(id: '1000001698', label: '爱情'),
      PlaylistTag(id: '1000001635', label: '经典老歌'),
      PlaylistTag(id: '1001076096', label: '网络热歌'),
      PlaylistTag(id: '1000001780', label: '儿歌'),
      PlaylistTag(id: '1000587717', label: '70后'),
      PlaylistTag(id: '1000587718', label: '80后'),
      PlaylistTag(id: '1000587726', label: '90后'),
      PlaylistTag(id: '1000587702', label: '广场舞'),
      PlaylistTag(id: '1000001670', label: '红歌'),
      PlaylistTag(id: '1000587698', label: '游戏'),
      PlaylistTag(id: '1000001675', label: '国风'),
      PlaylistTag(id: '1000001796', label: '安静'),
      PlaylistTag(id: '1000587712', label: '青春校园'),
      PlaylistTag(id: '1000587673', label: '小清新'),
      PlaylistTag(id: '1000093902', label: 'DJ舞曲'),
      PlaylistTag(id: '1001076078', label: '电视剧'),
      PlaylistTag(id: '1001076080', label: '电影'),
      PlaylistTag(id: '1000001831', label: '翻唱'),
    ],
  ),
  PlaylistTagGroup(
    id: '心情',
    label: '心情',
    tags: [
      PlaylistTag(id: '1000587677', label: '幸福'),
      PlaylistTag(id: '1000587710', label: '治愈'),
      PlaylistTag(id: '1000001703', label: '思念'),
      PlaylistTag(id: '1000001700', label: '励志'),
      PlaylistTag(id: '1000001694', label: '欢快'),
      PlaylistTag(id: '1002600588', label: '叛逆'),
      PlaylistTag(id: '1002600585', label: '宣泄'),
      PlaylistTag(id: '1000001696', label: '怀旧'),
      PlaylistTag(id: '1000587679', label: '减压'),
      PlaylistTag(id: '1000001699', label: '寂寞'),
      PlaylistTag(id: '1002600579', label: '忧郁'),
      PlaylistTag(id: '1000001795', label: '伤感'),
      PlaylistTag(id: '1000001796', label: '安静'),
    ],
  ),
];

// ---------------------------------------------------------------- 汽水音乐
// 平台没有服务端标签轴，八个标签是歌单搜索词，走 /luna/search/playlist。
const _qsTagGroups = <PlaylistTagGroup>[
  PlaylistTagGroup(
    id: 'keyword',
    label: '热门分类',
    tags: [
      PlaylistTag(id: 'qs_tag_rege', label: '热歌', keyword: '热歌'),
      PlaylistTag(id: 'qs_tag_liuxing', label: '流行', keyword: '流行'),
      PlaylistTag(id: 'qs_tag_yaogun', label: '摇滚', keyword: '摇滚'),
      PlaylistTag(id: 'qs_tag_dianzi', label: '电子', keyword: '电子'),
      PlaylistTag(id: 'qs_tag_yingshi', label: '影视', keyword: '影视'),
      PlaylistTag(id: 'qs_tag_minyao', label: '民谣', keyword: '民谣'),
      PlaylistTag(id: 'qs_tag_shuochang', label: '说唱', keyword: '说唱'),
      PlaylistTag(id: 'qs_tag_qingyinle', label: '纯音乐', keyword: '纯音乐'),
    ],
  ),
];

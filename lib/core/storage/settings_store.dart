import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/storage_location.dart';
import '../services/saf_storage.dart';
import '../api/dio_factory.dart';
import '../models/enums.dart';
import '../../theme/glass_settings.dart';
import '../../theme/liquid_glass_mode.dart';
import '../../theme/seed_palette.dart';
import 'base_url.dart';

export 'base_url.dart';

const String _kDownloadDirKey = 'download_dir';
const String _kDownloadFileNameFormatKey = 'download_file_name_format';
const String _kDownloadGroupByArtistKey = 'download_group_by_artist';
const String _kKtvModeEnabledKey = 'player_ktv_mode_enabled';
const String _kIosDynamicIslandEnabledKey = 'ios_dynamic_island_enabled';
const String _kKtvBackgroundStyleKey = 'player_ktv_background_style';
const String _kKtvBackgroundImageKey = 'player_ktv_background_image';
const String _kKtvBackgroundItemsKey = 'player_ktv_background_items';
const String _kKtvBackgroundSelectedIdKey = 'player_ktv_background_selected_id';
const String _kPortraitBackgroundSelectedIdKey =
    'player_portrait_background_selected_id';
const String _kKtvBackgroundMigratedKey =
    'player_ktv_background_items_migrated_v1';
const String _kLocalMusicDirKey = 'local_music_dir';
const String _kLocalMusicDirsKey = 'local_music_dirs';
const String _kLocalMusicIgnoredPathsKey = 'local_music_ignored_paths';
const String _kLocalMusicIgnoredRecordsKey = 'local_music_ignored_records';
const String _kUseBuiltInSourceFilePickerKey =
    'use_built_in_source_file_picker';
const String _kThemeModeKey = 'theme_mode';
const String _kThemeSeedKey = 'theme_seed_argb';
const String _kThemePaletteKey = 'theme_palette';
const String _kGlassConfigKey = 'glass_config';
const String _kLiquidGlassModeKey = 'liquid_glass_mode';
const String _kPlaylistArtworkColorsEnabledKey =
    'playlist_artwork_colors_enabled';
const String _kFlowingLightEnabledKey = 'flowing_light_enabled';
const String _kLyricViewBlurDisabledKey = 'lyric_view_blur_disabled';
const String _kLyricAlignModeKey = 'lyric_align_mode';
const String _kLyricAlignModeLandscapeKey = 'lyric_align_mode_landscape';
const String _kSquareAlbumCoverEnabledKey = 'square_album_cover_enabled';
const String _kLyricFontWeightKey = 'lyric_font_weight';
const String _kLyricFontSizeKey = 'lyric_font_size';
const String _kAutoPlayOnStartupKey = 'auto_play_on_startup';
const String _kSkipStartupScreenKey = 'skip_startup_screen';
const String _kCheckForUpdatesOnStartupKey = 'check_for_updates_on_startup';
const String _kIgnoredAppUpdateVersionKey = 'ignored_app_update_version';
// 旧版更新弹窗的「忽略更新」会把启动检查全局关掉且设置里无处恢复，
// 用这个标记对存量安装做一次复位迁移。
const String _kAppUpdateStartupCheckResetKey =
    'app_update_startup_check_reset_v1';
const String _kNetworkAdapterModeKey = 'network_adapter_mode';
const String _kEnabledSearchSourcesKey = 'enabled_search_source_codes';
// 汽水音乐 was added as a search source after release, so installs that already
// saved an enabled-source list never learn about it. This flag makes the
// one-time opt-in run exactly once.
const String _kQsSearchAddedKey = 'qs_search_added_v1';
// iOS 存量迁移标记：早期版本把 Android 路径写进 download_dir/local_music_dirs。
const String _kIosDirMigratedKey = 'ios_default_dir_migrated_v1';
const String _kDefaultSearchSourceKey = 'default_search_source';
const String _kReplaceQueueOnSearchPlayKey = 'replace_queue_on_search_play';
const String _kDiscoverySourceOrderKey = 'discovery_source_order';
const String _kPlatformButtonOnLeftKey = 'platform_button_on_left';
const String _kBottomBarBehaviorKey = 'bottom_bar_behavior';
const String _kOnlinePlaybackQualityKey = 'online_playback_quality';
// 在线播放音质按网络拆分：WiFi / 移动流量各一档。
const String _kOnlinePlaybackQualityWifiKey = 'online_playback_quality_wifi';
const String _kOnlinePlaybackQualityCellularKey =
    'online_playback_quality_cellular';
const String _kOnlinePlaybackQualitySplitKey =
    'online_playback_quality_split_v1';
const String _kBatchDownloadQualityKey = 'batch_download_quality';
const String _kShowMiniLyricsKey = 'show_mini_lyrics';
const String _kGrooveShiftEnabledKey = 'groove_shift_enabled';
const String _kAllowMixWithOthersKey = 'allow_mix_with_others';
const String _kPlayerVolumeKey = 'player_volume';
const String _kBluetoothLyricEnabledKey = 'bluetooth_lyric_enabled';
const String _kBluetoothFullLyricEnabledKey = 'bluetooth_full_lyric_enabled';
const String _kBluetoothLyricNoticeSeenKey = 'bluetooth_lyric_notice_seen';
const String _kDebugModeKey = 'debug_mode';
const String _kLegacyBaseUrlKey = 'base_url';

const kLyricFontWeightMin = 100.0;
const kLyricFontWeightMax = 1000.0;
const kLyricFontWeightDefault = 200.0;
const kLyricFontSizeMin = 16.0;
const kLyricFontSizeMax = 56.0;
const kLyricFontSizeDefault = 28.0;

double normalizeLyricFontWeight(double value) =>
    (value.clamp(kLyricFontWeightMin, kLyricFontWeightMax) / 100)
        .roundToDouble() *
    100;

double normalizeLyricFontSize(double value) =>
    value.clamp(kLyricFontSizeMin, kLyricFontSizeMax).roundToDouble();

/// 横屏 KTV 播放页的背景样式：内置动态图，或用户导入的自定义图片。
/// 上一版的 gradient / cover 两档已经下线，存量值一律按 builtin 读。
enum KtvBackgroundStyle {
  builtin('builtin', '内置动态'),
  custom('custom', '自定义图片');

  const KtvBackgroundStyle(this.code, this.label);

  final String code;
  final String label;

  static KtvBackgroundStyle fromCode(String? code) =>
      code == custom.code ? custom : builtin;
}

/// 用户导入的一张 KTV 自定义背景图。图片实体放在应用文档目录的
/// ktv_backgrounds/ 子目录里，[fileName] 是其中的文件名。
@immutable
class KtvBackgroundItem {
  const KtvBackgroundItem({
    required this.id,
    required this.name,
    required this.fileName,
  });

  final String id;
  final String name;
  final String fileName;

  KtvBackgroundItem copyWith({String? name}) =>
      KtvBackgroundItem(id: id, name: name ?? this.name, fileName: fileName);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'fileName': fileName,
  };

  static KtvBackgroundItem? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = value['name'];
    final fileName = value['fileName'];
    if (id is! String || id.isEmpty) return null;
    if (fileName is! String || fileName.isEmpty) return null;
    return KtvBackgroundItem(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name : '自定义背景',
      fileName: fileName,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is KtvBackgroundItem &&
      other.id == id &&
      other.name == name &&
      other.fileName == fileName;

  @override
  int get hashCode => Object.hash(id, name, fileName);
}

List<KtvBackgroundItem> _decodeKtvBackgroundItems(String? encoded) {
  if (encoded == null) return const [];
  try {
    final decoded = jsonDecode(encoded);
    if (decoded is! List) return const [];
    return List.unmodifiable(
      decoded.map(KtvBackgroundItem.fromJson).whereType<KtvBackgroundItem>(),
    );
  } catch (_) {
    return const [];
  }
}

/// 一条忽略记录的展示信息：忽略名单本体只存路径（扫描过滤消费），
/// 已忽略页要靠这里的标题/歌手/位置才能辨认歌曲——MediaStore 条目的
/// 路径是 content URI，末段只是数字 ID，靠路径本身无法展示。
@immutable
class IgnoredLocalSongRecord {
  const IgnoredLocalSongRecord({
    required this.path,
    this.title = '',
    this.singer = '',
    this.location = '',
  });

  /// 与忽略名单一致的匹配路径（归一化后的存储位置）。
  final String path;
  final String title;
  final String singer;

  /// 可读位置：有本地文件路径时是完整路径，否则是文件名/显示名。
  final String location;

  Map<String, dynamic> toJson() => {
    'path': path,
    'title': title,
    'singer': singer,
    'location': location,
  };

  static IgnoredLocalSongRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    final path = value['path'];
    if (path is! String || path.trim().isEmpty) return null;
    String text(String key) {
      final field = value[key];
      return field is String ? field : '';
    }

    return IgnoredLocalSongRecord(
      path: path,
      title: text('title'),
      singer: text('singer'),
      location: text('location'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IgnoredLocalSongRecord &&
      other.path == path &&
      other.title == title &&
      other.singer == singer &&
      other.location == location;

  @override
  int get hashCode => Object.hash(path, title, singer, location);
}

List<IgnoredLocalSongRecord> _decodeIgnoredLocalSongRecords(String? encoded) {
  if (encoded == null) return const [];
  try {
    final decoded = jsonDecode(encoded);
    if (decoded is! List) return const [];
    return List.unmodifiable(
      decoded
          .map(IgnoredLocalSongRecord.fromJson)
          .whereType<IgnoredLocalSongRecord>(),
    );
  } catch (_) {
    return const [];
  }
}

String _encodeIgnoredLocalSongRecords(
  List<IgnoredLocalSongRecord> records,
) => jsonEncode([for (final record in records) record.toJson()]);

/// 歌词对齐方式。竖屏歌词页与手机横屏歌词面板各用一份独立设置，
/// 共用这组选项。
enum LyricAlignMode {
  left('left', '左对齐'),
  center('center', '居中对齐');

  const LyricAlignMode(this.code, this.label);

  final String code;
  final String label;

  static LyricAlignMode fromCode(String? code) =>
      values.firstWhere((mode) => mode.code == code, orElse: () => left);
}

const Object _unsetValue = Object();

@immutable
class AppSettings {
  const AppSettings({
    required this.downloadDir,
    this.downloadFileNameFormat = DownloadFileNameFormat.artistTitle,
    this.downloadGroupByArtist = false,
    this.ktvModeEnabled = false,
    this.ktvBackgroundStyle = KtvBackgroundStyle.builtin,
    this.ktvBackgroundImagePath,
    this.ktvBackgroundItems = const [],
    this.ktvBackgroundSelectedId,
    this.portraitBackgroundSelectedId,
    required this.localMusicDirs,
    this.ignoredLocalSongPaths = const [],
    this.ignoredLocalSongRecords = const [],
    this.useBuiltInSourceFilePicker = false,
    required this.themeMode,
    required this.themeSeed,
    this.themePalette = SeedPalette.defaultColors,
    this.liquidGlassMode = LiquidGlassMode.standard,
    this.glassConfig = GlassConfig.defaults,
    this.playlistArtworkColorsEnabled = true,
    required this.flowingLightEnabled,
    this.lyricViewBlurDisabled = false,
    this.lyricAlignMode = LyricAlignMode.left,
    this.lyricAlignModeLandscape = LyricAlignMode.left,
    this.squareAlbumCoverEnabled = false,
    this.lyricFontWeight = kLyricFontWeightDefault,
    this.lyricFontSize = kLyricFontSizeDefault,
    this.autoPlayOnStartup = false,
    this.skipStartupScreen = false,
    this.checkForUpdatesOnStartup = true,
    this.ignoredAppUpdateVersion = '',
    required this.networkAdapterMode,
    required this.enabledSearchSources,
    this.defaultSearchSource = MusicSource.all,
    this.replaceQueueOnSearchPlay = true,
    required this.discoverySourceOrder,
    this.platformButtonOnLeft = false,
    this.bottomBarBehavior = BottomBarBehavior.always,
    required this.onlinePlaybackQualityWifi,
    required this.onlinePlaybackQualityCellular,
    required this.batchDownloadQuality,
    required this.showMiniLyrics,
    this.grooveShiftEnabled = false,
    this.iosDynamicIslandEnabled = true,
    required this.allowMixWithOthers,
    this.playerVolume = 1.0,
    required this.bluetoothLyricEnabled,
    required this.bluetoothFullLyricEnabled,
    required this.bluetoothLyricNoticeSeen,
    required this.debugMode,
  });

  final String downloadDir;
  final DownloadFileNameFormat downloadFileNameFormat;
  final bool downloadGroupByArtist;
  final bool ktvModeEnabled;
  final KtvBackgroundStyle ktvBackgroundStyle;

  /// 旧版单张自定义 KTV 背景图的本机文件路径，仅用于一次性迁移到
  /// [ktvBackgroundItems] 图库。指向设备本地文件，不参与跨设备同步。
  final String? ktvBackgroundImagePath;

  /// 用户导入的 KTV 自定义背景图库。条目（名称/文件名）参与跨设备
  /// 同步，图片实体是本机文件，不随同步迁移，缺失时回退内置背景。
  final List<KtvBackgroundItem> ktvBackgroundItems;

  /// 当前选中的自定义背景条目 id；为 null 或条目不存在时不生效。
  final String? ktvBackgroundSelectedId;

  /// 当前生效的自定义背景条目（样式为 custom 且选中条目存在时）。
  KtvBackgroundItem? get selectedKtvBackgroundItem {
    if (ktvBackgroundStyle != KtvBackgroundStyle.custom) return null;
    for (final item in ktvBackgroundItems) {
      if (item.id == ktvBackgroundSelectedId) return item;
    }
    return null;
  }

  /// 竖屏播放页选中的背景图库条目 id；为 null 时竖屏播放页用流光背景。
  /// 图库与图片文件和 KTV 共用，选中状态与 [ktvBackgroundSelectedId] 独立。
  final String? portraitBackgroundSelectedId;

  /// 竖屏播放页当前生效的背景条目（选中条目存在时）。
  KtvBackgroundItem? get selectedPortraitBackgroundItem {
    for (final item in ktvBackgroundItems) {
      if (item.id == portraitBackgroundSelectedId) return item;
    }
    return null;
  }

  final List<String> localMusicDirs;
  String get localMusicDir => localMusicDirs.first;

  /// 被「仅从本地列表移除」的歌曲路径（归一化后的存储位置）。扫描时按
  /// 路径键过滤，名单内文件不进本地库；本机设置，不参与跨设备同步。
  final List<String> ignoredLocalSongPaths;

  /// 与 [ignoredLocalSongPaths] 平行的展示信息（标题/歌手/位置），
  /// 供已忽略页辨认歌曲。旧版本写入的名单没有记录，对应条目为空缺，
  /// 页面回退到按路径解析。扫描过滤不消费这份数据。
  final List<IgnoredLocalSongRecord> ignoredLocalSongRecords;
  final bool useBuiltInSourceFilePicker;
  final ThemeMode themeMode;
  final Color themeSeed;
  final List<int> themePalette;
  final LiquidGlassMode liquidGlassMode;
  final GlassConfig glassConfig;
  bool get glassEnabled => liquidGlassMode != LiquidGlassMode.none;
  final bool playlistArtworkColorsEnabled;

  /// Whether the player backdrop animates its extracted colors. Off falls back
  /// to the static blurred-artwork backdrop.
  final bool flowingLightEnabled;
  final bool lyricViewBlurDisabled;
  final LyricAlignMode lyricAlignMode;

  /// 手机横屏歌词面板的对齐方式，与竖屏歌词页的 [lyricAlignMode]
  /// 相互独立、互不联动。本机设置，不参与跨设备同步。
  final LyricAlignMode lyricAlignModeLandscape;
  final bool squareAlbumCoverEnabled;
  final double lyricFontWeight;
  final double lyricFontSize;

  final bool autoPlayOnStartup;
  final bool skipStartupScreen;
  final bool checkForUpdatesOnStartup;

  /// 更新弹窗里被「忽略此版本」的版本号（tag）。只压住自动提示：
  /// 手动检查永远绕过，出现更新的版本时仍会重新提示。
  final String ignoredAppUpdateVersion;
  final NetworkAdapterMode networkAdapterMode;
  final Set<MusicSource> enabledSearchSources;
  final MusicSource defaultSearchSource;

  /// Applies to song search results in discovery, libraries and collections.
  final bool replaceQueueOnSearchPlay;
  final List<MusicSource> discoverySourceOrder;
  final bool platformButtonOnLeft;

  /// What the mini player and the floating dock do while a list scrolls.
  final BottomBarBehavior bottomBarBehavior;
  final OnlinePlaybackQuality onlinePlaybackQualityWifi;
  final OnlinePlaybackQuality onlinePlaybackQualityCellular;
  final OnlinePlaybackQuality batchDownloadQuality;

  /// 兼容旧引用：代表默认（WiFi）网络下的在线播放音质。
  /// 新代码应按当前网络类型选 wifi/cellular 字段，勿再依赖此 getter 做选档。
  OnlinePlaybackQuality get onlinePlaybackQuality => onlinePlaybackQualityWifi;
  final bool showMiniLyrics;

  /// Whether playback should avoid taking exclusive audio focus so other apps
  /// can continue playing at the same time.
  final bool grooveShiftEnabled;

  /// iOS 是否发布系统播放卡片（灵动岛与锁屏是同一张系统卡）。关闭后
  /// 自研通道与 audio_service 两条发布路径都停发，规避部分侧载机型
  /// 点卡误跳签名工具的问题。非 iOS 平台无此设置项。
  final bool iosDynamicIslandEnabled;
  final bool allowMixWithOthers;

  /// Playback gain in 0..1, applied to the BASS stream. Remembered so a level
  /// dialled in for a quiet Bluetooth path survives restarts.
  final double playerVolume;

  final bool bluetoothLyricEnabled;
  final bool bluetoothFullLyricEnabled;
  final bool bluetoothLyricNoticeSeen;
  final bool debugMode;

  AppSettings copyWith({
    String? downloadDir,
    DownloadFileNameFormat? downloadFileNameFormat,
    bool? downloadGroupByArtist,
    bool? ktvModeEnabled,
    KtvBackgroundStyle? ktvBackgroundStyle,
    Object? ktvBackgroundImagePath = _unsetValue,
    List<KtvBackgroundItem>? ktvBackgroundItems,
    Object? ktvBackgroundSelectedId = _unsetValue,
    Object? portraitBackgroundSelectedId = _unsetValue,
    String? localMusicDir,
    List<String>? localMusicDirs,
    List<String>? ignoredLocalSongPaths,
    List<IgnoredLocalSongRecord>? ignoredLocalSongRecords,
    bool? useBuiltInSourceFilePicker,
    ThemeMode? themeMode,
    Color? themeSeed,
    List<int>? themePalette,
    LiquidGlassMode? liquidGlassMode,
    GlassConfig? glassConfig,
    bool? playlistArtworkColorsEnabled,
    bool? flowingLightEnabled,
    bool? lyricViewBlurDisabled,
    LyricAlignMode? lyricAlignMode,
    LyricAlignMode? lyricAlignModeLandscape,
    bool? squareAlbumCoverEnabled,
    double? lyricFontWeight,
    double? lyricFontSize,
    bool? autoPlayOnStartup,
    bool? skipStartupScreen,
    bool? checkForUpdatesOnStartup,
    String? ignoredAppUpdateVersion,
    NetworkAdapterMode? networkAdapterMode,
    Set<MusicSource>? enabledSearchSources,
    MusicSource? defaultSearchSource,
    bool? replaceQueueOnSearchPlay,
    List<MusicSource>? discoverySourceOrder,
    bool? platformButtonOnLeft,
    BottomBarBehavior? bottomBarBehavior,
    OnlinePlaybackQuality? onlinePlaybackQualityWifi,
    OnlinePlaybackQuality? onlinePlaybackQualityCellular,
    OnlinePlaybackQuality? batchDownloadQuality,
    bool? showMiniLyrics,
    bool? grooveShiftEnabled,
    bool? iosDynamicIslandEnabled,
    bool? allowMixWithOthers,
    double? playerVolume,
    bool? bluetoothLyricEnabled,
    bool? bluetoothFullLyricEnabled,
    bool? bluetoothLyricNoticeSeen,
    bool? debugMode,
  }) => AppSettings(
    downloadDir: downloadDir ?? this.downloadDir,
    downloadFileNameFormat:
        downloadFileNameFormat ?? this.downloadFileNameFormat,
    downloadGroupByArtist: downloadGroupByArtist ?? this.downloadGroupByArtist,
    ktvModeEnabled: ktvModeEnabled ?? this.ktvModeEnabled,
    ktvBackgroundStyle: ktvBackgroundStyle ?? this.ktvBackgroundStyle,
    ktvBackgroundImagePath: identical(ktvBackgroundImagePath, _unsetValue)
        ? this.ktvBackgroundImagePath
        : ktvBackgroundImagePath as String?,
    ktvBackgroundItems: ktvBackgroundItems ?? this.ktvBackgroundItems,
    ktvBackgroundSelectedId: identical(ktvBackgroundSelectedId, _unsetValue)
        ? this.ktvBackgroundSelectedId
        : ktvBackgroundSelectedId as String?,
    portraitBackgroundSelectedId:
        identical(portraitBackgroundSelectedId, _unsetValue)
        ? this.portraitBackgroundSelectedId
        : portraitBackgroundSelectedId as String?,
    localMusicDirs:
        localMusicDirs ??
        (localMusicDir != null ? [localMusicDir] : this.localMusicDirs),
    ignoredLocalSongPaths: ignoredLocalSongPaths ?? this.ignoredLocalSongPaths,
    ignoredLocalSongRecords:
        ignoredLocalSongRecords ?? this.ignoredLocalSongRecords,
    useBuiltInSourceFilePicker:
        useBuiltInSourceFilePicker ?? this.useBuiltInSourceFilePicker,
    themeMode: themeMode ?? this.themeMode,
    themeSeed: themeSeed ?? this.themeSeed,
    themePalette: themePalette ?? this.themePalette,
    liquidGlassMode: liquidGlassMode ?? this.liquidGlassMode,
    glassConfig: glassConfig ?? this.glassConfig,
    playlistArtworkColorsEnabled:
        playlistArtworkColorsEnabled ?? this.playlistArtworkColorsEnabled,
    flowingLightEnabled: flowingLightEnabled ?? this.flowingLightEnabled,
    lyricViewBlurDisabled: lyricViewBlurDisabled ?? this.lyricViewBlurDisabled,
    lyricAlignMode: lyricAlignMode ?? this.lyricAlignMode,
    lyricAlignModeLandscape:
        lyricAlignModeLandscape ?? this.lyricAlignModeLandscape,
    squareAlbumCoverEnabled:
        squareAlbumCoverEnabled ?? this.squareAlbumCoverEnabled,
    lyricFontWeight: lyricFontWeight ?? this.lyricFontWeight,
    lyricFontSize: lyricFontSize ?? this.lyricFontSize,
    autoPlayOnStartup: autoPlayOnStartup ?? this.autoPlayOnStartup,
    skipStartupScreen: skipStartupScreen ?? this.skipStartupScreen,
    checkForUpdatesOnStartup:
        checkForUpdatesOnStartup ?? this.checkForUpdatesOnStartup,
    ignoredAppUpdateVersion:
        ignoredAppUpdateVersion ?? this.ignoredAppUpdateVersion,
    networkAdapterMode: networkAdapterMode ?? this.networkAdapterMode,
    enabledSearchSources: enabledSearchSources ?? this.enabledSearchSources,
    defaultSearchSource: defaultSearchSource ?? this.defaultSearchSource,
    replaceQueueOnSearchPlay:
        replaceQueueOnSearchPlay ?? this.replaceQueueOnSearchPlay,
    discoverySourceOrder: discoverySourceOrder ?? this.discoverySourceOrder,
    platformButtonOnLeft: platformButtonOnLeft ?? this.platformButtonOnLeft,
    bottomBarBehavior: bottomBarBehavior ?? this.bottomBarBehavior,
    onlinePlaybackQualityWifi:
        onlinePlaybackQualityWifi ?? this.onlinePlaybackQualityWifi,
    onlinePlaybackQualityCellular:
        onlinePlaybackQualityCellular ?? this.onlinePlaybackQualityCellular,
    batchDownloadQuality: batchDownloadQuality ?? this.batchDownloadQuality,
    showMiniLyrics: showMiniLyrics ?? this.showMiniLyrics,
    grooveShiftEnabled: grooveShiftEnabled ?? this.grooveShiftEnabled,
    iosDynamicIslandEnabled:
        iosDynamicIslandEnabled ?? this.iosDynamicIslandEnabled,
    allowMixWithOthers: allowMixWithOthers ?? this.allowMixWithOthers,
    playerVolume: playerVolume ?? this.playerVolume,
    bluetoothLyricEnabled: bluetoothLyricEnabled ?? this.bluetoothLyricEnabled,
    bluetoothFullLyricEnabled:
        bluetoothFullLyricEnabled ?? this.bluetoothFullLyricEnabled,
    bluetoothLyricNoticeSeen:
        bluetoothLyricNoticeSeen ?? this.bluetoothLyricNoticeSeen,
    debugMode: debugMode ?? this.debugMode,
  );

  static const AppSettings fallback = AppSettings(
    downloadDir: kDefaultDownloadDir,
    localMusicDirs: [kDefaultDownloadDir],
    themeMode: ThemeMode.system,
    themeSeed: SeedPalette.defaultSeed,
    flowingLightEnabled: true,
    autoPlayOnStartup: false,
    skipStartupScreen: false,
    networkAdapterMode: NetworkAdapterMode.system,
    enabledSearchSources: kDefaultEnabledSearchSources,
    replaceQueueOnSearchPlay: true,
    discoverySourceOrder: kDefaultDiscoverySourceOrder,
    onlinePlaybackQualityWifi: OnlinePlaybackQuality.highest,
    onlinePlaybackQualityCellular: OnlinePlaybackQuality.highest,
    batchDownloadQuality: OnlinePlaybackQuality.highest,
    showMiniLyrics: true,
    allowMixWithOthers: false,
    bluetoothLyricEnabled: false,
    bluetoothFullLyricEnabled: false,
    bluetoothLyricNoticeSeen: false,
    debugMode: false,
  );
}

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('Override sharedPreferencesProvider before runApp');
});

/// 平台默认音乐扫描根目录。Android 用历史常量，iOS 在 main.dart 用
/// getApplicationDocumentsDirectory() 解析后 override。
final defaultMusicDirProvider = Provider<String>((ref) {
  return kDefaultDownloadDir;
});

/// 平台默认下载目录。iOS 默认为 Documents/MuyinMusic，与
/// download_service.dart 的兜底一致；iOS 在 main.dart override。
final defaultDownloadDirProvider = Provider<String>((ref) {
  return kDefaultDownloadDir;
});

class SettingsNotifier extends Notifier<AppSettings> {
  late SharedPreferences _prefs;

  @override
  AppSettings build() {
    _prefs = ref.read(sharedPreferencesProvider);
    hydrateNetworkAdapterPreference(_prefs);
    SafStorage.loadLabels(_prefs);
    if (_prefs.containsKey(_kLegacyBaseUrlKey)) {
      unawaited(_prefs.remove(_kLegacyBaseUrlKey));
    }
    final defaultScanDir = ref.read(defaultMusicDirProvider);
    final defaultDownloadDir = ref.read(defaultDownloadDirProvider);
    final defaults = _migrateIosDirectories(
      _prefs,
      defaultScanDir,
      defaultDownloadDir,
    );
    final downloadDir = defaults.downloadDir;
    final onlineQuality = _migrateOnlinePlaybackQuality(_prefs);
    final enabledSearchSources = _migrateQsSearchSource(
      _prefs,
      decodeEnabledSearchSources(
        _prefs.getStringList(_kEnabledSearchSourcesKey),
      ),
    );
    final defaultSearchSource = MusicSource.fromCode(
      _prefs.getString(_kDefaultSearchSourceKey) ?? 'all',
    );
    final checkForUpdatesOnStartup = _migrateAppUpdateStartupCheck(_prefs);
    return AppSettings(
      downloadDir: downloadDir,
      downloadFileNameFormat: DownloadFileNameFormat.fromCode(
        _prefs.getString(_kDownloadFileNameFormatKey),
      ),
      downloadGroupByArtist:
          _prefs.getBool(_kDownloadGroupByArtistKey) ?? false,
      ktvModeEnabled: _prefs.getBool(_kKtvModeEnabledKey) ?? false,
      ktvBackgroundStyle: KtvBackgroundStyle.fromCode(
        _prefs.getString(_kKtvBackgroundStyleKey),
      ),
      ktvBackgroundImagePath: _prefs.getString(_kKtvBackgroundImageKey),
      ktvBackgroundItems: _decodeKtvBackgroundItems(
        _prefs.getString(_kKtvBackgroundItemsKey),
      ),
      ktvBackgroundSelectedId: _prefs.getString(_kKtvBackgroundSelectedIdKey),
      portraitBackgroundSelectedId: _prefs.getString(
        _kPortraitBackgroundSelectedIdKey,
      ),
      localMusicDirs: _normalizeLocalMusicDirs(
        _prefs.getStringList(_kLocalMusicDirsKey) ??
            [_prefs.getString(_kLocalMusicDirKey) ?? defaults.scanDir],
        fallback: defaults.scanDir,
      ),
      ignoredLocalSongPaths: _normalizeIgnoredLocalSongPaths(
        _prefs.getStringList(_kLocalMusicIgnoredPathsKey) ?? const [],
      ),
      ignoredLocalSongRecords: _decodeIgnoredLocalSongRecords(
        _prefs.getString(_kLocalMusicIgnoredRecordsKey),
      ),
      useBuiltInSourceFilePicker:
          _prefs.getBool(_kUseBuiltInSourceFilePickerKey) ?? false,
      themeMode: _decodeThemeMode(_prefs.getString(_kThemeModeKey)),
      themeSeed: Color(
        _prefs.getInt(_kThemeSeedKey) ?? SeedPalette.defaultSeed.toARGB32(),
      ),
      themePalette: List<int>.unmodifiable({
        ...(_prefs
                    .getStringList(_kThemePaletteKey)
                    ?.map(int.tryParse)
                    .whereType<int>() ??
                SeedPalette.defaultColors)
            .where((color) => color >= 0 && color <= 0xFFFFFFFF),
        if (!_prefs.containsKey(_kThemePaletteKey) &&
            _prefs.containsKey(_kThemeSeedKey))
          _prefs.getInt(_kThemeSeedKey)!,
      }),
      glassConfig: GlassConfig.decode(_prefs.getString(_kGlassConfigKey)),
      liquidGlassMode: LiquidGlassMode.fromCode(
        _prefs.getString(_kLiquidGlassModeKey),
      ),
      playlistArtworkColorsEnabled:
          _prefs.getBool(_kPlaylistArtworkColorsEnabledKey) ?? true,
      flowingLightEnabled: _prefs.getBool(_kFlowingLightEnabledKey) ?? true,
      lyricViewBlurDisabled:
          _prefs.getBool(_kLyricViewBlurDisabledKey) ?? false,
      lyricAlignMode: LyricAlignMode.fromCode(
        _prefs.getString(_kLyricAlignModeKey),
      ),
      lyricAlignModeLandscape: LyricAlignMode.fromCode(
        _prefs.getString(_kLyricAlignModeLandscapeKey),
      ),
      squareAlbumCoverEnabled:
          _prefs.getBool(_kSquareAlbumCoverEnabledKey) ?? false,
      lyricFontWeight: _validLyricFontWeight(_prefs.get(_kLyricFontWeightKey))
          ? normalizeLyricFontWeight(
              (_prefs.get(_kLyricFontWeightKey) as num).toDouble(),
            )
          : kLyricFontWeightDefault,
      lyricFontSize: _validLyricFontSize(_prefs.get(_kLyricFontSizeKey))
          ? normalizeLyricFontSize(
              (_prefs.get(_kLyricFontSizeKey) as num).toDouble(),
            )
          : kLyricFontSizeDefault,
      autoPlayOnStartup: _prefs.getBool(_kAutoPlayOnStartupKey) ?? false,
      skipStartupScreen: _prefs.getBool(_kSkipStartupScreenKey) ?? false,
      checkForUpdatesOnStartup: checkForUpdatesOnStartup,
      ignoredAppUpdateVersion:
          _prefs.getString(_kIgnoredAppUpdateVersionKey) ?? '',
      networkAdapterMode: NetworkAdapterPreference.current,
      enabledSearchSources: enabledSearchSources,
      defaultSearchSource: enabledSearchSources.contains(defaultSearchSource)
          ? defaultSearchSource
          : MusicSource.all,
      replaceQueueOnSearchPlay:
          _prefs.getBool(_kReplaceQueueOnSearchPlayKey) ?? true,
      discoverySourceOrder: decodeDiscoverySourceOrder(
        _prefs.getStringList(_kDiscoverySourceOrderKey),
      ),
      platformButtonOnLeft: _prefs.getBool(_kPlatformButtonOnLeftKey) ?? false,
      bottomBarBehavior: BottomBarBehavior.fromCode(
        _prefs.getString(_kBottomBarBehaviorKey),
      ),
      onlinePlaybackQualityWifi: onlineQuality.wifi,
      onlinePlaybackQualityCellular: onlineQuality.cellular,
      batchDownloadQuality: OnlinePlaybackQuality.fromCode(
        _prefs.getString(_kBatchDownloadQualityKey),
      ),
      showMiniLyrics: _prefs.getBool(_kShowMiniLyricsKey) ?? true,
      grooveShiftEnabled: _prefs.getBool(_kGrooveShiftEnabledKey) ?? false,
      allowMixWithOthers: readAllowMixWithOthersPreference(_prefs),
      iosDynamicIslandEnabled:
          _prefs.getBool(_kIosDynamicIslandEnabledKey) ?? true,
      playerVolume: (_prefs.getDouble(_kPlayerVolumeKey) ?? 1.0).clamp(
        0.0,
        1.0,
      ),
      bluetoothLyricEnabled:
          _prefs.getBool(_kBluetoothLyricEnabledKey) ?? false,
      bluetoothFullLyricEnabled:
          _prefs.getBool(_kBluetoothFullLyricEnabledKey) ?? false,
      bluetoothLyricNoticeSeen:
          _prefs.getBool(_kBluetoothLyricNoticeSeenKey) ?? false,
      debugMode: _prefs.getBool(_kDebugModeKey) ?? false,
    );
  }

  Future<void> setDownloadDir(String value) async {
    final previousLocalPath = await SafStorage.resolveLocalPath(
      state.downloadDir,
      requireReadable: false,
    );
    final nextLocalPath = await SafStorage.resolveLocalPath(
      value,
      requireReadable: false,
    );
    final localMusicFollowsDownload =
        state.localMusicDirs.length == 1 &&
        (normalizeStorageLocation(state.localMusicDir) ==
                normalizeStorageLocation(state.downloadDir) ||
            (previousLocalPath != null &&
                normalizeStorageLocation(state.localMusicDir) ==
                    normalizeStorageLocation(previousLocalPath)));
    await _prefs.setString(_kDownloadDirKey, value);
    if (localMusicFollowsDownload && nextLocalPath != null) {
      final directories = _normalizeLocalMusicDirs([
        nextLocalPath,
      ], fallback: nextLocalPath);
      await _persistLocalMusicDirs(directories);
      state = state.copyWith(downloadDir: value, localMusicDirs: directories);
    } else {
      state = state.copyWith(downloadDir: value);
    }
  }

  Future<void> setDownloadFileNameFormat(DownloadFileNameFormat format) async {
    await _prefs.setString(_kDownloadFileNameFormatKey, format.code);
    state = state.copyWith(downloadFileNameFormat: format);
  }

  Future<void> setDownloadGroupByArtist(bool value) async {
    await _prefs.setBool(_kDownloadGroupByArtistKey, value);
    state = state.copyWith(downloadGroupByArtist: value);
  }

  Future<void> setKtvModeEnabled(bool value) async {
    await _prefs.setBool(_kKtvModeEnabledKey, value);
    state = state.copyWith(ktvModeEnabled: value);
  }

  Future<void> setIosDynamicIslandEnabled(bool value) async {
    await _prefs.setBool(_kIosDynamicIslandEnabledKey, value);
    state = state.copyWith(iosDynamicIslandEnabled: value);
  }

  Future<void> setLocalMusicDir(String value) => setLocalMusicDirs([value]);

  Future<void> setLocalMusicDirs(List<String> values) async {
    final directories = _normalizeLocalMusicDirs(
      values,
      fallback: state.downloadDir,
    );
    await _persistLocalMusicDirs(directories);
    state = state.copyWith(localMusicDirs: directories);
  }

  Future<void> _persistLocalMusicDirs(List<String> directories) async {
    await _prefs.setStringList(_kLocalMusicDirsKey, directories);
    await _prefs.setString(_kLocalMusicDirKey, directories.first);
  }

  static List<String> _normalizeLocalMusicDirs(
    List<String> values, {
    required String fallback,
  }) {
    final directories = <String>[];
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) continue;
      final directory = normalizeStorageLocation(trimmed);
      if (directories.any((existing) => existing == directory)) {
        continue;
      }
      directories.add(directory);
    }
    if (directories.isEmpty) {
      // fallback 由调用方传入，iOS 上是运行时解析出的默认目录；不再写死 Android 路径。
      directories.add(normalizeStorageLocation(fallback.trim()));
    }
    return List.unmodifiable(directories);
  }

  static List<String> _normalizeIgnoredLocalSongPaths(List<String> values) {
    final paths = <String>[];
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) continue;
      final path = normalizeStorageLocation(trimmed);
      if (!paths.contains(path)) paths.add(path);
    }
    return List.unmodifiable(paths);
  }

  /// 把歌曲加入忽略名单：文件保留，之后扫描不再把它们收进本地库。
  Future<void> ignoreLocalSongPaths(Iterable<String> paths) async {
    final merged = _normalizeIgnoredLocalSongPaths([
      ...state.ignoredLocalSongPaths,
      ...paths,
    ]);
    if (merged.length == state.ignoredLocalSongPaths.length) return;
    await _prefs.setStringList(_kLocalMusicIgnoredPathsKey, merged);
    state = state.copyWith(ignoredLocalSongPaths: merged);
  }

  /// 与 [ignoreLocalSongPaths] 相同，但同时带上展示信息（标题/歌手/
  /// 位置），供已忽略页辨认歌曲。路径集合的语义与合并规则不变。
  Future<void> ignoreLocalSongs(
    Iterable<IgnoredLocalSongRecord> records,
  ) async {
    final incoming = <String, IgnoredLocalSongRecord>{};
    for (final record in records) {
      final trimmed = record.path.trim();
      if (trimmed.isEmpty) continue;
      final path = normalizeStorageLocation(trimmed);
      incoming[path] = IgnoredLocalSongRecord(
        path: path,
        title: record.title.trim(),
        singer: record.singer.trim(),
        location: record.location.trim(),
      );
    }
    if (incoming.isEmpty) return;
    final mergedPaths = _normalizeIgnoredLocalSongPaths([
      ...state.ignoredLocalSongPaths,
      ...incoming.keys,
    ]);
    final mergedRecords = <String, IgnoredLocalSongRecord>{
      for (final record in state.ignoredLocalSongRecords)
        record.path: record,
      ...incoming,
    };
    final nextRecords = List<IgnoredLocalSongRecord>.unmodifiable([
      for (final path in mergedPaths)
        if (mergedRecords.containsKey(path)) mergedRecords[path]!,
    ]);
    final pathsChanged =
        mergedPaths.length != state.ignoredLocalSongPaths.length;
    final recordsChanged =
        nextRecords.length != state.ignoredLocalSongRecords.length ||
        nextRecords.any(
          (record) => !state.ignoredLocalSongRecords.contains(record),
        );
    if (!pathsChanged && !recordsChanged) return;
    if (pathsChanged) {
      await _prefs.setStringList(_kLocalMusicIgnoredPathsKey, mergedPaths);
    }
    if (recordsChanged) {
      await _prefs.setString(
        _kLocalMusicIgnoredRecordsKey,
        _encodeIgnoredLocalSongRecords(nextRecords),
      );
    }
    state = state.copyWith(
      ignoredLocalSongPaths: mergedPaths,
      ignoredLocalSongRecords: nextRecords,
    );
  }

  /// 把歌曲移出忽略名单；调用方随后触发重扫，歌曲才回到本地列表。
  Future<void> unignoreLocalSongPaths(Iterable<String> paths) async {
    final removed = {
      for (final path in paths)
        if (path.trim().isNotEmpty) normalizeStorageLocation(path.trim()),
    };
    if (removed.isEmpty) return;
    final remaining = state.ignoredLocalSongPaths
        .where((path) => !removed.contains(path))
        .toList();
    if (remaining.length == state.ignoredLocalSongPaths.length) return;
    await _prefs.setStringList(_kLocalMusicIgnoredPathsKey, remaining);
    final remainingRecords = List<IgnoredLocalSongRecord>.unmodifiable(
      state.ignoredLocalSongRecords.where(
        (record) => !removed.contains(record.path),
      ),
    );
    if (remainingRecords.length != state.ignoredLocalSongRecords.length) {
      await _prefs.setString(
        _kLocalMusicIgnoredRecordsKey,
        _encodeIgnoredLocalSongRecords(remainingRecords),
      );
    }
    state = state.copyWith(
      ignoredLocalSongPaths: List.unmodifiable(remaining),
      ignoredLocalSongRecords: remainingRecords,
    );
  }

  Future<void> setUseBuiltInSourceFilePicker(bool value) async {
    await _prefs.setBool(_kUseBuiltInSourceFilePickerKey, value);
    state = state.copyWith(useBuiltInSourceFilePicker: value);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await _prefs.setString(_kThemeModeKey, _encodeThemeMode(mode));
  }

  Future<void> setThemeSeed(Color color) async {
    await _prefs.setInt(_kThemeSeedKey, color.toARGB32());
    state = state.copyWith(themeSeed: color);
  }

  Future<void> selectThemeColor(Color color) async {
    await _prefs.setInt(_kThemeSeedKey, color.toARGB32());
    state = state.copyWith(themeSeed: color);
  }

  Future<void> saveThemeColor(Color color, {int? replacing}) async {
    final argb = color.toARGB32();
    final palette = [...state.themePalette];
    final index = replacing == null ? -1 : palette.indexOf(replacing);
    if (index >= 0) palette.removeAt(index);
    if (!palette.contains(argb)) {
      palette.insert(index < 0 ? palette.length : index, argb);
    }
    await _prefs.setStringList(
      _kThemePaletteKey,
      palette.map((value) => value.toString()).toList(),
    );
    state = state.copyWith(themePalette: List<int>.unmodifiable(palette));
    if (replacing == null || replacing == state.themeSeed.toARGB32()) {
      await selectThemeColor(color);
    }
  }

  Future<void> deleteThemeColor(int color) async {
    final palette = state.themePalette
        .where((value) => value != color)
        .toList();
    await _prefs.setStringList(
      _kThemePaletteKey,
      palette.map((value) => value.toString()).toList(),
    );
    state = state.copyWith(themePalette: List<int>.unmodifiable(palette));
    if (state.themeSeed.toARGB32() == color) {
      await selectThemeColor(SeedPalette.defaultSeed);
    }
  }

  Future<void> resetThemeColors() async {
    await _prefs.remove(_kThemePaletteKey);
    state = state.copyWith(themePalette: SeedPalette.defaultColors);
    await selectThemeColor(SeedPalette.defaultSeed);
  }

  /// 玻璃总开关。画质固定 ultra：开=ultra、关=none。
  Future<void> setGlassEnabled(bool value) =>
      setLiquidGlassMode(value ? LiquidGlassMode.ultra : LiquidGlassMode.none);

  Future<void> setGlassConfig(GlassConfig config) async {
    await _prefs.setString(_kGlassConfigKey, config.encode());
    state = state.copyWith(glassConfig: config);
  }

  Future<void> setGlassAppearance(GlassAppearance appearance) =>
      setGlassConfig(state.glassConfig.copyWith(appearance: appearance));

  Future<void> setGlassSettingsForTab(
    GlassAppearance tab,
    GlassSettings settings,
  ) => setGlassConfig(
    state.glassConfig.copyWith(
      tabs: state.glassConfig.tabs.withAppearance(tab, settings),
    ),
  );

  Future<void> setLiquidGlassMode(LiquidGlassMode mode) async {
    await _prefs.setString(_kLiquidGlassModeKey, mode.code);
    state = state.copyWith(liquidGlassMode: mode);
  }

  Future<void> setPlaylistArtworkColorsEnabled(bool value) async {
    await _prefs.setBool(_kPlaylistArtworkColorsEnabledKey, value);
    state = state.copyWith(playlistArtworkColorsEnabled: value);
  }

  Future<void> setFlowingLightEnabled(bool value) async {
    await _prefs.setBool(_kFlowingLightEnabledKey, value);
    state = state.copyWith(flowingLightEnabled: value);
  }

  Future<void> setKtvBackgroundStyle(KtvBackgroundStyle style) async {
    await _prefs.setString(_kKtvBackgroundStyleKey, style.code);
    state = state.copyWith(ktvBackgroundStyle: style);
  }

  Future<void> setKtvBackgroundImagePath(String? path) async {
    if (path == null) {
      await _prefs.remove(_kKtvBackgroundImageKey);
    } else {
      await _prefs.setString(_kKtvBackgroundImageKey, path);
    }
    state = state.copyWith(ktvBackgroundImagePath: path);
  }

  Future<void> _persistKtvBackgroundItems() async {
    await _prefs.setString(
      _kKtvBackgroundItemsKey,
      jsonEncode(
        state.ktvBackgroundItems.map((item) => item.toJson()).toList(),
      ),
    );
    final selectedId = state.ktvBackgroundSelectedId;
    if (selectedId == null) {
      await _prefs.remove(_kKtvBackgroundSelectedIdKey);
    } else {
      await _prefs.setString(_kKtvBackgroundSelectedIdKey, selectedId);
    }
  }

  /// 选用内置动态背景。
  Future<void> selectBuiltinKtvBackground() async {
    state = state.copyWith(ktvBackgroundStyle: KtvBackgroundStyle.builtin);
    await _prefs.setString(
      _kKtvBackgroundStyleKey,
      KtvBackgroundStyle.builtin.code,
    );
  }

  /// 把一张已复制进 ktv_backgrounds/ 的图片登记进图库并立即选用。
  Future<void> addKtvBackgroundItem(KtvBackgroundItem item) async {
    state = state.copyWith(
      ktvBackgroundItems: List.unmodifiable([
        for (final current in state.ktvBackgroundItems)
          if (current.id != item.id) current,
        item,
      ]),
      ktvBackgroundSelectedId: item.id,
      ktvBackgroundStyle: KtvBackgroundStyle.custom,
    );
    await _prefs.setString(
      _kKtvBackgroundStyleKey,
      KtvBackgroundStyle.custom.code,
    );
    await _persistKtvBackgroundItems();
  }

  /// 选用图库中的一张自定义背景。
  Future<void> selectKtvBackgroundItem(String id) async {
    if (!state.ktvBackgroundItems.any((item) => item.id == id)) return;
    state = state.copyWith(
      ktvBackgroundSelectedId: id,
      ktvBackgroundStyle: KtvBackgroundStyle.custom,
    );
    await _prefs.setString(
      _kKtvBackgroundStyleKey,
      KtvBackgroundStyle.custom.code,
    );
    await _persistKtvBackgroundItems();
  }

  Future<void> _persistPortraitBackgroundSelectedId() async {
    final selectedId = state.portraitBackgroundSelectedId;
    if (selectedId == null) {
      await _prefs.remove(_kPortraitBackgroundSelectedIdKey);
    } else {
      await _prefs.setString(_kPortraitBackgroundSelectedIdKey, selectedId);
    }
  }

  /// 把一张已复制进 ktv_backgrounds/ 的图片登记进共用图库并选为竖屏
  /// 播放页背景；不改动 KTV 的样式与选中。
  Future<void> addPortraitBackgroundItem(KtvBackgroundItem item) async {
    state = state.copyWith(
      ktvBackgroundItems: List.unmodifiable([
        for (final current in state.ktvBackgroundItems)
          if (current.id != item.id) current,
        item,
      ]),
      portraitBackgroundSelectedId: item.id,
    );
    await _persistKtvBackgroundItems();
    await _persistPortraitBackgroundSelectedId();
  }

  /// 选用图库中的一张图作竖屏播放页背景；与 KTV 选中互不影响。
  Future<void> selectPortraitBackgroundItem(String id) async {
    if (!state.ktvBackgroundItems.any((item) => item.id == id)) return;
    state = state.copyWith(portraitBackgroundSelectedId: id);
    await _persistPortraitBackgroundSelectedId();
  }

  /// 竖屏播放页恢复无图背景（流光）。
  Future<void> clearPortraitBackground() async {
    if (state.portraitBackgroundSelectedId == null) return;
    state = state.copyWith(portraitBackgroundSelectedId: null);
    await _persistPortraitBackgroundSelectedId();
  }

  Future<void> renameKtvBackgroundItem(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    state = state.copyWith(
      ktvBackgroundItems: List.unmodifiable([
        for (final item in state.ktvBackgroundItems)
          if (item.id == id) item.copyWith(name: trimmed) else item,
      ]),
    );
    await _persistKtvBackgroundItems();
  }

  /// 删除图库条目；删掉的是当前选中时切回内置动态背景。
  /// 返回被删条目，调用方负责删除它的图片文件。
  Future<KtvBackgroundItem?> removeKtvBackgroundItem(String id) async {
    KtvBackgroundItem? removed;
    final remaining = <KtvBackgroundItem>[];
    for (final item in state.ktvBackgroundItems) {
      if (item.id == id) {
        removed = item;
      } else {
        remaining.add(item);
      }
    }
    if (removed == null) return null;
    final wasSelected = state.ktvBackgroundSelectedId == id;
    final wasPortraitSelected = state.portraitBackgroundSelectedId == id;
    state = state.copyWith(
      ktvBackgroundItems: List.unmodifiable(remaining),
      ktvBackgroundSelectedId: wasSelected
          ? null
          : state.ktvBackgroundSelectedId,
      ktvBackgroundStyle: wasSelected
          ? KtvBackgroundStyle.builtin
          : state.ktvBackgroundStyle,
      portraitBackgroundSelectedId: wasPortraitSelected
          ? null
          : state.portraitBackgroundSelectedId,
    );
    if (wasSelected) {
      await _prefs.setString(
        _kKtvBackgroundStyleKey,
        KtvBackgroundStyle.builtin.code,
      );
    }
    await _persistKtvBackgroundItems();
    if (wasPortraitSelected) {
      await _persistPortraitBackgroundSelectedId();
    }
    return removed;
  }

  /// 一次性迁移：把旧版单张自定义背景图登记进图库。[copiedFileName] 是
  /// 调用方已复制到 ktv_backgrounds/ 的文件名；旧图不存在时传 null，
  /// 只落迁移标记。图库非空时不覆盖已有条目。
  Future<void> migrateLegacyKtvBackground(String? copiedFileName) async {
    if (_prefs.getBool(_kKtvBackgroundMigratedKey) ?? false) return;
    await _prefs.setBool(_kKtvBackgroundMigratedKey, true);
    if (copiedFileName == null || state.ktvBackgroundItems.isNotEmpty) return;
    final item = KtvBackgroundItem(
      id: 'legacy',
      name: '自定义背景',
      fileName: copiedFileName,
    );
    final wasCustom = state.ktvBackgroundStyle == KtvBackgroundStyle.custom;
    state = state.copyWith(
      ktvBackgroundItems: List.unmodifiable([item]),
      ktvBackgroundSelectedId: wasCustom
          ? item.id
          : state.ktvBackgroundSelectedId,
    );
    await _persistKtvBackgroundItems();
  }

  Future<void> setLyricViewBlurDisabled(bool value) async {
    await _prefs.setBool(_kLyricViewBlurDisabledKey, value);
    state = state.copyWith(lyricViewBlurDisabled: value);
  }

  Future<void> setLyricAlignMode(LyricAlignMode mode) async {
    await _prefs.setString(_kLyricAlignModeKey, mode.code);
    state = state.copyWith(lyricAlignMode: mode);
  }

  Future<void> setLyricAlignModeLandscape(LyricAlignMode mode) async {
    await _prefs.setString(_kLyricAlignModeLandscapeKey, mode.code);
    state = state.copyWith(lyricAlignModeLandscape: mode);
  }

  Future<void> setSquareAlbumCoverEnabled(bool value) async {
    await _prefs.setBool(_kSquareAlbumCoverEnabledKey, value);
    state = state.copyWith(squareAlbumCoverEnabled: value);
  }

  static bool _validLyricFontWeight(Object? value) =>
      value is num &&
      value.isFinite &&
      value >= kLyricFontWeightMin &&
      value <= kLyricFontWeightMax;

  static bool _validLyricFontSize(Object? value) =>
      value is num &&
      value.isFinite &&
      value >= kLyricFontSizeMin &&
      value <= kLyricFontSizeMax;

  Future<void> setLyricFontStyle({
    required double weight,
    required double size,
  }) async {
    if (!_validLyricFontWeight(weight) || !_validLyricFontSize(size)) {
      throw ArgumentError('歌词字体粗细或大小超出范围');
    }
    final nextWeight = normalizeLyricFontWeight(weight);
    final nextSize = normalizeLyricFontSize(size);
    if (state.lyricFontWeight == nextWeight &&
        state.lyricFontSize == nextSize) {
      return;
    }
    state = state.copyWith(
      lyricFontWeight: nextWeight,
      lyricFontSize: nextSize,
    );
    await _prefs.setDouble(_kLyricFontWeightKey, nextWeight);
    await _prefs.setDouble(_kLyricFontSizeKey, nextSize);
  }

  Future<void> setAutoPlayOnStartup(bool value) async {
    await _prefs.setBool(_kAutoPlayOnStartupKey, value);
    state = state.copyWith(autoPlayOnStartup: value);
  }

  Future<void> setSkipStartupScreen(bool value) async {
    await _prefs.setBool(_kSkipStartupScreenKey, value);
    state = state.copyWith(skipStartupScreen: value);
  }

  Future<void> setCheckForUpdatesOnStartup(bool value) async {
    await _prefs.setBool(_kCheckForUpdatesOnStartupKey, value);
    state = state.copyWith(checkForUpdatesOnStartup: value);
  }

  Future<void> setIgnoredAppUpdateVersion(String value) async {
    await _prefs.setString(_kIgnoredAppUpdateVersionKey, value);
    state = state.copyWith(ignoredAppUpdateVersion: value);
  }

  Map<String, dynamic> exportAppearanceForSync() => {
    'themeMode': _encodeThemeMode(state.themeMode),
    'themeSeedArgb': state.themeSeed.toARGB32(),
    'themePalette': state.themePalette,
    'glassConfig': state.glassConfig.encode(),
    'liquidGlassMode': state.liquidGlassMode.code,
    'playlistArtworkColorsEnabled': state.playlistArtworkColorsEnabled,
    'flowingLightEnabled': state.flowingLightEnabled,
    'iosDynamicIslandEnabled': state.iosDynamicIslandEnabled,
    'ktvBackgroundStyle': state.ktvBackgroundStyle.code,
    'ktvBackgroundItems': state.ktvBackgroundItems
        .map((item) => item.toJson())
        .toList(),
    'ktvBackgroundSelectedId': state.ktvBackgroundSelectedId,
    'lyricViewBlurDisabled': state.lyricViewBlurDisabled,
    'lyricAlignMode': state.lyricAlignMode.code,
    'squareAlbumCoverEnabled': state.squareAlbumCoverEnabled,
    'lyricFontWeight': state.lyricFontWeight,
    'lyricFontSize': state.lyricFontSize,
  };

  Future<void> applyAppearanceFromSync(Object value) async {
    if (value is! Map) throw const FormatException('云端外观设置格式无效');
    final json = Map<String, dynamic>.from(value);
    final rawMode = json['themeMode'];
    final rawSeed = json['themeSeedArgb'];
    // 旧备份里的 colorStyle / useDynamicColor 键一并忽略（这两项已移除）。
    if (rawMode is! String ||
        rawSeed is! int ||
        rawSeed < 0 ||
        rawSeed > 0xFFFFFFFF) {
      throw const FormatException('云端外观设置不完整');
    }
    if (!const {'system', 'light', 'dark'}.contains(rawMode)) {
      throw const FormatException('云端主题模式无效');
    }

    // 玻璃配置是单 JSON blob；非法类型直接拒绝，内容缺字段在 decode 里回退默认。
    final rawGlassConfig = json['glassConfig'];
    if (rawGlassConfig != null && rawGlassConfig is! String) {
      throw const FormatException('云端玻璃设置无效');
    }

    // flowingLightEnabled 同样是后加字段，缺失时保留本机开关。
    final rawFlowingLight = json['flowingLightEnabled'];
    final bool? syncedFlowingLight;
    if (rawFlowingLight == null) {
      syncedFlowingLight = null;
    } else if (rawFlowingLight is bool) {
      syncedFlowingLight = rawFlowingLight;
    } else {
      throw const FormatException('云端流光设置无效');
    }

    // iosDynamicIslandEnabled 同样是后加字段，缺失时保留本机开关。
    final rawIosDynamicIsland = json['iosDynamicIslandEnabled'];
    final bool? syncedIosDynamicIsland;
    if (rawIosDynamicIsland == null) {
      syncedIosDynamicIsland = null;
    } else if (rawIosDynamicIsland is bool) {
      syncedIosDynamicIsland = rawIosDynamicIsland;
    } else {
      throw const FormatException('云端灵动岛设置无效');
    }

    final rawLyricBlurDisabled = json['lyricViewBlurDisabled'];
    if (json.containsKey('lyricViewBlurDisabled') &&
        rawLyricBlurDisabled is! bool) {
      throw const FormatException('云端歌词视图模糊设置无效');
    }
    final rawSquareCover = json['squareAlbumCoverEnabled'];
    if (json.containsKey('squareAlbumCoverEnabled') &&
        rawSquareCover is! bool) {
      throw const FormatException('云端专辑封面设置无效');
    }

    final rawGlass = json['liquidGlassMode'];
    if (rawGlass != null &&
        (rawGlass is! String ||
            !LiquidGlassMode.values.any((mode) => mode.code == rawGlass))) {
      throw const FormatException('云端液态玻璃设置无效');
    }
    final syncedGlass = rawGlass == null
        ? state.liquidGlassMode
        : LiquidGlassMode.fromCode(rawGlass as String);
    // ktvBackgroundStyle 同样是后加字段，缺失时保留本机选择；图片路径是本机
    // 文件，不进同步。
    final rawKtvBackground = json['ktvBackgroundStyle'];
    // gradient / cover 是已下线的旧档位，fromCode 会把它们读成 builtin。
    if (rawKtvBackground != null &&
        (rawKtvBackground is! String ||
            (rawKtvBackground != 'gradient' &&
                rawKtvBackground != 'cover' &&
                !KtvBackgroundStyle.values.any(
                  (style) => style.code == rawKtvBackground,
                )))) {
      throw const FormatException('云端 KTV 背景设置无效');
    }
    final syncedKtvBackground = rawKtvBackground == null
        ? state.ktvBackgroundStyle
        : KtvBackgroundStyle.fromCode(rawKtvBackground as String);
    // 图库条目同样是后加字段，缺失时保留本机图库；条目里的文件名是相对
    // 名，图片实体不随同步迁移，目标设备缺图时背景回退内置动态。
    final rawKtvItems = json['ktvBackgroundItems'];
    if (rawKtvItems != null && rawKtvItems is! List) {
      throw const FormatException('云端 KTV 背景图库无效');
    }
    final syncedKtvItems = rawKtvItems == null
        ? state.ktvBackgroundItems
        : List<KtvBackgroundItem>.unmodifiable(
            (rawKtvItems as List)
                .map(KtvBackgroundItem.fromJson)
                .whereType<KtvBackgroundItem>(),
          );
    final rawKtvSelectedId = json['ktvBackgroundSelectedId'];
    if (rawKtvSelectedId != null && rawKtvSelectedId is! String) {
      throw const FormatException('云端 KTV 背景选择无效');
    }
    final syncedKtvSelectedId = json.containsKey('ktvBackgroundSelectedId')
        ? rawKtvSelectedId as String?
        : state.ktvBackgroundSelectedId;
    // lyricAlignMode 同样是后加字段，缺失时保留本机选择。
    final rawLyricAlign = json['lyricAlignMode'];
    if (rawLyricAlign != null &&
        (rawLyricAlign is! String ||
            !LyricAlignMode.values.any((mode) => mode.code == rawLyricAlign))) {
      throw const FormatException('云端歌词对齐设置无效');
    }
    final syncedLyricAlign = rawLyricAlign == null
        ? state.lyricAlignMode
        : LyricAlignMode.fromCode(rawLyricAlign as String);
    final rawPalette = json['themePalette'];
    if (rawPalette != null &&
        (rawPalette is! List ||
            rawPalette.any(
              (color) => color is! int || color < 0 || color > 0xFFFFFFFF,
            ))) {
      throw const FormatException('云端主题颜色列表无效');
    }
    final syncedPalette = List<int>.unmodifiable({
      ...(rawPalette == null
          ? state.themePalette
          : (rawPalette as List).cast<int>()),
      rawSeed,
    });
    // Old backups may contain customTheme. Ignore the retired editor settings.

    final rawLyricWeight = json['lyricFontWeight'];
    if (json.containsKey('lyricFontWeight') &&
        !_validLyricFontWeight(rawLyricWeight)) {
      throw const FormatException('云端歌词字体粗细无效');
    }
    final syncedLyricWeight = rawLyricWeight == null
        ? null
        : normalizeLyricFontWeight((rawLyricWeight as num).toDouble());
    final rawLyricSize = json['lyricFontSize'];
    if (json.containsKey('lyricFontSize') &&
        !_validLyricFontSize(rawLyricSize)) {
      throw const FormatException('云端歌词字体大小无效');
    }
    final syncedLyricSize = rawLyricSize == null
        ? null
        : normalizeLyricFontSize((rawLyricSize as num).toDouble());
    final rawPlaylistColors = json['playlistArtworkColorsEnabled'];
    if (json.containsKey('playlistArtworkColorsEnabled') &&
        rawPlaylistColors is! bool) {
      throw const FormatException('云端歌单动态配色设置无效');
    }
    final syncedPlaylistColors =
        rawPlaylistColors as bool? ?? state.playlistArtworkColorsEnabled;

    final next = state.copyWith(
      themeMode: _decodeThemeMode(rawMode),
      themeSeed: Color(rawSeed),
      themePalette: syncedPalette,
      glassConfig: rawGlassConfig == null
          ? state.glassConfig
          : GlassConfig.decode(rawGlassConfig as String),
      liquidGlassMode: syncedGlass,
      playlistArtworkColorsEnabled: syncedPlaylistColors,
      flowingLightEnabled: syncedFlowingLight,
      iosDynamicIslandEnabled: syncedIosDynamicIsland,
      ktvBackgroundStyle: syncedKtvBackground,
      ktvBackgroundItems: syncedKtvItems,
      ktvBackgroundSelectedId: syncedKtvSelectedId,
      lyricAlignMode: syncedLyricAlign,
      lyricViewBlurDisabled: rawLyricBlurDisabled as bool?,
      squareAlbumCoverEnabled: rawSquareCover as bool?,
      lyricFontWeight: syncedLyricWeight,
      lyricFontSize: syncedLyricSize,
    );
    await _prefs.setString(_kThemeModeKey, rawMode);
    await _prefs.setInt(_kThemeSeedKey, rawSeed);
    await _prefs.setStringList(
      _kThemePaletteKey,
      syncedPalette.map((color) => color.toString()).toList(),
    );
    if (rawGlassConfig != null) {
      await _prefs.setString(_kGlassConfigKey, rawGlassConfig as String);
    }
    if (syncedFlowingLight != null) {
      await _prefs.setBool(_kFlowingLightEnabledKey, syncedFlowingLight);
    }
    if (syncedIosDynamicIsland != null) {
      await _prefs.setBool(
        _kIosDynamicIslandEnabledKey,
        syncedIosDynamicIsland,
      );
    }
    if (rawLyricBlurDisabled != null) {
      await _prefs.setBool(_kLyricViewBlurDisabledKey, rawLyricBlurDisabled);
    }
    if (rawSquareCover != null) {
      await _prefs.setBool(_kSquareAlbumCoverEnabledKey, rawSquareCover);
    }
    if (syncedLyricWeight != null) {
      await _prefs.setDouble(_kLyricFontWeightKey, syncedLyricWeight);
    }
    if (syncedLyricSize != null) {
      await _prefs.setDouble(_kLyricFontSizeKey, syncedLyricSize);
    }
    await _prefs.setString(_kLiquidGlassModeKey, syncedGlass.code);
    await _prefs.setString(_kKtvBackgroundStyleKey, syncedKtvBackground.code);
    await _prefs.setString(
      _kKtvBackgroundItemsKey,
      jsonEncode(syncedKtvItems.map((item) => item.toJson()).toList()),
    );
    if (syncedKtvSelectedId == null) {
      await _prefs.remove(_kKtvBackgroundSelectedIdKey);
    } else {
      await _prefs.setString(_kKtvBackgroundSelectedIdKey, syncedKtvSelectedId);
    }
    await _prefs.setString(_kLyricAlignModeKey, syncedLyricAlign.code);
    await _prefs.setBool(
      _kPlaylistArtworkColorsEnabledKey,
      syncedPlaylistColors,
    );
    state = next;
  }

  Future<void> setNetworkAdapterMode(NetworkAdapterMode mode) async {
    NetworkAdapterPreference.current = mode;
    await _prefs.setString(_kNetworkAdapterModeKey, mode.code);
    state = state.copyWith(networkAdapterMode: mode);
  }

  Future<bool> setSearchSourceEnabled(MusicSource source, bool enabled) async {
    if (!kManageableSearchSources.contains(source)) return false;
    final next = {...state.enabledSearchSources};
    enabled ? next.add(source) : next.remove(source);
    if (next.isEmpty) return false;

    final ordered = {
      for (final candidate in kManageableSearchSources)
        if (next.contains(candidate)) candidate,
    };
    await _prefs.setStringList(
      _kEnabledSearchSourcesKey,
      ordered.map((candidate) => candidate.code).toList(growable: false),
    );
    final defaultSource = ordered.contains(state.defaultSearchSource)
        ? state.defaultSearchSource
        : MusicSource.all;
    if (defaultSource != state.defaultSearchSource) {
      await _prefs.setString(_kDefaultSearchSourceKey, defaultSource.code);
    }
    state = state.copyWith(
      enabledSearchSources: Set<MusicSource>.unmodifiable(ordered),
      defaultSearchSource: defaultSource,
    );
    return true;
  }

  Future<void> setDefaultSearchSource(MusicSource source) async {
    if (source != MusicSource.all &&
        !state.enabledSearchSources.contains(source)) {
      return;
    }
    await _prefs.setString(_kDefaultSearchSourceKey, source.code);
    state = state.copyWith(defaultSearchSource: source);
  }

  Future<void> setDiscoverySourceOrder(Iterable<MusicSource> sources) async {
    final order = normalizeDiscoverySourceOrder(sources);
    await _prefs.setStringList(
      _kDiscoverySourceOrderKey,
      order.map((source) => source.code).toList(growable: false),
    );
    state = state.copyWith(discoverySourceOrder: order);
  }

  Future<void> setReplaceQueueOnSearchPlay(bool value) async {
    await _prefs.setBool(_kReplaceQueueOnSearchPlayKey, value);
    state = state.copyWith(replaceQueueOnSearchPlay: value);
  }

  Future<void> setPlatformButtonOnLeft(bool value) async {
    state = state.copyWith(platformButtonOnLeft: value);
    await _prefs.setBool(_kPlatformButtonOnLeftKey, value);
  }

  Future<void> setBottomBarBehavior(BottomBarBehavior behavior) async {
    state = state.copyWith(bottomBarBehavior: behavior);
    await _prefs.setString(_kBottomBarBehaviorKey, behavior.code);
  }

  Future<void> setOnlinePlaybackQualityWifi(
    OnlinePlaybackQuality quality,
  ) async {
    await _prefs.setString(_kOnlinePlaybackQualityWifiKey, quality.code);
    state = state.copyWith(onlinePlaybackQualityWifi: quality);
  }

  Future<void> setOnlinePlaybackQualityCellular(
    OnlinePlaybackQuality quality,
  ) async {
    await _prefs.setString(_kOnlinePlaybackQualityCellularKey, quality.code);
    state = state.copyWith(onlinePlaybackQualityCellular: quality);
  }

  /// 兼容旧引用：等价于设置 WiFi 档。新代码按网络用上面两个方法。
  Future<void> setOnlinePlaybackQuality(OnlinePlaybackQuality quality) =>
      setOnlinePlaybackQualityWifi(quality);

  Future<void> setBatchDownloadQuality(OnlinePlaybackQuality quality) async {
    await _prefs.setString(_kBatchDownloadQualityKey, quality.code);
    state = state.copyWith(batchDownloadQuality: quality);
  }

  Future<void> setShowMiniLyrics(bool value) async {
    await _prefs.setBool(_kShowMiniLyricsKey, value);
    state = state.copyWith(showMiniLyrics: value);
  }

  Future<void> setGrooveShiftEnabled(bool value) async {
    await _prefs.setBool(_kGrooveShiftEnabledKey, value);
    state = state.copyWith(grooveShiftEnabled: value);
  }

  Future<void> setAllowMixWithOthers(bool value) async {
    await _prefs.setBool(_kAllowMixWithOthersKey, value);
    state = state.copyWith(allowMixWithOthers: value);
  }

  Future<void> setPlayerVolume(double value) async {
    final volume = value.clamp(0.0, 1.0);
    await _prefs.setDouble(_kPlayerVolumeKey, volume);
    state = state.copyWith(playerVolume: volume);
  }

  Future<void> setBluetoothLyricEnabled(bool value) async {
    await _prefs.setBool(_kBluetoothLyricEnabledKey, value);
    state = state.copyWith(bluetoothLyricEnabled: value);
  }

  Future<void> setBluetoothFullLyricEnabled(bool value) async {
    await _prefs.setBool(_kBluetoothFullLyricEnabledKey, value);
    state = state.copyWith(bluetoothFullLyricEnabled: value);
  }

  Future<void> markBluetoothLyricNoticeSeen() async {
    if (state.bluetoothLyricNoticeSeen) return;
    await _prefs.setBool(_kBluetoothLyricNoticeSeenKey, true);
    state = state.copyWith(bluetoothLyricNoticeSeen: true);
  }

  Future<void> setDebugMode(bool value) async {
    await _prefs.setBool(_kDebugModeKey, value);
    state = state.copyWith(debugMode: value);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

bool readAllowMixWithOthersPreference(SharedPreferences preferences) =>
    preferences.getBool(_kAllowMixWithOthersKey) ?? false;

String _encodeThemeMode(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.system:
      return 'system';
    case ThemeMode.light:
      return 'light';
    case ThemeMode.dark:
      return 'dark';
  }
}

ThemeMode _decodeThemeMode(String? raw) {
  switch (raw) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

void hydrateNetworkAdapterPreference(SharedPreferences prefs) {
  NetworkAdapterPreference.current = NetworkAdapterMode.fromCode(
    prefs.getString(_kNetworkAdapterModeKey),
  );
}

Set<MusicSource> decodeEnabledSearchSources(List<String>? codes) {
  if (codes == null) return kDefaultEnabledSearchSources;
  final decoded = <MusicSource>{};
  for (final code in codes) {
    final source = MusicSource.tryFromCode(code);
    if (source != null && kManageableSearchSources.contains(source)) {
      decoded.add(source);
    }
  }
  if (decoded.isEmpty) return kDefaultEnabledSearchSources;
  return Set<MusicSource>.unmodifiable({
    for (final source in kManageableSearchSources)
      if (decoded.contains(source)) source,
  });
}

/// 新旧在线播放音质设置的迁移结果（内存值），prefs 异步落盘。
class _OnlineQuality {
  const _OnlineQuality({required this.wifi, required this.cellular});
  final OnlinePlaybackQuality wifi;
  final OnlinePlaybackQuality cellular;
}

/// 旧版本只有一个在线播放音质 key。首次升级时把它里的值同时写进
/// WiFi / 移动流量两个新 key，避免老用户设置丢失；随后删除旧 key。
_OnlineQuality _migrateOnlinePlaybackQuality(SharedPreferences prefs) {
  var wifi = prefs.getString(_kOnlinePlaybackQualityWifiKey);
  var cellular = prefs.getString(_kOnlinePlaybackQualityCellularKey);
  if (prefs.getBool(_kOnlinePlaybackQualitySplitKey) != true) {
    final legacy = prefs.getString(_kOnlinePlaybackQualityKey);
    if (legacy != null) {
      wifi ??= legacy;
      cellular ??= legacy;
      unawaited(prefs.setString(_kOnlinePlaybackQualityWifiKey, legacy));
      unawaited(prefs.setString(_kOnlinePlaybackQualityCellularKey, legacy));
      unawaited(prefs.remove(_kOnlinePlaybackQualityKey));
    }
    unawaited(prefs.setBool(_kOnlinePlaybackQualitySplitKey, true));
  }
  return _OnlineQuality(
    wifi: OnlinePlaybackQuality.fromCode(wifi),
    cellular: OnlinePlaybackQuality.fromCode(cellular),
  );
}

/// 旧版更新弹窗的「忽略更新」会把启动检查全局关掉，且设置里没有重新打开的
/// 入口，误点一次就再也收不到新版本提示。这里做一次复位：把被旧逻辑关掉的
/// 启动检查恢复为开；之后「忽略」只针对单个版本（见 ignoredAppUpdateVersion）。
bool _migrateAppUpdateStartupCheck(SharedPreferences prefs) {
  if (prefs.getBool(_kAppUpdateStartupCheckResetKey) != true) {
    unawaited(prefs.setBool(_kAppUpdateStartupCheckResetKey, true));
    if (prefs.getBool(_kCheckForUpdatesOnStartupKey) == false) {
      unawaited(prefs.setBool(_kCheckForUpdatesOnStartupKey, true));
      return true;
    }
  }
  return prefs.getBool(_kCheckForUpdatesOnStartupKey) ?? true;
}

/// A saved list only ever contains the sources that existed when the user last
/// touched the setting, so a newly added platform has to be merged in once.
/// Without this an upgrade keeps 汽水音乐 out of search with no way to tell why.
Set<MusicSource> _migrateQsSearchSource(
  SharedPreferences prefs,
  Set<MusicSource> current,
) {
  if (prefs.getBool(_kQsSearchAddedKey) == true) return current;
  final merged = Set<MusicSource>.unmodifiable({
    for (final source in kManageableSearchSources)
      if (current.contains(source) || source == MusicSource.qs) source,
  });
  unawaited(
    prefs.setStringList(
      _kEnabledSearchSourcesKey,
      merged.map((source) => source.code).toList(growable: false),
    ),
  );
  unawaited(prefs.setBool(_kQsSearchAddedKey, true));
  return merged;
}

/// iOS 存量目录迁移结果：build() 同步使用这些内存值，prefs 异步落盘。
class _IosDirectories {
  const _IosDirectories({required this.downloadDir, required this.scanDir});
  final String downloadDir;
  final String scanDir;
}

/// 早期 iOS 版本把 Android 路径 /storage/emulated/0/... 写进了设置。
/// 一次性把 download_dir 与 local_music_dirs 换成运行时解析出的 iOS 默认目录。
_IosDirectories _migrateIosDirectories(
  SharedPreferences prefs,
  String defaultScanDir,
  String defaultDownloadDir,
) {
  var downloadDir = prefs.getString(_kDownloadDirKey);
  var scanDirs = prefs.getStringList(_kLocalMusicDirsKey);
  final legacyScan = prefs.getString(_kLocalMusicDirKey);

  bool isAndroidPath(String value) => value.startsWith('/storage/emulated/');

  // 侧载 App 升级/重装后 Documents 容器的 UUID 会变。持久化的是绝对路径，
  // 若仍指向旧 UUID：下载落到新容器、扫描却盯旧路径，saved 事件的 owner
  // 归属判断失败被静默丢弃，表现为「下载成功但扫描不到」。
  // 每次启动校验：只刷新落在沙盒容器内但 UUID 已过期的路径；用户手动选的
  // 外部目录（不含此标记）原样保留。
  const marker = '/Containers/Data/Application/';
  final idx = defaultScanDir.indexOf(marker);
  final currentUuid = idx < 0
      ? ''
      : defaultScanDir.substring(idx + marker.length).split('/').first;
  bool stale(String value) {
    if (currentUuid.isEmpty) return false;
    final i = value.indexOf(marker);
    if (i < 0) return false;
    return value.substring(i + marker.length).split('/').first != currentUuid;
  }

  if (Platform.isIOS) {
    if (downloadDir != null && stale(downloadDir)) {
      downloadDir = defaultDownloadDir;
      unawaited(prefs.setString(_kDownloadDirKey, downloadDir));
    }
    if (scanDirs != null && scanDirs.isNotEmpty) {
      var changed = false;
      final refreshed = <String>[];
      for (final dir in scanDirs) {
        final value = stale(dir) ? defaultScanDir : dir;
        if (value != dir) changed = true;
        if (refreshed.contains(value)) {
          changed = true;
        } else {
          refreshed.add(value);
        }
      }
      if (changed) {
        scanDirs = refreshed;
        unawaited(prefs.setStringList(_kLocalMusicDirsKey, scanDirs));
      }
    }
    if (legacyScan != null && stale(legacyScan)) {
      unawaited(prefs.setString(_kLocalMusicDirKey, defaultScanDir));
    }
  }

  // 一次性迁移旧版本写入的 Android 路径。
  if (Platform.isIOS && prefs.getBool(_kIosDirMigratedKey) != true) {
    if (downloadDir == null || isAndroidPath(downloadDir)) {
      downloadDir = defaultDownloadDir;
      unawaited(prefs.setString(_kDownloadDirKey, downloadDir));
    }
    if (scanDirs == null || scanDirs.isEmpty) {
      scanDirs = [defaultScanDir];
      unawaited(prefs.setStringList(_kLocalMusicDirsKey, scanDirs));
    } else if (scanDirs.any(isAndroidPath)) {
      // 剔除 Android 路径；若剔除后为空则回落到 iOS 默认扫描目录。
      final kept = scanDirs.where((dir) => !isAndroidPath(dir)).toList();
      scanDirs = kept.isEmpty ? [defaultScanDir] : kept;
      unawaited(prefs.setStringList(_kLocalMusicDirsKey, scanDirs));
    }
    if (legacyScan == null || isAndroidPath(legacyScan)) {
      unawaited(prefs.setString(_kLocalMusicDirKey, defaultScanDir));
    }
    unawaited(prefs.setBool(_kIosDirMigratedKey, true));
  }

  // 下载根与扫描根同源：iOS 上让下载目录始终是扫描根下的 MuyinMusic，
  // 保证落点归属判断恒成立（对齐 Cymusic「固定自有目录」的做法）。
  if (Platform.isIOS) {
    final scanRoot = scanDirs?.isEmpty == true
        ? defaultScanDir
        : (scanDirs?.first ?? defaultScanDir);
    final derived = p.join(scanRoot, 'MuyinMusic');
    if (downloadDir == null ||
        isAndroidPath(downloadDir) ||
        stale(downloadDir)) {
      downloadDir = derived;
    } else {
      final dl = normalizeStorageLocation(downloadDir);
      final expected = normalizeStorageLocation(derived);
      final root = normalizeStorageLocation(scanRoot);
      if (dl != expected && dl != root) downloadDir = derived;
    }
  }

  return _IosDirectories(
    downloadDir: downloadDir ?? defaultDownloadDir,
    scanDir: scanDirs?.isEmpty == true
        ? defaultScanDir
        : (scanDirs?.first ?? defaultScanDir),
  );
}

const List<MusicSource> kDefaultDiscoverySourceOrder = <MusicSource>[
  MusicSource.wy,
  MusicSource.tx,
  MusicSource.kw,
  MusicSource.kg,
  MusicSource.mg,
  MusicSource.qs,
];

List<MusicSource> decodeDiscoverySourceOrder(List<String>? codes) {
  if (codes == null) return kDefaultDiscoverySourceOrder;
  return normalizeDiscoverySourceOrder(
    codes.map(MusicSource.tryFromCode).nonNulls,
  );
}

List<MusicSource> normalizeDiscoverySourceOrder(Iterable<MusicSource> sources) {
  final order = <MusicSource>[];
  for (final source in sources) {
    if (kDefaultDiscoverySourceOrder.contains(source) &&
        !order.contains(source)) {
      order.add(source);
    }
  }
  for (final source in kDefaultDiscoverySourceOrder) {
    if (!order.contains(source)) order.add(source);
  }
  return List<MusicSource>.unmodifiable(order);
}

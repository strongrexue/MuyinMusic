import '../../theme/app_theme.dart';
import 'widgets/settings_sheet.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../core/app_info.dart';
import '../../core/api/dio_factory.dart';
import '../../core/models/enums.dart';
import '../../core/music_sources/music_source_controller.dart';
import '../../core/services/permission_service.dart';
import '../../core/services/saf_storage.dart';
import '../../core/services/storage_location.dart';
import '../../core/services/app_icon_service.dart';
import '../../core/storage/settings_store.dart';
import '../../core/sync/webdav_sync_controller.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/car_display_layout.dart';
import '../debug/widgets/log_recording_menu.dart';
import '../shell/shell_toolbar_visibility.dart';
import '../shell/shell_bottom_area.dart';
import '../shell/widgets/scrolling_page_header.dart';
import '../songs/local_song_scan_cache.dart';
import '../update/app_update_prompt.dart';
import 'settings_section.dart';
import 'widgets/app_icon_sheet.dart';
import 'widgets/appearance_theme_settings.dart';
import 'widgets/discovery_source_order_sheet.dart';
import 'widgets/settings_action.dart';
import 'widgets/settings_menu.dart';
import 'widgets/storage_permission_card.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key, this.section});

  final SettingsSection? section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final sourceState = section == SettingsSection.network
        ? ref.watch(musicSourceControllerProvider)
        : null;
    final webDavState =
        section == SettingsSection.sync || section == SettingsSection.network
        ? ref.watch(webDavSyncControllerProvider)
        : null;
    final appIcon =
        section == SettingsSection.appearance && supportsCustomAppIcons
        ? ref.watch(appIconProvider)
        : null;
    final versionLabel = ref.watch(appVersionLabelProvider);
    final baseTheme = Theme.of(context);
    final scheme = baseTheme.colorScheme;

    return Theme(
      data: baseTheme.copyWith(
        scaffoldBackgroundColor: scheme.appSettingsSurface,
      ),
      child: Scaffold(
        backgroundColor: scheme.appSettingsSurface,
        body: CustomScrollView(
          key: PageStorageKey('settings-${section?.name ?? 'overview'}-scroll'),
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            const SliverToBoxAdapter(child: ScrollHeaderSpacer()),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                ShellBottomArea.contentPadding(context, 118),
              ),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: CarDisplayLayout.contentConstraints(
                      context,
                      maxWidth: 640,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (section == null)
                          SettingsCard(
                            title: null,
                            children: [
                              for (final category in SettingsSection.values)
                                SettingsAction(
                                  key: ValueKey('settings-${category.name}'),
                                  icon: category.icon,
                                  title: category.title,
                                  trailing: Icons.chevron_right_rounded,
                                  destination: category.location,
                                ),
                            ],
                          ),
                        if (section == SettingsSection.network)
                          SettingsCard(
                            title: null,
                            children: [
                              SettingsAction(
                                icon: Symbols.audio_file,
                                title: '音源管理',
                                value: sourceState!.when(
                                  data: (value) => value.primary == null
                                      ? '未启用音源'
                                      : '已启用 ${value.enabledIds.length} 个 · '
                                            '首选：${value.primary!.name}',
                                  loading: () => '正在加载音源',
                                  error: (_, _) => '音源状态读取失败',
                                ),
                                trailing: Symbols.chevron_right,
                                destination: '/settings/sources',
                              ),
                              SettingsSwitchAction(
                                key: const ValueKey(
                                  'source-file-picker-setting',
                                ),
                                icon: Icons.snippet_folder_outlined,
                                title: '音源内置文件选择器',
                                value: settings.useBuiltInSourceFilePicker,
                                onChanged: (value) => ref
                                    .read(settingsProvider.notifier)
                                    .setUseBuiltInSourceFilePicker(value),
                              ),
                              SettingsMenuAction(
                                key: const ValueKey('network-adapter-menu'),
                                menuId: 'network-adapter-menu',
                                icon: Icons.cable_rounded,
                                title: '网络适配器',
                                options: [
                                  for (final mode in NetworkAdapterMode.values)
                                    SettingsMenuOption(
                                      id: mode.code,
                                      label: mode.label,
                                      selected:
                                          mode == settings.networkAdapterMode,
                                      onSelected: () => _setNetworkAdapter(
                                        context,
                                        ref,
                                        mode,
                                      ),
                                    ),
                                ],
                              ),
                              SettingsAction(
                                key: const ValueKey('discovery-source-order'),
                                icon: Icons.explore_outlined,
                                title: '发现页平台顺序',
                                trailing: Icons.chevron_right_rounded,
                                onTap: () => unawaited(
                                  _showDiscoverySourceOrderSheet(context, ref),
                                ),
                              ),
                            ],
                          ),
                        if (section == SettingsSection.playback)
                          SettingsCard(
                            title: null,
                            children: [
                              SettingsMenuAction(
                                key: const ValueKey('search-source-menu'),
                                menuId: 'search-source-menu',
                                icon: Icons.manage_search_rounded,
                                title: '搜索源管理',
                                multiSelect: true,
                                options: [
                                  for (final source in kManageableSearchSources)
                                    SettingsMenuOption(
                                      id: source.code,
                                      label: source.label,
                                      selected: settings.enabledSearchSources
                                          .contains(source),
                                      enabled:
                                          settings
                                                  .enabledSearchSources
                                                  .length !=
                                              1 ||
                                          !settings.enabledSearchSources
                                              .contains(source),
                                      onSelected: () => _setSearchSourceEnabled(
                                        context,
                                        ref,
                                        source,
                                        !settings.enabledSearchSources.contains(
                                          source,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              SettingsMenuAction(
                                key: const ValueKey(
                                  'default-search-source-menu',
                                ),
                                menuId: 'default-search-source-menu',
                                icon: Icons.search_rounded,
                                title: '默认搜索平台',
                                options: [
                                  for (final source in kSearchSources)
                                    SettingsMenuOption(
                                      id: source.code,
                                      label: source == MusicSource.all
                                          ? '聚合'
                                          : source.label,
                                      selected:
                                          source ==
                                          settings.defaultSearchSource,
                                      enabled:
                                          source == MusicSource.all ||
                                          settings.enabledSearchSources
                                              .contains(source),
                                      onSelected: () => ref
                                          .read(settingsProvider.notifier)
                                          .setDefaultSearchSource(source),
                                    ),
                                ],
                              ),
                              SettingsMenuAction(
                                key: const ValueKey('online-quality-menu'),
                                menuId: 'online-quality-menu',
                                icon: Icons.wifi_rounded,
                                title: '在线播放音质（WiFi）',
                                options: [
                                  for (final quality
                                      in OnlinePlaybackQuality.values)
                                    SettingsMenuOption(
                                      id: quality.code,
                                      label: quality.label,
                                      selected:
                                          quality ==
                                          settings.onlinePlaybackQualityWifi,
                                      onSelected: () =>
                                          _setOnlinePlaybackQualityWifi(
                                            context,
                                            ref,
                                            quality,
                                          ),
                                    ),
                                ],
                              ),
                              SettingsMenuAction(
                                menuId: 'online-quality-menu-cellular',
                                icon: Icons.signal_cellular_alt_rounded,
                                title: '在线播放音质（移动流量）',
                                options: [
                                  for (final quality
                                      in OnlinePlaybackQuality.values)
                                    SettingsMenuOption(
                                      id: quality.code,
                                      label: quality.label,
                                      selected:
                                          quality ==
                                          settings
                                              .onlinePlaybackQualityCellular,
                                      onSelected: () =>
                                          _setOnlinePlaybackQualityCellular(
                                            context,
                                            ref,
                                            quality,
                                          ),
                                    ),
                                ],
                              ),
                              SettingsSwitchAction(
                                key: const ValueKey(
                                  'auto-play-on-startup-setting',
                                ),
                                icon: Icons.play_circle_outline_rounded,
                                title: '启动后自动播放',
                                value: settings.autoPlayOnStartup,
                                onChanged: (value) => ref
                                    .read(settingsProvider.notifier)
                                    .setAutoPlayOnStartup(value),
                              ),
                              const SizedBox(height: 4),
                              SettingsSwitchAction(
                                key: const ValueKey('groove-shift-setting'),
                                icon: Icons.auto_awesome_rounded,
                                title: '智能过渡',
                                value: settings.grooveShiftEnabled,
                                onChanged: (value) => ref
                                    .read(settingsProvider.notifier)
                                    .setGrooveShiftEnabled(value),
                              ),
                              SettingsSwitchAction(
                                key: const ValueKey(
                                  'allow-mix-with-others-setting',
                                ),
                                icon: Icons.multitrack_audio_rounded,
                                title: '允许与其他 APP 共同播放',
                                value: settings.allowMixWithOthers,
                                onChanged: (value) => ref
                                    .read(settingsProvider.notifier)
                                    .setAllowMixWithOthers(value),
                              ),
                              if (Platform.isIOS)
                                SettingsSwitchAction(
                                  key: const ValueKey(
                                    'ios-dynamic-island-setting',
                                  ),
                                  icon: Icons.phone_iphone_rounded,
                                  title: '启用灵动岛',
                                  subtitle: '关闭后不再显示灵动岛与锁屏播放卡片',
                                  value: settings.iosDynamicIslandEnabled,
                                  onChanged: (value) => ref
                                      .read(settingsProvider.notifier)
                                      .setIosDynamicIslandEnabled(value),
                                ),
                              SettingsSwitchAction(
                                key: const ValueKey('bluetooth-lyric-setting'),
                                icon: Icons.bluetooth_audio_rounded,
                                title: '显示蓝牙歌词',
                                value: settings.bluetoothLyricEnabled,
                                onChanged: (value) => _setBluetoothLyricEnabled(
                                  context,
                                  ref,
                                  value,
                                ),
                              ),
                              SettingsSwitchAction(
                                key: const ValueKey(
                                  'bluetooth-full-lyric-setting',
                                ),
                                icon: Icons.lyrics_rounded,
                                title: '显示完整蓝牙歌词',
                                value: settings.bluetoothFullLyricEnabled,
                                onChanged: (value) =>
                                    _setBluetoothFullLyricEnabled(
                                      context,
                                      ref,
                                      value,
                                    ),
                              ),
                            ],
                          ),
                        if (section == SettingsSection.permissions) ...[
                          const StoragePermissionCard(),
                          const SizedBox(height: 24),
                        ],
                        if (section == SettingsSection.sync)
                          SettingsCard(
                            title: null,
                            children: [
                              SettingsAction(
                                key: const ValueKey('webdav-sync-setting'),
                                icon: Icons.cloud_sync_outlined,
                                title: 'WebDAV 同步',
                                value: _webDavSubtitle(webDavState!),
                                trailing: Symbols.chevron_right,
                                destination: '/settings/webdav',
                              ),
                            ],
                          ),
                        if (section == SettingsSection.downloads)
                          SettingsCard(
                            title: '下载',
                            children: [
                              SettingsMenuAction(
                                key: const ValueKey(
                                  'batch-download-quality-menu',
                                ),
                                menuId: 'batch-download-quality-menu',
                                icon: Icons.download_for_offline_rounded,
                                title: '批量下载音质',
                                options: [
                                  for (final quality
                                      in OnlinePlaybackQuality.values)
                                    SettingsMenuOption(
                                      id: quality.code,
                                      label: quality.label,
                                      selected:
                                          quality ==
                                          settings.batchDownloadQuality,
                                      onSelected: () =>
                                          _setBatchDownloadQuality(
                                            context,
                                            ref,
                                            quality,
                                          ),
                                    ),
                                ],
                              ),
                              SettingsMenuAction(
                                key: const ValueKey('download-file-name-menu'),
                                menuId: 'download-file-name-menu',
                                icon: Icons.drive_file_rename_outline_rounded,
                                title: '文件命名方式',
                                options: [
                                  for (final format
                                      in DownloadFileNameFormat.values)
                                    SettingsMenuOption(
                                      id: format.code,
                                      label: format.label,
                                      selected:
                                          format ==
                                          settings.downloadFileNameFormat,
                                      onSelected: () => ref
                                          .read(settingsProvider.notifier)
                                          .setDownloadFileNameFormat(format),
                                    ),
                                ],
                              ),
                              SettingsSwitchAction(
                                key: const ValueKey(
                                  'download-group-by-artist-switch',
                                ),
                                icon: Icons.create_new_folder_outlined,
                                title: '按歌手分文件夹',
                                subtitle: '文件保存到以歌手命名的子文件夹',
                                value: settings.downloadGroupByArtist,
                                onChanged: (value) => ref
                                    .read(settingsProvider.notifier)
                                    .setDownloadGroupByArtist(value),
                              ),
                              SettingsAction(
                                icon: Icons.folder_outlined,
                                title: '下载位置',
                                value: SafStorage.label(settings.downloadDir),
                                trailing: Symbols.chevron_right,
                                onTap: () => _pickDownloadDir(context, ref),
                              ),
                              SettingsFooter(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    16,
                                    16,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Wrap(
                                      spacing: 10,
                                      runSpacing: 8,
                                      children: [
                                        FilledButton.tonalIcon(
                                          onPressed: () =>
                                              _resetDownloadDir(context, ref),
                                          icon: VariedIcon.varied(
                                            Symbols.restart_alt,
                                            size: 18,
                                            weight: 300,
                                          ),
                                          label: const Text('恢复默认'),
                                          style: FilledButton.styleFrom(
                                            minimumSize: const Size(0, 40),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 20,
                                              vertical: 10,
                                            ),
                                            shape: const StadiumBorder(),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        if (section == SettingsSection.downloads) ...[
                          const SizedBox(height: 24),
                          SettingsCard(
                            title: '音乐扫描',
                            children: [
                              for (final (_, directory)
                                  in settings.localMusicDirs.indexed)
                                Row(
                                  children: [
                                    Expanded(
                                      child: SettingsAction(
                                        icon: Icons.library_music_outlined,
                                        title: '目录',
                                        value: SafStorage.label(directory),
                                        trailing: Symbols.chevron_right,
                                        onTap: () => _pickLocalMusicDir(
                                          context,
                                          ref,
                                          replacing: directory,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '移除扫描文件夹',
                                      onPressed:
                                          settings.localMusicDirs.length > 1
                                          ? () => _removeLocalMusicDir(
                                              context,
                                              ref,
                                              directory,
                                            )
                                          : null,
                                      icon: const Icon(
                                        Icons.remove_circle_outline_rounded,
                                      ),
                                    ),
                                  ],
                                ),
                              SettingsAction(
                                icon: Icons.create_new_folder_outlined,
                                title: '添加目录',
                                trailing: Icons.add_rounded,
                                onTap: () => _pickLocalMusicDir(context, ref),
                              ),
                              SettingsFooter(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    16,
                                    16,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Wrap(
                                      spacing: 10,
                                      runSpacing: 8,
                                      children: [
                                        FilledButton.tonalIcon(
                                          onPressed: () =>
                                              _resetLocalMusicDir(context, ref),
                                          icon: const Icon(
                                            Icons.sync_rounded,
                                            size: 18,
                                          ),
                                          label: const Text('仅扫描下载位置'),
                                          style: FilledButton.styleFrom(
                                            minimumSize: const Size(0, 40),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 20,
                                              vertical: 10,
                                            ),
                                            shape: const StadiumBorder(),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (section == SettingsSection.appearance) ...[
                          const AppearanceThemeSettings(),
                          const SizedBox(height: 16),
                          SettingsCard(
                            title: null,
                            children: [
                              SettingsSwitchAction(
                                key: const ValueKey(
                                  'skip-startup-screen-setting',
                                ),
                                icon: Icons.skip_next_rounded,
                                title: '跳过启动页',
                                value: settings.skipStartupScreen,
                                onChanged: (value) => ref
                                    .read(settingsProvider.notifier)
                                    .setSkipStartupScreen(value),
                              ),
                              if (supportsCustomAppIcons)
                                SettingsAction(
                                  icon: Icons.apps_rounded,
                                  title: '应用图标',
                                  value: appIcon?.isLoading == true
                                      ? '读取中'
                                      : appIcon?.hasError == true
                                      ? '读取失败'
                                      : appIcon?.valueOrNull?.label ?? '经典白',
                                  trailing: Icons.chevron_right,
                                  onTap: () => _chooseAppIcon(context, ref),
                                ),
                              SettingsSwitchAction(
                                icon: Icons.auto_awesome_outlined,
                                title: '歌单详情动态配色',
                                value: settings.playlistArtworkColorsEnabled,
                                onChanged: (value) => ref
                                    .read(settingsProvider.notifier)
                                    .setPlaylistArtworkColorsEnabled(value),
                              ),
                              const SizedBox(height: 4),
                              SettingsMenuAction(
                                key: const ValueKey('platform-button-position'),
                                menuId: 'platform-button-position',
                                icon: Icons.swap_horiz_rounded,
                                title: '平台按钮位置',
                                options: [
                                  for (final option in const {
                                    false: '搜索框右侧',
                                    true: '搜索框左侧',
                                  }.entries)
                                    SettingsMenuOption(
                                      id: option.key ? 'left' : 'right',
                                      label: option.value,
                                      selected:
                                          settings.platformButtonOnLeft ==
                                          option.key,
                                      onSelected: () => ref
                                          .read(settingsProvider.notifier)
                                          .setPlatformButtonOnLeft(option.key),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              SettingsMenuAction(
                                key: const ValueKey('bottom-bar-behavior'),
                                menuId: 'bottom-bar-behavior',
                                icon: Icons.vertical_align_bottom_rounded,
                                title: '底栏行为',
                                options: [
                                  for (final option in BottomBarBehavior.values)
                                    SettingsMenuOption(
                                      id: option.code,
                                      label: option.label,
                                      selected:
                                          settings.bottomBarBehavior == option,
                                      onSelected: () => ref
                                          .read(settingsProvider.notifier)
                                          .setBottomBarBehavior(option),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              SettingsSwitchAction(
                                key: const ValueKey('car-pad-mode-setting'),
                                icon: Icons.directions_car_filled_rounded,
                                title: '车机/Pad 模式',
                                value: settings.carPadModeEnabled,
                                onChanged: (value) => ref
                                    .read(settingsProvider.notifier)
                                    .setCarPadModeEnabled(value),
                              ),
                              const SizedBox(height: 4),
                              SettingsSwitchAction(
                                key: const ValueKey('car-display-setting'),
                                icon: Icons.display_settings_rounded,
                                title: '车机显示适配',
                                value: settings.carDisplayEnabled,
                                onChanged: (value) => ref
                                    .read(settingsProvider.notifier)
                                    .setCarDisplayEnabled(value),
                              ),
                              if (settings.carDisplayEnabled)
                                SettingsMenuAction(
                                  menuId: 'car-display-size-menu',
                                  icon: Icons.format_size_rounded,
                                  title: '车机界面大小',
                                  options: [
                                    for (final option in {
                                      0.85: '紧凑',
                                      1.0: '标准',
                                      1.25: '更大',
                                    }.entries)
                                      SettingsMenuOption(
                                        id: option.key.toString(),
                                        label: option.value,
                                        selected:
                                            settings.carDisplaySize ==
                                            option.key,
                                        onSelected: () => ref
                                            .read(settingsProvider.notifier)
                                            .setCarDisplaySize(option.key),
                                      ),
                                  ],
                                ),
                              const SizedBox(height: 4),
                              SettingsSwitchAction(
                                key: const ValueKey('flowing-light-setting'),
                                icon: Icons.blur_on_rounded,
                                title: '动态流光',
                                value: settings.flowingLightEnabled,
                                onChanged: (value) => ref
                                    .read(settingsProvider.notifier)
                                    .setFlowingLightEnabled(value),
                              ),
                              const SizedBox(height: 4),
                            ],
                          ),
                        ],
                        if (section == SettingsSection.about)
                          SettingsCard(
                            title: null,
                            children: [
                              SettingsAction(
                                key: const ValueKey('check-update-setting'),
                                icon: Icons.system_update_alt_rounded,
                                title: '检查更新',
                                value: versionLabel,
                                trailing: Symbols.chevron_right,
                                onTap: () => unawaited(
                                  checkForAppUpdate(
                                    context,
                                    ref,
                                    showFeedback: true,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        if (section == SettingsSection.debug)
                          SettingsCard(
                            title: null,
                            children: [
                              DebugModeRow(
                                value: settings.debugMode,
                                onChanged: (value) => ref
                                    .read(settingsProvider.notifier)
                                    .setDebugMode(value),
                              ),
                              const LogRecordingMenu(),
                              if (settings.debugMode) ...[
                                const SizedBox(height: 12),
                                SettingsAction(
                                  icon: Icons.terminal_rounded,
                                  title: '日志控制台',
                                  trailing: Symbols.chevron_right,
                                  destination: '/debug',
                                ),
                              ],
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setBluetoothLyricEnabled(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    if (value) await _ensureBluetoothLyricNotice(context, ref);
    if (!context.mounted) return;
    await ref.read(settingsProvider.notifier).setBluetoothLyricEnabled(value);
  }

  Future<void> _setBluetoothFullLyricEnabled(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    if (value) await _ensureBluetoothLyricNotice(context, ref);
    if (!context.mounted) return;
    await ref
        .read(settingsProvider.notifier)
        .setBluetoothFullLyricEnabled(value);
  }

  Future<void> _ensureBluetoothLyricNotice(
    BuildContext context,
    WidgetRef ref,
  ) async {
    if (ref.read(settingsProvider).bluetoothLyricNoticeSeen) return;
    await showSettingsDialog<void>(
      context: context,
      useRootNavigator: true,
      // 玻璃适配：prism.AlertDialog 内部自动玻璃 + 主题色 + 降级；图标改挂 trailing
      builder: (dialogContext) => prism.AlertDialog(
        trailing: const Icon(Icons.directions_car_filled_rounded),
        title: '蓝牙歌词提示',
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('我知道了'),
          ),
        ],
        child: const Text(
          '蓝牙歌词通过媒体信息兼容发送，不同车机或蓝牙设备的支持情况可能不同。'
          '\n\n驾车时请勿操作手机，注意道路安全。',
        ),
      ),
    );
    await ref.read(settingsProvider.notifier).markBluetoothLyricNoticeSeen();
  }

  Future<void> _resetDownloadDir(BuildContext context, WidgetRef ref) async {
    await ref
        .read(settingsProvider.notifier)
        .setDownloadDir(ref.read(defaultDownloadDirProvider));
    unawaited(
      ref
          .read(localSongScanCacheProvider)
          .ensureScan(directories: ref.read(settingsProvider).localMusicDirs),
    );
    if (!context.mounted) return;
    showAppToast(context, '已恢复默认下载位置', type: AppToastType.success);
  }

  Future<void> _resetLocalMusicDir(BuildContext context, WidgetRef ref) async {
    final downloadDir = ref.read(settingsProvider).downloadDir;
    final localDir = await SafStorage.resolveLocalPath(
      downloadDir,
      requireReadable: false,
    );
    if (!context.mounted) return;
    if (localDir == null) {
      showAppToast(context, '下载位置没有可直接读取的本地路径，请选择本地扫描文件夹');
      return;
    }
    final scanCache = ref.read(localSongScanCacheProvider);
    await ref.read(settingsProvider.notifier).setLocalMusicDirs([localDir]);
    unawaited(scanCache.ensureScan(directories: [localDir]));
    if (!context.mounted) return;
    showAppToast(context, '已恢复为下载位置', type: AppToastType.success);
  }

  Future<void> _pickDownloadDir(BuildContext context, WidgetRef ref) async {
    String? path;
    try {
      path = await SafStorage.pickDirectory(
        writable: true,
        initialLocation: ref.read(settingsProvider).downloadDir,
      );
    } on PlatformException catch (error) {
      if (context.mounted) {
        showAppToast(
          context,
          error.message ?? '无法选择文件夹，请重试',
          type: AppToastType.error,
        );
      }
      return;
    } catch (error) {
      // Windows 下 file_picker 抛的是 WindowsException，不是 PlatformException，
      // 旧代码只 catch PlatformException 会让异常逃逸，表现为点击后毫无反应。
      if (context.mounted) {
        showAppToast(
          context,
          '无法选择文件夹，请重试',
          type: AppToastType.error,
        );
      }
      return;
    }
    if (!context.mounted) return;
    if (path == null || path.isEmpty) return;

    if (!await _validateWritableDirectory(context, path)) return;
    await ref.read(settingsProvider.notifier).setDownloadDir(path);
    unawaited(
      ref
          .read(localSongScanCacheProvider)
          .ensureScan(directories: ref.read(settingsProvider).localMusicDirs),
    );
    if (!context.mounted) return;
    showAppToast(
      context,
      '下载目录已切换到 ${SafStorage.label(path)}',
      type: AppToastType.success,
    );
  }

  Future<void> _pickLocalMusicDir(
    BuildContext context,
    WidgetRef ref, {
    String? replacing,
  }) async {
    String? selected;
    try {
      selected = await SafStorage.pickDirectory(
        writable: false,
        initialLocation:
            replacing ?? ref.read(settingsProvider).localMusicDirs.last,
      );
    } on PlatformException catch (error) {
      if (context.mounted) {
        showAppToast(
          context,
          error.message ?? '无法打开系统目录选择器，请重试',
          type: AppToastType.error,
        );
      }
      return;
    } catch (_) {
      // Windows 下 file_picker 抛的是 WindowsException，不是 PlatformException，
      // 补通用兜底避免异常逃逸导致点击后毫无反应。
      if (context.mounted) {
        showAppToast(
          context,
          '无法打开系统目录选择器，请重试',
          type: AppToastType.error,
        );
      }
      return;
    }
    if (!context.mounted || selected == null || selected.isEmpty) return;

    // The system picker grants a URI; MediaStore filters by its local path.
    // Resolving it must not require broad access to enumerate the directory.
    final path = await SafStorage.resolveLocalPath(
      selected,
      requireReadable: false,
    );
    if (!context.mounted) return;
    if (path == null) {
      showAppToast(
        context,
        '请选择内部存储、SD卡或U盘中的本地文件夹',
        type: AppToastType.warning,
      );
      return;
    }

    await _applyLocalMusicDir(context, ref, path, replacing: replacing);
  }

  Future<void> _applyLocalMusicDir(
    BuildContext context,
    WidgetRef ref,
    String path, {
    String? replacing,
  }) async {
    if (!await _validateReadableDirectory(context, path)) return;
    if (!context.mounted) return;
    final directories = [...ref.read(settingsProvider).localMusicDirs];
    final normalizedPath = normalizeStorageLocation(path);
    if (replacing == null && directories.contains(normalizedPath)) {
      showAppToast(context, '该文件夹已在扫描列表中');
      return;
    }
    if (replacing != null) {
      final index = directories.indexOf(replacing);
      if (index < 0) return;
      directories[index] = normalizedPath;
    } else {
      directories.add(normalizedPath);
    }
    final scanCache = ref.read(localSongScanCacheProvider);
    await ref.read(settingsProvider.notifier).setLocalMusicDirs(directories);
    unawaited(scanCache.ensureScan(directories: directories));
    if (!context.mounted) return;
    showAppToast(
      context,
      replacing == null ? '已添加扫描文件夹' : '扫描文件夹已修改',
      type: AppToastType.success,
    );
  }

  Future<void> _removeLocalMusicDir(
    BuildContext context,
    WidgetRef ref,
    String path,
  ) async {
    final directories = [...ref.read(settingsProvider).localMusicDirs];
    if (directories.length <= 1) return;
    directories.remove(path);
    final scanCache = ref.read(localSongScanCacheProvider);
    await ref.read(settingsProvider.notifier).setLocalMusicDirs(directories);
    unawaited(scanCache.ensureScan(directories: directories));
    if (!context.mounted) return;
    showAppToast(context, '已移除扫描文件夹', type: AppToastType.success);
  }

  Future<void> _showDiscoverySourceOrderSheet(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final toolbar = ref.read(shellToolbarVisibleProvider.notifier);
    final wasToolbarVisible = ref.read(shellToolbarVisibleProvider);
    toolbar.state = false;
    try {
      await showDiscoverySourceOrderSheet(
        context,
        order: ref.read(settingsProvider).discoverySourceOrder,
        onChanged: (order) async {
          await ref
              .read(settingsProvider.notifier)
              .setDiscoverySourceOrder(order);
        },
      );
    } finally {
      if (toolbar.mounted) toolbar.state = wasToolbarVisible;
    }
  }

  Future<bool> _validateWritableDirectory(
    BuildContext context,
    String path,
  ) async {
    try {
      await SafStorage.validateDirectory(path, writable: true);
    } catch (_) {
      if (!context.mounted) return false;
      showAppToast(
        context,
        isContentLocation(path)
            ? '文件夹不可写或授权已失效，请通过系统选择器重新选择'
            : '所选文件夹不可写，请重新选择，或在「权限、下载与目录」中授予存储权限',
        type: AppToastType.error,
      );
      return false;
    }
    return true;
  }

  Future<bool> _validateReadableDirectory(
    BuildContext context,
    String path,
  ) async {
    if (Platform.isAndroid &&
        !isContentLocation(path) &&
        await PermissionService.hasAudioLibraryRead()) {
      return true;
    }
    try {
      await SafStorage.validateDirectory(path, writable: false);
    } catch (_) {
      if (!context.mounted) return false;
      showAppToast(
        context,
        isContentLocation(path)
            ? '文件夹不可读取或授权已失效，请通过系统选择器重新选择'
            : '所选文件夹不可读取，请重新选择，或在「权限、下载与目录」中授予存储权限',
        type: AppToastType.error,
      );
      return false;
    }
    return true;
  }

  Future<void> _setNetworkAdapter(
    BuildContext context,
    WidgetRef ref,
    NetworkAdapterMode selected,
  ) async {
    final current = ref.read(settingsProvider).networkAdapterMode;
    if (selected == current) return;
    await ref.read(settingsProvider.notifier).setNetworkAdapterMode(selected);
    if (!context.mounted) return;
    final type = selected == NetworkAdapterMode.native
        ? AppToastType.warning
        : AppToastType.success;
    showAppToast(context, '网络适配器已切换为 ${selected.label}', type: type);
  }

  Future<void> _setSearchSourceEnabled(
    BuildContext context,
    WidgetRef ref,
    MusicSource source,
    bool? enabled,
  ) async {
    if (enabled == null) return;
    final changed = await ref
        .read(settingsProvider.notifier)
        .setSearchSourceEnabled(source, enabled);
    if (!changed && context.mounted) {
      showAppToast(context, '至少保留一个搜索源', type: AppToastType.warning);
    }
  }

  Future<void> _setOnlinePlaybackQualityWifi(
    BuildContext context,
    WidgetRef ref,
    OnlinePlaybackQuality quality,
  ) async {
    if (quality == ref.read(settingsProvider).onlinePlaybackQualityWifi) return;
    await ref
        .read(settingsProvider.notifier)
        .setOnlinePlaybackQualityWifi(quality);
    if (!context.mounted) return;
    showAppToast(
      context,
      'WiFi 在线播放音质已设为 ${quality.label}',
      type: AppToastType.success,
    );
  }

  Future<void> _setOnlinePlaybackQualityCellular(
    BuildContext context,
    WidgetRef ref,
    OnlinePlaybackQuality quality,
  ) async {
    if (quality == ref.read(settingsProvider).onlinePlaybackQualityCellular) {
      return;
    }
    await ref
        .read(settingsProvider.notifier)
        .setOnlinePlaybackQualityCellular(quality);
    if (!context.mounted) return;
    showAppToast(
      context,
      '移动流量在线播放音质已设为 ${quality.label}',
      type: AppToastType.success,
    );
  }

  Future<void> _setBatchDownloadQuality(
    BuildContext context,
    WidgetRef ref,
    OnlinePlaybackQuality quality,
  ) async {
    if (quality == ref.read(settingsProvider).batchDownloadQuality) return;
    await ref.read(settingsProvider.notifier).setBatchDownloadQuality(quality);
    if (!context.mounted) return;
    showAppToast(
      context,
      '批量下载音质已设为 ${quality.label}',
      type: AppToastType.success,
    );
  }

  Future<void> _chooseAppIcon(BuildContext context, WidgetRef ref) async {
    if (ref.read(appIconProvider).isLoading) return;
    if (ref.read(appIconProvider).hasError) ref.invalidate(appIconProvider);
    final toolbar = ref.read(shellToolbarVisibleProvider.notifier);
    final wasToolbarVisible = ref.read(shellToolbarVisibleProvider);
    toolbar.state = false;
    try {
      final current = await ref.read(appIconProvider.future);
      if (!context.mounted) return;
      final selected = await showAppIconSheet(context, current);
      if (selected == null || selected == current || !context.mounted) return;
      final changed = await ref.read(appIconProvider.notifier).select(selected);
      if (!changed || !context.mounted) return;
      showAppToast(
        context,
        '桌面图标已设为${selected.label}',
        type: AppToastType.success,
      );
    } catch (_) {
      if (context.mounted) {
        showAppToast(context, '无法更换桌面图标，请稍后重试', type: AppToastType.error);
      }
    } finally {
      if (toolbar.mounted) toolbar.state = wasToolbarVisible;
    }
  }
}

String _webDavSubtitle(AsyncValue<WebDavSyncState> value) {
  return value.when(
    loading: () => '正在读取同步配置',
    error: (_, _) => '同步配置读取失败',
    data: (sync) {
      if (!sync.config.isConfigured) return '未配置';
      if (sync.phase == WebDavSyncPhase.connecting) return '正在连接';
      if (sync.phase == WebDavSyncPhase.syncing) return '正在同步';
      if (sync.phase == WebDavSyncPhase.failure) {
        return sync.errorMessage ?? '最近同步失败';
      }
      final lastSyncedAt = sync.lastSyncedAt?.toLocal();
      if (lastSyncedAt == null) return '已连接，尚未同步';
      return '上次同步 ${_shortDateTime(lastSyncedAt)}';
    },
  );
}

String _shortDateTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.month}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}

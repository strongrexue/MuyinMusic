import 'package:flutter/material.dart';

enum SettingsSection {
  appearance(
    title: '外观',
    subtitle: '主题、应用图标与播放界面',
    icon: Icons.palette_outlined,
  ),
  network(
    title: '音源与网络',
    subtitle: '音源管理、网络适配与平台顺序',
    icon: Icons.cloud_outlined,
  ),
  playback(
    title: '搜索与播放',
    subtitle: '搜索源、默认搜索平台、播放音质与蓝牙歌词',
    icon: Icons.play_circle_outline_rounded,
  ),
  downloads(
    title: '下载与目录',
    subtitle: '下载音质、文件命名、下载位置与音乐扫描文件夹',
    icon: Icons.folder_shared_outlined,
  ),
  permissions(
    title: '权限管理',
    subtitle: '存储授权与系统权限',
    icon: Icons.verified_user_outlined,
  ),
  sync(
    title: 'WebDAV 同步',
    subtitle: '备份与恢复播放数据',
    icon: Icons.cloud_sync_outlined,
  ),
  about(title: '关于', subtitle: '当前版本与检查更新', icon: Icons.info_outline_rounded),
  debug(title: '调试', subtitle: '调试模式与日志控制台', icon: Icons.bug_report_outlined);

  const SettingsSection({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  String get location => '/settings/$name';

  static SettingsSection? fromLocation(String location) {
    for (final section in values) {
      if (section.location == location) return section;
    }
    return null;
  }
}

String? settingsParentLocation(String location) {
  if (SettingsSection.fromLocation(location) != null) return '/settings';
  return switch (location) {
    '/settings/sources' => SettingsSection.network.location,
    '/settings/webdav' => SettingsSection.sync.location,
    '/settings/cloud-drive2' => SettingsSection.sync.location,
    '/settings/equalizer' => SettingsSection.playback.location,
    '/debug' => SettingsSection.debug.location,
    _ => null,
  };
}

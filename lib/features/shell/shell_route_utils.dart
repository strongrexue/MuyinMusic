import 'package:flutter/material.dart';

import '../settings/settings_section.dart';

// Pure route helpers shared by the AppShell state machine (app_shell.dart)
// and the extracted shell widgets (widgets/). Kept in their own file so
// widgets/ never has to import the page file.

ColorScheme shellSchemeFor(String location, ColorScheme fallback) {
  return fallback;
}

bool isPlaylistLocation(String location) {
  return location == '/playlists' || location.startsWith('/playlists/');
}

bool isPlaylistDetailLocation(String location) {
  return location.startsWith('/playlists/') && location != '/playlists/import';
}

bool isImmersivePlaylistDetailLocation(String location) {
  final leaderboardDetail =
      location.startsWith('/discover/leaderboards/') &&
      location.split('/').length > 4;
  return isPlaylistDetailLocation(location) ||
      location.startsWith('/discover/playlists/') ||
      location.startsWith('/discover/artists/') ||
      location.startsWith('/discover/albums/') ||
      leaderboardDetail;
}

bool isDiscoveryLocation(String location) =>
    location == '/' || location.startsWith('/discover/');

bool isHomeLocation(String location) => location == '/home';

/// 首页的搜索页自绘标题（与发现区同一套做法）。
bool isHomeSearchLocation(String location) => location == '/home/search';

/// 首页自己的下载页：返回键回到首页而不是歌曲 tab。
bool isHomeDownloadsLocation(String location) => location == '/home/downloads';

bool isSongsLibraryLocation(String location) {
  return location == '/songs' || location == '/songs/search';
}

/// 跨 tab 切换时随 `context.go` 传入的路由 extra。目标 tab 记住的可能是
/// 发现区详情页，这时它是被「切回」而不是被打开，页面应直接出现、不播放
/// 进场动画。保留的栏目通过 goBranch 切换时不需要这个标记。
class ShellTabSwitch {
  const ShellTabSwitch();
}

String normalizedPlayerReturnLocation(String primary, String fallback) {
  if (isPlayerReturnLocation(primary)) return primary;
  if (isPlayerReturnLocation(fallback)) return fallback;
  return '/songs';
}

bool isPlayerReturnLocation(String location) {
  final uri = Uri.tryParse(location);
  if (uri == null || uri.hasScheme || uri.hasAuthority) return false;
  final path = uri.path;
  if (isDiscoveryLocation(path)) return true;
  if (isPlaylistLocation(path)) return true;
  if (SettingsSection.fromLocation(path) != null) return true;
  return switch (path) {
    '/' ||
    '/home' ||
    '/downloads' ||
    '/songs' ||
    '/songs/search' ||
    '/settings' ||
    '/settings/sources' ||
    '/settings/webdav' ||
    '/settings/xiaomi-login' ||
    '/settings/xiaomi-devices' ||
    '/settings/equalizer' ||
    '/debug' => true,
    _ => false,
  };
}

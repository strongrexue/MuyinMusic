import 'dart:async';
import 'dart:io';

import 'package:bass_player/bass_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/audio/windows_bass_backend.dart';
import 'core/services/app_logger.dart';
import 'core/services/native_log_bridge.dart';
import 'core/services/storage_browser_service.dart';
import 'core/debug/debug_paint_guard.dart';
import 'core/storage/settings_store.dart';
import 'features/player/player_audio_handler.dart';
import 'features/player/live_activity_service.dart';
import 'features/player/music_home_widget_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.installErrorHandlers();
  try {
    await _startApp();
  } catch (error, stack) {
    await AppLogger.recordUnhandledError('startup', error, stack);
    rethrow;
  }
}

Future<void> _startApp() async {
  final prefs = await SharedPreferences.getInstance();
  AppLogger.configureRecording(prefs);
  await AppLogger.logEnvironment();
  DebugPaintGuard.install();
  // iOS 原生失败（实时活动 / 备用图标…）默认只写 NSLog，Release 包用户看不到。
  // 尽早装上这条桥，后面原生一有问题就直接出现在 App 内的「日志」页。
  if (Platform.isIOS) NativeLogBridge.install();
  if (Platform.isAndroid) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarContrastEnforced: false,
      ),
    );
    // A widget or media service can start this engine without an Activity.
    // Android's platform channel then has no UI handler and never replies;
    // waiting here would prevent the player and widget controls from starting.
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }
  hydrateNetworkAdapterPreference(prefs);
  final audioHandler = await initializePlayerAudioHandler(
    allowMixWithOthers: readAllowMixWithOthersPreference(prefs),
    player: Platform.isWindows ? BassPlayer(backend: WindowsBassBackend()) : null,
  );
  // iOS / Windows 默认目录在运行时解析：扫描根 = Documents，下载 = Documents/MuyinMusic。
  // Android 沿用 base_url.dart 的历史常量，保持既有行为。
  final documentsDir = (Platform.isIOS || Platform.isWindows)
      ? (await getApplicationDocumentsDirectory()).path
      : null;
  final defaultScanDir = documentsDir ?? kDefaultDownloadDir;
  final defaultDownloadDir = documentsDir == null
      ? kDefaultDownloadDir
      : '$documentsDir/MuyinMusic';
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      playerAudioHandlerProvider.overrideWithValue(audioHandler),
      defaultMusicDirProvider.overrideWithValue(defaultScanDir),
      defaultDownloadDirProvider.overrideWithValue(defaultDownloadDir),
    ],
  );
  // The media-service engine can start without an Activity or a rendered
  // frame. Install widget controls before runApp, using the same providers.
  await container.read(musicHomeWidgetProvider).initialize();
  // iOS 的灵动岛 / 锁屏实时活动：与桌面小组件同理，尽早建立通道监听，
  // 免得从锁屏直接点播放时错过第一次状态变化。
  await container.read(liveActivityProvider).initialize();
  // 立刻接上播放状态跟随：巨魔 / 无 Live Activity 权限时，系统媒体卡片
  // （灵动岛 / 锁屏）完全依赖 nowPlayingInfo 降级通道，而它靠这里的监听触发。
  // 放在 runApp 之前可覆盖「锁屏直接点播放、App 还没渲染首帧」的场景。
  // iOS：尽早为已授权的 bookmark 根持有 security scope，避免锁屏直接播放
  // 等绕过首帧的路径读不到沙盒外文件。失败不阻断启动（app.dart 会再试一次）。
  if (Platform.isIOS) {
    try {
      await const StorageBrowserService().acquireAllAccess();
    } catch (error, stack) {
      await AppLogger.recordUnhandledError('acquireAllAccess', error, stack);
    }
  }
  container.read(liveActivitySyncProvider);
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CyShineMusicApp(),
    ),
  );
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/services/app_logger.dart';
import 'core/services/native_log_bridge.dart';
import 'core/debug/debug_paint_guard.dart';
import 'core/sdk/qishui_sdk.dart';
import 'core/storage/settings_store.dart';
import 'features/player/player_audio_handler.dart';
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
  QishuiSdk.configureSession(ensureQishuiSessionPreference(prefs));
  final audioHandler = await initializePlayerAudioHandler(
    allowMixWithOthers: readAllowMixWithOthersPreference(prefs),
  );
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      playerAudioHandlerProvider.overrideWithValue(audioHandler),
    ],
  );
  // The media-service engine can start without an Activity or a rendered
  // frame. Install widget controls before runApp, using the same providers.
  await container.read(musicHomeWidgetProvider).initialize();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CyShineMusicApp(),
    ),
  );
}

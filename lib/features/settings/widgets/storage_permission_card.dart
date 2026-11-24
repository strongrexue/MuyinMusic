import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/permission_service.dart';
import '../../../core/storage/settings_store.dart';
import '../../../core/ui/app_toast.dart';
import '../../songs/local_song_scan_cache.dart';
import 'settings_action.dart';

class StoragePermissionCard extends ConsumerStatefulWidget {
  const StoragePermissionCard({super.key});

  @override
  ConsumerState<StoragePermissionCard> createState() =>
      _StoragePermissionCardState();
}

class _StoragePermissionCardState extends ConsumerState<StoragePermissionCard>
    with WidgetsBindingObserver {
  bool? _audioGranted;
  bool? _wideGranted;
  bool? _notificationGranted;
  bool? _backgroundGranted;
  bool? _overlayGranted;
  bool _requesting = false;
  bool _checkFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshPermission());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshPermission());
  }

  Future<void> _refreshPermission() async {
    try {
      final status = await Future.wait([
        PermissionService.hasAudioLibraryRead(),
        PermissionService.hasExternalStorageWrite(),
        PermissionService.hasNotificationPermission(),
        PermissionService.hasBackgroundPlaybackProtection(),
        PermissionService.hasOverlayPermission(),
      ]);
      if (!mounted) return;
      final newlyGranted =
          (status[0] && _audioGranted == false) ||
          (status[1] && _wideGranted == false);
      setState(() {
        _audioGranted = status[0];
        _wideGranted = status[1];
        _notificationGranted = status[2];
        _backgroundGranted = status[3];
        _overlayGranted = status[4];
        _checkFailed = false;
      });
      if (newlyGranted) {
        unawaited(
          ref
              .read(localSongScanCacheProvider)
              .refresh(directories: ref.read(settingsProvider).scanDirectories),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _checkFailed = true);
    }
  }

  /// Runs [request] and reports the result, opening the system page when the
  /// platform has already handed the decision to Settings.
  Future<void> _run(
    Future<bool> Function() request, {
    required String grantedMessage,
    required String deniedMessage,
  }) async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      final granted = await request();
      await _refreshPermission();
      if (!mounted) return;
      showAppToast(
        context,
        granted ? grantedMessage : deniedMessage,
        type: granted ? AppToastType.success : AppToastType.warning,
      );
    } catch (_) {
      if (mounted) {
        showAppToast(context, '权限申请失败，请在系统设置中检查', type: AppToastType.error);
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Future<void> _toggleNotification() async {
    if (await PermissionService.hasNotificationPermission()) {
      await PermissionService.openSystemAppSettings();
      return;
    }
    await _run(
      PermissionService.requestNotificationPermission,
      grantedMessage: '已开启通知权限',
      deniedMessage: '未开启通知权限，控制中心通知不会显示',
    );
  }

  Future<void> _toggleBackground() async {
    if (await PermissionService.hasBackgroundPlaybackProtection()) {
      await PermissionService.openSystemAppSettings();
      return;
    }
    await _run(
      PermissionService.requestBackgroundPlaybackProtection,
      grantedMessage: '已加入电池优化白名单',
      deniedMessage: '未加入白名单，长时间后台播放可能被系统中断',
    );
  }

  Future<void> _toggleOverlay() async {
    if (await PermissionService.hasOverlayPermission()) {
      await PermissionService.openSystemAppSettings();
      return;
    }
    await _run(
      PermissionService.requestOverlayPermission,
      grantedMessage: '已开启悬浮窗权限',
      deniedMessage: '未开启悬浮窗权限，部分浮层可能无法显示',
    );
  }

  Future<void> _requestPermission({bool compatibility = false}) async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      if (compatibility) {
        await PermissionService.openExternalStorageSettings();
        await _refreshPermission();
        return;
      }
      if (_audioGranted == true) {
        await PermissionService.openSystemAppSettings();
        return;
      }
      final granted = await PermissionService.requestAudioLibraryRead();
      await _refreshPermission();
      if (!mounted) return;
      showAppToast(
        context,
        granted ? '已允许读取本地音乐' : '未允许读取本地音乐，可稍后重新授权',
        type: granted ? AppToastType.success : AppToastType.warning,
      );
    } catch (_) {
      if (mounted) {
        showAppToast(context, '权限申请失败，请在系统设置中检查', type: AppToastType.error);
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  IconData _trailing(bool? granted) => granted == true
      ? Icons.check_circle_outline_rounded
      : Icons.chevron_right_rounded;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 24,
      children: [
        SettingsCard(
          title: '权限',
          children: [
            SettingsAction(
              icon: Icons.library_music_outlined,
              title: '音乐和音频',
              value: _checkFailed ? '检查失败' : null,
              trailing: _trailing(_audioGranted),
              onTap: () => _requestPermission(),
            ),
            SettingsAction(
              icon: Icons.folder_shared_outlined,
              title: '所有文件访问（兼容）',
              value: _checkFailed ? '检查失败' : null,
              trailing: _trailing(_wideGranted),
              onTap: () => _requestPermission(compatibility: true),
            ),
          ],
        ),
        SettingsCard(
          title: '播放与通知',
          children: [
            SettingsAction(
              icon: Icons.notifications_active_outlined,
              title: '通知权限',
              value: _notificationGranted == true ? '已开启' : '未开启',
              trailing: _trailing(_notificationGranted),
              onTap: _toggleNotification,
            ),
            SettingsAction(
              icon: Icons.battery_saver_outlined,
              title: '后台播放保护',
              value: _backgroundGranted == true ? '已保护' : '可能被系统中断',
              trailing: _trailing(_backgroundGranted),
              onTap: _toggleBackground,
            ),
            SettingsAction(
              icon: Icons.picture_in_picture_alt_outlined,
              title: '悬浮窗权限',
              value: _overlayGranted == true ? '已开启' : '未开启',
              trailing: _trailing(_overlayGranted),
              onTap: _toggleOverlay,
            ),
          ],
        ),
      ],
    );
  }
}

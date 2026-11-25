import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../core/app_info.dart';
import '../../core/services/app_logger.dart';
import '../../core/services/app_update_service.dart';
import '../../core/storage/settings_store.dart';
import '../../core/ui/app_toast.dart';

enum AppUpdateCheckOutcome {
  updateAvailable,
  upToDate,
  failed,
  alreadyChecking,

  /// 自动检查时命中的版本已被用户「忽略此版本」，静默跳过提示。
  ignoredVersion,
}

bool _appUpdateCheckInProgress = false;

enum _AppUpdateAction { ignore, download }

Future<AppUpdateCheckOutcome> checkForAppUpdate(
  BuildContext context,
  WidgetRef ref, {
  bool showFeedback = false,
}) async {
  if (_appUpdateCheckInProgress) {
    if (showFeedback && context.mounted) {
      showAppToast(context, '正在检查更新，请稍候');
    }
    return AppUpdateCheckOutcome.alreadyChecking;
  }
  _appUpdateCheckInProgress = true;

  AppToastHandle? progressToast;
  if (showFeedback) {
    progressToast = showAppToast(
      context,
      '正在检查更新…',
      duration: const Duration(seconds: 10),
    );
  }

  try {
    final packageInfo = await ref.read(packageInfoProvider.future);
    final latest = await ref
        .read(appUpdateServiceProvider)
        .fetchLatestRelease();
    if (!context.mounted) return AppUpdateCheckOutcome.failed;
    dismissAppToast(progressToast, showRemoveAnimation: false);
    progressToast = null;

    if (latest == null ||
        !isNewerAppVersion(
          currentVersion: packageInfo.version,
          latestVersion: latest.tagName,
        )) {
      if (showFeedback) {
        showAppToast(
          context,
          '已是最新版（${packageInfo.version}）',
          type: AppToastType.success,
        );
      }
      return AppUpdateCheckOutcome.upToDate;
    }

    // 「忽略此版本」只压住自动提示；手动检查（showFeedback）永远绕过，
    // 有新版本必弹。忽略记录的是单个版本号，出现更新的版本仍会提示。
    if (!showFeedback &&
        ref.read(settingsProvider).ignoredAppUpdateVersion ==
            latest.tagName) {
      return AppUpdateCheckOutcome.ignoredVersion;
    }

    await _showUpdateDialog(
      context,
      ref,
      currentVersion: packageInfo.version,
      release: latest,
    );
    return AppUpdateCheckOutcome.updateAvailable;
  } catch (error) {
    await AppLogger.write('update', 'check failed: $error');
    if (context.mounted && showFeedback) {
      showAppToast(context, '检查更新失败，请稍后重试', type: AppToastType.warning);
    }
    return AppUpdateCheckOutcome.failed;
  } finally {
    _appUpdateCheckInProgress = false;
    dismissAppToast(progressToast, showRemoveAnimation: false);
  }
}

Future<void> _showUpdateDialog(
  BuildContext context,
  WidgetRef ref, {
  required String currentVersion,
  required AppRelease release,
}) async {
  final action = await prism.showFloatingDialog<_AppUpdateAction>(
    context: context,
    // 玻璃遮罩由 showFloatingDialog 提供；child 换成 prism 确认框。
    child: Builder(
      builder: (dialogContext) => prism.AlertDialog(
        key: const ValueKey('app-update-dialog'),
        title: '发现新版本',
        actions: [
          prism.TextButton(
            key: const ValueKey('app-update-ignore'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_AppUpdateAction.ignore),
            child: const Text('忽略此版本'),
          ),
          prism.TextButton(
            key: const ValueKey('app-update-later'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('稍后再说'),
          ),
          prism.FilledButton(
            key: const ValueKey('app-update-open-release'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_AppUpdateAction.download),
            child: const Text('前往下载'),
          ),
        ],
        child: Text(
          '$currentVersion  →  ${release.version}\n\n'
          '${release.title}\n'
          '将打开胖虎音乐的更新页面，由你选择并下载更新包。\n\n'
          '忽略此版本后，启动时不再提示该版本；有更新的版本仍会提示，'
          '也可在设置中手动检查更新。',
        ),
      ),
    ),
  );
  if (!context.mounted) return;
  if (action == _AppUpdateAction.ignore) {
    await ref
        .read(settingsProvider.notifier)
        .setIgnoredAppUpdateVersion(release.tagName);
    if (context.mounted) {
      showAppToast(context, '已忽略此版本，可在设置中手动检查更新');
    }
    return;
  }
  // 「稍后再说」或点遮罩关闭：不写任何持久状态，只 snooze 本次启动；
  // 下次冷启动会重新检查并再次提示，误触可自愈。
  if (action != _AppUpdateAction.download) return;

  try {
    final opened = await ref.read(externalUriLauncherProvider)(release.pageUri);
    if (!opened && context.mounted) {
      showAppToast(context, '无法打开胖虎音乐的更新页面', type: AppToastType.error);
    }
  } catch (error) {
    await AppLogger.write('update', 'open release page failed: $error');
    if (context.mounted) {
      showAppToast(context, '无法打开胖虎音乐的更新页面', type: AppToastType.error);
    }
  }
}

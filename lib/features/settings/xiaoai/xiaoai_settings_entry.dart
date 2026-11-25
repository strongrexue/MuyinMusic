import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/xiaomi/takeover/takeover_state.dart';
import '../../../core/xiaomi/takeover_providers.dart';
import '../widgets/settings_action.dart';
import 'xiaoai_settings_controller.dart';

/// 设置页总览的「小爱音箱」入口行：点击进入独立页，副标题跟随
/// 登录态与接管相位（措辞与独立页内的状态文案一致）。
class XiaoaiSettingsEntry extends ConsumerStatefulWidget {
  const XiaoaiSettingsEntry({super.key});

  @override
  ConsumerState<XiaoaiSettingsEntry> createState() =>
      _XiaoaiSettingsEntryState();
}

class _XiaoaiSettingsEntryState extends ConsumerState<XiaoaiSettingsEntry> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(xiaoaiSettingsProvider.notifier).initialize());
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(xiaoaiSettingsProvider);
    final takeover = ref.watch(xiaoaiTakeoverControllerProvider);

    final String subtitle;
    if (!settings.initialized) {
      subtitle = '正在加载';
    } else if (!settings.loggedIn) {
      subtitle = '未登录小米账号';
    } else {
      subtitle = switch (takeover.phase) {
        TakeoverPhase.error => takeover.errorMessage ?? '接管异常',
        TakeoverPhase.listening => '监听中',
        TakeoverPhase.disabled => settings.statusNote ?? '未开启',
      };
    }

    return SettingsCard(
      title: null,
      children: [
        SettingsAction(
          key: const ValueKey('xiaoai-settings-entry'),
          icon: Icons.speaker_outlined,
          title: '小爱音箱',
          value: subtitle,
          trailing: Icons.chevron_right_rounded,
          destination: '/settings/xiaomi',
        ),
      ],
    );
  }
}

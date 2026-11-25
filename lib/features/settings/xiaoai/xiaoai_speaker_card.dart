import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/ui/app_toast.dart';
import '../../../core/xiaomi/takeover/takeover_state.dart';
import '../../../core/xiaomi/takeover_providers.dart';
import '../widgets/settings_action.dart';
import 'xiaoai_settings_controller.dart';

/// 已登录 / 监听中状态文字用的绿（与种子色板里的绿同值）。
const Color _statusGreen = Color(0xFF4CAF50);

/// 设置页总览的「小爱音箱」卡：三态（未登录 / 登录表单入口 / 接管中）
/// 严格按已定效果图排版，监听相位与最近接管直接消费模块二状态。
class XiaoaiSpeakerCard extends ConsumerStatefulWidget {
  const XiaoaiSpeakerCard({super.key});

  @override
  ConsumerState<XiaoaiSpeakerCard> createState() => _XiaoaiSpeakerCardState();
}

class _XiaoaiSpeakerCardState extends ConsumerState<XiaoaiSpeakerCard> {
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final settings = ref.watch(xiaoaiSettingsProvider);
    final takeover = ref.watch(xiaoaiTakeoverControllerProvider);

    return SettingsCard(
      title: null,
      insetContent: true,
      separate: false,
      children: [
        Row(
          children: [
            Icon(Icons.speaker_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text(
              '小爱音箱',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (!settings.initialized)
          Text(
            '正在加载',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else if (!settings.loggedIn)
          ..._loggedOut(context, theme)
        else
          ..._loggedIn(context, theme, settings, takeover),
      ],
    );
  }

  List<Widget> _loggedOut(BuildContext context, ThemeData theme) {
    final scheme = theme.colorScheme;
    return [
      Text('未登录小米账号', style: theme.textTheme.bodyLarge),
      const SizedBox(height: 6),
      Text(
        '登录后，对小爱音箱说“播放歌曲…”，由胖虎音乐接管播放',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          height: 1.5,
        ),
      ),
      const SizedBox(height: 16),
      FilledButton(
        key: const ValueKey('xiaoai-login-button'),
        onPressed: () => context.push('/settings/xiaomi-login'),
        child: const Text('登录小米账号'),
      ),
    ];
  }

  List<Widget> _loggedIn(
    BuildContext context,
    ThemeData theme,
    XiaoaiSettingsState settings,
    XiaoaiTakeoverState takeover,
  ) {
    final scheme = theme.colorScheme;
    final device = settings.selectedDevice;
    final record = takeover.lastRecord;

    final (statusText, statusColor) = switch (takeover.phase) {
      TakeoverPhase.error => (
        takeover.errorMessage ?? '接管异常',
        scheme.error,
      ),
      TakeoverPhase.listening => ('监听中', _statusGreen),
      TakeoverPhase.disabled =>
        settings.statusNote != null
            ? (settings.statusNote!, scheme.error)
            : ('未开启', null),
    };

    return [
      _InfoRow(
        label: '小米账号',
        value: '已登录',
        valueColor: _statusGreen,
      ),
      const Divider(height: 1),
      _InfoRow(
        label: '目标音箱',
        value: device == null
            ? '未选择'
            : '${minaDeviceDisplayName(device)} · ${device.isOnline ? '在线' : '离线'}',
        chevron: true,
        onTap: () => context.push('/settings/xiaomi-devices'),
      ),
      const Divider(height: 1),
      _InfoRow(
        label: '语音点歌接管',
        trailing: prism.Switch(
          key: const ValueKey('xiaoai-takeover-switch'),
          value: settings.takeoverEnabled,
          onChanged: (value) => unawaited(_onToggleChanged(value)),
        ),
      ),
      const Divider(height: 1),
      _InfoRow(label: '监听状态', value: statusText, valueColor: statusColor),
      if (takeover.phase == TakeoverPhase.error)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => context.push('/settings/xiaomi-login'),
            child: const Text('重新登录'),
          ),
        ),
      if (record != null) ...[
        const Divider(height: 1),
        const SizedBox(height: 10),
        Text(
          '最近接管',
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '《${record.title}》·${record.artist}·'
          '${record.success ? '已播放' : (record.detail ?? '未播放')}',
          style: theme.textTheme.bodyMedium,
        ),
      ],
      const SizedBox(height: 8),
      Center(
        child: TextButton(
          key: const ValueKey('xiaoai-logout-button'),
          onPressed: () => unawaited(_logout()),
          child: const Text('退出登录'),
        ),
      ),
    ];
  }

  Future<void> _onToggleChanged(bool value) async {
    final settings = ref.read(xiaoaiSettingsProvider);
    if (value && settings.selectedDevice == null) {
      // 没选设备时先引导去选，不直接把开关拨过去。
      if (mounted) context.push('/settings/xiaomi-devices');
      return;
    }
    await ref.read(xiaoaiSettingsProvider.notifier).setTakeoverEnabled(value);
  }

  Future<void> _logout() async {
    await ref.read(xiaoaiSettingsProvider.notifier).logout();
    if (!mounted) return;
    showAppToast(context, '已退出小米账号', type: AppToastType.success);
  }
}

/// 卡内信息行：左标签、右值（可带颜色 / 右箭头 / 自定义尾部）。
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    this.value,
    this.valueColor,
    this.trailing,
    this.chevron = false,
    this.onTap,
  });

  final String label;
  final String? value;
  final Color? valueColor;
  final Widget? trailing;
  final bool chevron;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Text(label, style: theme.textTheme.bodyLarge),
          const Spacer(),
          if (value != null)
            Flexible(
              child: Text(
                value!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium?.copyWith(color: valueColor),
              ),
            ),
          ?trailing,
          if (chevron) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}

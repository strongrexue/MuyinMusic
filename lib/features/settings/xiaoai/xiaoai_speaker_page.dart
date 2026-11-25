import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/ui/app_toast.dart';
import '../../../core/xiaomi/takeover/takeover_state.dart';
import '../../../core/xiaomi/takeover_providers.dart';
import '../../../theme/app_theme.dart';
import '../../shell/shell_bottom_area.dart';
import '../../shell/widgets/scrolling_page_header.dart';
import '../widgets/settings_action.dart';
import '../widgets/settings_sheet.dart';
import 'xiaoai_settings_controller.dart';

/// 已登录 / 监听中状态文字用的绿（与种子色板里的绿同值）。
const Color _statusGreen = Color(0xFF4CAF50);

/// 「小爱音箱」独立页：三态（未登录 / 已登录 / 接管中）内容沿用原设置页
/// 内嵌卡的排版与文案，标题与返回由壳顶栏承担（路由 /settings/xiaomi）。
class XiaoaiSpeakerPage extends ConsumerStatefulWidget {
  const XiaoaiSpeakerPage({super.key});

  @override
  ConsumerState<XiaoaiSpeakerPage> createState() => _XiaoaiSpeakerPageState();
}

class _XiaoaiSpeakerPageState extends ConsumerState<XiaoaiSpeakerPage> {
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

    return Scaffold(
      backgroundColor: scheme.appSettingsSurface,
      body: CustomScrollView(
        key: const PageStorageKey('xiaoai-speaker-scroll'),
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
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: SettingsCard(
                    title: null,
                    insetContent: true,
                    separate: false,
                    children: [
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
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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
      _InfoRow(
        label: '专属口令',
        trailing: prism.Switch(
          key: const ValueKey('xiaoai-wake-word-switch'),
          value: settings.wakeWordEnabled,
          onChanged: (value) => unawaited(
            ref.read(xiaoaiSettingsProvider.notifier).setWakeWordEnabled(value),
          ),
        ),
      ),
      if (settings.wakeWordEnabled) ...[
        const Divider(height: 1),
        _InfoRow(
          label: '口令词',
          value: settings.wakeWord,
          chevron: true,
          onTap: () => unawaited(_editWakeWord(settings.wakeWord)),
        ),
      ],
      const SizedBox(height: 4),
      Text(
        '开启后，只有带口令的指令才会被接管，如「胖虎，播放晴天」',
        style: theme.textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
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
      if (takeover.records.isNotEmpty) ...[
        const Divider(height: 1),
        const SizedBox(height: 10),
        Text(
          '最近接管',
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < takeover.records.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          Text(
            '《${takeover.records[i].title}》·${takeover.records[i].artist}·'
            '${takeover.records[i].success ? '已播放' : (takeover.records[i].detail ?? '未播放')}',
            style: theme.textTheme.bodyMedium,
          ),
          Text(
            _recordMeta(takeover.records[i]),
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
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

  Future<void> _editWakeWord(String current) async {
    final result = await showSettingsDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _WakeWordDialog(initialValue: current),
    );
    if (result == null) return;
    await ref.read(xiaoaiSettingsProvider.notifier).setWakeWord(result);
  }

  Future<void> _logout() async {
    await ref.read(xiaoaiSettingsProvider.notifier).logout();
    if (!mounted) return;
    showAppToast(context, '已退出小米账号', type: AppToastType.success);
  }
}

/// 口令词编辑弹窗（随项目内既有编辑弹窗风格：prism.AlertDialog + 输入框）。
class _WakeWordDialog extends StatefulWidget {
  const _WakeWordDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_WakeWordDialog> createState() => _WakeWordDialogState();
}

class _WakeWordDialogState extends State<_WakeWordDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.initialValue.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    // 空输入不保存，保持原值。
    if (value.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return prism.AlertDialog(
      title: '口令词',
      hasFields: true,
      actions: [
        prism.TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        prism.FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
      child: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: '口令词',
          hintText: '例如：胖虎',
        ),
        onSubmitted: (_) => _submit(),
      ),
    );
  }
}

/// 接管记录的次行 meta：本地时间 HH:mm、音源、音质、推播方式，
/// 缺项跳过，以 ' · ' 连接。
String _recordMeta(TakeoverRecord record) {
  final at = DateTime.fromMillisecondsSinceEpoch(record.atMs).toLocal();
  final hh = at.hour.toString().padLeft(2, '0');
  final mm = at.minute.toString().padLeft(2, '0');
  return [
    '$hh:$mm',
    ?record.sourceName,
    ?record.qualityLabel,
    record.viaProxy ? '局域网代理' : '直推',
  ].join(' · ');
}

/// 页内信息行：左标签、右值（可带颜色 / 右箭头 / 自定义尾部）。
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/xiaomi/mina_models.dart';
import '../../../theme/app_theme.dart';
import '../../shell/shell_bottom_area.dart';
import '../../shell/widgets/scrolling_page_header.dart';
import '../widgets/settings_action.dart';
import 'xiaoai_settings_controller.dart';

/// 目标音箱选择页：从模块一设备列表单选一台，在线状态随列表实时值。
class XiaoaiDevicePage extends ConsumerStatefulWidget {
  const XiaoaiDevicePage({super.key});

  @override
  ConsumerState<XiaoaiDevicePage> createState() => _XiaoaiDevicePageState();
}

class _XiaoaiDevicePageState extends ConsumerState<XiaoaiDevicePage> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    await ref.read(xiaoaiSettingsProvider.notifier).refreshDevices();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(xiaoaiSettingsProvider);
    final devices = settings.devices;
    final selectedId = settings.selectedDevice?.deviceId;

    return Scaffold(
      backgroundColor: scheme.appSettingsSurface,
      body: CustomScrollView(
        key: const PageStorageKey('xiaomi-device-scroll'),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (devices.isNotEmpty)
                        SettingsCard(
                          title: null,
                          children: [
                            for (final device in devices)
                              SettingsAction(
                                key: ValueKey(
                                  'xiaoai-device-${device.deviceId}',
                                ),
                                icon: Icons.speaker_outlined,
                                title: minaDeviceDisplayName(device),
                                value: device.isOnline ? '在线' : '离线',
                                trailingWidget: device.deviceId == selectedId
                                    ? Icon(
                                        Icons.check_rounded,
                                        size: 20,
                                        color: scheme.primary,
                                      )
                                    : null,
                                onTap: () => unawaited(_select(device)),
                              ),
                          ],
                        )
                      else
                        SettingsCard(
                          title: null,
                          insetContent: true,
                          separate: false,
                          children: [
                            Text(
                              _loading
                                  ? '正在加载设备…'
                                  : '未找到音箱，请确认音箱已绑定到该小米账号',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      const SizedBox(height: 16),
                      SettingsCard(
                        title: null,
                        children: [
                          SettingsAction(
                            icon: Icons.refresh_rounded,
                            title: '重新加载设备列表',
                            onTap: () {
                              if (!_loading) unawaited(_refresh());
                            },
                          ),
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
    );
  }

  Future<void> _select(MinaDevice device) async {
    await ref.read(xiaoaiSettingsProvider.notifier).selectDevice(device);
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/settings');
    }
  }
}

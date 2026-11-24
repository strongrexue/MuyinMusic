import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../core/storage/settings_store.dart';
import '../../core/ui/app_toast.dart';
import '../../theme/app_theme.dart';
import '../cloud/cloud_drive2_client.dart';
import '../cloud/cloud_library.dart';
import '../shell/shell_bottom_area.dart';
import '../shell/widgets/scrolling_page_header.dart';
import 'widgets/settings_action.dart';

/// CloudDrive2 独立设置页（与 WebDAV 同步同形态：设置页独立入口 → 独立页）。
/// 地址与令牌是页内输入框：编辑后回车即保存，测试连接直接用输入框现值
/// 探测，不要求先保存。令牌只进设置存储与请求头，不落日志。
class CloudDrive2SettingsPage extends ConsumerStatefulWidget {
  const CloudDrive2SettingsPage({super.key});

  @override
  ConsumerState<CloudDrive2SettingsPage> createState() =>
      _CloudDrive2SettingsPageState();
}

class _CloudDrive2SettingsPageState
    extends ConsumerState<CloudDrive2SettingsPage> {
  final _serverController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _tokenVisible = false;
  bool _testing = false;
  CloudConnectionResult? _testResult;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _serverController.text = settings.cloudDrive2Server;
    _tokenController.text = settings.cloudDrive2Token;
  }

  @override
  void dispose() {
    _serverController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _saveFields() async {
    final notifier = ref.read(settingsProvider.notifier);
    await notifier.setCloudDrive2Server(_serverController.text);
    await notifier.setCloudDrive2Token(_tokenController.text);
  }

  Future<void> _setEnabled(bool value) async {
    // 先把输入框现值落盘，开关读到的才是用户刚填的地址与令牌。
    await _saveFields();
    await ref.read(settingsProvider.notifier).setCloudDrive2Enabled(value);
  }

  Future<void> _testConnection() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_testing) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final result = await ref
        .read(cloudDrive2LibraryProvider)
        .testConnection(
          server: _serverController.text,
          token: _tokenController.text,
        );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
    if (result.ok) {
      showAppToast(context, 'CloudDrive2 连接成功', type: AppToastType.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.appSettingsSurface,
      body: CustomScrollView(
        key: const PageStorageKey('cloud-drive2-settings-scroll'),
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
                      SettingsCard(
                        separate: false,
                        title: '连接',
                        children: [
                          SettingsSwitchAction(
                            key: const ValueKey('cloud-drive2-enabled-switch'),
                            icon: Icons.cloud_outlined,
                            title: 'CloudDrive2',
                            subtitle: '把网盘中的音乐作为云端歌曲加入本地列表',
                            value: settings.cloudDrive2Enabled,
                            onChanged: (value) =>
                                unawaited(_setEnabled(value)),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: prism.FilledInputTheme(
                              borderRadius: prism.AppRadius.md,
                              fillColor: prism.SurfaceLevel.block.colorOf(
                                prism.Theme.of(context).colorScheme,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _LabeledField(
                                    label: '服务器地址',
                                    child: prism.TextField(
                                      key: const ValueKey(
                                        'cloud-drive2-server-field',
                                      ),
                                      controller: _serverController,
                                      keyboardType: TextInputType.url,
                                      textInputAction: TextInputAction.next,
                                      autocorrect: false,
                                      enableSuggestions: false,
                                      onSubmitted: (_) =>
                                          unawaited(_saveFields()),
                                      decoration: const prism.InputDecoration(
                                        hintText: '例如：192.168.1.10:19798',
                                        hintMaxLines: 1,
                                        prefixIcon: Icon(
                                          Icons.dns_outlined,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  _LabeledField(
                                    label: 'API 令牌',
                                    child: prism.TextField(
                                      key: const ValueKey(
                                        'cloud-drive2-token-field',
                                      ),
                                      controller: _tokenController,
                                      obscureText: !_tokenVisible,
                                      textInputAction: TextInputAction.done,
                                      autocorrect: false,
                                      enableSuggestions: false,
                                      enableIMEPersonalizedLearning: false,
                                      onSubmitted: (_) =>
                                          unawaited(_saveFields()),
                                      decoration: prism.InputDecoration(
                                        hintText: '在 CloudDrive2 管理界面创建的 API 令牌',
                                        hintMaxLines: 1,
                                        prefixIcon: const Icon(
                                          Icons.key_outlined,
                                          size: 20,
                                        ),
                                        suffixIcon: prism.IconButton(
                                          tooltip: _tokenVisible
                                              ? '隐藏令牌'
                                              : '显示令牌',
                                          onPressed: () => setState(
                                            () => _tokenVisible =
                                                !_tokenVisible,
                                          ),
                                          icon: Icon(
                                            _tokenVisible
                                                ? Icons
                                                      .visibility_off_outlined
                                                : Icons.visibility_outlined,
                                            size: 20,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (_testResult != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                              child: Row(
                                key: const ValueKey('cloud-drive2-test-result'),
                                children: [
                                  Icon(
                                    _testResult!.ok
                                        ? Icons.cloud_done_outlined
                                        : Icons.cloud_off_outlined,
                                    size: 18,
                                    color: _testResult!.ok
                                        ? scheme.primary
                                        : scheme.error,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _testResult!.message,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: _testResult!.ok
                                            ? scheme.onSurface
                                            : scheme.error,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                            child: FilledButton.icon(
                              key: const ValueKey('cloud-drive2-test-button'),
                              onPressed: _testing ? null : _testConnection,
                              icon: _testing
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.network_ping_rounded,
                                      size: 20,
                                    ),
                              label: Text(_testing ? '正在测试' : '测试连接'),
                            ),
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
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          label,
          style: prism.AppTextStyle.subheadline
              .of(context)
              .copyWith(
                color: prism.Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
      Semantics(label: label, child: child),
    ],
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/storage/glass_preview_provider.dart';
import '../../../core/storage/settings_store.dart';
import '../../../theme/glass_settings.dart';
import 'settings_sheet.dart';

/// 打开「玻璃设置」面板（对齐 MoviePilot 的 GlassSettingsDialog）：居中玻璃弹窗，
/// 拖动即时预览，保存后落盘。
///
/// 草稿在推路由之前写入：`initState` 期间改 provider 会在首个 build 里触发
/// `Tried to modify a provider while the widget tree was building`。
Future<void> showGlassSettingsDialog(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final preview = container.read(glassPreviewProvider.notifier);
  preview.state = container.read(settingsProvider).glassConfig;
  try {
    await showSettingsDialog<void>(
      context: context,
      builder: (_) => const _GlassSettingsDialog(),
    );
  } finally {
    // 保存路径会自己清空；关闭 / 点遮罩 / 返回键由这里兜底。
    preview.state = null;
  }
}

class _GlassSettingsDialog extends ConsumerStatefulWidget {
  const _GlassSettingsDialog();

  @override
  ConsumerState<_GlassSettingsDialog> createState() =>
      _GlassSettingsDialogState();
}

class _GlassSettingsDialogState extends ConsumerState<_GlassSettingsDialog> {
  late GlassConfig _draft;

  @override
  void initState() {
    super.initState();
    // 只读不写：预览草稿由 showGlassSettingsDialog 提前写好。
    _draft = ref.read(settingsProvider).glassConfig;
  }

  StateController<GlassConfig?> get _preview =>
      ref.read(glassPreviewProvider.notifier);

  void _selectTab(GlassAppearance appearance) {
    final next = _draft.copyWith(appearance: appearance);
    setState(() => _draft = next);
    _preview.state = next;
  }

  void _updateCurrent(GlassSettings settings) {
    final next = _draft.copyWith(
      tabs: _draft.tabs.withAppearance(_draft.appearance, settings),
    );
    setState(() => _draft = next);
    _preview.state = next;
  }

  void _resetCurrentTab() =>
      _updateCurrent(GlassSettings.presetFor(_draft.appearance));

  Future<void> _save() async {
    await ref.read(settingsProvider.notifier).setGlassConfig(_draft);
    if (!mounted) return;
    _preview.state = null;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final current = _draft.tabs.forAppearance(_draft.appearance);
    final scheme = prism.Theme.of(context).colorScheme;
    return prism.AlertDialog(
      title: '玻璃设置',
      contentWidth: 340,
      actions: [
        prism.TextButton(onPressed: _resetCurrentTab, child: const Text('重置')),
        prism.FilledButton(onPressed: _save, child: const Text('保存')),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '调整即时预览，保存后生效；关闭或取消不写入',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          prism.SegmentedControl<GlassAppearance>(
            segments: const [
              (GlassAppearance.frosted, '磨砂'),
              (GlassAppearance.clear, '透明'),
            ],
            value: _draft.appearance,
            onChanged: _selectTab,
          ),
          const SizedBox(height: 4),
          _GlassSlider(
            label: '通透度',
            value: current.clarity,
            onChanged: (value) =>
                _updateCurrent(current.copyWith(clarity: value)),
          ),
          _GlassSlider(
            label: '透射亮度',
            value: current.transmission,
            onChanged: (value) =>
                _updateCurrent(current.copyWith(transmission: value)),
          ),
          _GlassSlider(
            label: '反射亮度',
            value: current.reflection,
            onChanged: (value) =>
                _updateCurrent(current.copyWith(reflection: value)),
          ),
        ],
      ),
    );
  }
}

class _GlassSlider extends StatelessWidget {
  const _GlassSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(label), Text('${value.round()}%')],
        ),
        prism.Slider(
          value: value,
          min: 0,
          max: 100,
          divisions: 100,
          label: '${value.round()}%',
          onChanged: onChanged,
        ),
      ],
    ),
  );
}

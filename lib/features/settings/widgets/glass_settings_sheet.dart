import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/storage/glass_preview_provider.dart';
import '../../../core/storage/settings_store.dart';
import '../../../theme/glass_settings.dart';
import 'settings_sheet.dart';

/// 打开「玻璃设置」二级面板（对齐 MoviePilot 的 GlassSettingsDialog）。
Future<void> showGlassSettingsSheet(BuildContext context) async {
  await showSettingsSheet<void>(
    context: context,
    showDragHandle: true,
    heightFraction: 0.9,
    maxHeight: 720,
    detents: const [0.9],
    builder: (_) => const _GlassSettingsSheet(),
  );
}

class _GlassSettingsSheet extends ConsumerStatefulWidget {
  const _GlassSettingsSheet();

  @override
  ConsumerState<_GlassSettingsSheet> createState() =>
      _GlassSettingsSheetState();
}

class _GlassSettingsSheetState extends ConsumerState<_GlassSettingsSheet> {
  late final StateController<GlassConfig?> _preview;
  late GlassConfig _draft;

  @override
  void initState() {
    super.initState();
    _preview = ref.read(glassPreviewProvider.notifier);
    _draft = ref.read(settingsProvider).glassConfig;
    // 打开即进入预览：面板里的改动只写草稿，不落盘。
    _preview.state = _draft;
  }

  @override
  void dispose() {
    // 任何关闭路径（保存 / 关闭 / barrier）都撤掉草稿，恢复持久化配置。
    // 用 post-frame 避免在 widget 树 dispose 期间直接改 provider。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preview.state = null;
    });
    super.dispose();
  }

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

  void _resetCurrentTab() => _updateCurrent(GlassSettings.defaults);

  Future<void> _save() async {
    await ref.read(settingsProvider.notifier).setGlassConfig(_draft);
    if (!mounted) return;
    _preview.state = null;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final current = _draft.tabs.forAppearance(_draft.appearance);
    return SettingsSheetLayout(
      title: '玻璃设置',
      subtitle: '调整即时预览，保存后生效；关闭或取消不写入',
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<GlassAppearance>(
              segments: const [
                ButtonSegment(
                  value: GlassAppearance.frosted,
                  label: Text('磨砂'),
                ),
                ButtonSegment(
                  value: GlassAppearance.clear,
                  label: Text('透明'),
                ),
                ButtonSegment(
                  value: GlassAppearance.tinted,
                  label: Text('色调'),
                ),
              ],
              selected: {_draft.appearance},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => _selectTab(selection.first),
            ),
            const SizedBox(height: 16),
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
      ),
      actions: [
        prism.TextButton(
          onPressed: _resetCurrentTab,
          child: const Text('重置'),
        ),
        prism.FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
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
          children: [
            Text(label),
            Text('${value.round()}%'),
          ],
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

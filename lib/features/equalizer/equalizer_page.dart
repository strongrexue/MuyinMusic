import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../core/ui/app_toast.dart';
import '../../core/ui/car_display_layout.dart';
import '../../theme/app_theme.dart';
import '../playlists/playlist_name_dialog.dart';
import '../settings/widgets/settings_action.dart';
import '../settings/widgets/settings_menu.dart';
import '../settings/widgets/settings_sheet.dart';
import '../shell/shell_toolbar_visibility.dart';
import '../shell/shell_bottom_area.dart';
import '../shell/widgets/scrolling_page_header.dart';
import 'equalizer_store.dart';
import 'widgets/equalizer_band_editor.dart';
import 'widgets/equalizer_controls.dart';
import 'widgets/equalizer_curve.dart';

class EqualizerPage extends ConsumerStatefulWidget {
  const EqualizerPage({super.key});

  @override
  ConsumerState<EqualizerPage> createState() => _EqualizerPageState();
}

class _EqualizerPageState extends ConsumerState<EqualizerPage> {
  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(equalizerProvider);
    final notifier = ref.read(equalizerProvider.notifier);
    final userPresets = ref.watch(userEqualizerPresetsProvider);
    final scheme = Theme.of(context).colorScheme;
    final isCustom =
        !equalizerPresets.any((preset) => preset.id == settings.presetId) &&
        !userPresets.any((preset) => preset.id == settings.presetId);

    return Scaffold(
      backgroundColor: scheme.appSettingsSurface,
      body: CustomScrollView(
        key: const PageStorageKey('equalizer-scroll'),
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
                  constraints: CarDisplayLayout.contentConstraints(
                    context,
                    maxWidth: 640,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SettingsCard(
                        separate: false,
                        children: [
                          SettingsSwitchAction(
                            icon: Icons.graphic_eq_rounded,
                            title: '启用均衡器',
                            value: settings.enabled,
                            onChanged: notifier.setEnabled,
                          ),
                          SettingsMenuAction(
                            menuId: 'equalizer-preset',
                            icon: Icons.auto_awesome_outlined,
                            title: '声音预设',
                            options: [
                              if (isCustom)
                                SettingsMenuOption(
                                  id: 'custom',
                                  label: '自定义',
                                  selected: true,
                                  enabled: false,
                                  onSelected: () {},
                                ),
                              for (final preset in equalizerPresets)
                                SettingsMenuOption(
                                  id: preset.id,
                                  label: preset.label,
                                  selected: settings.presetId == preset.id,
                                  onSelected: () =>
                                      notifier.applyPreset(preset),
                                ),
                              for (final preset in userPresets)
                                SettingsMenuOption(
                                  id: preset.id,
                                  label: preset.label,
                                  selected: settings.presetId == preset.id,
                                  onSelected: () =>
                                      notifier.applyPreset(preset),
                                ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            child: EqualizerCurve(settings: settings),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SettingsCard(
                        title: '增益调节',
                        insetContent: true,
                        children: [
                          EqualizerValueSlider(
                            label: '输入增益',
                            valueLabel: equalizerDbLabel(settings.inputGainDb),
                            value: settings.inputGainDb,
                            min: equalizerMinGainDb,
                            max: equalizerMaxGainDb,
                            onChanged: notifier.setInputGain,
                            onReset: settings.inputGainDb.abs() > 0.05
                                ? () => notifier.setInputGain(0)
                                : null,
                          ),
                          const SizedBox(height: 12),
                          EqualizerValueSlider(
                            label: '输出增益',
                            valueLabel: equalizerDbLabel(settings.outputGainDb),
                            value: settings.outputGainDb,
                            min: equalizerMinGainDb,
                            max: equalizerMaxGainDb,
                            onChanged: notifier.setOutputGain,
                            onReset: settings.outputGainDb.abs() > 0.05
                                ? () => notifier.setOutputGain(0)
                                : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      EqualizerBandsSection(
                        bands: settings.bands,
                        onAdd: () => _addBand(settings),
                        onEdit: _editBand,
                        onGainChanged: notifier.setBandGain,
                      ),
                      const SizedBox(height: 12),
                      SettingsCard(
                        // 均衡器页保持整块，跟设置页的逐行卡片区分开。
                        separate: false,
                        title: '预设配置',
                        children: [
                          SettingsAction(
                            icon: Icons.file_open_outlined,
                            title: '导入预设',
                            value: '.speq / .json',
                            trailing: Icons.chevron_right_rounded,
                            onTap: _importSpeq,
                          ),
                          SettingsAction(
                            icon: Icons.save_alt_rounded,
                            title: '导出预设',
                            value: '.speq',
                            trailing: Icons.chevron_right_rounded,
                            onTap: () => _exportSpeq(settings),
                          ),
                          if (userPresets.isNotEmpty)
                            SettingsMenuAction(
                              menuId: 'equalizer-rename-imported',
                              icon: Icons.drive_file_rename_outline_rounded,
                              title: '重命名导入的预设',
                              options: [
                                for (final preset in userPresets)
                                  SettingsMenuOption(
                                    id: preset.id,
                                    label: preset.label,
                                    selected: false,
                                    onSelected: () =>
                                        _renameUserPreset(preset),
                                  ),
                              ],
                            ),
                          if (userPresets.isNotEmpty)
                            SettingsAction(
                              icon: Icons.delete_sweep_outlined,
                              title: '清除导入的预设',
                              value: '${userPresets.length} 个',
                              onTap: () => ref
                                  .read(userEqualizerPresetsProvider.notifier)
                                  .clear(),
                            ),
                          SettingsAction(
                            icon: Icons.restart_alt_rounded,
                            title: '恢复默认',
                            trailing: Icons.chevron_right_rounded,
                            onTap: _reset,
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

  Future<T> _withHiddenToolbar<T>(Future<T> Function() action) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final toolbar = ref.read(shellToolbarVisibleProvider.notifier);
    final wasToolbarVisible = ref.read(shellToolbarVisibleProvider);
    toolbar.state = false;
    try {
      return await action();
    } finally {
      if (toolbar.mounted) toolbar.state = wasToolbarVisible;
    }
  }

  Future<void> _addBand(EqualizerSettings settings) async {
    final band = EqualizerBandSetting(
      id: 'custom-${DateTime.now().microsecondsSinceEpoch}',
      frequencyHz: nextEqualizerBandFrequency(settings.bands),
    );
    final result = await _withHiddenToolbar(
      () => showEqualizerBandEditor(context, band, adding: true),
    );
    if (result is EqualizerBandSaved && mounted) {
      ref.read(equalizerProvider.notifier).addBand(result.band);
    }
  }

  Future<void> _editBand(EqualizerBandSetting band) async {
    final result = await _withHiddenToolbar(
      () => showEqualizerBandEditor(context, band, adding: false),
    );
    if (!mounted) return;
    if (result is EqualizerBandSaved) {
      ref.read(equalizerProvider.notifier).updateBand(result.band);
    } else if (result is EqualizerBandDeleted) {
      ref.read(equalizerProvider.notifier).removeBand(band.id);
    }
  }

  Future<void> _importSpeq() async {
    // .speq has no MIME type registered with Android, so filtering by
    // custom extension leaves such files unselectable in the system
    // picker. Pick any file and validate the extension here instead.
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '导入均衡器配置',
      type: FileType.any,
      withData: true,
    );
    if (result == null || !mounted) return;
    try {
      final picked = result.files.single;
      final name = picked.name.toLowerCase();
      if (!name.endsWith('.speq') && !name.endsWith('.json')) {
        throw const FormatException('请选择 .speq 或 .json 配置文件');
      }
      final value = picked.bytes != null
          ? utf8.decode(picked.bytes!)
          : await File(picked.path!).readAsString();
      ref.read(equalizerProvider.notifier).importSpeq(value);
      if (!mounted) return;
      showAppToast(context, '均衡器配置已导入', type: AppToastType.success);
    } catch (error) {
      if (!mounted) return;
      showAppToast(context, '无法导入配置：$error', type: AppToastType.error);
    }
  }

  Future<void> _exportSpeq(EqualizerSettings settings) async {
    try {
      final content = settings.toSpeq();
      // Android and iOS require the bytes up front: the plugin writes them
      // itself and returns a content URI rather than a writable path.
      // Desktop pickers only return a path, so write the file there.
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出均衡器配置',
        fileName: 'MuyinMusic.speq',
        type: FileType.custom,
        allowedExtensions: const ['speq'],
        bytes: Uint8List.fromList(utf8.encode(content)),
      );
      if (path == null || !mounted) return;
      if (!Platform.isAndroid && !Platform.isIOS) {
        var target = path;
        if (!target.toLowerCase().endsWith('.speq')) target = '$target.speq';
        await File(target).writeAsString(content, flush: true);
      }
      if (!mounted) return;
      showAppToast(context, '均衡器配置已导出', type: AppToastType.success);
    } catch (error) {
      if (!mounted) return;
      showAppToast(context, '无法导出配置：$error', type: AppToastType.error);
    }
  }

  Future<void> _renameUserPreset(EqualizerPreset preset) async {
    final name = await _withHiddenToolbar(
      () => showPlaylistNameDialog(
        context,
        title: '重命名预设',
        actionLabel: '保存',
        initialValue: preset.label,
      ),
    );
    if (name == null || !mounted) return;
    ref.read(userEqualizerPresetsProvider.notifier).rename(preset.id, name);
    if (!mounted) return;
    showAppToast(context, '预设名称已更新', type: AppToastType.success);
  }

  Future<void> _reset() async {
    final confirmed = await _withHiddenToolbar(
      () => showSettingsDialog<bool>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) => prism.AlertDialog(
          title: '恢复默认均衡器？',
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('恢复'),
            ),
          ],
          child: const Text('这会关闭均衡器，并恢复原声配置。'),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    ref.read(equalizerProvider.notifier).reset();
  }
}

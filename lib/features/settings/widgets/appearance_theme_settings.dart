import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import 'glass_settings_dialog.dart';
import 'settings_action.dart';
import 'settings_menu.dart';
import 'theme_color_settings.dart';

class AppearanceThemeSettings extends ConsumerWidget {
  const AppearanceThemeSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCard(
          title: '主题',
          children: [
            SettingsMenuAction(
              menuId: 'theme-mode-menu',
              applyImmediately: true,
              showSubtitle: false,
              icon: Icons.dark_mode_outlined,
              title: '主题模式',
              options: [
                for (final item in const {
                  ThemeMode.system: '跟随系统',
                  ThemeMode.light: '浅色',
                  ThemeMode.dark: '深色',
                }.entries)
                  SettingsMenuOption(
                    id: item.key.name,
                    label: item.value,
                    selected: settings.themeMode == item.key,
                    onSelected: () => notifier.setThemeMode(item.key),
                  ),
              ],
            ),
          ],
        ),
        const ThemeColorSettings(),
        SettingsCard(
          title: '材质',
          children: [
            SettingsSwitchAction(
              icon: Icons.blur_on_rounded,
              title: '启用玻璃特效',
              value: settings.glassEnabled,
              onChanged: notifier.setGlassEnabled,
            ),
            if (settings.glassEnabled)
              SettingsAction(
                icon: Icons.tune_rounded,
                title: '玻璃设置',
                onTap: () => showGlassSettingsDialog(context),
              ),
          ],
        ),
      ],
    );
  }
}

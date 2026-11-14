import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/storage/glass_preview_provider.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/settings/widgets/glass_settings_dialog.dart';
import 'package:cy_shine_music/theme/app_theme.dart';
import 'package:cy_shine_music/theme/glass_settings.dart';

import 'helpers/prism_test_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('glass config decode falls back and clamps out-of-range values', () {
    expect(GlassConfig.decode(null), GlassConfig.defaults);
    expect(GlassConfig.decode('not json'), GlassConfig.defaults);
    expect(GlassConfig.decode(123), GlassConfig.defaults);
    final decoded = GlassConfig.decode(
      jsonEncode({
        // A retired "色调" tab decodes back to the frosted preset.
        'appearance': 'tinted',
        'tabs': {
          'clear': {'clarity': 999, 'transmission': -5, 'reflection': 30},
        },
      }),
    );
    expect(decoded.appearance, GlassAppearance.frosted);
    expect(decoded.tabs.clear.clarity, 100);
    expect(decoded.tabs.clear.transmission, 0);
    expect(decoded.tabs.clear.reflection, 30);
    expect(decoded.tabs.frosted.reflection, 38);
  });

  test('each glass tab keeps its own settings across restarts', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await notifier.setGlassSettingsForTab(
      GlassAppearance.clear,
      const GlassSettings(clarity: 80),
    );
    await notifier.setGlassAppearance(GlassAppearance.clear);
    final config = container.read(settingsProvider).glassConfig;
    expect(config.appearance, GlassAppearance.clear);
    expect(config.tabs.clear.clarity, 80);
    expect(config.tabs.frosted.clarity, 47);
    final restored = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(restored.dispose);
    expect(restored.read(settingsProvider).glassConfig.tabs.clear.clarity, 80);
    expect(
      restored.read(settingsProvider).glassConfig.appearance,
      GlassAppearance.clear,
    );
  });

  test('glass preview overrides without writing disk until save', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    final initial = container.read(effectiveGlassConfigProvider);
    expect(initial, GlassConfig.defaults);

    const draft = GlassConfig(
      appearance: GlassAppearance.clear,
      tabs: GlassSettingsByTab(
        clear: GlassSettings(clarity: 90, transmission: 10, reflection: 20),
      ),
    );
    container.read(glassPreviewProvider.notifier).state = draft;
    expect(container.read(effectiveGlassConfigProvider), draft);
    expect(prefs.getString('glass_config'), isNull);

    // 取消：清草稿，回到持久化值。
    container.read(glassPreviewProvider.notifier).state = null;
    expect(container.read(effectiveGlassConfigProvider), initial);

    // 保存：写盘。
    await notifier.setGlassConfig(draft);
    expect(container.read(effectiveGlassConfigProvider), draft);
    expect(GlassConfig.decode(prefs.getString('glass_config')), draft);
  });

  test('appearance sync rejects malformed glass config atomically', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    final backup = notifier.exportAppearanceForSync();
    await expectLater(
      notifier.applyAppearanceFromSync({...backup, 'glassConfig': 123}),
      throwsFormatException,
    );
    expect(notifier.exportAppearanceForSync(), backup);
  });

  test('style transform maps slider bounds to a valid glass style', () {
    final base = prism.LiquidGlassStyle(tint: const Color(0x66FFFFFF));
    for (final appearance in GlassAppearance.values) {
      for (final value in const [0.0, 50.0, 100.0]) {
        final settings = GlassSettings(
          clarity: value,
          transmission: value,
          reflection: value,
        );
        final result = settings.applyTo(base, appearance);
        expect(result.tint.a, inInclusiveRange(0.0, 1.0));
        expect(result.blur, greaterThanOrEqualTo(0));
        expect(result.haze, greaterThanOrEqualTo(0));
      }
    }
  });

  /// 首开红屏的回归：草稿曾经在 `initState` 里写 provider，首个 build 直接抛
  /// `Tried to modify a provider while the widget tree was building`。
  testWidgets('glass settings dialog reopens, previews and saves', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    // app.dart:289 一直在 watch 这个 provider；没有监听者时 StateController
    // 干脆不通知，红屏反而复现不出来。
    container.listen(effectiveGlassConfigProvider, (_, _) {});

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: buildPrismTestEnvironment,
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showGlassSettingsDialog(context),
                child: const Text('打开玻璃设置'),
              ),
            ),
          ),
        ),
      ),
    );

    // 第一次：打开 → 切 tab → 关闭（不写盘）。
    await tester.tap(find.text('打开玻璃设置'));
    await tester.pumpAndSettle();
    expect(find.text('玻璃设置'), findsOneWidget);
    expect(container.read(glassPreviewProvider), GlassConfig.defaults);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('透明'));
    await tester.pumpAndSettle();
    expect(
      container.read(glassPreviewProvider)?.appearance,
      GlassAppearance.clear,
    );
    expect(prefs.getString('glass_config'), isNull);

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('玻璃设置'), findsNothing);
    expect(container.read(glassPreviewProvider), isNull);

    // 第二次：连开不炸，保存后落盘。
    await tester.tap(find.text('打开玻璃设置'));
    await tester.pumpAndSettle();
    expect(container.read(glassPreviewProvider), GlassConfig.defaults);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('玻璃设置'), findsNothing);
    expect(container.read(glassPreviewProvider), isNull);
    expect(prefs.getString('glass_config'), isNotNull);
    expect(container.read(settingsProvider).glassConfig, GlassConfig.defaults);
  });
}

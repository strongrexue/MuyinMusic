import 'package:flutter/material.dart';

import 'app_motion.dart';

class AppTheme {
  const AppTheme._();

  static const Color designSeed = Colors.blue;

  /// Same CJK stack the player lyrics render with, so body text across the
  /// app matches the lyric typography.
  static const List<String> fontFallback = [
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'HarmonyOS Sans SC',
    'PingFang SC',
    'Microsoft YaHei',
  ];

  static ThemeData light([Color seed = designSeed]) =>
      _build(Brightness.light, seed);

  static ThemeData dark([Color seed = designSeed]) =>
      _build(Brightness.dark, seed);

  static ThemeData fromScheme(ColorScheme scheme) => _buildFromScheme(scheme);

  /// 固定用 fidelity 展开种子色：primary 尽量还原用户选的原色（对齐 MoviePilot）。
  static ColorScheme schemeFor(Color seed, Brightness brightness) =>
      ColorScheme.fromSeed(
        seedColor: seed,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      );

  static ThemeData _build(Brightness brightness, Color seed) =>
      _buildFromScheme(schemeFor(seed, brightness));

  /// 背景永远中性：所有 surface 角色洗成中性灰阶，配色只影响强调色。
  static ColorScheme surfaceSchemeFor(ColorScheme base) => neutralSurfaces(base);

  static ColorScheme neutralSurfaces(ColorScheme base) {
    final dark = base.brightness == Brightness.dark;
    return base.copyWith(
      surface: dark ? const Color(0xFF101012) : Colors.white,
      surfaceDim: dark ? const Color(0xFF101012) : const Color(0xFFE4E4E7),
      surfaceBright: dark ? const Color(0xFF363639) : Colors.white,
      surfaceContainerLowest: dark ? const Color(0xFF0C0C0E) : Colors.white,
      surfaceContainerLow: dark ? const Color(0xFF1C1C1E) : Colors.white,
      surfaceContainer: dark
          ? const Color(0xFF242426)
          : const Color(0xFFF2F2F5),
      surfaceContainerHigh: dark
          ? const Color(0xFF2C2C2E)
          : const Color(0xFFEDEDF0),
      surfaceContainerHighest: dark
          ? const Color(0xFF363639)
          : const Color(0xFFE5E5EA),
      onSurface: dark ? const Color(0xFFF5F5F7) : const Color(0xFF1C1C1E),
      onSurfaceVariant: dark
          ? const Color(0xFFAEAEB2)
          : const Color(0xFF6E6E73),
      outline: dark ? const Color(0xFF8E8E93) : const Color(0xFF8E8E93),
      outlineVariant: dark ? const Color(0xFF3A3A3C) : const Color(0xFFDCDCE0),
      surfaceTint: Colors.transparent,
    );
  }

  static ThemeData _buildFromScheme(ColorScheme base) {
    final scheme = surfaceSchemeFor(base);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,

      // NavigationBar 会把 32dp 的指示胶囊和标签在这个高度里垂直居中，
      // 内容本身约 52dp；再往下压会被 loose 约束挤扁并溢出到背景之外。
      navigationBarTheme: const NavigationBarThemeData(height: 64),
      fontFamilyFallback: fontFallback,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      splashFactory: InkRipple.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 2,
        surfaceTintColor: scheme.surfaceTint,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w500,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.appContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
      ),
      chipTheme: ChipThemeData(
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        hoverColor: scheme.onSurface.withValues(alpha: 0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: scheme.appContainerHigh,
        contentTextStyle: TextStyle(color: scheme.onSurface),
        actionTextColor: scheme.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.appContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(28)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(72, 48),
          shape: const StadiumBorder(),
        ).copyWith(animationDuration: AppMotion.medium),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(72, 48),
          shape: const StadiumBorder(),
          side: BorderSide(color: scheme.outline),
        ).copyWith(animationDuration: AppMotion.medium),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: const CircleBorder(),
        ).copyWith(animationDuration: AppMotion.medium),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: scheme.outline),
            ),
          ),
        ),
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16),
        ),
      ),
      searchViewTheme: SearchViewThemeData(
        backgroundColor: scheme.appContainerHigh,
        surfaceTintColor: Colors.transparent,
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
    );
  }
}

extension AppColorScheme on ColorScheme {
  /// Match Prism's page level; its dark card level uses surfaceContainer.
  Color get appSettingsSurface =>
      brightness == Brightness.dark ? surface : surfaceContainer;

  Color get appSurface => surfaceContainerLow.withValues(alpha: 1);

  Color get appContainerLow => surfaceContainerLow;

  Color get appContainerHigh => surfaceContainerHigh;

  Color get appContainerHighest => surfaceContainerHighest;

  Color get appInputFill =>
      _blendPrimary(brightness == Brightness.dark ? 0.14 : 0.07);

  Color _blendPrimary(double alpha) {
    return Color.alphaBlend(
      primary.withValues(alpha: alpha),
      appSurface,
    ).withValues(alpha: 1);
  }
}

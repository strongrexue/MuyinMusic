import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

/// 玻璃外观两档（磨砂 / 透明）。
enum GlassAppearance {
  frosted('frosted', '磨砂'),
  clear('clear', '透明');

  const GlassAppearance(this.code, this.label);

  final String code;
  final String label;

  static GlassAppearance fromCode(String? code) => values.firstWhere(
    (value) => value.code == code,
    orElse: () => GlassAppearance.frosted,
  );
}

double _clamp(double value) => value.clamp(0.0, 100.0);

/// The placeholder values older builds wrote for both presets.
const GlassSettings _legacyDefault50 = GlassSettings(
  clarity: 50,
  transmission: 50,
  reflection: 50,
);

/// 一个 tab 的 3 个静态滑杆（0..100）。
@immutable
class GlassSettings {
  const GlassSettings({
    this.clarity = 47,
    this.transmission = 59,
    this.reflection = 38,
  });

  /// 通透度：越高玻璃越清、底色越透。
  final double clarity;

  /// 透射亮度：透过玻璃看到的背景亮度。
  final double transmission;

  /// 反射亮度：边缘高光 / rim 亮度。
  final double reflection;

  /// 磨砂预设：通透度 47% / 透射亮度 59% / 反射亮度 38%。
  static const frosted = GlassSettings(
    clarity: 47,
    transmission: 59,
    reflection: 38,
  );

  /// 透明预设：通透度 55% / 透射亮度 61% / 反射亮度 43%。
  static const clear = GlassSettings(
    clarity: 55,
    transmission: 61,
    reflection: 43,
  );

  static const defaults = frosted;

  static GlassSettings presetFor(GlassAppearance appearance) =>
      switch (appearance) {
        GlassAppearance.frosted => frosted,
        GlassAppearance.clear => clear,
      };

  GlassSettings copyWith({
    double? clarity,
    double? transmission,
    double? reflection,
  }) => GlassSettings(
    clarity: _clamp(clarity ?? this.clarity),
    transmission: _clamp(transmission ?? this.transmission),
    reflection: _clamp(reflection ?? this.reflection),
  );

  Map<String, double> toJson() => {
    'clarity': clarity,
    'transmission': transmission,
    'reflection': reflection,
  };

  static GlassSettings fromJson(Object? json, [GlassSettings? fallback]) {
    final defaults = fallback ?? GlassSettings.frosted;
    if (json is! Map) return defaults;
    double read(String key) {
      final value = json[key];
      return value is num ? _clamp(value.toDouble()) : defaults.clarity;
    }

    final decoded = GlassSettings(
      clarity: read('clarity'),
      transmission: read('transmission'),
      reflection: read('reflection'),
    );
    // Builds before the presets shipped defaulted every slider to 50%; those
    // are indistinguishable from "never touched", so they follow the preset.
    if (decoded == _legacyDefault50) return defaults;
    return decoded;
  }

  /// 把当前滑杆 + 外观档映射成 prism 的 19 字段 style 变换。
  /// 纯 Dart、不碰 .frag；所有 pane 的 style 都会经过它。
  prism.LiquidGlassStyle applyTo(
    prism.LiquidGlassStyle base,
    GlassAppearance appearance,
  ) {
    final clarity = _clamp(this.clarity) / 100;
    final transmission = _clamp(this.transmission) / 100;
    final reflection = _clamp(this.reflection) / 100;

    // 两档外观预设。用 switch 表达式返回 record，避免任何控制流歧义。
    final (tintAlpha, blurScale, haze, brightnessBias) =
        switch (appearance) {
      GlassAppearance.frosted => (0.62, 1.4, 0.35, -0.1),
      GlassAppearance.clear => (0.28, 0.7, 0.0, 0.15),
    };

    // 通透度越高，底色越淡、模糊越小。
    final alpha = (tintAlpha * (1.1 - 0.6 * clarity)).clamp(0.0, 1.0);
    final blur = base.blur * blurScale * (1.4 - 0.8 * clarity);

    return prism.LiquidGlassStyle(
      tint: base.tint.withValues(alpha: alpha),
      contrast: base.contrast,
      blur: blur,
      haze: haze,
      hazeBlur: base.hazeBlur > 0 ? base.hazeBlur : 15.6,
      refraction: base.refraction,
      bevel: base.bevel,
      saturation: base.saturation,
      brightness:
          base.brightness + brightnessBias + (transmission - 0.5) * 0.5,
      rim: (base.rim * (0.5 + reflection)).clamp(0.0, 2.0),
      rimWidth: base.rimWidth,
      rimTail: base.rimTail,
      rimFocus: base.rimFocus,
      rimAdded: base.rimAdded,
      endShade: base.endShade,
      dispersion: base.dispersion,
      rimBlur: base.rimBlur,
      hairline: base.hairline,
      hairlineSide: base.hairlineSide,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlassSettings &&
      other.clarity == clarity &&
      other.transmission == transmission &&
      other.reflection == reflection;

  @override
  int get hashCode => Object.hash(clarity, transmission, reflection);
}

/// 两个 tab 各存各的一份设置。
@immutable
class GlassSettingsByTab {
  const GlassSettingsByTab({
    this.frosted = GlassSettings.frosted,
    this.clear = GlassSettings.clear,
  });

  final GlassSettings frosted;
  final GlassSettings clear;

  GlassSettings forAppearance(GlassAppearance appearance) =>
      switch (appearance) {
        GlassAppearance.frosted => frosted,
        GlassAppearance.clear => clear,
      };

  GlassSettingsByTab withAppearance(
    GlassAppearance appearance,
    GlassSettings settings,
  ) => switch (appearance) {
    GlassAppearance.frosted => copyWith(frosted: settings),
    GlassAppearance.clear => copyWith(clear: settings),
  };

  GlassSettingsByTab copyWith({
    GlassSettings? frosted,
    GlassSettings? clear,
  }) => GlassSettingsByTab(
    frosted: frosted ?? this.frosted,
    clear: clear ?? this.clear,
  );

  Map<String, dynamic> toJson() => {
    'frosted': frosted.toJson(),
    'clear': clear.toJson(),
  };

  static GlassSettingsByTab fromJson(Object? json) {
    if (json is! Map) return const GlassSettingsByTab();
    return GlassSettingsByTab(
      frosted: GlassSettings.fromJson(json['frosted'], GlassSettings.frosted),
      clear: GlassSettings.fromJson(json['clear'], GlassSettings.clear),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlassSettingsByTab &&
      other.frosted == frosted &&
      other.clear == clear;

  @override
  int get hashCode => Object.hash(frosted, clear);
}

/// 全部玻璃配置：当前 tab + 三 tab 设置，单 blob 持久化 / 同步。
@immutable
class GlassConfig {
  const GlassConfig({
    this.appearance = GlassAppearance.frosted,
    this.tabs = const GlassSettingsByTab(),
  });

  final GlassAppearance appearance;
  final GlassSettingsByTab tabs;

  static const defaults = GlassConfig();

  GlassConfig copyWith({
    GlassAppearance? appearance,
    GlassSettingsByTab? tabs,
  }) => GlassConfig(
    appearance: appearance ?? this.appearance,
    tabs: tabs ?? this.tabs,
  );

  /// 生成供 prism_ui 注入的 style 变换（捕获外观档）。
  prism.LiquidGlassStyle Function(prism.LiquidGlassStyle) toStyleTransform() {
    final appearance = this.appearance;
    final settings = tabs.forAppearance(appearance);
    return (base) => settings.applyTo(base, appearance);
  }

  String encode() => jsonEncode({
    'appearance': appearance.code,
    'tabs': tabs.toJson(),
  });

  static GlassConfig decode(Object? raw) {
    if (raw is! String) return defaults;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return defaults;
      return GlassConfig(
        appearance: GlassAppearance.fromCode(json['appearance'] as String?),
        tabs: GlassSettingsByTab.fromJson(json['tabs']),
      );
    } catch (_) {
      return defaults;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is GlassConfig &&
      other.appearance == appearance &&
      other.tabs == tabs;

  @override
  int get hashCode => Object.hash(appearance, tabs);
}

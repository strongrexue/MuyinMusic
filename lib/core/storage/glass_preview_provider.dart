import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/glass_settings.dart';
import 'settings_store.dart';

/// 二级页拖动滑杆时的草稿，只在内存里、不落盘。
/// 对齐 MoviePilot `useThemeCustomizer.ts` 的 preview / commit / cancel 事务。
final glassPreviewProvider = StateProvider<GlassConfig?>((ref) => null);

/// PrismEnvironment 读这个：草稿优先，否则用已持久化的配置。
final effectiveGlassConfigProvider = Provider<GlassConfig>((ref) {
  final preview = ref.watch(glassPreviewProvider);
  if (preview != null) return preview;
  return ref.watch(settingsProvider.select((settings) => settings.glassConfig));
});

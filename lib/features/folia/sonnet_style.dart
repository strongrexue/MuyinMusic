import 'folia_common_background.dart';
import 'folia_stage_registry.dart';
import 'sonnet_stage.dart';

/// Registers the sonnet (商籁) stage style: id 'sonnet', display
/// label '商籁' — both verified against the Folia source
/// (src/components/visualizer/sonnet/entry.tsx: mode 'sonnet',
/// labelFallback '商籁'; src/i18n/locales/zh-CN.ts
/// "visualizerSonnet": "商籁").
FoliaStageStyle sonnetStageStyle() => FoliaStageStyle(
  id: 'sonnet',
  label: '商籁',
  builder: (context, stage) => SonnetStageWidget(stage: stage),
);

/// Registers every built-in folia style and background. Called once
/// at startup from main.dart, before runApp. The background is
/// Folia's built-in 'common' (通用) — the dark cover-derived base +
/// geometric layer the folia stage sits on.
void registerFoliaStyles([FoliaStageRegistry? registry]) {
  final target = registry ?? foliaStageRegistry;
  target.register(sonnetStageStyle());
  target.registerBackground(commonStageBackground());
}

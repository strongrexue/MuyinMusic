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

/// Registers every built-in folia style. Called once at startup
/// from main.dart, before runApp.
void registerFoliaStyles() {
  foliaStageRegistry.register(sonnetStageStyle());
}

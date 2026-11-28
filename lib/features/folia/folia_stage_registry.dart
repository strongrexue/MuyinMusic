import 'package:flutter/material.dart';

import '../player/lyric_parser.dart';
import 'audio_analysis.dart';
import 'folia_theme.dart';

/// Folia porting rule (user, 2026-11-28): verify every style/background
/// behaviour, parameter and display name against the Folia source
/// registry first — never from screenshots or memory. Source of truth
/// is the read-only copy at ~/workspace/folia-sonnet-research:
///   src/types/visualizerModes.ts — BUILTIN_VISUALIZER_MODES (21 styles)
///     blank 无歌词, cadenza 心象, cappella 群唱, claddagh 回环,
///     classic 流光, diorama 镜台, fume 浮名, hanabi 花火, kinetic 文字PV,
///     lumiere 绘光, machi 町景, metaphor 隐喻, monet 莫奈, nebbia 雾笺,
///     partita 云阶, pendolo 时计, prompt 提示词, sonnet 商籁, still 静止,
///     tempera 凝彩, tilt 倾诉
///   BUILTIN_VISUALIZER_BACKGROUND_MODES (9 backgrounds)
///     common 通用, latent 隐现, monet 莫奈, mv MV, nomand 漫游,
///     particles 粒子, sonic 音域回响, sora 空, url 嵌入
///   src/components/visualizer/`<id>`/entry.tsx — per-mode behaviour
///   src/i18n/locales/zh-CN.ts — display names
/// Bilibili MV is NOT a built-in style (it has a zh-CN entry but no
/// BUILTIN_VISUALIZER_MODES id); the 94 on-device count includes mods
/// and prompt-generated styles. Anything not found in the source goes
/// to the user as a question, never a guess.
///
/// Everything a stage style needs to evaluate a frame as f(absolute
/// playback time). Styles read the position on demand via [positionNow]
/// — never cached — so seeks and pauses stay exact.
@immutable
class FoliaStageContext {
  const FoliaStageContext({
    required this.lyrics,
    required this.theme,
    required this.analysis,
    required this.songId,
    required this.positionNow,
    required this.playingNow,
  });

  final KaraokeLyrics lyrics;
  final FoliaTheme theme;
  final Stream<AudioAnalysisFrame> analysis;
  final String songId;
  final Duration Function() positionNow;

  /// Whether playback is running right now. Stages use it to
  /// freeze their interpolated clock on pause instead of drifting
  /// forward on the wall clock.
  final bool Function() playingNow;
}

/// One registered stage style: an id, the display label shown in the
/// style picker list, and the widget that draws it. The label is what
/// users see — every style needs a proper name, not a generic one.
///
/// Styles draw the lyric layer only, on a transparent background: the
/// backdrop comes from the player page's existing background layer
/// (KTV photo / flowing light), never from the style. Phase 1 builds
/// no backgrounds at all.
@immutable
class FoliaStageStyle {
  const FoliaStageStyle({
    required this.id,
    required this.label,
    required this.builder,
  });

  final String id;
  final String label;
  final Widget Function(BuildContext context, FoliaStageContext stage)
  builder;
}

/// One registered stage background. The folia stage page renders
/// the registered 'common' background as its opaque bottom layer.
@immutable
class FoliaStageBackground {
  const FoliaStageBackground({
    required this.id,
    required this.label,
    required this.builder,
  });

  final String id;
  final String label;
  final Widget Function(BuildContext context, FoliaStageContext stage)
  builder;
}

/// Style registry for the folia mode: styles register themselves and
/// the stage page hosts the selected one. The foundation registers
/// none — styles arrive with the style phase.
class FoliaStageRegistry {
  final Map<String, FoliaStageStyle> _styles = {};
  final Map<String, FoliaStageBackground> _backgrounds = {};

  List<FoliaStageStyle> get styles => List.unmodifiable(_styles.values);

  FoliaStageStyle? byId(String id) => _styles[id];

  void register(FoliaStageStyle style) {
    if (_styles.containsKey(style.id)) {
      throw StateError('Duplicate folia style id: ${style.id}');
    }
    _styles[style.id] = style;
  }

  void unregister(String id) => _styles.remove(id);

  /// Background slot. The stage page renders the registered
  /// 'common' background as its opaque bottom layer.
  List<FoliaStageBackground> get backgrounds =>
      List.unmodifiable(_backgrounds.values);

  FoliaStageBackground? backgroundById(String id) => _backgrounds[id];

  void registerBackground(FoliaStageBackground background) {
    if (_backgrounds.containsKey(background.id)) {
      throw StateError(
        'Duplicate folia background id: ${background.id}',
      );
    }
    _backgrounds[background.id] = background;
  }

  void unregisterBackground(String id) => _backgrounds.remove(id);
}

/// App-wide registry. Styles register at startup; tests use their own
/// [FoliaStageRegistry] instances.
final FoliaStageRegistry foliaStageRegistry = FoliaStageRegistry();

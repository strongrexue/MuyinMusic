import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_audio_handler.dart';
import '../player/player_controller.dart';
import '../player/widgets/immersive_chrome.dart';
import '../player/widgets/player_control_color.dart';
import '../player/widgets/transport_bar.dart';
import 'audio_analysis.dart';
import 'folia_stage_registry.dart';
import 'folia_theme.dart';

/// The folia mode's full-screen landscape stage shell. It is a
/// transparent layer over the player page's existing background (KTV
/// photo / flowing light — phase 1 builds no backgrounds): styles draw
/// the lyric layer only.
///
/// The shell owns the [AudioAnalysisService], resolves the per-song
/// theme from the cover, and hosts the first registered style. With no
/// style registered yet it shows a plain placeholder. Style selection
/// arrives with the style phase.
class FoliaStagePage extends ConsumerStatefulWidget {
  const FoliaStagePage({super.key});

  @override
  ConsumerState<FoliaStagePage> createState() => _FoliaStagePageState();
}

class _FoliaStagePageState extends ConsumerState<FoliaStagePage> {
  late final AudioAnalysisService _analysis;

  @override
  void initState() {
    super.initState();
    final handler = ref.read(playerAudioHandlerProvider);
    _analysis = AudioAnalysisService(
      fetchFft: handler.getFft,
      positionNow: () => ref.read(playerControllerProvider).position,
    )..start();
  }

  @override
  void dispose() {
    unawaited(_analysis.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(
      playerControllerProvider.select(
        (s) => (
          lyricLoading: s.lyricLoading,
          lyrics: s.lyrics,
          trackId: s.track?.id,
          localWithoutLyrics: s.track?.isLocal ?? false,
        ),
      ),
    );
    final theme =
        ref.watch(playerArtworkColorsProvider).valueOrNull?.foliaTheme ??
        FoliaTheme.fallback;
    if (vm.lyricLoading) return const _FoliaStatus(text: '歌词加载中');
    if (vm.lyrics.isEmpty) {
      return _FoliaStatus(
        text: vm.localWithoutLyrics ? '本地播放 · 未找到歌词' : '暂无歌词',
      );
    }
    final style = foliaStageRegistry.styles.firstOrNull;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (style != null)
          style.builder(
            context,
            FoliaStageContext(
              lyrics: vm.lyrics,
              theme: theme,
              analysis: _analysis.frames,
              songId: vm.trackId ?? '',
              positionNow: () =>
                  ref.read(playerControllerProvider).position,
            ),
          )
        else
          const _FoliaStatus(text: 'Folia 模式 · 舞台效果即将到来'),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ImmersiveFade(child: TransportBar(compact: true)),
        ),
      ],
    );
  }
}

class _FoliaStatus extends StatelessWidget {
  const _FoliaStatus({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: Colors.white.withValues(alpha: 0.75),
        ),
      ),
    );
  }
}

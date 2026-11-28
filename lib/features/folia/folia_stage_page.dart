import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import '../player/player_audio_handler.dart';
import '../player/player_controller.dart';
import '../player/widgets/player_control_color.dart';
import '../player/widgets/transport_bar.dart';
import 'audio_analysis.dart';
import 'folia_chrome.dart';
import 'folia_stage_registry.dart';
import 'folia_theme.dart';

/// The folia mode's full-screen landscape stage shell. It draws its
/// own background (Folia's built-in 'common': a dark cover-derived
/// base + geometric layer) as an opaque bottom layer, so the player
/// page's background (the KTV photo) does not show through; styles
/// draw the lyric layer on top of it.
///
/// The shell owns the [AudioAnalysisService], resolves the per-song
/// theme from the cover, and hosts the style selected in settings
/// (falling back to the first registered style). Switching styles
/// mid-playback cross-fades with a soft transition; the song never
/// restarts.
class FoliaStagePage extends ConsumerStatefulWidget {
  const FoliaStagePage({super.key});

  @override
  ConsumerState<FoliaStagePage> createState() => _FoliaStagePageState();
}

class _FoliaStagePageState extends ConsumerState<FoliaStagePage> {
  late final AudioAnalysisService _analysis;
  // Captured in initState: ref.read is not usable in dispose (the
  // element is already marked disposed), so the chrome notifier is
  // kept here for the dispose-time restore.
  late final FoliaChromeNotifier _chrome;

  @override
  void initState() {
    super.initState();
    final handler = ref.read(playerAudioHandlerProvider);
    _analysis = AudioAnalysisService(
      fetchFft: handler.getFft,
      positionNow: () => ref.read(playerControllerProvider).position,
    )..start();
    // Enter immersive: the chrome starts hidden while playing so the
    // stage fills the whole screen; a paused song keeps it visible.
    final playing = ref.read(playerControllerProvider).playing;
    _chrome = ref.read(foliaChromeProvider.notifier);
    _chrome.syncPlaying(playing);
    if (playing) _chrome.hide();
  }

  @override
  void dispose() {
    // Leaving folia mode restores the normal chrome.
    _chrome.show();
    unawaited(_analysis.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the chrome's auto-hide in step with playback.
    ref.listen<bool>(
      playerControllerProvider.select((s) => s.playing),
      (_, playing) =>
          ref.read(foliaChromeProvider.notifier).syncPlaying(playing),
    );
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
        (ref.watch(playerArtworkColorsProvider).valueOrNull?.foliaTheme ??
                FoliaTheme.fallback)
            // The stage (background + lyrics) follows the app's
            // current brightness: the blueprint's common background
            // base is daylight #f5f5f4 in light mode and #09090b in
            // dark mode (buildAppStyle.ts, baseThemes.ts).
            .resolveForBrightness(Theme.of(context).brightness);
    final foliaStyleId = ref.watch(
      settingsProvider.select((s) => s.foliaStyleId),
    );
    final style =
        foliaStageRegistry.byId(foliaStyleId) ??
        foliaStageRegistry.styles.firstOrNull;
    final stageContext = FoliaStageContext(
      lyrics: vm.lyrics,
      theme: theme,
      analysis: _analysis.frames,
      songId: vm.trackId ?? '',
      positionNow: () => ref.read(playerControllerProvider).position,
      playingNow: () => ref.read(playerControllerProvider).playing,
    );
    // The folia background (Folia's built-in 'common'): an opaque
    // bottom layer that replaces the player page's background (the
    // KTV photo) while in folia mode. KTV and portrait keep their
    // own backgrounds — this layer only exists in this page.
    final background = foliaStageRegistry.backgroundById('common');
    final backgroundLayer = background == null
        ? const SizedBox.shrink()
        : Positioned.fill(
            child: background.builder(context, stageContext),
          );
    if (vm.lyricLoading) {
      return Stack(
        fit: StackFit.expand,
        children: [backgroundLayer, const _FoliaStatus(text: '歌词加载中')],
      );
    }
    if (vm.lyrics.isEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          backgroundLayer,
          _FoliaStatus(
            text: vm.localWithoutLyrics ? '本地播放 · 未找到歌词' : '暂无歌词',
          ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        backgroundLayer,
        // A tap on the empty stage toggles the chrome (top bar +
        // bottom bar). Taps on the transport bar's own buttons win
        // the gesture arena, so they keep working as controls.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ref.read(foliaChromeProvider.notifier).toggle(),
            child: style != null
                ? AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: KeyedSubtree(
                      key: ValueKey(style.id),
                      child: style.builder(context, stageContext),
                    ),
                  )
                : const _FoliaStatus(text: 'Folia 模式 · 舞台效果即将到来'),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: FoliaChromeFade(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) =>
                  ref.read(foliaChromeProvider.notifier).poke(),
              child: const TransportBar(compact: true),
            ),
          ),
        ),
        // The only bottom element while the chrome is hidden: a thin
        // progress line, like the blueprint's full-screen stage.
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _FoliaProgressLine(),
        ),
      ],
    );
  }
}

/// Thin progress line pinned to the bottom edge, visible only while
/// the folia chrome is hidden. A separate consumer so position ticks
/// rebuild just this 2px strip, not the stage.
class _FoliaProgressLine extends ConsumerWidget {
  const _FoliaProgressLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chromeVisible = ref.watch(foliaChromeProvider);
    final progress = ref.watch(
      playerControllerProvider.select(
        (s) => (position: s.position, duration: s.duration),
      ),
    );
    final totalMs = progress.duration.inMilliseconds;
    final fraction = totalMs <= 0
        ? 0.0
        : (progress.position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    return AnimatedOpacity(
      opacity: chromeVisible ? 0 : 1,
      duration: const Duration(milliseconds: 300),
      child: SizedBox(
        height: 2,
        child: LinearProgressIndicator(
          value: fraction,
          backgroundColor: Colors.white.withValues(alpha: 0.25),
          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
          minHeight: 2,
        ),
      ),
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

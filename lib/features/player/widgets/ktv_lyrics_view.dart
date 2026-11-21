import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../lyric_parser.dart';
import '../player_controller.dart';
import 'immersive_chrome.dart';
import 'karaoke_line_text.dart';
import 'player_layout.dart';
import 'transport_bar.dart';

/// The KTV player layout: the dual-slot lyrics fill the whole area and
/// the slim transport bar floats over their bottom edge. The bar takes
/// part in the player page's immersive auto-hide (see
/// [ImmersiveChrome]) while the top chrome stays visible; when the bar
/// fades, the lyrics sink into the space it leaves (see
/// [KtvLyricsView]).
class KtvPlayerLayout extends StatelessWidget {
  const KtvPlayerLayout({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const KtvLyricsPanel(),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ImmersiveFade(child: const TransportBar(compact: true)),
        ),
      ],
    );
  }
}

/// Full-screen KTV lyrics for landscape playback, modeled on classic
/// KTV subtitles: two alternating slots near the bottom of the screen.
/// Even lines sit in the upper-left slot, odd lines in the lower-right
/// one; the singing line sweeps word-by-word via [KaraokeLineText]
/// while the next line waits in the other slot. The player page's
/// immersive cover background stays behind it.
class KtvLyricsPanel extends ConsumerWidget {
  const KtvLyricsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(
      playerControllerProvider.select(
        (s) => (
          lyricLoading: s.lyricLoading,
          lyrics: s.lyrics,
          localWithoutLyrics: s.track?.isLocal ?? false,
        ),
      ),
    );
    if (vm.lyricLoading) return const _KtvStatus(text: '歌词加载中');
    if (vm.lyrics.isEmpty) {
      return _KtvStatus(text: vm.localWithoutLyrics ? '本地播放 · 未找到歌词' : '暂无歌词');
    }
    final lyricsKey = identityHashCode(vm.lyrics).toString();
    return KtvLyricsView(
      key: ValueKey('ktv-lyrics-view-$lyricsKey'),
      lyrics: vm.lyrics,
    );
  }
}

class _KtvStatus extends StatelessWidget {
  const _KtvStatus({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        text,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class KtvLyricsView extends ConsumerStatefulWidget {
  const KtvLyricsView({super.key, required this.lyrics});

  final KaraokeLyrics lyrics;

  @override
  ConsumerState<KtvLyricsView> createState() => _KtvLyricsViewState();
}

class _KtvLyricsViewState extends ConsumerState<KtvLyricsView> {
  // Per-tick playback values flow through these notifiers so the view
  // itself only rebuilds when the active line changes.
  final _anchorMs = ValueNotifier<int>(0);
  final _playing = ValueNotifier<bool>(false);
  final _buffering = ValueNotifier<bool>(false);
  int _activeIndex = -1;
  Timer? _lineAdvanceTimer;

  @override
  void initState() {
    super.initState();
    final initial = ref.read(playerControllerProvider);
    _anchorMs.value = initial.position.inMilliseconds;
    _playing.value = initial.playing;
    _buffering.value = initial.buffering;
    _activeIndex = widget.lyrics.activeIndex(initial.position);
    ref.listenManual(playerControllerProvider.select((s) => s.position), (
      previous,
      next,
    ) {
      _anchorMs.value = next.inMilliseconds;
      _syncActiveLine(next);
      _scheduleLineAdvance(next);
    });
    ref.listenManual(playerControllerProvider.select((s) => s.playing), (
      previous,
      next,
    ) {
      _playing.value = next;
      _scheduleLineAdvance(ref.read(playerControllerProvider).position);
    });
    ref.listenManual(playerControllerProvider.select((s) => s.buffering), (
      previous,
      next,
    ) {
      _buffering.value = next;
    });
    _scheduleLineAdvance(initial.position);
  }

  @override
  void dispose() {
    _lineAdvanceTimer?.cancel();
    _anchorMs.dispose();
    _playing.dispose();
    _buffering.dispose();
    super.dispose();
  }

  void _syncActiveLine(Duration position) {
    final index = widget.lyrics.activeIndex(position);
    if (index != _activeIndex && mounted) {
      setState(() => _activeIndex = index);
    }
  }

  // The position stream ticks slower than line boundaries; a one-shot
  // timer at the next line's start keeps the roll on time.
  void _scheduleLineAdvance(Duration position) {
    _lineAdvanceTimer?.cancel();
    if (!_playing.value || _buffering.value) return;
    final lines = widget.lyrics.lines;
    final next = _activeIndex + 1;
    if (next < 0 || next >= lines.length) return;
    final delayMs = lines[next].startMs - position.inMilliseconds;
    _lineAdvanceTimer = Timer(Duration(milliseconds: delayMs < 0 ? 0 : delayMs), () {
      if (!mounted) return;
      final current = ref.read(playerControllerProvider).position;
      _syncActiveLine(current);
      _scheduleLineAdvance(current);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = widget.lyrics.lines;
    // The two visible lines are the singing one and the one after it;
    // before the first line starts, line 0 waits as the upcoming line.
    final firstVisible = _activeIndex < 0 ? 0 : _activeIndex;
    int? slotIndex(int parity) {
      for (final index in [firstVisible, firstVisible + 1]) {
        if (index < lines.length && index % 2 == parity) return index;
      }
      return null;
    }

    final slotA = slotIndex(0);
    final slotB = slotIndex(1);
    final chromeVisible = ImmersiveChromeScope.maybeOf(context);
    // The panel stretches full-bleed, so on notched phones the side
    // cutout would cover the lyric edges: keep at least the device
    // safe-area inset on each side.
    final viewPadding = MediaQuery.paddingOf(context);
    final extraLeft = math.max(0.0, viewPadding.left - playerContentInset);
    final extraRight = math.max(0.0, viewPadding.right - playerContentInset);

    return Padding(
      padding: EdgeInsets.only(left: extraLeft, right: extraRight),
      child: LayoutBuilder(
      builder: (context, constraints) {
        // Both lines share one fixed size, like mainstream KTV apps:
        // the singing line never grows and the waiting line never
        // shrinks, so a line change does not shift the block around.
        final fontSize = (constraints.maxHeight * 0.095).clamp(24.0, 40.0);
        final slotHeight = fontSize * 1.35;
        // Bottom clearance of the lyric block. With the chrome shown
        // the block floats above the transport bar; when the chrome
        // fades (immersive), the block sinks by about the bar's height
        // into the space the bar occupied.
        final shownClearance = (constraints.maxHeight * 0.32).clamp(
          104.0,
          170.0,
        );
        // In immersive the block takes the transport bar's place: the
        // bottom line ends at the screen's bottom edge, with only the
        // bar's own small bottom inset below it — no reserved row.
        final sunkClearance = (constraints.maxHeight * 0.045).clamp(14.0, 32.0);
        return Column(
          children: [
            const Spacer(),
            SizedBox(
              height: slotHeight,
              child: _KtvSlot(
                line: slotA == null ? null : lines[slotA],
                isActive: slotA == _activeIndex,
                alignRight: false,
                anchorMs: _anchorMs,
                playing: _playing,
                buffering: _buffering,
                fontSize: fontSize,
                color: scheme.onSurface,
                accent: scheme.primary,
              ),
            ),
            SizedBox(height: fontSize * 0.35),
            SizedBox(
              height: slotHeight,
              child: _KtvSlot(
                line: slotB == null ? null : lines[slotB],
                isActive: slotB == _activeIndex,
                alignRight: true,
                anchorMs: _anchorMs,
                playing: _playing,
                buffering: _buffering,
                fontSize: fontSize,
                color: scheme.onSurface,
                accent: scheme.primary,
              ),
            ),
            if (chromeVisible == null)
              SizedBox(height: shownClearance)
            else
              ValueListenableBuilder<bool>(
                valueListenable: chromeVisible,
                builder: (context, isVisible, _) => AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  height: isVisible ? shownClearance : sunkClearance,
                ),
              ),
          ],
        );
      },
      ),
    );
  }
}

/// One of the two alternating KTV slots. Content fades when the slot's
/// line changes; the slot itself never moves.
class _KtvSlot extends StatelessWidget {
  const _KtvSlot({
    required this.line,
    required this.isActive,
    required this.alignRight,
    required this.anchorMs,
    required this.playing,
    required this.buffering,
    required this.fontSize,
    required this.color,
    required this.accent,
  });

  final KaraokeLyricLine? line;
  final bool isActive;
  final bool alignRight;
  final ValueListenable<int> anchorMs;
  final ValueListenable<bool> playing;
  final ValueListenable<bool> buffering;
  final double fontSize;
  final Color color;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final current = line;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 160),
      child: current == null
          ? const SizedBox.shrink(key: ValueKey('ktv-slot-empty'))
          : Align(
              key: ValueKey('ktv-slot-${current.startMs}'),
              alignment: alignRight
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: isActive
                  ? _KtvActiveLine(
                      line: current,
                      anchorMs: anchorMs,
                      playing: playing,
                      buffering: buffering,
                      fontSize: fontSize,
                      color: color,
                      accent: accent,
                      alignRight: alignRight,
                    )
                  : _KtvUpcomingLine(
                      text: current.text,
                      fontSize: fontSize,
                      color: color.withValues(alpha: 0.85),
                      alignRight: alignRight,
                    ),
            ),
    );
  }
}

class _KtvUpcomingLine extends StatelessWidget {
  const _KtvUpcomingLine({
    required this.text,
    required this.fontSize,
    required this.color,
    required this.alignRight,
  });

  final String text;
  final double fontSize;
  final Color color;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: playerContentInset),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: alignRight ? TextAlign.right : TextAlign.left,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: color,
          height: 1.2,
          shadows: const [Shadow(color: Colors.black45, blurRadius: 12)],
        ),
      ),
    );
  }
}

class _KtvActiveLine extends StatelessWidget {
  const _KtvActiveLine({
    required this.line,
    required this.anchorMs,
    required this.playing,
    required this.buffering,
    required this.fontSize,
    required this.color,
    required this.accent,
    required this.alignRight,
  });

  final KaraokeLyricLine line;
  final ValueListenable<int> anchorMs;
  final ValueListenable<bool> playing;
  final ValueListenable<bool> buffering;
  final double fontSize;
  final Color color;
  final Color accent;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      color: color,
      height: 1.2,
      shadows: const [Shadow(color: Colors.black45, blurRadius: 12)],
    );
    if (!line.hasWordTiming) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: playerContentInset),
        child: Text(
          line.text,
          maxLines: 2,
          textAlign: alignRight ? TextAlign.right : TextAlign.left,
          style: style,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: playerContentInset),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // KaraokeLineText left-aligns its paragraph within the given
          // width; measure the line and hand it exactly that width so
          // the slot can place the box against its own edge.
          final painter = TextPainter(
            text: TextSpan(text: line.text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          final width = painter.width > constraints.maxWidth
              ? constraints.maxWidth
              : painter.width;
          painter.dispose();
          return Align(
            alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
            child: SizedBox(
              width: width,
              child: DefaultTextStyle(
                style: style,
                child: KaraokeLineText(
                  line: line,
                  anchorMs: anchorMs,
                  playing: playing,
                  buffering: buffering,
                  active: true,
                  accent: accent,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

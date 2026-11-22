import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
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
    return Center(
      child: Text(
        text,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          // KTV 背景恒为深色画面，提示文字固定白色系，不随主题亮度变化。
          color: Colors.white.withValues(alpha: 0.75),
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
    _lineAdvanceTimer = Timer(
      Duration(milliseconds: delayMs < 0 ? 0 : delayMs),
      () {
        if (!mounted) return;
        final current = ref.read(playerControllerProvider).position;
        _syncActiveLine(current);
        _scheduleLineAdvance(current);
      },
    );
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
    // Effective end of a line for the no-word-timing progress sweep:
    // the next line's start, or the song duration for the last line.
    int endMsFor(int index) {
      if (index + 1 < lines.length) return lines[index + 1].startMs;
      final durationMs = ref
          .read(playerControllerProvider)
          .duration
          .inMilliseconds;
      return durationMs > lines[index].startMs
          ? durationMs
          : lines[index].endMs;
    }
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
          final sunkClearance = (constraints.maxHeight * 0.045).clamp(
            14.0,
            32.0,
          );
          // Pull both slots in from the screen edges by a share of the
          // available width, so short lines (or a wide screen) do not
          // leave the middle feeling empty. Stacks on top of the
          // safe-area compensation of the outer padding.
          final slotInset = constraints.maxWidth * 0.06;
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: slotInset),
            child: Column(
              children: [
                const Spacer(),
                // KTV lyrics always render white, like the dark theme:
                // they sit on the full-bleed background image, so the
                // light theme's dark onSurface would be unreadable.
                SizedBox(
                  height: slotHeight,
                  child: _KtvSlot(
                    line: slotA == null ? null : lines[slotA],
                    endMs: slotA == null ? 0 : endMsFor(slotA),
                    isActive: slotA == _activeIndex,
                    alignRight: false,
                    anchorMs: _anchorMs,
                    playing: _playing,
                    buffering: _buffering,
                    fontSize: fontSize,
                    color: Colors.white,
                    accent: scheme.primary,
                  ),
                ),
                SizedBox(height: fontSize * 0.35),
                SizedBox(
                  height: slotHeight,
                  child: _KtvSlot(
                    line: slotB == null ? null : lines[slotB],
                    endMs: slotB == null ? 0 : endMsFor(slotB),
                    isActive: slotB == _activeIndex,
                    alignRight: true,
                    anchorMs: _anchorMs,
                    playing: _playing,
                    buffering: _buffering,
                    fontSize: fontSize,
                    color: Colors.white,
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
            ),
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
    required this.endMs,
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

  /// Effective end of [line] (next line's start / song duration);
  /// only the no-word-timing sweep uses it.
  final int endMs;
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
                      endMs: endMs,
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
                      color: color,
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
    required this.endMs,
    required this.anchorMs,
    required this.playing,
    required this.buffering,
    required this.fontSize,
    required this.color,
    required this.accent,
    required this.alignRight,
  });

  final KaraokeLyricLine line;
  final int endMs;
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
      // No per-word timestamps: sweep the whole line instead, so the
      // singing line still reads as progressing (white base, accent
      // fill clipped in from the left by line progress).
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: playerContentInset),
        child: _KtvSweepLine(
          line: line,
          endMs: endMs,
          anchorMs: anchorMs,
          playing: playing,
          buffering: buffering,
          style: style,
          accent: accent,
          alignRight: alignRight,
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
            alignment: alignRight
                ? Alignment.centerRight
                : Alignment.centerLeft,
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
                  // KTV 当前行整行实色：未唱字不压暗，只靠已唱字
                  // 变强调色区分进度。
                  unsungAlpha: 1.0,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Active KTV line without word timings: the white line is overlaid
/// by the same text in the accent color, clipped in from the left by
/// the line's progress (see [lyricLineProgress]).
///
/// Driven by the same anchor mechanism as [KaraokeLineText]: the
/// position stream ticks slower than the sweep, so the anchor is
/// extrapolated with a stopwatch between ticks and small stream
/// corrections are absorbed instead of stepping the fill backwards.
class _KtvSweepLine extends StatefulWidget {
  const _KtvSweepLine({
    required this.line,
    required this.endMs,
    required this.anchorMs,
    required this.playing,
    required this.buffering,
    required this.style,
    required this.accent,
    required this.alignRight,
  });

  final KaraokeLyricLine line;
  final int endMs;
  final ValueListenable<int> anchorMs;
  final ValueListenable<bool> playing;
  final ValueListenable<bool> buffering;
  final TextStyle style;
  final Color accent;
  final bool alignRight;

  @override
  State<_KtvSweepLine> createState() => _KtvSweepLineState();
}

class _KtvSweepLineState extends State<_KtvSweepLine>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _sinceAnchor = Stopwatch();
  late final ValueNotifier<double> _fraction;
  late double _anchorPositionMs;
  double _anchorErrorMs = 0;
  bool _reduceMotion = false;

  double get _clockPosition {
    final elapsedMs = _sinceAnchor.elapsedMicroseconds / 1000;
    return _anchorPositionMs +
        elapsedMs +
        _anchorErrorMs * math.exp(-elapsedMs / 200);
  }

  double _progress() => lyricLineProgress(
    startMs: widget.line.startMs,
    endMs: widget.endMs,
    positionMs: _clockPosition.round(),
  );

  @override
  void initState() {
    super.initState();
    _anchorPositionMs = widget.anchorMs.value.toDouble();
    _fraction = ValueNotifier(_progress());
    _ticker = createTicker((_) => _publish());
    widget.anchorMs.addListener(_handleAnchor);
    widget.playing.addListener(_handlePlayback);
    widget.buffering.addListener(_handlePlayback);
    _syncClock();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant _KtvSweepLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.anchorMs, oldWidget.anchorMs)) {
      oldWidget.anchorMs.removeListener(_handleAnchor);
      widget.anchorMs.addListener(_handleAnchor);
    }
    if (!identical(widget.playing, oldWidget.playing)) {
      oldWidget.playing.removeListener(_handlePlayback);
      widget.playing.addListener(_handlePlayback);
    }
    if (!identical(widget.buffering, oldWidget.buffering)) {
      oldWidget.buffering.removeListener(_handlePlayback);
      widget.buffering.addListener(_handlePlayback);
    }
    if (widget.line != oldWidget.line || widget.endMs != oldWidget.endMs) {
      _anchorPositionMs = widget.anchorMs.value.toDouble();
      _anchorErrorMs = 0;
      _sinceAnchor.reset();
    }
    _syncClock();
  }

  void _handleAnchor() {
    final anchor = widget.anchorMs.value.toDouble();
    final error = _clockPosition - anchor;
    // Same absorption as KaraokeLineText: small corrections decay
    // into the clock; a seek (large jump) applies immediately.
    _anchorErrorMs = _sinceAnchor.isRunning && error.abs() < 160 ? error : 0;
    _anchorPositionMs = anchor;
    _sinceAnchor.reset();
    _syncClock();
  }

  void _handlePlayback() {
    // Freeze at the displayed time when pausing or buffering.
    _anchorPositionMs = _clockPosition;
    _anchorErrorMs = 0;
    _sinceAnchor.reset();
    _syncClock();
  }

  void _syncClock() {
    final running = widget.playing.value && !widget.buffering.value;
    if (running) {
      _sinceAnchor.start();
    } else {
      _sinceAnchor.stop();
    }
    final needsTicks =
        running && !_reduceMotion && _clockPosition < widget.endMs;
    if (needsTicks && !_ticker.isActive) {
      _ticker.start();
    } else if (!needsTicks && _ticker.isActive) {
      _ticker.stop();
    }
    _publish();
  }

  void _publish() {
    _fraction.value = _progress();
    if (_clockPosition >= widget.endMs && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    widget.anchorMs.removeListener(_handleAnchor);
    widget.playing.removeListener(_handlePlayback);
    widget.buffering.removeListener(_handlePlayback);
    _ticker.dispose();
    _fraction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textAlign = widget.alignRight ? TextAlign.right : TextAlign.left;
    return Stack(
      children: [
        Text(
          widget.line.text,
          maxLines: 2,
          textAlign: textAlign,
          style: widget.style,
        ),
        ValueListenableBuilder<double>(
          valueListenable: _fraction,
          child: Text(
            widget.line.text,
            maxLines: 2,
            textAlign: textAlign,
            style: widget.style.copyWith(color: widget.accent),
          ),
          builder: (context, fraction, child) => ClipRect(
            child: Align(
              alignment: Alignment.centerLeft,
              widthFactor: fraction,
              heightFactor: 1,
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

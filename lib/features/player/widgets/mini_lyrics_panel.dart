import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import '../../../theme/app_motion.dart';
import '../lyric_parser.dart';
import '../player_controller.dart';
import 'lyric_sweep_line.dart';
import 'player_layout.dart';

/// Blur applied directly to the previous and next lyric text. Increase this
/// value for a stronger effect; the active line always stays sharp.
const double miniLyricsInactiveBlurSigma = 0.45;

const double _miniLyricLineExtent = 26;
const int _miniLyricVisibleLineCount = 3;
const Duration _miniLyricScrollDuration = Duration(milliseconds: 380);
// Breathing room INSIDE the list viewport so the first/last row's blur halo
// fades out before reaching the viewport clip instead of being sliced flat
// against it. The panel padding below hands back the same amount, so text
// keeps its exact on-screen position and the window math is untouched:
// row i starts at bleed + i*extent, and the existing `windowStart * extent`
// scroll target leaves the top row exactly `bleed` inside the viewport.
const double _miniLyricBlurBleed = 4;
const double _miniLyricViewportExtent =
    _miniLyricVisibleLineCount * _miniLyricLineExtent + _miniLyricBlurBleed;

class MiniLyricsPanel extends ConsumerStatefulWidget {
  const MiniLyricsPanel({super.key, required this.onOpenLyrics});

  final VoidCallback onOpenLyrics;

  @override
  ConsumerState<MiniLyricsPanel> createState() => _MiniLyricsPanelState();
}

class _MiniLyricsPanelState extends ConsumerState<MiniLyricsPanel> {
  // Per-tick playback values for the no-word-timing sweep, fed through
  // notifiers like the KTV view so position ticks do not rebuild the
  // panel itself.
  final _anchorMs = ValueNotifier<int>(0);
  final _playing = ValueNotifier<bool>(false);
  final _buffering = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    final initial = ref.read(playerControllerProvider);
    _anchorMs.value = initial.position.inMilliseconds;
    _playing.value = initial.playing;
    _buffering.value = initial.buffering;
    ref.listenManual(playerControllerProvider.select((s) => s.position), (
      previous,
      next,
    ) {
      _anchorMs.value = next.inMilliseconds;
    });
    ref.listenManual(playerControllerProvider.select((s) => s.playing), (
      previous,
      next,
    ) {
      _playing.value = next;
    });
    ref.listenManual(playerControllerProvider.select((s) => s.buffering), (
      previous,
      next,
    ) {
      _buffering.value = next;
    });
  }

  @override
  void dispose() {
    _anchorMs.dispose();
    _playing.dispose();
    _buffering.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(
      settingsProvider.select((settings) => settings.showMiniLyrics),
    );
    if (!enabled) return const SizedBox.shrink();
    final vm = ref.watch(
      playerControllerProvider.select(
        (state) => (
          lyrics: state.lyrics,
          activeIndex: state.lyricLoading || state.lyrics.isEmpty
              ? -1
              : state.lyrics.activeIndex(state.position),
          durationMs: state.duration.inMilliseconds,
        ),
      ),
    );
    if (vm.activeIndex < 0 || vm.lyrics.isEmpty) {
      return const SizedBox.shrink();
    }

    return Semantics(
      button: true,
      label: '打开歌词页面',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Material(
          key: const ValueKey('player-mini-lyrics-surface'),
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey('player-mini-lyrics'),
            onTap: widget.onOpenLyrics,
            child: SizedBox(
              // Viewport extent + the vertical padding below, exactly:
              // a taller box would stretch the viewport past three rows
              // (the tight constraint overrides the inner SizedBox).
              height: _miniLyricViewportExtent + 2 * (9 - _miniLyricBlurBleed),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: playerProgressTrackInset - _miniLyricBlurBleed,
                  vertical: 9 - _miniLyricBlurBleed,
                ),
                child: SizedBox(
                  height: _miniLyricViewportExtent,
                  child: _MiniLyricsScroller(
                    lyrics: vm.lyrics,
                    activeIndex: vm.activeIndex,
                    anchorMs: _anchorMs,
                    playing: _playing,
                    buffering: _buffering,
                    songDurationMs: vm.durationMs,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 迷你歌词页当前行的逐字 KTV 染色：起唱（startMs）即变强调色，
/// 未唱到的字保持普通色。自己 watch position，只重建这一行。
class _MiniKaraokeLine extends ConsumerWidget {
  const _MiniKaraokeLine({
    super.key,
    required this.line,
    required this.sungColor,
    required this.pendingColor,
    required this.fontSize,
  });

  final KaraokeLyricLine line;
  final Color sungColor;
  final Color pendingColor;
  final double fontSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positionMs = ref.watch(
      playerControllerProvider.select((s) => s.position.inMilliseconds),
    );
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w400,
      height: 1.3,
    );
    final spans = <TextSpan>[];
    for (final word in line.words) {
      final sung = positionMs >= word.startMs;
      spans.add(
        TextSpan(
          text: word.text,
          style: style.copyWith(color: sung ? sungColor : pendingColor),
        ),
      );
    }
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      text: TextSpan(children: spans, style: style.copyWith(color: pendingColor)),
    );
  }
}

class _MiniLyricsScroller extends StatefulWidget {
  const _MiniLyricsScroller({
    required this.lyrics,
    required this.activeIndex,
    required this.anchorMs,
    required this.playing,
    required this.buffering,
    required this.songDurationMs,
  });

  final KaraokeLyrics lyrics;
  final int activeIndex;
  final ValueListenable<int> anchorMs;
  final ValueListenable<bool> playing;
  final ValueListenable<bool> buffering;
  final int songDurationMs;

  @override
  State<_MiniLyricsScroller> createState() => _MiniLyricsScrollerState();
}

class _MiniLyricsScrollerState extends State<_MiniLyricsScroller> {
  late final ScrollController _controller;
  late int _windowStart;
  int _scrollGeneration = 0;

  @override
  void initState() {
    super.initState();
    _windowStart = _resolveWindowStart();
    _controller = ScrollController(
      initialScrollOffset: _windowStart * _miniLyricLineExtent,
    );
  }

  @override
  void didUpdateWidget(covariant _MiniLyricsScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextStart = _resolveWindowStart();
    final lyricsChanged = !identical(widget.lyrics, oldWidget.lyrics);
    if (!lyricsChanged && nextStart == _windowStart) return;
    _windowStart = nextStart;
    _scheduleScroll(animate: !lyricsChanged);
  }

  @override
  void dispose() {
    _scrollGeneration++;
    _controller.dispose();
    super.dispose();
  }

  int _sweepEndMsFor(int index) {
    final lines = widget.lyrics.lines;
    final line = lines[index];
    final limitMs = index + 1 < lines.length
        ? lines[index + 1].startMs
        : (widget.songDurationMs > line.startMs
              ? widget.songDurationMs
              : line.endMs);
    return sweepEndMs(
      startMs: line.startMs,
      totalWeight: lyricSweepTotalWeight(lyricSweepSegments(line.text)),
      limitMs: limitMs,
    );
  }

  int _resolveWindowStart() {
    final lineCount = widget.lyrics.lines.length;
    final maxStart = (lineCount - _miniLyricVisibleLineCount).clamp(
      0,
      lineCount,
    );
    return (widget.activeIndex - 1).clamp(0, maxStart);
  }

  void _scheduleScroll({required bool animate}) {
    final generation = ++_scrollGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _scrollGeneration ||
          !_controller.hasClients) {
        return;
      }
      final target = (_windowStart * _miniLyricLineExtent).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      );
      if (!animate || MediaQuery.disableAnimationsOf(context)) {
        _controller.jumpTo(target);
        return;
      }
      unawaited(
        _controller.animateTo(
          target,
          duration: _miniLyricScrollDuration,
          curve: AppMotion.emphasized,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = widget.lyrics.lines;
    final blurDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _miniLyricScrollDuration;
    return ListView.builder(
      key: const ValueKey('player-mini-lyrics-scroll'),
      controller: _controller,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(_miniLyricBlurBleed),
      itemExtent: _miniLyricLineExtent,
      // ignore: deprecated_member_use
      cacheExtent: 0,
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final active = index == widget.activeIndex;
        final targetSigma = active ? 0.0 : miniLyricsInactiveBlurSigma;
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: targetSigma),
          duration: blurDuration,
          curve: AppMotion.emphasized,
          child: Align(
            alignment: Alignment.center,
            // 当前行有逐字时间戳时逐字染色（KTV 式：起唱即强调色），
            // 无逐字时整行进度扫色（与 KTV、歌词页同一套加权模型）；
            // 非当前行保持原有模糊 + 变体色。
            child: active && lines[index].hasWordTiming
                ? _MiniKaraokeLine(
                    key: ValueKey('player-mini-lyric-line-$index'),
                    line: lines[index],
                    sungColor: scheme.primary,
                    pendingColor: scheme.onSurface,
                    fontSize: 17,
                  )
                : active
                ? LyricSweepLine(
                    key: ValueKey('player-mini-lyric-line-$index'),
                    line: lines[index],
                    endMs: _sweepEndMsFor(index),
                    anchorMs: widget.anchorMs,
                    playing: widget.playing,
                    buffering: widget.buffering,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 17,
                      fontWeight: FontWeight.w400,
                      height: 1.3,
                    ),
                    accent: scheme.primary,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : Text(
                    lines[index].text,
                    key: ValueKey('player-mini-lyric-line-$index'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      height: 1.3,
                    ),
                  ),
          ),
          builder: (context, sigma, child) => ImageFiltered(
            key: ValueKey('player-mini-lyric-blur-$index'),
            // Decal so the blur halo fades past the text bounds instead of
            // clamp's hard seam at the glyph edges.
            imageFilter: ImageFilter.blur(
              sigmaX: sigma,
              sigmaY: sigma,
              tileMode: TileMode.decal,
            ),
            enabled: sigma > 0.05,
            child: child,
          ),
        );
      },
    );
  }
}

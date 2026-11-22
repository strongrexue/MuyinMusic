import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../lyric_parser.dart';

/// A lyric line without per-word timings, rendered as a plain base
/// line overlaid by the same text in [accent], clipped in from the
/// left by the singing progress. Shared by the KTV view, the lyrics
/// page and the mini lyrics so all three sweep identically.
///
/// The clip fraction is not linear in time: it follows the weighted
/// model in [lyricSweepSegments] (CJK beats, faster latin, a pause
/// after punctuation, a held final character), mapped through
/// [lyricSweepWidthFraction] over the span up to [endMs] (see
/// [sweepEndMs]).
///
/// Driven by the same anchor mechanism as KaraokeLineText: the
/// position stream ticks slower than the sweep, so the anchor is
/// extrapolated with a stopwatch between ticks and small stream
/// corrections are absorbed instead of stepping the fill backwards.
/// Pausing or buffering freezes the clock at the displayed time.
class LyricSweepLine extends StatefulWidget {
  const LyricSweepLine({
    super.key,
    required this.line,
    required this.endMs,
    required this.anchorMs,
    required this.playing,
    required this.buffering,
    required this.accent,
    this.style,
    this.textAlign = TextAlign.left,
    this.maxLines,
    this.overflow,
    this.active = true,
  });

  final KaraokeLyricLine line;

  /// Effective sweep end for this line (see [sweepEndMs]).
  final int endMs;
  final ValueListenable<int> anchorMs;
  final ValueListenable<bool> playing;
  final ValueListenable<bool> buffering;
  final Color accent;

  /// Base text style; defaults to the ambient [DefaultTextStyle].
  final TextStyle? style;
  final TextAlign textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  /// When false the line renders as plain base text and the sweep
  /// clock stays stopped (e.g. unfocused rows on the lyrics page).
  final bool active;

  @override
  State<LyricSweepLine> createState() => _LyricSweepLineState();
}

class _LyricSweepLineState extends State<LyricSweepLine>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _sinceAnchor = Stopwatch();
  late final ValueNotifier<double> _fraction;
  late double _anchorPositionMs;
  double _anchorErrorMs = 0;
  bool _reduceMotion = false;
  late List<LyricSweepSegment> _segments;
  late int _runeCount;

  double get _clockPosition {
    final elapsedMs = _sinceAnchor.elapsedMicroseconds / 1000;
    return _anchorPositionMs +
        elapsedMs +
        _anchorErrorMs * math.exp(-elapsedMs / 200);
  }

  double _progress() => lyricSweepWidthFraction(
    segments: _segments,
    runeCount: _runeCount,
    progress: lyricLineProgress(
      startMs: widget.line.startMs,
      endMs: widget.endMs,
      positionMs: _clockPosition.round(),
    ),
  );

  void _retime() {
    _segments = lyricSweepSegments(widget.line.text);
    _runeCount = widget.line.text.runes.length;
  }

  @override
  void initState() {
    super.initState();
    _retime();
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
  void didUpdateWidget(covariant LyricSweepLine oldWidget) {
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
      _retime();
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
    final running =
        widget.active && widget.playing.value && !widget.buffering.value;
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
    final style = widget.style ?? DefaultTextStyle.of(context).style;
    final base = Text(
      widget.line.text,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      textAlign: widget.textAlign,
      style: style,
    );
    if (!widget.active) return base;
    return Stack(
      children: [
        base,
        ValueListenableBuilder<double>(
          valueListenable: _fraction,
          child: Text(
            widget.line.text,
            maxLines: widget.maxLines,
            overflow: widget.overflow,
            textAlign: widget.textAlign,
            style: style.copyWith(color: widget.accent),
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

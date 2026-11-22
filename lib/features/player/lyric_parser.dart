import 'dart:convert' show LineSplitter;
import 'dart:math' as math;

import '../../core/models/lyric_info.dart';

class KaraokeLyrics {
  const KaraokeLyrics(this.lines);

  final List<KaraokeLyricLine> lines;

  bool get isEmpty => lines.isEmpty;

  int activeIndex(Duration position) {
    if (lines.isEmpty) return -1;
    final ms = position.inMilliseconds;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (ms >= line.startMs && ms < line.endMs) return i;
      if (ms < line.startMs) return math.max(0, i - 1);
    }
    return lines.length - 1;
  }
}

class KaraokeLyricLine {
  const KaraokeLyricLine({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.translation,
    this.roman,
    this.words = const [],
  });

  final int startMs;
  final int endMs;
  final String text;
  final String? translation;
  final String? roman;
  final List<KaraokeWordTiming> words;

  bool get hasWordTiming => words.isNotEmpty;
}

/// Fraction of a word-timing-less line that has elapsed at
/// [positionMs], where [endMs] is the line's effective sweep end (see
/// [sweepEndMs]). Drives the whole-line progress sweep shown for
/// lyrics without per-word timestamps.
double lyricLineProgress({
  required int startMs,
  required int endMs,
  required int positionMs,
}) {
  if (positionMs <= startMs) return 0;
  if (positionMs >= endMs) return 1;
  final duration = math.max(1, endMs - startMs);
  return ((positionMs - startMs) / duration).clamp(0, 1).toDouble();
}

/// Effective end of a word-timing-less line for the progress sweep:
/// the earlier of [limitMs] (the next line's start, or the song's
/// duration for the last line) and an estimate of when the line
/// finishes being sung, so the sweep completes with the singing
/// instead of spreading across the silent tail before the next line.
/// The estimate is ~300ms per unit of [totalWeight] (see
/// [lyricSweepSegments]), clamped to at least 1s and at most the gap
/// up to [limitMs].
int sweepEndMs({
  required int startMs,
  required double totalWeight,
  required int limitMs,
}) {
  final gapMs = math.max(0, limitMs - startMs);
  final estimateMs = (totalWeight * _kSweepMsPerWeight)
      .round()
      .clamp(1000, math.max(1000, gapMs))
      .toInt();
  return math.min(limitMs, startMs + estimateMs);
}

/// One span of a word-timing-less line in the weighted sweep model:
/// [weight] is how long the sweep spends crossing the span, and
/// [start]/[end] are the rune offsets its ink covers. A pause segment
/// (inserted after punctuation) has start == end: the sweep waits at
/// that rune boundary while its weight elapses.
class LyricSweepSegment {
  const LyricSweepSegment({
    required this.weight,
    required this.start,
    required this.end,
  });

  final double weight;
  final double start;
  final double end;
}

const double _kSweepCjkWeight = 1.0;
const double _kSweepLatinWeight = 0.45;
const double _kSweepSpaceWeight = 0.3;
const double _kSweepPunctuationWeight = 0.2;
const double _kSweepPunctuationPauseWeight = 0.8;
const double _kSweepTailWeightFactor = 2.5;
const int _kSweepMsPerWeight = 300;

bool _isSweepSpace(int rune) => rune == 0x20 || rune == 0x09 || rune == 0x3000;

bool _isSweepPunctuation(int rune) {
  // ASCII punctuation plus the CJK/fullwidth marks common in lyrics.
  if (rune < 0x80) {
    return (rune >= 0x21 && rune <= 0x2F) ||
        (rune >= 0x3A && rune <= 0x40) ||
        (rune >= 0x5B && rune <= 0x5E) ||
        (rune >= 0x7B && rune <= 0x7E);
  }
  return rune == 0xB7 || // ·
      (rune >= 0x2013 && rune <= 0x2014) || // – —
      rune == 0x2018 ||
      rune == 0x2019 ||
      rune == 0x201C ||
      rune == 0x201D ||
      rune == 0x2026 || // …
      (rune >= 0x3001 && rune <= 0x3002) || // 、 。
      (rune >= 0x3008 && rune <= 0x3011) || // 〈 〉 《 》 【 】
      rune == 0xFF01 || // ！
      rune == 0xFF08 || // （
      rune == 0xFF09 || // ）
      rune == 0xFF0C || // ，
      rune == 0xFF1A || // ：
      rune == 0xFF1B || // ；
      rune == 0xFF1F; // ？
}

bool _isSweepCjk(int rune) =>
    (rune >= 0x2E80 && rune <= 0x303E) ||
    (rune >= 0x3041 && rune <= 0x30FF) || // hiragana + katakana
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0xAC00 && rune <= 0xD7A3) || // hangul syllables
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0xFF00 && rune <= 0xFF5E) || // fullwidth forms
    (rune >= 0x20000 && rune <= 0x2A6DF);

bool _isSweepLatin(int rune) =>
    (rune >= 0x30 && rune <= 0x39) || // digits
    (rune >= 0x41 && rune <= 0x5A) ||
    (rune >= 0x61 && rune <= 0x7A) ||
    (rune >= 0xC0 && rune <= 0x24F); // latin-1 letters + latin extended

double _sweepRuneWeight(int rune) {
  if (_isSweepSpace(rune)) return _kSweepSpaceWeight;
  if (_isSweepCjk(rune)) return _kSweepCjkWeight;
  if (_isSweepLatin(rune)) return _kSweepLatinWeight;
  return _kSweepCjkWeight;
}

/// Splits [text] into weighted sweep segments. Singing does not move
/// at a constant speed through a line: CJK syllables carry a full
/// beat each, latin letters run faster, a pause follows punctuation,
/// and the last content character of the line is held (its weight is
/// multiplied, modelling the trailing note). The three sweep surfaces
/// (KTV, lyrics page, mini lyrics) share this model so their timing
/// math is identical.
List<LyricSweepSegment> lyricSweepSegments(String text) {
  final segments = <LyricSweepSegment>[];
  var offset = 0.0;
  var lastContentSegment = -1;
  for (final rune in text.runes) {
    if (_isSweepPunctuation(rune)) {
      segments.add(
        LyricSweepSegment(
          weight: _kSweepPunctuationWeight,
          start: offset,
          end: offset + 1,
        ),
      );
      offset += 1;
      // The pause after punctuation: time passes, no ink advances.
      segments.add(
        LyricSweepSegment(
          weight: _kSweepPunctuationPauseWeight,
          start: offset,
          end: offset,
        ),
      );
      continue;
    }
    segments.add(
      LyricSweepSegment(
        weight: _sweepRuneWeight(rune),
        start: offset,
        end: offset + 1,
      ),
    );
    if (!_isSweepSpace(rune)) lastContentSegment = segments.length - 1;
    offset += 1;
  }
  if (lastContentSegment >= 0) {
    final tail = segments[lastContentSegment];
    segments[lastContentSegment] = LyricSweepSegment(
      weight: tail.weight * _kSweepTailWeightFactor,
      start: tail.start,
      end: tail.end,
    );
  }
  return segments;
}

/// Total singing weight of [segments]; a line's estimated sung
/// duration is this times ~300ms (see [sweepEndMs]).
double lyricSweepTotalWeight(List<LyricSweepSegment> segments) =>
    segments.fold(0.0, (sum, segment) => sum + segment.weight);

/// Maps the elapsed fraction [progress] of a line's estimated sung
/// duration to the sweep's clip fraction (0..1 of the line's rune
/// span): the position where the cumulative segment weight reaches
/// progress × total weight, interpolated inside the segment it lands
/// in. During a pause segment the position holds at its boundary.
double lyricSweepWidthFraction({
  required List<LyricSweepSegment> segments,
  required int runeCount,
  required double progress,
}) {
  if (segments.isEmpty || runeCount <= 0) return 0;
  if (progress <= 0) return 0;
  if (progress >= 1) return 1;
  final target = progress * lyricSweepTotalWeight(segments);
  var cumulative = 0.0;
  for (final segment in segments) {
    final next = cumulative + segment.weight;
    if (target <= next) {
      if (segment.weight <= 0 || segment.end <= segment.start) {
        return (segment.start / runeCount).clamp(0.0, 1.0).toDouble();
      }
      final within = (target - cumulative) / segment.weight;
      final position = segment.start + within * (segment.end - segment.start);
      return (position / runeCount).clamp(0.0, 1.0).toDouble();
    }
    cumulative = next;
  }
  return 1;
}

class KaraokeWordTiming {
  const KaraokeWordTiming({
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  final String text;
  final int startMs;
  final int endMs;

  double progressAt(int positionMs) {
    if (positionMs <= startMs) return 0;
    if (positionMs >= endMs) return 1;
    final duration = math.max(1, endMs - startMs);
    return ((positionMs - startMs) / duration).clamp(0, 1).toDouble();
  }
}

class KaraokeLyricsParser {
  const KaraokeLyricsParser._();

  static final _lineTimeExp = RegExp(
    r'\[(\d{1,3}(?::\d{1,3}){0,2}(?:\.\d{1,3})?)\]',
  );
  static final _leadingTimeFieldExp = RegExp(r'^(?:\[[\d:.]+\])+');
  static final _wordTimingExp = RegExp(r'<(\d+),(\d+)>');
  static final _absWordTagExp = RegExp(
    r'<(\d{1,3}(?::\d{1,3}){0,2}(?:\.\d{1,3})?)>',
  );

  /// Parses a single combined lyric string read back from a local file's
  /// embedded tag (written by `LyricBuilder.build`). That text may carry
  /// absolute-timestamp word tags (`<mm:ss.xxx>`, distinct
  /// from the API's `<offsetMs,durationMs>` word format) and, when
  /// translation/roman tracks were embedded too, reuses the main lyric's
  /// timestamps for those extra blocks. Lines are grouped by timestamp: the
  /// first occurrence is the main lyric (with its word tags converted into
  /// karaoke word timings), the second/third become translation/roman.
  static KaraokeLyrics parseEmbedded(String raw) {
    final bodiesByMs = <int, List<String>>{};
    for (final line in const LineSplitter().convert(raw.replaceAll('\r', ''))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final field = _leadingTimeFieldExp.firstMatch(trimmed);
      if (field == null) continue;
      final body = trimmed.substring(field.end);
      if (body.replaceAll(_absWordTagExp, '').trim().isEmpty) continue;
      for (final time in _lineTimeExp.allMatches(field.group(0)!)) {
        final ms = _parseTimeMs(time.group(1)!);
        if (ms == null) continue;
        bodiesByMs.putIfAbsent(ms, () => []).add(body);
      }
    }
    final lines = <KaraokeLyricLine>[];
    final sortedMs = bodiesByMs.keys.toList()..sort();
    for (final ms in sortedMs) {
      final bodies = bodiesByMs[ms]!;
      final words = _parseAbsoluteWords(bodies.first);
      final text = bodies.first.replaceAll(_absWordTagExp, '').trim();
      if (text.isEmpty) continue;
      String? extraAt(int index) {
        if (index >= bodies.length) return null;
        final value = bodies[index].replaceAll(_absWordTagExp, '').trim();
        return value.isEmpty ? null : value;
      }

      lines.add(
        KaraokeLyricLine(
          startMs: ms,
          endMs: words.isEmpty
              ? ms + 4000
              : math.max(ms + 1, words.map((w) => w.endMs).reduce(math.max)),
          text: text,
          translation: extraAt(1),
          roman: extraAt(2),
          words: words,
        ),
      );
    }
    return KaraokeLyrics(_finalizeLineEnds(lines));
  }

  /// Absolute word tags carry absolute timestamps and bracket each word:
  /// `<start>word<end><start>word<end>…`, where a shared boundary collapses
  /// the `<end><start>` pair into one tag. Every text chunk between two
  /// adjacent tags is therefore one word.
  static List<KaraokeWordTiming> _parseAbsoluteWords(String body) {
    final tags = _absWordTagExp.allMatches(body).toList(growable: false);
    if (tags.length < 2) return const [];
    final words = <KaraokeWordTiming>[];
    for (var i = 0; i + 1 < tags.length; i++) {
      final text = body.substring(tags[i].end, tags[i + 1].start);
      if (text.isEmpty) continue;
      final start = _parseTimeMs(tags[i].group(1)!);
      final end = _parseTimeMs(tags[i + 1].group(1)!);
      if (start == null || end == null || end < start) continue;
      words.add(
        KaraokeWordTiming(
          text: text,
          startMs: start,
          endMs: math.max(start + 1, end),
        ),
      );
    }
    return words;
  }

  static KaraokeLyrics parse(LyricInfo info) {
    final mainLines = _parseTextByTime(info.lyric);
    final translations = _parseTextByTime(info.tlyric);
    final romans = _parseTextByTime(info.rlyric);
    final wordLyric = info.lxlyric?.trim();
    var lines = wordLyric != null && wordLyric.isNotEmpty
        ? _parseWordLyric(wordLyric, mainLines, translations, romans)
        : const <KaraokeLyricLine>[];
    if (lines.isEmpty) {
      // lxlyric present but unparseable (or absent) — the plain lyric is
      // still worth showing per-line rather than reporting "no lyrics".
      lines = _parsePlainLyric(info.lyric, translations, romans);
    }
    return KaraokeLyrics(_finalizeLineEnds(lines));
  }

  static List<KaraokeLyricLine> _parseWordLyric(
    String lrc,
    Map<int, String> mainLines,
    Map<int, String> translations,
    Map<int, String> romans,
  ) {
    final lines = <KaraokeLyricLine>[];
    for (final raw in const LineSplitter().convert(lrc.replaceAll('\r', ''))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final field = _leadingTimeFieldExp.firstMatch(line);
      if (field == null) continue;
      final time = _lineTimeExp.firstMatch(field.group(0)!);
      if (time == null) continue;
      final startMs = _parseTimeMs(time.group(1)!);
      if (startMs == null) continue;
      final body = line.substring(field.end).trim();
      if (body.isEmpty) continue;
      final words = _parseWords(body, startMs);
      final text = body.replaceAll(_wordTimingExp, '').trim();
      if (text.isEmpty) continue;
      final extendedTrackAnchor = _matchingMainLineStart(
        mainLines,
        text,
        startMs,
      );
      final endMs = words.isEmpty
          ? startMs + 4000
          : math.max(startMs + 1, words.map((w) => w.endMs).reduce(math.max));
      lines.add(
        KaraokeLyricLine(
          startMs: startMs,
          endMs: endMs,
          text: text,
          translation: _nearestLine(translations, extendedTrackAnchor),
          roman: _nearestLine(romans, extendedTrackAnchor),
          words: words,
        ),
      );
    }
    lines.sort((a, b) => a.startMs.compareTo(b.startMs));
    return lines;
  }

  static List<KaraokeWordTiming> _parseWords(String body, int lineStartMs) {
    final matches = _wordTimingExp.allMatches(body).toList(growable: false);
    if (matches.isEmpty) return const [];
    final words = <KaraokeWordTiming>[];
    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final relStart = int.tryParse(match.group(1)!);
      final duration = int.tryParse(match.group(2)!);
      if (relStart == null || duration == null) continue;
      final textStart = match.end;
      final textEnd = i + 1 < matches.length
          ? matches[i + 1].start
          : body.length;
      final text = body.substring(textStart, textEnd);
      if (text.isEmpty) continue;
      final startMs = lineStartMs + relStart;
      words.add(
        KaraokeWordTiming(
          text: text,
          startMs: startMs,
          endMs: math.max(startMs + 1, startMs + duration),
        ),
      );
    }
    return words;
  }

  static List<KaraokeLyricLine> _parsePlainLyric(
    String lrc,
    Map<int, String> translations,
    Map<int, String> romans,
  ) {
    final lines = <KaraokeLyricLine>[];
    for (final raw in const LineSplitter().convert(lrc.replaceAll('\r', ''))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final field = _leadingTimeFieldExp.firstMatch(line);
      if (field == null) continue;
      final text = line.substring(field.end).trim();
      if (text.isEmpty) continue;
      for (final match in _lineTimeExp.allMatches(field.group(0)!)) {
        final startMs = _parseTimeMs(match.group(1)!);
        if (startMs == null) continue;
        lines.add(
          KaraokeLyricLine(
            startMs: startMs,
            endMs: startMs + 4000,
            text: text,
            translation: _nearestLine(translations, startMs),
            roman: _nearestLine(romans, startMs),
          ),
        );
      }
    }
    lines.sort((a, b) => a.startMs.compareTo(b.startMs));
    return lines;
  }

  static List<KaraokeLyricLine> _finalizeLineEnds(
    List<KaraokeLyricLine> lines,
  ) {
    if (lines.isEmpty) return const [];
    final out = <KaraokeLyricLine>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final nextStart = i + 1 < lines.length ? lines[i + 1].startMs : null;
      final naturalEnd = nextStart == null
          ? math.max(line.endMs, line.startMs + 4000)
          : math.max(line.startMs + 1, nextStart);
      out.add(
        KaraokeLyricLine(
          startMs: line.startMs,
          endMs: naturalEnd,
          text: line.text,
          translation: line.translation,
          roman: line.roman,
          words: line.words,
        ),
      );
    }
    return out;
  }

  static Map<int, String> _parseTextByTime(String? lrc) {
    if (lrc == null || lrc.trim().isEmpty) return const {};
    final out = <int, String>{};
    for (final raw in const LineSplitter().convert(lrc.replaceAll('\r', ''))) {
      final line = raw.trim();
      final field = _leadingTimeFieldExp.firstMatch(line);
      if (field == null) continue;
      final text = line.substring(field.end).trim();
      if (text.isEmpty) continue;
      for (final match in _lineTimeExp.allMatches(field.group(0)!)) {
        final ms = _parseTimeMs(match.group(1)!);
        if (ms != null) out[ms] = text;
      }
    }
    return out;
  }

  static int _matchingMainLineStart(
    Map<int, String> mainLines,
    String text,
    int fallbackStartMs,
  ) {
    final normalizedText = _normalizeLineText(text);
    int? bestStartMs;
    var bestDelta = 1 << 31;
    for (final entry in mainLines.entries) {
      if (_normalizeLineText(entry.value) != normalizedText) continue;
      final delta = (entry.key - fallbackStartMs).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestStartMs = entry.key;
      }
    }
    return bestStartMs ?? fallbackStartMs;
  }

  static String _normalizeLineText(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String? _nearestLine(Map<int, String> lines, int startMs) {
    if (lines.isEmpty) return null;
    final exact = lines[startMs];
    if (exact != null) return exact;
    int? bestKey;
    var bestDelta = 121;
    for (final key in lines.keys) {
      final delta = (key - startMs).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestKey = key;
      }
    }
    return bestKey == null ? null : lines[bestKey];
  }

  static int? _parseTimeMs(String label) {
    final parts = label.split(':');
    if (parts.isEmpty || parts.length > 3) return null;
    num seconds = 0;
    for (var i = 0; i < parts.length; i++) {
      final exp = parts.length - 1 - i;
      final value = double.tryParse(parts[i]);
      if (value == null) return null;
      seconds += value * _pow60[exp];
    }
    return (seconds * 1000).round();
  }

  static const _pow60 = [1, 60, 3600];
}

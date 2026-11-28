import 'package:flutter/foundation.dart';

import '../player/lyric_parser.dart';

/// Shot templates: the seven deterministic camera/layout templates a
/// stage engine interprets (mirrors Folia's seven sonnet shot kinds).
/// The compiler only picks them; the rendering lives in the styles.
enum FoliaShotKind {
  editorial,
  impact,
  collage,
  ribbon,
  reveal,
  poster,
  tableau,
}

/// Paragraph kinds: [verse] is the default, [chorus] holds repeated
/// lines, [interlude] follows a long silence, [outro] is the final
/// stretch of the song.
enum FoliaParagraphKind { verse, chorus, interlude, outro }

/// One shot's camera path: a slow push-in (scale grows) with a small
/// drift. Scales hover around 1.0–1.10; offsets are fractions of the
/// screen width/height, so the frame never leaves the stage.
@immutable
class FoliaCamera {
  const FoliaCamera({
    required this.startScale,
    required this.endScale,
    required this.startDx,
    required this.startDy,
    required this.endDx,
    required this.endDy,
  });

  final double startScale;
  final double endScale;
  final double startDx;
  final double startDy;
  final double endDx;
  final double endDy;

  @override
  bool operator ==(Object other) =>
      other is FoliaCamera &&
      other.startScale == startScale &&
      other.endScale == endScale &&
      other.startDx == startDx &&
      other.startDy == startDy &&
      other.endDx == endDx &&
      other.endDy == endDy;

  @override
  int get hashCode => Object.hash(
    startScale,
    endScale,
    startDx,
    startDy,
    endDx,
    endDy,
  );
}

/// One shot: up to [FoliaStoryboardCompiler.kMaxLinesPerShot] lines
/// spanning at most [FoliaStoryboardCompiler.kMaxShotMs], with its
/// template and camera path. [lineIndices] index into the source
/// lyrics' lines.
@immutable
class FoliaShot {
  const FoliaShot({
    required this.lineIndices,
    required this.startMs,
    required this.endMs,
    required this.kind,
    required this.camera,
  });

  final List<int> lineIndices;
  final int startMs;
  final int endMs;
  final FoliaShotKind kind;
  final FoliaCamera camera;

  @override
  bool operator ==(Object other) =>
      other is FoliaShot &&
      listEquals(other.lineIndices, lineIndices) &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.kind == kind &&
      other.camera == camera;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(lineIndices), startMs, endMs, kind, camera);
}

@immutable
class FoliaParagraph {
  const FoliaParagraph({required this.kind, required this.shots});

  final FoliaParagraphKind kind;
  final List<FoliaShot> shots;

  @override
  bool operator ==(Object other) =>
      other is FoliaParagraph &&
      other.kind == kind &&
      listEquals(other.shots, shots);

  @override
  int get hashCode => Object.hash(kind, Object.hashAll(shots));
}

/// A whole song, precompiled: paragraphs of shots, ready for a stage
/// to evaluate as f(absolute playback time). Deterministic: the same
/// lyrics + song id always compile to the same program.
@immutable
class FoliaProgram {
  const FoliaProgram({
    required this.songId,
    required this.paragraphs,
    required this.durationMs,
  });

  final String songId;
  final List<FoliaParagraph> paragraphs;
  final int durationMs;

  List<FoliaShot> get shots =>
      paragraphs.expand((paragraph) => paragraph.shots).toList();

  bool get isEmpty => shots.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is FoliaProgram &&
      other.songId == songId &&
      other.durationMs == durationMs &&
      listEquals(other.paragraphs, paragraphs);

  @override
  int get hashCode =>
      Object.hash(songId, durationMs, Object.hashAll(paragraphs));
}

/// Pure compiler: lyrics + song id → [FoliaProgram]. No UI, no state;
/// every choice derives from a stable FNV-1a hash of the song id plus
/// the paragraph/shot position, so the program is identical on every
/// run, preview, and export.
class FoliaStoryboardCompiler {
  const FoliaStoryboardCompiler();

  static const int kMaxLinesPerShot = 4;
  static const int kMaxShotMs = 6000;

  /// A gap this long between lines starts a new paragraph.
  static const int kParagraphGapMs = 8000;

  /// A gap this long before a paragraph marks it an interlude.
  static const int kBreakGapMs = 12000;

  FoliaProgram compile(KaraokeLyrics lyrics, String songId) {
    final lines = List<KaraokeLyricLine>.of(lyrics.lines)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    if (lines.isEmpty) {
      return FoliaProgram(songId: songId, paragraphs: const [], durationMs: 0);
    }
    final durationMs = lines.last.endMs;
    final repeated = _repeatedTexts(lines);

    // Split into paragraphs at long gaps, remembering the gap before
    // each paragraph for the interlude classification.
    final groups = <_Group>[];
    var current = <int>[0];
    var gapBefore = 0;
    for (var i = 1; i < lines.length; i++) {
      final gap = lines[i].startMs - lines[i - 1].endMs;
      if (gap >= kParagraphGapMs) {
        groups.add(_Group(current, gapBefore));
        current = [i];
        gapBefore = gap;
      } else {
        current.add(i);
      }
    }
    groups.add(_Group(current, gapBefore));

    FoliaShotKind? previousKind;
    final paragraphs = <FoliaParagraph>[];
    for (var p = 0; p < groups.length; p++) {
      final group = groups[p];
      final isChorus = group.indices.any(
        (i) => repeated.contains(_normalized(lines[i].text)),
      );
      final kind = isChorus
          ? FoliaParagraphKind.chorus
          : p == groups.length - 1 &&
                lines[group.indices.first].startMs >= durationMs * 0.75
          ? FoliaParagraphKind.outro
          : group.gapBefore >= kBreakGapMs
          ? FoliaParagraphKind.interlude
          : FoliaParagraphKind.verse;
      final shots = <FoliaShot>[];
      var shotStart = 0;
      while (shotStart < group.indices.length) {
        var shotEnd = shotStart;
        while (shotEnd + 1 < group.indices.length &&
            shotEnd - shotStart + 1 < kMaxLinesPerShot &&
            lines[group.indices[shotEnd + 1]].endMs -
                        lines[group.indices[shotStart]].startMs <=
                    kMaxShotMs) {
          shotEnd++;
        }
        final indices = group.indices.sublist(shotStart, shotEnd + 1);
        final startMs = lines[indices.first].startMs;
        final endMs = lines[indices.last].endMs;
        final shotKind = _pickKind(
          songId: songId,
          paragraphIndex: p,
          shotIndex: shots.length,
          previous: previousKind,
          shotMs: endMs - startMs,
          isChorus: kind == FoliaParagraphKind.chorus,
        );
        shots.add(
          FoliaShot(
            lineIndices: indices,
            startMs: startMs,
            endMs: endMs,
            kind: shotKind,
            camera: _camera(songId, p, shots.length),
          ),
        );
        previousKind = shotKind;
        shotStart = shotEnd + 1;
      }
      paragraphs.add(FoliaParagraph(kind: kind, shots: shots));
    }
    return FoliaProgram(
      songId: songId,
      paragraphs: paragraphs,
      durationMs: durationMs,
    );
  }

  Set<String> _repeatedTexts(List<KaraokeLyricLine> lines) {
    final counts = <String, int>{};
    for (final line in lines) {
      final normalized = _normalized(line.text);
      if (normalized.isEmpty) continue;
      counts[normalized] = (counts[normalized] ?? 0) + 1;
    }
    return counts.entries
        .where((entry) => entry.value >= 2)
        .map((entry) => entry.key)
        .toSet();
  }

  String _normalized(String text) =>
      text.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  FoliaShotKind _pickKind({
    required String songId,
    required int paragraphIndex,
    required int shotIndex,
    required FoliaShotKind? previous,
    required int shotMs,
    required bool isChorus,
  }) {
    // Short shots go quiet; a chorus never goes quiet.
    if (shotMs < 2000) {
      if (previous != FoliaShotKind.tableau) return FoliaShotKind.tableau;
      return FoliaShotKind.editorial;
    }
    var pool = FoliaShotKind.values.where((kind) => kind != previous).toList();
    if (isChorus) {
      pool = pool.where((kind) => kind != FoliaShotKind.tableau).toList();
    }
    final hash = _fnv1a('$songId:$paragraphIndex:$shotIndex');
    return pool[hash % pool.length];
  }

  FoliaCamera _camera(String songId, int paragraphIndex, int shotIndex) {
    final hash = _fnv1a('cam:$songId:$paragraphIndex:$shotIndex');
    double unit(int shift) => ((hash >> shift) & 0xFF) / 255.0;
    final startScale = 1.0 + unit(0) * 0.04;
    return FoliaCamera(
      startScale: startScale,
      endScale: startScale + 0.02 + unit(8) * 0.04,
      startDx: (unit(16) - 0.5) * 0.06,
      startDy: (unit(24) - 0.5) * 0.06,
      endDx: (unit(4) - 0.5) * 0.06,
      endDy: (unit(12) - 0.5) * 0.06,
    );
  }

  /// FNV-1a 32-bit over UTF-16 code units. Stable across runs and
  /// platforms, unlike String.hashCode.
  int _fnv1a(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}

class _Group {
  const _Group(this.indices, this.gapBefore);
  final List<int> indices;
  final int gapBefore;
}

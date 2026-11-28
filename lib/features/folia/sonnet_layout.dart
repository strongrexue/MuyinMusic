import 'dart:math' as math;

import 'folia_storyboard.dart';

/// Sonnet (商籁) layout engine: the deterministic typography
/// compositions, ported from the Folia blueprint
/// (src/components/visualizer/sonnet/sonnetTypographyLayout.ts,
/// sonnetShotFlowLayouts.ts, sonnetPosterBlocksLayout.ts).
///
/// All coordinates are center-based: (0, 0) is the stage center,
/// x right, y down — the blueprint's convention. The stage converts
/// to top-left widget coordinates.
///
/// Every layout runs the blueprint's global-fit ladder
/// (placeWithGlobalFit): scales [1, 0.92, 0.84, 0.76, 0.68, 0.6,
/// 0.52] until every box sits inside the safe area (|x| + w/2 ≤
/// 0.48 × width, |y| + h/2 ≤ 0.46 × height). The last rung is kept
/// even when it still overflows, exactly like the blueprint.

enum SonnetLayoutDirection { horizontal, vertical }

/// Whether [text] contains a CJK glyph (Han, Hiragana/Katakana,
/// Hangul). The blueprint stacks CJK words as vertical columns in
/// the vertical layouts and rotates non-CJK words instead
/// (sonnetGlyphLayout.ts isCjkSegment).
bool sonnetIsCjk(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0x3040 && rune <= 0x30FF) ||
        (rune >= 0xAC00 && rune <= 0xD7AF)) {
      return true;
    }
  }
  return false;
}

/// One measured word entering the layout pass. [measuredWidth] /
/// [measuredHeight] are at [fontScale]; the fit ladder scales all
/// three together. The layout pass writes [x], [y], [rotation],
/// [enterX], [enterY] and [layoutDirection].
class SonnetLayoutWord {
  SonnetLayoutWord({
    required this.index,
    required this.isHero,
    required this.isSemiHero,
    required this.fontScale,
    required this.measuredWidth,
    required this.measuredHeight,
    this.vertical = false,
    this.rotation = 0,
    this.verticalMeasuredWidth,
    this.verticalMeasuredHeight,
    this.verticalFontScale,
  });

  final int index;
  final bool isHero;
  final bool isSemiHero;
  double fontScale;
  double measuredWidth;
  double measuredHeight;

  /// CJK column orientation (stacked glyphs). Set by the caller
  /// from the blueprint's per-kind vertical rule.
  bool vertical;

  /// Base rotation in radians (π/2 for a rotated non-CJK block).
  double rotation;

  /// Pre-measured vertical-column alternative, used by poster
  /// blocks when the flow orientation is vertical. Null for
  /// non-CJK words (they keep the horizontal footprint).
  final double? verticalMeasuredWidth;
  final double? verticalMeasuredHeight;
  final double? verticalFontScale;

  double x = 0;
  double y = 0;
  double enterX = 0;
  double enterY = 0;
  SonnetLayoutDirection layoutDirection =
      SonnetLayoutDirection.horizontal;
}

class SonnetLayoutOutcome {
  const SonnetLayoutOutcome({
    required this.editorialVariant,
    required this.ribbonVariant,
    required this.tableauVariant,
    required this.collageVariant,
    required this.posterOrientation,
    required this.secondaryHeroIndex,
    required this.boxes,
  });

  /// Editorial variant 0–4 (0 vertical pillar, 1 flush-right rail,
  /// 2 magazine header, 3 double hero lines, 4 logo badge).
  final int editorialVariant;
  final int ribbonVariant;
  final int tableauVariant;
  final int collageVariant;

  /// Poster flow orientation: 0 horizontal rows, 1 vertical
  /// columns (right-to-left, traditional Japanese typesetting).
  final int posterOrientation;
  final int secondaryHeroIndex;
  final List<SonnetLayoutWord> boxes;
}

/// Variant seed: sum of trimmed segment lengths + segment count
/// (sonnetTypographyLayout.ts layoutVariantSeed).
int sonnetLayoutVariantSeed(List<int> trimmedLengths) =>
    trimmedLengths.fold(0, (sum, length) => sum + length) +
    trimmedLengths.length;

/// Editorial variant with the blueprint's fallbacks: variant 3
/// needs > 2 segments and a secondary hero, otherwise 0; variant 4
/// with < 2 segments falls back to 2 (magazine header).
int sonnetEditorialVariant(
  int layoutVariantSeed,
  int segmentCount,
  int secondaryHeroIndex,
) {
  var variant = layoutVariantSeed % 5;
  if (variant == 3) {
    if (segmentCount <= 2 || secondaryHeroIndex < 0) variant = 0;
  } else if (variant == 4 && segmentCount < 2) {
    variant = 2;
  }
  return variant;
}

/// Word-to-word gap and line/column gap shared by all branches
/// (sonnetShotFlowLayouts.ts resolveSonnetFlowGaps).
({double flowGap, double stackGap}) sonnetFlowGaps(double baseFontSize) {
  final flowGap = (baseFontSize * 0.35).clamp(16, 40).toDouble();
  return (flowGap: flowGap, stackGap: math.max(24, flowGap * 1.35));
}

void _placeWithGlobalFit(
  List<SonnetLayoutWord> boxes,
  double width,
  double height,
  void Function(double globalScale) place,
) {
  final snapshot = boxes
      .map((box) => (box.fontScale, box.measuredWidth, box.measuredHeight))
      .toList();
  const rungs = [1.0, 0.92, 0.84, 0.76, 0.68, 0.6, 0.52];
  final safeHalfW = width * 0.48;
  final safeHalfH = height * 0.46;
  for (final rung in rungs) {
    for (var i = 0; i < boxes.length; i++) {
      boxes[i].fontScale = snapshot[i].$1 * rung;
      boxes[i].measuredWidth = snapshot[i].$2 * rung;
      boxes[i].measuredHeight = snapshot[i].$3 * rung;
    }
    place(rung);
    final fits = boxes.every(
      (box) =>
          box.x.abs() + box.measuredWidth / 2 <= safeHalfW + 0.5 &&
          box.y.abs() + box.measuredHeight / 2 <= safeHalfH + 0.5,
    );
    if (fits) return;
  }
}

SonnetLayoutOutcome sonnetLayoutShot({
  required List<SonnetLayoutWord> boxes,
  required int heroIndex,
  required int secondaryHeroIndex,
  required FoliaShotKind kind,
  required double width,
  required double height,
  required double baseFontSize,
  required int layoutVariantSeed,
  required int posterSeed,
}) {
  final gaps = sonnetFlowGaps(baseFontSize);
  final editorialVariant = kind == FoliaShotKind.editorial
      ? sonnetEditorialVariant(
          layoutVariantSeed,
          boxes.length,
          secondaryHeroIndex,
        )
      : 0;
  final ribbonVariant = layoutVariantSeed % 3;
  final tableauVariant = layoutVariantSeed % 4;
  final collageVariant = layoutVariantSeed % 3;
  final posterOrientation = posterSeed % 2;

  switch (kind) {
    case FoliaShotKind.editorial:
      _layoutEditorialColumn(
        boxes: boxes,
        heroIndex: heroIndex,
        secondaryHeroIndex: secondaryHeroIndex,
        variant: editorialVariant,
        width: width,
        height: height,
        flowGap: gaps.flowGap,
        stackGap: gaps.stackGap,
      );
    case FoliaShotKind.ribbon:
      _layoutTrackingRibbon(
        boxes: boxes,
        heroIndex: heroIndex,
        variant: ribbonVariant,
        width: width,
        height: height,
        flowGap: gaps.flowGap,
        stackGap: gaps.stackGap,
      );
    case FoliaShotKind.tableau:
      _layoutQuietTableau(
        boxes: boxes,
        heroIndex: heroIndex,
        variant: tableauVariant,
        width: width,
        height: height,
        flowGap: gaps.flowGap,
        stackGap: gaps.stackGap,
      );
    case FoliaShotKind.collage:
      _layoutFragmentCollage(
        boxes: boxes,
        heroIndex: heroIndex,
        variant: collageVariant,
        width: width,
        height: height,
        flowGap: gaps.flowGap,
        stackGap: gaps.stackGap,
      );
    case FoliaShotKind.impact:
    case FoliaShotKind.reveal:
      _layoutCrossStack(
        boxes: boxes,
        heroIndex: heroIndex,
        width: width,
        height: height,
        flowGap: gaps.flowGap,
        stackGap: gaps.stackGap,
      );
    case FoliaShotKind.poster:
      _layoutPosterBlocks(
        boxes: boxes,
        width: width,
        height: height,
        baseFontSize: baseFontSize,
        gap: gaps.flowGap,
        seed: posterSeed,
        orientation: posterOrientation,
      );
  }
  return SonnetLayoutOutcome(
    editorialVariant: editorialVariant,
    ribbonVariant: ribbonVariant,
    tableauVariant: tableauVariant,
    collageVariant: collageVariant,
    posterOrientation: posterOrientation,
    secondaryHeroIndex: secondaryHeroIndex,
    boxes: boxes,
  );
}

void _layoutEditorialColumn({
  required List<SonnetLayoutWord> boxes,
  required int heroIndex,
  required int secondaryHeroIndex,
  required int variant,
  required double width,
  required double height,
  required double flowGap,
  required double stackGap,
}) {
  final heroBox = boxes[heroIndex];
  if (variant == 0) {
    for (final box in boxes) {
      box.layoutDirection = SonnetLayoutDirection.vertical;
    }
    _placeWithGlobalFit(boxes, width, height, (_) {
      heroBox.x = -width * 0.15;
      heroBox.y = 0;
      var currentY =
          heroBox.y - heroBox.measuredHeight / 2 + stackGap * 0.5;
      for (var i = 0; i < heroIndex; i++) {
        final box = boxes[i];
        box.x =
            heroBox.x +
            heroBox.measuredWidth / 2 +
            flowGap +
            box.measuredWidth / 2;
        box.y = currentY + box.measuredHeight / 2;
        currentY += box.measuredHeight + stackGap;
        box.enterX = -20;
        box.enterY = 0;
      }
      currentY = heroBox.y - heroBox.measuredHeight / 2 + stackGap * 0.5;
      for (var i = heroIndex + 1; i < boxes.length; i++) {
        final box = boxes[i];
        box.x =
            heroBox.x -
            heroBox.measuredWidth / 2 -
            flowGap -
            box.measuredWidth / 2;
        box.y = currentY + box.measuredHeight / 2;
        currentY += box.measuredHeight + stackGap;
        box.enterX = 20;
        box.enterY = 0;
      }
    });
  } else if (variant == 1) {
    for (final box in boxes) {
      box.layoutDirection = SonnetLayoutDirection.vertical;
    }
    _placeWithGlobalFit(boxes, width, height, (_) {
      final rightEdge = width * 0.28;
      final safeHalfH = height * 0.46;
      final railStep =
          boxes.fold(
            0.0,
            (max, box) => math.max(max, box.measuredWidth),
          ) +
          stackGap;
      final totalHeight =
          boxes.fold(0.0, (sum, box) => sum + box.measuredHeight) +
          stackGap * (boxes.length - 1);
      final fitsSingleRail = totalHeight <= safeHalfH * 2;
      if (fitsSingleRail) {
        var currentY = -totalHeight / 2;
        for (final box in boxes) {
          box.x = rightEdge - box.measuredWidth / 2;
          box.y = currentY + box.measuredHeight / 2;
          currentY += box.measuredHeight + stackGap;
          box.enterX = 20;
          box.enterY = 0;
        }
        return;
      }
      var rail = 0;
      var currentY = -safeHalfH;
      for (final box in boxes) {
        if (currentY + box.measuredHeight > safeHalfH) {
          rail += 1;
          currentY = -safeHalfH;
        }
        box.x = (rightEdge - rail * railStep) - box.measuredWidth / 2;
        box.y = currentY + box.measuredHeight / 2;
        currentY += box.measuredHeight + stackGap;
        box.enterX = 20;
        box.enterY = 0;
      }
    });
  } else if (variant == 2) {
    for (final box in boxes) {
      box.layoutDirection = SonnetLayoutDirection.horizontal;
    }
    _placeWithGlobalFit(boxes, width, height, (_) {
      heroBox.x = 0;
      heroBox.y = -height * 0.25;
      final before = boxes.sublist(0, heroIndex);
      final after = boxes.sublist(heroIndex + 1);
      if (before.isNotEmpty) {
        final kickerHeight = before.fold(
          0.0,
          (max, box) => math.max(max, box.measuredHeight),
        );
        final kickerWidth =
            before.fold(0.0, (sum, box) => sum + box.measuredWidth) +
            flowGap * (before.length - 1);
        final kickerY =
            heroBox.y -
            heroBox.measuredHeight / 2 -
            stackGap -
            kickerHeight / 2;
        var currentX = heroBox.x - kickerWidth / 2;
        for (final box in before) {
          box.x = currentX + box.measuredWidth / 2;
          box.y = kickerY;
          currentX += box.measuredWidth + flowGap;
          box.enterX = 0;
          box.enterY = -20;
        }
      }
      final leftAnchor =
          heroBox.x - heroBox.measuredWidth * 0.25 - flowGap;
      final rightAnchor =
          heroBox.x + heroBox.measuredWidth * 0.25 + flowGap;
      var currentY =
          heroBox.y + heroBox.measuredHeight / 2 + stackGap;
      for (var pair = 0; pair < after.length; pair += 2) {
        final left = after[pair];
        final right = pair + 1 < after.length ? after[pair + 1] : null;
        final rowHeight = math.max(
          left.measuredHeight,
          right?.measuredHeight ?? 0,
        );
        left.x = leftAnchor - left.measuredWidth / 2;
        left.y = currentY + left.measuredHeight / 2;
        left.enterX = -20;
        left.enterY = 0;
        if (right != null) {
          right.x = rightAnchor + right.measuredWidth / 2;
          right.y = currentY + right.measuredHeight / 2;
          right.enterX = 20;
          right.enterY = 0;
        }
        currentY += rowHeight + stackGap;
      }
    });
  } else if (variant == 3) {
    for (final box in boxes) {
      box.layoutDirection = SonnetLayoutDirection.horizontal;
    }
    _placeWithGlobalFit(boxes, width, height, (_) {
      heroBox.x = 0;
      heroBox.y = 0;
      final firstHero = math.min(heroIndex, secondaryHeroIndex);
      final line1 = boxes.sublist(0, firstHero + 1);
      final line2 = boxes.sublist(firstHero + 1);
      final line1Height = line1.fold(
        0.0,
        (max, box) => math.max(max, box.measuredHeight),
      );
      final line2Height = line2.isEmpty
          ? 0.0
          : line2.fold(
              0.0,
              (max, box) => math.max(max, box.measuredHeight),
            );
      final totalHeight = line1Height + stackGap + line2Height;
      final line1Y = heroBox.y - totalHeight / 2 + line1Height / 2;
      final line2Y =
          line1Y + line1Height / 2 + stackGap + line2Height / 2;
      double layLine(
        List<SonnetLayoutWord> line,
        double lineY,
        double enterX,
      ) {
        final lineWidth =
            line.fold(0.0, (sum, box) => sum + box.measuredWidth) +
            flowGap * (line.length - 1);
        var currentX = -lineWidth / 2;
        for (final box in line) {
          box.x = currentX + box.measuredWidth / 2;
          box.y = lineY;
          currentX += box.measuredWidth + flowGap;
          box.enterX = enterX;
          box.enterY = 0;
        }
        return lineWidth;
      }

      final line1Width = layLine(line1, line1Y, 30);
      final line2Width = layLine(line2, line2Y, -30);
      final offsetAmount =
          math.max(line1Width, line2Width) * 0.12;
      for (final box in line1) {
        box.x -= offsetAmount;
      }
      for (final box in line2) {
        box.x += offsetAmount;
      }
    });
  } else {
    // Variant 4: logo badge — the hero pillar floats on the
    // flow-start side; earlier words take full-width rows above it,
    // later words wrap beside it, then continue full-width below.
    for (var i = 0; i < boxes.length; i++) {
      boxes[i].layoutDirection = i == heroIndex
          ? SonnetLayoutDirection.vertical
          : SonnetLayoutDirection.horizontal;
    }
    _placeWithGlobalFit(boxes, width, height, (_) {
      final heroOnRight = heroIndex == boxes.length - 1;
      final blockLeft = -width * 0.40;
      final blockRight = width * 0.40;
      var currentY = -height * 0.34;

      void flowWords(
        List<int> indices,
        List<double> Function(double rowTop) regionFor,
      ) {
        var region = regionFor(currentY);
        var left = region[0];
        var right = region[1];
        var currentX = left;
        var rowHeight = 0.0;
        for (final index in indices) {
          final box = boxes[index];
          if (currentX > left && currentX + box.measuredWidth > right) {
            currentY += rowHeight + stackGap;
            region = regionFor(currentY);
            left = region[0];
            right = region[1];
            currentX = left;
            rowHeight = 0;
          }
          box.x = currentX + box.measuredWidth / 2;
          box.y = currentY + box.measuredHeight / 2;
          box.enterX = heroOnRight ? -25 : 25;
          box.enterY = 0;
          currentX += box.measuredWidth + flowGap;
          rowHeight = math.max(rowHeight, box.measuredHeight);
        }
        if (indices.isNotEmpty) currentY += rowHeight;
      }

      final beforeIndices = [
        for (var i = 0; i < heroIndex; i++) i,
      ];
      final afterIndices = [
        for (var i = heroIndex + 1; i < boxes.length; i++) i,
      ];
      flowWords(beforeIndices, (_) => [blockLeft, blockRight]);
      currentY += stackGap;

      final pillarLeft = heroOnRight
          ? blockRight - heroBox.measuredWidth
          : blockLeft;
      heroBox.x = pillarLeft + heroBox.measuredWidth / 2;
      heroBox.y = currentY + heroBox.measuredHeight / 2;
      final pillarBottom = currentY + heroBox.measuredHeight + stackGap;
      final besideLeft = heroOnRight
          ? blockLeft
          : pillarLeft + heroBox.measuredWidth + flowGap;
      final besideRight = heroOnRight
          ? pillarLeft - flowGap
          : blockRight;
      flowWords(afterIndices, (rowTop) {
        if (rowTop < pillarBottom - 0.5) {
          return [besideLeft, besideRight];
        }
        return [blockLeft, blockRight];
      });
    });
  }
}

void _layoutTrackingRibbon({
  required List<SonnetLayoutWord> boxes,
  required int heroIndex,
  required int variant,
  required double width,
  required double height,
  required double flowGap,
  required double stackGap,
}) {
  final heroBox = boxes[heroIndex];
  for (final box in boxes) {
    box.layoutDirection = SonnetLayoutDirection.horizontal;
  }
  _placeWithGlobalFit(boxes, width, height, (_) {
    heroBox.x = 0;
    heroBox.y = 0;
    double alignY(SonnetLayoutWord box, int index) {
      if (variant == 1) {
        return heroBox.y + heroBox.measuredHeight / 2 - box.measuredHeight / 2;
      }
      if (variant == 2) {
        return heroBox.y - heroBox.measuredHeight / 2 + box.measuredHeight / 2;
      }
      return heroBox.y + (index % 2 == 0 ? 10 : -10);
    }

    final enter = variant == 2 ? 20.0 : 30.0;
    var currentX =
        heroBox.x - heroBox.measuredWidth / 2 - flowGap;
    for (var i = heroIndex - 1; i >= 0; i--) {
      final box = boxes[i];
      box.x = currentX - box.measuredWidth / 2;
      box.y = alignY(box, i);
      currentX -= box.measuredWidth + flowGap;
      box.enterX = enter;
      box.enterY = 0;
    }
    currentX = heroBox.x + heroBox.measuredWidth / 2 + flowGap;
    for (var i = heroIndex + 1; i < boxes.length; i++) {
      final box = boxes[i];
      box.x = currentX + box.measuredWidth / 2;
      box.y = alignY(box, i);
      currentX += box.measuredWidth + flowGap;
      box.enterX = -enter;
      box.enterY = 0;
    }
  });
}

void _layoutQuietTableau({
  required List<SonnetLayoutWord> boxes,
  required int heroIndex,
  required int variant,
  required double width,
  required double height,
  required double flowGap,
  required double stackGap,
}) {
  final heroBox = boxes[heroIndex];
  final horizontalCard = variant == 2 || variant == 3;
  for (final box in boxes) {
    box.layoutDirection = horizontalCard
        ? SonnetLayoutDirection.horizontal
        : SonnetLayoutDirection.vertical;
  }
  _placeWithGlobalFit(boxes, width, height, (_) {
    heroBox.x = 0;
    heroBox.y = horizontalCard ? 0 : -height * 0.1;
    final safeHalfH = height * 0.46;
    final stagger = variant == 3 ? 70.0 : 0.0;
    final columnStep =
        boxes.fold(
          0.0,
          (max, box) => math.max(max, box.measuredWidth),
        ) +
        stackGap +
        stagger;
    double xFor(SonnetLayoutWord box, int index) {
      if (variant == 1) {
        return heroBox.x - heroBox.measuredWidth / 2 + box.measuredWidth / 2;
      }
      if (variant == 3) {
        return heroBox.x + ((index % 2 == 0) ? 1 : -1) * 35;
      }
      return heroBox.x;
    }

    var column = 0;
    var currentY =
        heroBox.y - heroBox.measuredHeight / 2 - stackGap;
    for (var i = heroIndex - 1; i >= 0; i--) {
      final box = boxes[i];
      if (currentY - box.measuredHeight < -safeHalfH) {
        column += 1;
        currentY = safeHalfH;
      }
      box.x = xFor(box, i) + column * columnStep;
      box.y = currentY - box.measuredHeight / 2;
      currentY -= box.measuredHeight + stackGap;
      if (variant == 1) {
        box.enterX = 20;
        box.enterY = 0;
      } else if (variant == 3) {
        box.enterX = box.x > heroBox.x ? 30 : -30;
        box.enterY = 0;
      } else {
        box.enterX = 0;
        box.enterY = 20;
      }
    }
    column = 0;
    currentY = heroBox.y + heroBox.measuredHeight / 2 + stackGap;
    for (var i = heroIndex + 1; i < boxes.length; i++) {
      final box = boxes[i];
      if (currentY + box.measuredHeight > safeHalfH) {
        column += 1;
        currentY = -safeHalfH;
      }
      box.x = xFor(box, i) - column * columnStep;
      box.y = currentY + box.measuredHeight / 2;
      currentY += box.measuredHeight + stackGap;
      if (variant == 1) {
        box.enterX = -20;
        box.enterY = 0;
      } else if (variant == 3) {
        box.enterX = box.x > heroBox.x ? 30 : -30;
        box.enterY = 0;
      } else {
        box.enterX = 0;
        box.enterY = -20;
      }
    }
  });
}

void _layoutFragmentCollage({
  required List<SonnetLayoutWord> boxes,
  required int heroIndex,
  required int variant,
  required double width,
  required double height,
  required double flowGap,
  required double stackGap,
}) {
  final heroBox = boxes[heroIndex];
  // Flatten rotated non-CJK blocks back to horizontal before the
  // fit retries snapshot the boxes.
  for (var i = 0; i < boxes.length; i++) {
    if (i == heroIndex) continue;
    final box = boxes[i];
    final quarterTurns = (box.rotation / (math.pi / 2)).round();
    if (quarterTurns % 2 != 0) {
      final rotatedWidth = box.measuredHeight;
      box.measuredHeight = box.measuredWidth;
      box.measuredWidth = rotatedWidth;
    }
    box.rotation = 0;
  }
  _placeWithGlobalFit(boxes, width, height, (globalScale) {
    heroBox.x = 0;
    heroBox.y = 0;
    final baseRadius =
        math.sqrt(
          heroBox.measuredWidth * heroBox.measuredWidth +
              heroBox.measuredHeight * heroBox.measuredHeight,
        ) /
        2 +
        stackGap;
    final count = math.max(1, boxes.length - 1);
    const squash = 0.65;
    final placed = <({double left, double right, double top, double bottom})>[
      (
        left: heroBox.x - heroBox.measuredWidth / 2,
        right: heroBox.x + heroBox.measuredWidth / 2,
        top: heroBox.y - heroBox.measuredHeight / 2,
        bottom: heroBox.y + heroBox.measuredHeight / 2,
      ),
    ];
    double rectSeparation(
      ({double left, double right, double top, double bottom}) a,
      ({double left, double right, double top, double bottom}) b,
    ) => math.max(
      math.max(a.left - b.right, b.left - a.right),
      math.max(a.top - b.bottom, b.top - a.bottom),
    );
    var angle = math.pi / 4;
    var supportIndex = 0;
    for (var i = 0; i < boxes.length; i++) {
      if (i == heroIndex) continue;
      final box = boxes[i];
      var radius = baseRadius;
      if (variant == 1) {
        radius += (35 + (supportIndex / count) * 150) * globalScale;
      } else if (variant == 2) {
        radius += ((supportIndex % 2 == 1) ? 140 : 50) * globalScale;
      } else {
        radius += (45 + ((supportIndex * 23) % 90)) * globalScale;
      }
      supportIndex += 1;
      var candidate = angle;
      var resolvedRadius = radius;
      var placedClear = false;
      ({double left, double right, double top, double bottom}) rect = (
        left: 0,
        right: 0,
        top: 0,
        bottom: 0,
      );
      for (var ring = 0; ring < 14 && !placedClear; ring++) {
        for (var attempt = 0; attempt < 400; attempt++) {
          rect = (
            left:
                math.cos(candidate) * resolvedRadius -
                box.measuredWidth / 2,
            right:
                math.cos(candidate) * resolvedRadius +
                box.measuredWidth / 2,
            top:
                math.sin(candidate) * resolvedRadius * squash -
                box.measuredHeight / 2,
            bottom:
                math.sin(candidate) * resolvedRadius * squash +
                box.measuredHeight / 2,
          );
          if (placed.every(
            (entry) => rectSeparation(entry, rect) >= flowGap,
          )) {
            placedClear = true;
            break;
          }
          candidate += 0.07;
        }
        if (!placedClear) {
          resolvedRadius += (36 + ring * 12) * globalScale;
        }
      }
      angle = candidate + 0.02;
      placed.add(rect);
      box.x = heroBox.x + math.cos(candidate) * resolvedRadius;
      box.y = heroBox.y + math.sin(candidate) * resolvedRadius * squash;
      box.layoutDirection =
          math.cos(candidate).abs() >= math.sin(candidate).abs()
          ? SonnetLayoutDirection.vertical
          : SonnetLayoutDirection.horizontal;
      box.enterX = math.cos(candidate) * -60;
      box.enterY = math.sin(candidate) * -60;
    }
  });
}

void _layoutCrossStack({
  required List<SonnetLayoutWord> boxes,
  required int heroIndex,
  required double width,
  required double height,
  required double flowGap,
  required double stackGap,
}) {
  final heroBox = boxes[heroIndex];
  final beforeCount = heroIndex;
  final topCount = beforeCount ~/ 2;
  final afterCount = boxes.length - 1 - heroIndex;
  final rightCount = (afterCount + 1) ~/ 2;

  _placeWithGlobalFit(boxes, width, height, (_) {
    heroBox.x = 0;
    heroBox.y = 0;

    double fillColumn(List<SonnetLayoutWord> column) {
      if (column.isEmpty) return 0;
      final available = math.max(
        0,
        height * 0.46 - heroBox.measuredHeight / 2 - stackGap,
      );
      if (available <= 0) return 0;
      final gaps = stackGap * (column.length - 1);
      final contentHeight = column.fold(
        0.0,
        (sum, box) => sum + box.measuredHeight,
      );
      final target = available * 0.72;
      if (contentHeight + gaps < target) {
        final boost = math.min(
          2.2,
          (target - gaps) / math.max(1, contentHeight),
        );
        for (final box in column) {
          final capped = math.min(
            boost,
            (heroBox.fontScale * 0.6) / box.fontScale,
          );
          if (capped > 1.05) {
            box.fontScale *= capped;
            box.measuredWidth *= capped;
            box.measuredHeight *= capped;
          }
        }
      }
      if (column.length < 2) return 0;
      final grown = column.fold(
        0.0,
        (sum, box) => sum + box.measuredHeight,
      );
      final pitch = (available * 0.95 - grown) / (column.length - 1);
      return math.max(0, math.min(stackGap * 2, pitch - stackGap));
    }

    final topStretch = fillColumn(boxes.sublist(0, topCount));
    final bottomStretch = fillColumn(
      boxes.sublist(heroIndex + rightCount + 1),
    );

    var currentX =
        heroBox.x - heroBox.measuredWidth / 2 - stackGap;
    for (var i = heroIndex - 1; i >= topCount; i--) {
      final box = boxes[i];
      box.layoutDirection = SonnetLayoutDirection.horizontal;
      box.x = currentX - box.measuredWidth / 2;
      box.y = heroBox.y + (i % 2 == 0 ? 10 : -10);
      currentX -= box.measuredWidth + flowGap;
      box.enterX = -30;
      box.enterY = 0;
    }

    var currentY =
        heroBox.y - heroBox.measuredHeight / 2 - stackGap;
    for (var i = topCount - 1; i >= 0; i--) {
      final box = boxes[i];
      box.layoutDirection = SonnetLayoutDirection.vertical;
      box.x = heroBox.x + (i % 2 == 0 ? 15 : -15);
      box.y = currentY - box.measuredHeight / 2;
      currentY -= box.measuredHeight + stackGap + topStretch;
      box.enterX = 0;
      box.enterY = -30;
    }

    currentX = heroBox.x + heroBox.measuredWidth / 2 + stackGap;
    for (var i = heroIndex + 1; i <= heroIndex + rightCount; i++) {
      final box = boxes[i];
      box.layoutDirection = SonnetLayoutDirection.horizontal;
      box.x = currentX + box.measuredWidth / 2;
      box.y = heroBox.y + (i % 2 == 0 ? 10 : -10);
      currentX += box.measuredWidth + flowGap;
      box.enterX = 30;
      box.enterY = 0;
    }

    currentY = heroBox.y + heroBox.measuredHeight / 2 + stackGap;
    for (var i = heroIndex + rightCount + 1; i < boxes.length; i++) {
      final box = boxes[i];
      box.layoutDirection = SonnetLayoutDirection.vertical;
      box.x = heroBox.x + (i % 2 == 0 ? 15 : -15);
      box.y = currentY + box.measuredHeight / 2;
      currentY += box.measuredHeight + stackGap + bottomStretch;
      box.enterX = 0;
      box.enterY = 30;
    }
  });
}

void _layoutPosterBlocks({
  required List<SonnetLayoutWord> boxes,
  required double width,
  required double height,
  required double baseFontSize,
  required double gap,
  required int seed,
  required int orientation,
}) {
  final chipGap = gap;
  final lineGap = gap * 1.15;
  final canvasLeft = -width * 0.42;
  final canvasTop = -height * 0.40;
  final canvasWidth = width * 0.84;
  final canvasHeight = height * 0.80;
  // Flow u is the reading direction, v the stacking direction.
  final spaceU = orientation == 0 ? canvasWidth : canvasHeight;
  final spaceV = orientation == 0 ? canvasHeight : canvasWidth;

  ({List<_PosterPlacement> placements, double vTotal}) attempt(
    double globalScale,
  ) {
    final placements = <_PosterPlacement>[];
    final floats = <({double extent, double vBottom})>[];
    var vCursor = 0.0;
    var ownBandOnEndSide = ((seed >> 1) & 1) == 1;

    ({bool useVertical, double scale, double w, double h}) measure(
      SonnetLayoutWord box,
    ) {
      final useVertical =
          orientation == 1 &&
          box.verticalMeasuredWidth != null &&
          box.verticalMeasuredHeight != null &&
          box.verticalFontScale != null;
      final baseScale = useVertical
          ? box.verticalFontScale!
          : box.fontScale;
      final w =
          (useVertical
                  ? box.verticalMeasuredWidth!
                  : box.measuredWidth) *
              globalScale;
      final h =
          (useVertical
                  ? box.verticalMeasuredHeight!
                  : box.measuredHeight) *
              globalScale;
      return (useVertical: useVertical, scale: baseScale, w: w, h: h);
    }

    ({double uSize, double vSize}) toFlowSize(double w, double h) =>
        orientation == 0 ? (uSize: w, vSize: h) : (uSize: h, vSize: w);

    void pruneFloats() {
      for (var i = floats.length - 1; i >= 0; i--) {
        if (floats[i].vBottom <= vCursor) floats.removeAt(i);
      }
    }

    // Partition into emphasis zones and support groups, in order.
    final items = <({bool isZone, SonnetLayoutWord? zone, List<SonnetLayoutWord>? group})>[];
    var group = <SonnetLayoutWord>[];
    for (final box in boxes) {
      if (box.isHero || box.isSemiHero) {
        if (group.isNotEmpty) {
          items.add((isZone: false, zone: null, group: group));
        }
        group = [];
        items.add((isZone: true, zone: box, group: null));
      } else {
        group.add(box);
      }
    }
    if (group.isNotEmpty) {
      items.add((isZone: false, zone: null, group: group));
    }

    for (var itemIndex = 0; itemIndex < items.length; itemIndex++) {
      final item = items[itemIndex];
      pruneFloats();
      if (!item.isZone) {
        final reservedU = floats.fold(
          0.0,
          (sum, entry) => sum + entry.extent,
        );
        final capacity = math.max(chipGap * 2, spaceU - reservedU);
        final uStart = reservedU;
        final chips = item.group!.map((box) {
          final dims = measure(box);
          final flow = toFlowSize(dims.w, dims.h);
          return (
            box: box,
            dims: dims,
            uSize: flow.uSize,
            vSize: flow.vSize,
            shrink: 1.0,
          );
        }).toList();
        var line = <({
          SonnetLayoutWord box,
          ({bool useVertical, double scale, double w, double h}) dims,
          double uSize,
          double vSize,
          double shrink,
        })>[];
        var lineUsedU = 0.0;
        void flushLine() {
          if (line.isEmpty) return;
          final lineV = line.fold(
            0.0,
            (max, chip) => math.max(max, chip.vSize * chip.shrink),
          );
          final leftover = capacity - lineUsedU;
          final spread = line.length > 1 && leftover > 0
              ? math.min(leftover / (line.length - 1), chipGap * 2.5)
              : 0.0;
          var uCursor = uStart;
          for (final chip in line) {
            final finalScale =
                chip.dims.scale * globalScale * chip.shrink;
            placements.add(
              _PosterPlacement(
                box: chip.box,
                u: uCursor,
                v: vCursor,
                uSize: chip.uSize * chip.shrink,
                vSize: chip.vSize * chip.shrink,
                scale: finalScale,
                vertical: chip.dims.useVertical,
              ),
            );
            uCursor += chip.uSize * chip.shrink + chipGap + spread;
          }
          vCursor += lineV + lineGap;
          pruneFloats();
          line = [];
          lineUsedU = 0;
        }

        for (final chip in chips) {
          var chipMut = chip;
          final needed =
              lineUsedU +
              (line.isNotEmpty ? chipGap : 0) +
              chip.uSize;
          if (needed > capacity && line.isNotEmpty) flushLine();
          if (chip.uSize > capacity) {
            chipMut = (
              box: chip.box,
              dims: chip.dims,
              uSize: chip.uSize,
              vSize: chip.vSize,
              shrink: math.max(0.5, capacity / chip.uSize),
            );
            lineUsedU = 0;
            line.add(chipMut);
            flushLine();
            continue;
          }
          lineUsedU += (line.isNotEmpty ? chipGap : 0) + chip.uSize;
          line.add(chipMut);
        }
        flushLine();
        continue;
      }

      final zone = item.zone!;
      vCursor = math.max(
        vCursor,
        floats.fold(0.0, (max, entry) => math.max(max, entry.vBottom)),
      );
      floats.clear();
      final dims = measure(zone);
      final flow = toFlowSize(dims.w, dims.h);
      final followedByGroup =
          itemIndex + 1 < items.length && !items[itemIndex + 1].isZone;
      final zoneShrink = math.min(
        1,
        math.min(
          (spaceU * (followedByGroup ? 0.62 : 0.9)) / flow.uSize,
          (spaceV * 0.66) / flow.vSize,
        ),
      );
      final uSize = flow.uSize * zoneShrink;
      final vSize = flow.vSize * zoneShrink;
      final onlyZone = items.length == 1;
      final u = onlyZone
          ? (spaceU - uSize) / 2
          : followedByGroup
          ? 0
          : ownBandOnEndSide
          ? spaceU - uSize
          : 0;
      placements.add(
        _PosterPlacement(
          box: zone,
          u: u.toDouble(),
          v: vCursor,
          uSize: uSize,
          vSize: vSize,
          scale: dims.scale * globalScale * zoneShrink,
          vertical: dims.useVertical,
        ),
      );
      if (followedByGroup) {
        floats.add(
          (extent: uSize + chipGap, vBottom: vCursor + vSize + lineGap),
        );
      } else {
        vCursor += vSize + lineGap;
        ownBandOnEndSide = !ownBandOnEndSide;
      }
    }
    final vTotal = placements.fold(
      0.0,
      (max, p) => math.max(max, p.v + p.vSize),
    );
    return (placements: placements, vTotal: vTotal);
  }

  var result = attempt(1);
  for (final rung in [0.92, 0.84, 0.76, 0.68, 0.6, 0.52]) {
    if (result.vTotal <= spaceV + 0.5) break;
    result = attempt(rung);
  }
  if (result.vTotal > spaceV) {
    final fitScale = spaceV / result.vTotal;
    for (final p in result.placements) {
      p.u *= fitScale;
      p.v *= fitScale;
      p.uSize *= fitScale;
      p.vSize *= fitScale;
      p.scale *= fitScale;
    }
    result = (
      placements: result.placements,
      vTotal: spaceV,
    );
  }
  final vShift = math.max(0, (spaceV - result.vTotal) / 2);
  for (final p in result.placements) {
    final v = p.v + vShift;
    // Map the flow-space rect to screen coordinates. In the
    // vertical variant columns progress right-to-left.
    double cx, cy, w, h;
    if (orientation == 0) {
      cx = canvasLeft + p.u + p.uSize / 2;
      cy = canvasTop + v + p.vSize / 2;
      w = p.uSize;
      h = p.vSize;
    } else {
      cx = canvasLeft + canvasWidth - v - p.vSize;
      cy = canvasTop + p.u + p.uSize / 2;
      w = p.vSize;
      h = p.uSize;
    }
    final box = p.box;
    box.fontScale = p.scale;
    box.measuredWidth = w;
    box.measuredHeight = h;
    box.x = cx;
    box.y = cy;
    box.rotation = 0;
    box.vertical = p.vertical;
    box.layoutDirection = orientation == 1
        ? SonnetLayoutDirection.vertical
        : SonnetLayoutDirection.horizontal;
    if (orientation == 0) {
      box.enterX =
          (cx < 0 ? -1 : 1) *
          math.min(28, baseFontSize * 0.45);
      box.enterY = math.min(18, baseFontSize * 0.25);
    } else {
      box.enterX = math.min(18, baseFontSize * 0.25);
      box.enterY =
          (cy < 0 ? -1 : 1) *
          math.min(28, baseFontSize * 0.45);
    }
  }
}

class _PosterPlacement {
  _PosterPlacement({
    required this.box,
    required this.u,
    required this.v,
    required this.uSize,
    required this.vSize,
    required this.scale,
    required this.vertical,
  });

  final SonnetLayoutWord box;
  double u;
  double v;
  double uSize;
  double vSize;
  double scale;
  final bool vertical;
}

/// Giant decorative text (showGiantDecorativeText): hollow
/// oversized copies of the heroes, from
/// sonnetTypographyLayout.ts. Only for shots that are neither
/// quiet-tableau nor poster-blocks. Each decoration copies its
/// hero's word and timing; the stage renders it hollow at alpha
/// 0.2 (sonnetTextViewBuilder.ts).
class SonnetDecoration {
  const SonnetDecoration({
    required this.sourceIndex,
    required this.fontScale,
    required this.x,
    required this.y,
    required this.rotation,
    required this.enterX,
    required this.enterY,
  });

  /// Index of the hero word this decoration copies.
  final int sourceIndex;
  final double fontScale;
  final double x;
  final double y;
  final double rotation;
  final double enterX;
  final double enterY;
}

List<SonnetDecoration> sonnetDecorations({
  required List<SonnetLayoutWord> boxes,
  required double heroFontScale,
  required double width,
  required double height,
  required FoliaShotKind kind,
}) {
  if (kind == FoliaShotKind.tableau || kind == FoliaShotKind.poster) {
    return const [];
  }
  final heroes = boxes.where((box) => box.isHero).toList();
  final decorations = <SonnetDecoration>[];
  for (var idx = 0; idx < heroes.length; idx++) {
    final hero = heroes[idx];
    decorations.add(
      SonnetDecoration(
        sourceIndex: hero.index,
        fontScale: math.max(
          2.8,
          math.min(heroFontScale * 3.5, 5.5),
        ),
        x: hero.x - width * (0.1 - idx * 0.03),
        y: hero.y - height * (0.05 - idx * 0.02),
        rotation: -0.15 + (idx % 2 == 0 ? 0 : 0.05),
        enterX: -width * 0.05,
        enterY: -height * 0.05,
      ),
    );
  }
  if (boxes.length > 1 && heroes.isNotEmpty) {
    final last = boxes.last;
    final dec2 = last.isHero ? boxes.first : last;
    decorations.add(
      SonnetDecoration(
        sourceIndex: dec2.index,
        fontScale: math.max(
          1.8,
          math.min(heroFontScale * 2.2, 3.5),
        ),
        x: heroes.first.x + width * 0.25,
        y: heroes.first.y + height * 0.15,
        rotation: 0.08,
        enterX: width * 0.05,
        enterY: height * 0.05,
      ),
    );
  }
  return decorations;
}

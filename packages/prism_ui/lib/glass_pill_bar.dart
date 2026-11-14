import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/context.dart';
import 'package:prism_ui/liquid_glass.dart';
import 'package:prism_ui/navigation_dock.dart' show dockShadows;
import 'package:prism_ui/shape.dart';

/// The dock bar's own height, so every floating pill bar lines up with it.
const double kGlassPillBarHeight = 56;

/// A strip of equal segments shaped like the floating dock: one capsule shell
/// (glass when the scope allows it) around a single pill that springs between
/// the segments at the dock's own travel speed.
///
/// [segmentBuilder] builds each segment's content and receives the segment's
/// full box: the whole slot is tappable, not just the icon and label inside it.
class GlassPillBar extends StatefulWidget {
  const GlassPillBar({
    super.key,
    required this.count,
    required this.index,
    required this.segmentBuilder,
    this.height = kGlassPillBarHeight,
    this.inset = 5,
    this.pillGap = 4,
  }) : assert(count > 0, 'A pill bar needs at least one segment.');

  final int count;
  final int index;
  final Widget Function(BuildContext context, int index, bool selected)
  segmentBuilder;
  final double height;

  /// Room between the shell's edge and the segments.
  final double inset;

  /// Room between the sliding pill and its segment's box.
  final double pillGap;

  @override
  State<GlassPillBar> createState() => _GlassPillBarState();
}

class _GlassPillBarState extends State<GlassPillBar>
    with SingleTickerProviderStateMixin {
  /// The dock's own travel spring, so both surfaces move identically.
  static final SpringDescription _travel =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 260),
        bounce: 0.12,
      );

  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: widget.index.toDouble(),
  );

  @override
  void didUpdateWidget(covariant GlassPillBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    _position.animateWith(
      SpringSimulation(_travel, _position.value, widget.index.toDouble(), 0),
    );
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final dark = colorScheme.brightness == Brightness.dark;
    final glass = LiquidGlassScope.of(context);
    // Exactly the dock lens platter: the indicator must read as the same
    // material whether the glass shell is on or off.
    final pillColor = colorScheme.onSurface.withValues(
      alpha: dark ? 0.14 : 0.06,
    );
    final content = _content(context, pillColor);
    if (glass) {
      return LiquidGlass(
        style: LiquidGlassStyle.pill(colorScheme),
        shadows: dockShadows(colorScheme),
        child: content,
      );
    }
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.62),
        shape: AppShape.full,
        shadows: dockShadows(colorScheme),
      ),
      child: content,
    );
  }

  Widget _content(BuildContext context, Color pillColor) {
    return SizedBox(
      height: widget.height,
      child: Padding(
        padding: EdgeInsets.all(widget.inset),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final slot = constraints.maxWidth / widget.count;
            final gap = math.min(widget.pillGap, slot / 4);
            return Stack(
              children: [
                AnimatedBuilder(
                  animation: _position,
                  builder: (context, _) {
                    final position = _position.value.clamp(
                      0.0,
                      (widget.count - 1).toDouble(),
                    );
                    return Positioned(
                      left: position * slot + gap,
                      top: 0,
                      width: math.max(0, slot - gap * 2),
                      height: constraints.maxHeight,
                      child: ExcludeSemantics(
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: pillColor,
                            shape: AppShape.full,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    );
                  },
                ),
                Positioned.fill(
                  child: Row(
                    children: [
                      for (var i = 0; i < widget.count; i++)
                        Expanded(
                          // Tight constraints so the segment's own hit area
                          // spans the whole slot instead of hugging its glyphs.
                          child: SizedBox.expand(
                            child: widget.segmentBuilder(
                              context,
                              i,
                              i == widget.index,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

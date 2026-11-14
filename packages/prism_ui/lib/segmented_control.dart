import 'package:flutter/widgets.dart';
import 'package:prism_ui/card_surface.dart';
import 'package:prism_ui/context.dart';
import 'package:prism_ui/glass_pill_bar.dart';
import 'package:prism_ui/press_surface.dart';
import 'package:prism_ui/shape.dart';
import 'package:prism_ui/typography.dart';

class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
    this.iconBuilder,
  });

  static const double _height = kGlassPillBarHeight;
  static const double _inset = 5;

  final List<(T, String)> segments;
  final T value;
  final ValueChanged<T> onChanged;

  /// Optional leading glyph per segment; [selected] drives its color.
  final Widget Function(T option, bool selected)? iconBuilder;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final index = segments.indexWhere((segment) => segment.$1 == value);
    return GlassPillBar(
      count: segments.length,
      index: index < 0 ? 0 : index,
      height: _height,
      inset: _inset,
      segmentBuilder: (context, i, selected) {
        final (option, label) = segments[i];
        return PressSurface(
          fill: const Color(0x00000000),
          shape: AppShape.full,
          look: selected ? PressLook.none : PressLook.ink,
          ringStandsOff: selected,
          selected: selected,
          childFills: true,
          // A null onPressed would unfocus the selected segment.
          onPressed: selected ? () {} : () => onChanged(option),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (iconBuilder != null) ...[
                  iconBuilder!(option, selected),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    style: AppTextStyle.subheadline
                        .of(context, emphasized: selected)
                        .copyWith(
                          color: selected
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

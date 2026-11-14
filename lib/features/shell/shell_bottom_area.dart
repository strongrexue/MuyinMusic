import 'package:flutter/widgets.dart';

/// Navigation controls hover over content as a floating capsule dock.
/// Pages pad their scrollables so the last item can still scroll clear of it.
class ShellBottomArea extends InheritedWidget {
  const ShellBottomArea({
    super.key,
    required this.extent,
    required this.floatingExtent,
    required super.child,
  });

  /// Full height of the bottom controls (navigation bar plus player strip).
  /// Overlays such as FABs stack above this.
  final double extent;

  /// The part of [extent] that overlaps content instead of pushing it up.
  final double floatingExtent;

  static ShellBottomArea? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellBottomArea>();

  static double contentPadding(BuildContext context, double legacyPadding) {
    final area = maybeOf(context);
    if (area == null) return legacyPadding;
    return area.extent > 0 ? area.extent + 16 : legacyPadding;
  }

  /// Margins a scrollable keeps clear when it brings an item fully into view
  /// (e.g. the card a detail page collapses back into). Reads without
  /// subscribing, so it is safe in tap handlers.
  static EdgeInsets revealPaddingOf(BuildContext context) {
    final area = context.getInheritedWidgetOfExactType<ShellBottomArea>();
    return EdgeInsets.only(top: 8, bottom: (area?.floatingExtent ?? 0) + 8);
  }

  @override
  bool updateShouldNotify(ShellBottomArea oldWidget) =>
      extent != oldWidget.extent ||
      floatingExtent != oldWidget.floatingExtent;
}

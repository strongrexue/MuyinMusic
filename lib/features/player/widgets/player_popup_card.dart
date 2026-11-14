import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

/// Inset the card keeps between its edge and the rows inside, matching what
/// [prism.PopupMenu] uses for its own card.
const double _playerPopupCardInset = 8;

/// The surface a player entry's anchored popup draws its content on.
///
/// It is the same glass, fill, corner radius and shadow a [prism.PopupMenu]
/// card uses, sized for a short list of rows instead of a menu column. The
/// popup route already paints the glass behind the card while it morphs out of
/// the anchor, so the card layers its own fill on top rather than relying on
/// the route.
class PlayerPopupCard extends StatelessWidget {
  const PlayerPopupCard({
    super.key,
    required this.child,
    this.minWidth = 208,
    this.maxWidth = 304,
    this.maxHeight = 420,
    this.scrollable = true,
  });

  final Widget child;
  final double minWidth;
  final double maxWidth;
  final double maxHeight;

  /// Whether the card scrolls [child] itself. Turn it off when the child
  /// already owns a scrolling list, so the two do not fight over the drag.
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final colorScheme = prism.Theme.of(context).colorScheme;
    final borderRadius = prism.AppRadius.xl;
    final shadows = prism.menuShadows(colorScheme);
    final content = ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: minWidth,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ),
      // Surface.transparent, as prism.PopupMenuCard does, sets the card's
      // DefaultTextStyle. Without it, any plain TextStyle that inherits inside
      // the card falls back to the app's unstyled debug style — the yellow
      // double underline.
      child: prism.Surface.transparent(
        child: Padding(
          padding: const EdgeInsets.all(_playerPopupCardInset),
          child: scrollable
              ? SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: child,
                )
              : child,
        ),
      ),
    );
    final clipped = ClipRRect(borderRadius: borderRadius, child: content);
    if (!prism.LiquidGlassScope.of(context)) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: prism.SurfaceLevel.floatingOf(
            colorScheme,
          ).colorOf(colorScheme),
          borderRadius: borderRadius,
          boxShadow: shadows,
        ),
        child: clipped,
      );
    }
    return prism.LiquidGlass(
      style: prism.LiquidGlassStyle.menu(colorScheme),
      borderRadius: borderRadius,
      shadows: shadows,
      child: clipped,
    );
  }
}

/// A title (and optional explanation) at the top of a [PlayerPopupCard].
class PlayerPopupHeader extends StatelessWidget {
  const PlayerPopupHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colorScheme = prism.Theme.of(context).colorScheme;
    final subtitle = this.subtitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: prism.AppTextStyle.subheadline
                      .of(context, emphasized: true)
                      .copyWith(color: colorScheme.onSurface),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: prism.AppTextStyle.footnote
                        .of(context)
                        .copyWith(color: colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

/// One tappable line in a [PlayerPopupCard], sized like a [prism.PopupMenuItem]
/// row.
class PlayerPopupRow extends StatelessWidget {
  const PlayerPopupRow({
    super.key,
    required this.label,
    this.subtitle,
    this.leading,
    this.trailing,
    this.selected = false,
    this.onTap,
  });

  final String label;
  final String? subtitle;

  /// Drawn in the row's 20 px leading slot, as [prism.PopupMenuItem.leading]
  /// would be.
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = prism.Theme.of(context).colorScheme;
    final leading = this.leading;
    final trailing = this.trailing;
    final subtitle = this.subtitle;
    return prism.PressRegion(
      onTap: onTap,
      shape: prism.AppShape.md,
      overlay: prism.PressRegion.hoverOverlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            if (leading != null) ...[
              SizedBox.square(dimension: 20, child: Center(child: leading)),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: prism.AppTextStyle.subheadline
                        .of(context)
                        .copyWith(
                          fontSize: 14,
                          height: 20 / 14,
                          color: colorScheme.onSurface,
                        ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: prism.AppTextStyle.footnote
                          .of(context)
                          .copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing,
            ] else if (selected) ...[
              const SizedBox(width: 10),
              Icon(Icons.check_rounded, size: 18, color: colorScheme.primary),
            ],
          ],
        ),
      ),
    );
  }
}

/// A hairline between groups of rows inside a [PlayerPopupCard].
class PlayerPopupDivider extends StatelessWidget {
  const PlayerPopupDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = prism.Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 10),
      child: Container(
        height: 0.5,
        color: colorScheme.outlineVariant.withValues(alpha: 0.5),
      ),
    );
  }
}

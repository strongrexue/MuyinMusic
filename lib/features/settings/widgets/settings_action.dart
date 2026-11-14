import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:go_router/go_router.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/icons/icons.dart' as glyph;

import 'settings_style.dart';
import '../../../core/ui/widgets/settings_route_page.dart';

class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    this.title,
    required this.children,
    this.insetContent = false,
    this.separate,
  });

  final String? title;
  final List<Widget> children;
  final bool insetContent;

  /// 每行各占一张卡片。默认随 [insetContent] 走：整块内容的卡片不拆，逐行
  /// 动作的卡片拆开。
  final bool? separate;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (title != null && title!.isNotEmpty) prism.ListHeader(title: title!),
      SettingsGroup(
        separate: separate ?? !insetContent,
        children: insetContent
            ? [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ]
            : children.where((child) => child is! SizedBox).toList(),
      ),
    ],
  );
}

/// The section owns its corners, including rows with separate action buttons
/// and footers that do not paint a DecorationListItem background of their own.
///
/// [separate] breaks that one slab into one card per row, spaced apart: rows
/// no longer share a fill, so a list of actions reads as a list of entries.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.children,
    this.separate = false,
  });

  final List<Widget> children;
  final bool separate;

  static const _gap = 10.0;

  @override
  Widget build(BuildContext context) {
    final scheme = prism.Theme.of(context).colorScheme;
    final fill = prism.SurfaceLevel.card.colorOf(scheme);
    if (!separate || children.length < 2) {
      return _slab(fill, prism.generateGroup(children));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: _gap,
      children: [
        for (final child in children)
          // 行间隔（SizedBox / Divider）和按钮页脚本来就只是留白 / 附属操作，
          // 别给它们发一张和设置行一样的卡片。
          if (_isSpacer(child) || child is SettingsFooter)
            child
          else
            _slab(
              fill,
              prism.ItemPositionProvider(
                position: prism.ItemPosition.startAndEnd,
                child: child,
              ),
            ),
      ],
    );
  }

  static bool _isSpacer(Widget child) =>
      (child is SizedBox && child.child == null) || child is Divider;

  Widget _slab(Color fill, Widget child) => ClipRSuperellipse(
    borderRadius: prism.AppRadius.xl,
    child: ColoredBox(color: fill, child: child),
  );
}

/// Marks a child of a [SettingsGroup] as a footer: a button strip under the
/// rows. It never gets a card of its own, however the group is laid out.
class SettingsFooter extends StatelessWidget {
  const SettingsFooter({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

Widget _positionedRow(BuildContext context, Widget row) =>
    prism.ItemPositionProvider.of(context) != null
    ? row
    : prism.ItemPositionProvider(
        position: prism.ItemPosition.startAndEnd,
        child: row,
      );

class SettingsAction extends StatelessWidget {
  const SettingsAction({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle = '',
    this.onTap,
    this.destination,
    this.value,
    this.trailing,
    this.trailingWidget,
    this.interactionKey,
    this.onTapDown,
    this.showIcon = true,
  }) : assert(onTap != null || destination != null);

  final IconData icon;
  final String title;
  final String subtitle;
  final String? value;
  final VoidCallback? onTap;
  final String? destination;
  final IconData? trailing;
  final Widget? trailingWidget;
  final Key? interactionKey;
  final GestureTapDownCallback? onTapDown;
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget? tail =
        trailingWidget ??
        (trailing == null
            ? null
            : trailing == Icons.chevron_right ||
                  trailing == Icons.chevron_right_rounded ||
                  trailing == Symbols.chevron_right
            ? const glyph.GlyphIcon(glyph.Glyphs.chevronForward, size: 16)
            : Icon(trailing, size: 18, color: scheme.onSurfaceVariant));
    if (value case final value? when value.isNotEmpty) {
      tail = Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.3,
            ),
            child: Tooltip(
              message: value,
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
              ),
            ),
          ),
          ?tail,
        ],
      );
    }
    Widget row(VoidCallback? action) => prism.DecorationListItem(
      key: interactionKey,
      leading: showIcon ? SettingsSymbolBubble(icon: icon) : null,
      title: Text(title, maxLines: 2),
      horizontalTitleGap: 12,
      trailing: tail,
      onPressed: action,
    );
    if (destination case final location?) {
      final position =
          prism.ItemPositionProvider.of(context)?.position ??
          prism.ItemPosition.startAndEnd;
      return prism.OpenContainer<void>(
        transition: prism.OpenContainerTransition.zoom,
        clipBehavior: Clip.none,
        closedShape: prism.AppShape.of(prism.listItemRadiusOf(position)),
        closedBuilder: (_, open) =>
            prism.ItemPositionProvider(position: position, child: row(open)),
        // The destination is supplied by router.dart, the owner of page imports.
        onOpen: (createRoute) {
          // A native-tab tap can replace this route with `go('/settings')`
          // instead of popping it. Do not keep OpenContainer's opening lock
          // waiting for the push future, which only completes after a pop.
          unawaited(
            context.push<void>(
              location,
              extra: SettingsContainerOrigin(createRoute),
            ),
          );
        },
      );
    }
    return _positionedRow(context, row(onTap));
  }
}

class SettingsSwitchAction extends StatelessWidget {
  const SettingsSwitchAction({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle = '',
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _positionedRow(
    context,
    prism.DecorationListItem(
      leading: SettingsSymbolBubble(icon: icon),
      title: Text(title, maxLines: 2),
      horizontalTitleGap: 12,
      onPressed: () => onChanged(!value),
      trailing: prism.Switch(value: value, onChanged: onChanged),
    ),
  );
}

class DebugModeRow extends StatelessWidget {
  const DebugModeRow({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SettingsSwitchAction(
    icon: Icons.bug_report_outlined,
    title: '调试模式',
    value: value,
    onChanged: onChanged,
  );
}

import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/ui/app_sheet.dart';

// Settings and music screens share the same Prism sheet implementation.
typedef SettingsSheetLayout = AppSheetLayout;

Future<T?> showSettingsSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = true,
  bool showDragHandle = true,
  Color? backgroundColor,
  double heightFraction = 0.5,
  double maxHeight = 480,
  List<double>? detents,
  bool glass = false, // 透传给入口，各设置弹窗按需开启玻璃底板。
}) => showAppSheet<T>(
  context: context,
  builder: builder,
  useRootNavigator: useRootNavigator,
  showDragHandle: showDragHandle,
  backgroundColor: backgroundColor,
  heightFraction: heightFraction,
  maxHeight: maxHeight,
  detents: detents,
  glass: glass,
);

Future<T?> showSettingsDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = true,
  bool barrierDismissible = true,
}) => prism.showFloatingDialog<T>(
  context: useRootNavigator
      ? Navigator.of(context, rootNavigator: true).context
      : context,
  dismissible: barrierDismissible,
  child: Builder(builder: builder),
);

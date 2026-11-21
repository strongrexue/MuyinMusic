import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player_controller.dart';

/// Auto-hiding player chrome: while music plays, controls wrapped in
/// [ImmersiveFade] fade out after a few idle seconds; any touch brings
/// them back and restarts the countdown. Pausing keeps them visible.
class ImmersiveChrome extends ConsumerStatefulWidget {
  const ImmersiveChrome({super.key, required this.active, required this.child});

  /// Whether the player layer is the visible one; becoming active
  /// re-shows the chrome.
  final bool active;
  final Widget child;

  @override
  ConsumerState<ImmersiveChrome> createState() => _ImmersiveChromeState();
}

class _ImmersiveChromeState extends ConsumerState<ImmersiveChrome> {
  static const hideDelay = Duration(milliseconds: 3500);

  final _visible = ValueNotifier<bool>(true);
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    ref.listenManual(playerControllerProvider.select((s) => s.playing), (
      previous,
      next,
    ) {
      if (next) {
        _poke();
      } else {
        _hideTimer?.cancel();
        _visible.value = true;
      }
    });
    ref.listenManual(playerControllerProvider.select((s) => s.track?.id), (
      previous,
      next,
    ) {
      if (previous != next) _poke();
    });
    if (ref.read(playerControllerProvider).playing) _restartHideTimer();
  }

  @override
  void didUpdateWidget(ImmersiveChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _poke();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _visible.dispose();
    super.dispose();
  }

  void _poke() {
    _visible.value = true;
    _restartHideTimer();
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    if (!widget.active) return;
    if (!ref.read(playerControllerProvider).playing) return;
    _hideTimer = Timer(hideDelay, () => _visible.value = false);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _poke(),
      onPointerUp: (_) => _restartHideTimer(),
      child: ImmersiveChromeScope(visible: _visible, child: widget.child),
    );
  }
}

class ImmersiveChromeScope extends InheritedWidget {
  const ImmersiveChromeScope({
    super.key,
    required this.visible,
    required super.child,
  });

  final ValueListenable<bool> visible;

  static ValueListenable<bool>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ImmersiveChromeScope>()
      ?.visible;

  @override
  bool updateShouldNotify(ImmersiveChromeScope oldWidget) =>
      visible != oldWidget.visible;
}

/// Fades [child] out while the surrounding [ImmersiveChrome] is hidden,
/// and stops it from receiving touches then.
class ImmersiveFade extends StatelessWidget {
  const ImmersiveFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final visible = ImmersiveChromeScope.maybeOf(context);
    if (visible == null) return child;
    return ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (context, isVisible, child) => AnimatedOpacity(
        opacity: isVisible ? 1 : 0,
        duration: const Duration(milliseconds: 300),
        child: IgnorePointer(ignoring: !isVisible, child: child),
      ),
      child: child,
    );
  }
}

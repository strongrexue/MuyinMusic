import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Folia mode's immersive chrome visibility: the top bar and the
/// bottom transport bar. Entering folia mode hides the chrome so the
/// stage fills the whole screen; a tap on the stage toggles it, and
/// it auto-hides again after a few idle seconds while playing
/// (same 3.5s delay as the player page's immersive chrome). Pausing
/// keeps it visible.
///
/// This is separate from the page-level immersive chrome on purpose:
/// the page level listener shows chrome on every touch, but folia
/// needs a tap on the empty stage to *toggle* it, while taps on the
/// controls themselves must not hide them. KTV mode keeps its own
/// pinned chrome and never reads this provider.
///
/// The notifier is playing-aware through [syncPlaying] (called by
/// [FoliaStagePage], which owns the controller subscription); it
/// does not read the player controller itself, so it stays unit
/// testable on its own.
final foliaChromeProvider =
    NotifierProvider<FoliaChromeNotifier, bool>(FoliaChromeNotifier.new);

class FoliaChromeNotifier extends Notifier<bool> {
  static const hideDelay = Duration(milliseconds: 3500);

  Timer? _hideTimer;
  bool _playing = true;

  @override
  bool build() {
    // Hidden on entry: folia mode opens immersive (full-screen stage).
    ref.onDispose(() => _hideTimer?.cancel());
    return false;
  }

  /// Keep the auto-hide behaviour in step with playback: pausing
  /// shows the chrome and holds it; resuming restarts the countdown
  /// when the chrome is visible.
  void syncPlaying(bool playing) {
    _playing = playing;
    if (!playing) {
      _hideTimer?.cancel();
      if (!state) state = true;
    } else if (state) {
      _restartHideTimer();
    }
  }

  /// Show the chrome and restart the auto-hide countdown (held while
  /// paused).
  void show() {
    _hideTimer?.cancel();
    if (!state) state = true;
    _restartHideTimer();
  }

  /// Hide the chrome immediately.
  void hide() {
    _hideTimer?.cancel();
    if (state) state = false;
  }

  /// Tap on the empty stage: show when hidden, hide when shown.
  void toggle() {
    if (state) {
      hide();
    } else {
      show();
    }
  }

  /// Interaction with the chrome itself (a button, the slider):
  /// keep it visible and restart the countdown.
  void poke() {
    if (!state) return;
    _restartHideTimer();
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    if (!_playing) return;
    _hideTimer = Timer(hideDelay, () {
      state = false;
    });
  }
}

/// Fades [child] with the folia chrome state, and stops it from
/// receiving touches while hidden.
class FoliaChromeFade extends ConsumerWidget {
  const FoliaChromeFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(foliaChromeProvider);
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 300),
      child: IgnorePointer(ignoring: !visible, child: child),
    );
  }
}

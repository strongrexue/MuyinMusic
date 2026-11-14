import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/storage/settings_store.dart';
import '../player_controller.dart';
import 'player_palette.dart';

/// Height of the draggable track inside [PlayerVolumeCard].
const double _trackHeight = 132;

/// Opens the volume card just above [anchor] (the button that asked for it),
/// so a fader at the bottom of the player never runs off the screen.
Future<void> showVolumeCard(BuildContext context, {required Rect anchor}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '音量',
    barrierColor: Colors.black.withValues(alpha: 0.12),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (dialogContext, _, _) {
      final size = MediaQuery.sizeOf(dialogContext);
      return Stack(
        children: [
          Positioned(
            right: 14,
            bottom: size.height - anchor.top + 10,
            child: const PlayerVolumeCard(),
          ),
        ],
      );
    },
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
  );
}

/// The floating card opened from the action row's volume button: a single
/// vertical fader for the playback gain, draggable up and down.
class PlayerVolumeCard extends ConsumerWidget {
  const PlayerVolumeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = ref.watch(
      settingsProvider.select((settings) => settings.playerVolume),
    );
    final scheme = prism.Theme.of(context).colorScheme;
    final content = Material(
      color: Colors.transparent,
      child: SizedBox(
        width: 92,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                volume <= 0.001
                    ? Icons.volume_off_rounded
                    : volume < 0.5
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded,
                size: 20,
                color: playerInk(context),
              ),
              const SizedBox(height: 10),
              _VolumeFader(
                value: volume,
                onChanged: (next) => unawaited(
                  ref.read(playerControllerProvider.notifier).setPlaybackVolume(
                    next,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${(volume * 100).round()}%',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: playerInk(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!prism.LiquidGlassScope.of(context)) {
      return DecoratedBox(
        decoration: ShapeDecoration(
          color: scheme.surfaceContainerHigh,
          shape: prism.AppShape.lg,
          shadows: prism.dockShadows(scheme),
        ),
        child: content,
      );
    }
    return prism.LiquidGlass(
      style: prism.LiquidGlassStyle.pill(scheme),
      shadows: prism.dockShadows(scheme),
      child: content,
    );
  }
}

class _VolumeFader extends StatelessWidget {
  const _VolumeFader({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  void _report(BuildContext context, Offset localPosition) {
    final fraction = 1 - (localPosition.dy / _trackHeight);
    onChanged(fraction.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = prism.Theme.of(context).colorScheme;
    final active = playerInk(context);
    const thumb = 20.0;
    final clamped = value.clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _report(context, details.localPosition),
      onVerticalDragStart: (details) =>
          _report(context, details.localPosition),
      onVerticalDragUpdate: (details) =>
          _report(context, details.localPosition),
      child: SizedBox(
        width: 40,
        height: _trackHeight,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 10,
                height: _trackHeight,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.onSurface.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const SizedBox.expand(),
                    ),
                    FractionallySizedBox(
                      heightFactor: clamped,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: active,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: clamped * (_trackHeight - thumb),
              child: Container(
                width: thumb,
                height: thumb,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active,
                  boxShadow: [
                    BoxShadow(
                      color: active.withValues(alpha: 0.28),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

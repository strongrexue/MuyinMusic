import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../sleep_timer_controller.dart';
import 'player_popup_card.dart';

String formatSleepTimerRemaining(Duration duration) {
  final seconds = duration.isNegative ? 0 : duration.inSeconds;
  String two(int value) => value.toString().padLeft(2, '0');
  final minutes = seconds ~/ 60;
  final tail = two(seconds % 60);
  if (minutes < 60) return '${two(minutes)}:$tail';
  return '${minutes ~/ 60}:${two(minutes % 60)}:$tail';
}

/// The timer's quick presets as an anchored popup, so starting a common
/// duration never covers the player. Custom minutes expand an in-card
/// stepper — taps only, no keyboard.
class PlayerSleepTimerPopup extends ConsumerStatefulWidget {
  const PlayerSleepTimerPopup({super.key});

  static const _presets = [15, 30, 45, 60, 90];

  @override
  ConsumerState<PlayerSleepTimerPopup> createState() =>
      _PlayerSleepTimerPopupState();
}

class _PlayerSleepTimerPopupState
    extends ConsumerState<PlayerSleepTimerPopup> {
  static const _minMinutes = 1;
  static const _maxMinutes = 180;
  static const _stepMinutes = 5;

  bool _customOpen = false;
  int _customMinutes = 30;

  void _adjust(int delta) {
    setState(() {
      _customMinutes = (_customMinutes + delta).clamp(
        _minMinutes,
        _maxMinutes,
      );
    });
  }

  void _startCustom() {
    ref.read(sleepTimerProvider.notifier).start(
      Duration(minutes: _customMinutes),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = ref.watch(sleepTimerProvider);
    final timer = ref.read(sleepTimerProvider.notifier);
    return PlayerPopupCard(
      key: const ValueKey('player-sleep-timer-popup'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PlayerPopupHeader(
            title: '定时关闭音乐',
            subtitle: remaining == null
                ? '到时自动暂停播放'
                : '距离暂停 ${formatSleepTimerRemaining(remaining)}',
          ),
          for (final preset in PlayerSleepTimerPopup._presets)
            PlayerPopupRow(
              key: ValueKey('player-sleep-timer-preset-$preset'),
              label: '$preset 分钟',
              onTap: () {
                timer.start(Duration(minutes: preset));
                Navigator.of(context).pop();
              },
            ),
          if (!_customOpen)
            PlayerPopupRow(
              key: const ValueKey('player-sleep-timer-custom-entry'),
              label: '自定义…',
              leading: const Icon(Icons.edit_outlined, size: 18),
              onTap: () => setState(() => _customOpen = true),
            )
          else ...[
            const PlayerPopupDivider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '自定义时长',
                      style: prism.AppTextStyle.footnote
                          .of(context)
                          .copyWith(
                            color: prism.Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  _StepButton(
                    key: const ValueKey('player-sleep-timer-minus'),
                    icon: Icons.remove_rounded,
                    onPressed: _customMinutes > _minMinutes
                        ? () => _adjust(-_stepMinutes)
                        : null,
                  ),
                  SizedBox(width: 88, child: _StepperValue(minutes: _customMinutes)),
                  _StepButton(
                    key: const ValueKey('player-sleep-timer-plus'),
                    icon: Icons.add_rounded,
                    onPressed: _customMinutes < _maxMinutes
                        ? () => _adjust(_stepMinutes)
                        : null,
                  ),
                ],
              ),
            ),
            PlayerPopupRow(
              key: const ValueKey('player-sleep-timer-custom-start'),
              label: '开启定时',
              leading: const Icon(Icons.timer_outlined, size: 18),
              onTap: _startCustom,
            ),
          ],
          if (remaining != null) ...[
            const PlayerPopupDivider(),
            PlayerPopupRow(
              key: const ValueKey('player-sleep-timer-cancel-entry'),
              label: '取消定时',
              leading: const Icon(Icons.timer_off_outlined, size: 18),
              onTap: () {
                timer.cancel();
                Navigator.of(context).pop();
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// The minutes readout inside the popup's stepper. Cycles through tens so the
/// value stays scannable while ± steps round to the nearest 5.
class _StepperValue extends StatelessWidget {
  const _StepperValue({required this.minutes});

  final int minutes;

  @override
  Widget build(BuildContext context) {
    final colorScheme = prism.Theme.of(context).colorScheme;
    return Semantics(
      key: const ValueKey('player-sleep-timer-custom-value'),
      value: '$minutes',
      child: Text(
        '$minutes 分钟',
        textAlign: TextAlign.center,
        style: prism.AppTextStyle.subheadline
            .of(context, emphasized: true)
            .copyWith(fontSize: 15, color: colorScheme.onSurface),
      ),
    );
  }
}

/// A ± button for the popup stepper, dimmed while disabled.
class _StepButton extends StatelessWidget {
  const _StepButton({super.key, required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = prism.Theme.of(context).colorScheme;
    return prism.IconButton(
      onPressed: onPressed,
      style: prism.ButtonStyle.from(
        fixedSize: const Size.square(34),
        shape: const CircleBorder(),
        backgroundColor: colorScheme.surfaceContainerHighest,
      ),
      icon: Icon(
        icon,
        size: 18,
        color: onPressed == null
            ? colorScheme.onSurface.withValues(alpha: 0.3)
            : colorScheme.onSurface,
      ),
    );
  }
}

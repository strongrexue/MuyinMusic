import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../player/widgets/player_popup_card.dart';
import '../equalizer_store.dart';

/// The equalizer's on/off switch and its presets as an anchored popup hanging
/// off the player's equalizer button, with the page kept one tap away.
class PlayerEqualizerPopup extends ConsumerWidget {
  const PlayerEqualizerPopup({super.key, required this.onOpenPage});

  /// Opens the full equalizer page, where the bands themselves are adjusted.
  final VoidCallback onOpenPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(equalizerProvider);
    final notifier = ref.read(equalizerProvider.notifier);
    final colorScheme = prism.Theme.of(context).colorScheme;
    return PlayerPopupCard(
      key: const ValueKey('player-equalizer-popup'),
      scrollable: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PlayerPopupHeader(
            title: '均衡器',
            subtitle: settings.summary,
            trailing: prism.Switch(
              key: const ValueKey('player-equalizer-switch'),
              value: settings.enabled,
              semanticLabel: '启用均衡器',
              onChanged: notifier.setEnabled,
            ),
          ),
          const PlayerPopupDivider(),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 288),
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final preset in equalizerPresets)
                      PlayerPopupRow(
                        key: ValueKey('player-equalizer-preset-${preset.id}'),
                        label: preset.label,
                        selected: preset.id == settings.presetId,
                        onTap: () => notifier.applyPreset(preset),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const PlayerPopupDivider(),
          PlayerPopupRow(
            key: const ValueKey('player-equalizer-open-page'),
            label: '打开均衡器',
            leading: Icon(
              Icons.tune_rounded,
              size: 18,
              color: colorScheme.onSurface,
            ),
            onTap: () {
              Navigator.of(context).pop();
              onOpenPage();
            },
          ),
        ],
      ),
    );
  }
}

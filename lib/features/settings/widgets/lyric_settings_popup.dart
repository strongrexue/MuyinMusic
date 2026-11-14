import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/storage/settings_store.dart';
import '../../player/widgets/player_popup_card.dart';
import 'lyric_font_controls.dart';

/// Lyric display settings as an anchored glass card hanging off the player's
/// lyric-settings button, so the controls stay next to the entry that opened
/// them instead of sliding up as a bottom sheet.
class LyricSettingsPopup extends ConsumerWidget {
  const LyricSettingsPopup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(
      settingsProvider.select(
        (settings) => (
          miniLyrics: settings.showMiniLyrics,
          blurDisabled: settings.lyricViewBlurDisabled,
          weight: settings.lyricFontWeight,
          size: settings.lyricFontSize,
        ),
      ),
    );
    final notifier = ref.read(settingsProvider.notifier);
    final weight = normalizeLyricFontWeight(options.weight);
    final size = normalizeLyricFontSize(options.size);
    final isDefault =
        weight == kLyricFontWeightDefault && size == kLyricFontSizeDefault;

    return PlayerPopupCard(
      key: const ValueKey('lyric-settings-popup'),
      maxWidth: 320,
      maxHeight: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PlayerPopupHeader(
            title: '歌词界面设置',
            subtitle: '调整歌词的显示样式',
            trailing: prism.TextButton.icon(
              onPressed: isDefault
                  ? null
                  : () => unawaited(
                      notifier.setLyricFontStyle(
                        weight: kLyricFontWeightDefault,
                        size: kLyricFontSizeDefault,
                      ),
                    ),
              icon: const Icon(Icons.restart_alt_rounded, size: 16),
              label: const Text('重置'),
            ),
          ),
          PlayerPopupRow(
            label: '迷你歌词',
            selected: options.miniLyrics,
            onTap: () => unawaited(
              notifier.setShowMiniLyrics(!options.miniLyrics),
            ),
          ),
          PlayerPopupRow(
            label: '关闭歌词视图模糊',
            selected: options.blurDisabled,
            onTap: () => unawaited(
              notifier.setLyricViewBlurDisabled(!options.blurDisabled),
            ),
          ),
          const PlayerPopupDivider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
            child: LyricStyleControl(
              icon: Icons.format_bold_rounded,
              label: '字体粗细',
              value: weight,
              min: kLyricFontWeightMin,
              max: kLyricFontWeightMax,
              step: 100,
              onChanged: (value) => unawaited(
                notifier.setLyricFontStyle(weight: value, size: size),
              ),
            ),
          ),
          const PlayerPopupDivider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 12),
            child: LyricStyleControl(
              icon: Icons.format_size_rounded,
              label: '字体大小',
              value: size,
              min: kLyricFontSizeMin,
              max: kLyricFontSizeMax,
              step: 1,
              onChanged: (value) => unawaited(
                notifier.setLyricFontStyle(weight: weight, size: value),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

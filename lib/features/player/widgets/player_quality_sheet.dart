import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/enums.dart';
import '../../../core/models/music_info.dart';
import '../../../core/ui/widgets/quality_option_tile.dart';
import '../player_controller.dart';
import 'player_popup_card.dart';

List<QualityOption> availablePlaybackQualityOptions(PlayerTrack track) {
  final parsedCurrent = Quality.tryFromCode(track.qualityLabel);
  final allOptions = track.availableQualityOptions.isEmpty
      ? [
          for (final quality
              in track.availableQualities.isEmpty
                  ? [?parsedCurrent]
                  : track.availableQualities)
            QualityOption(type: quality),
        ]
      : track.availableQualityOptions;
  // Source-declared qualities remain selectable even when catalogue sizes are
  // absent. Size is optional metadata, not proof of source support.
  return allOptions;
}

String playerQualityLabel(PlayerTrack track) {
  final quality = Quality.tryFromCode(track.qualityLabel);
  return switch (quality) {
    Quality.atmosPlus => 'Atmos+',
    Quality.flac24bit => '24-bit FLAC',
    null => track.qualityLabel,
    _ => qualityName(quality),
  };
}

/// Compact quality tag for tight spots like the player top bar, where the full
/// [playerQualityLabel] wording would crowd out the track title.
String playerQualityShortLabel(PlayerTrack track) {
  final quality = Quality.tryFromCode(track.qualityLabel);
  return switch (quality) {
    Quality.master => 'Master',
    Quality.atmosPlus => 'Atmos+',
    Quality.atmos => 'Atmos',
    Quality.hires => 'Hi-Res',
    Quality.flac24bit => '24bit',
    Quality.flac => 'FLAC',
    Quality.k320 => '320K',
    Quality.k192 => '192K',
    Quality.k128 => '128K',
    null => track.qualityLabel,
    _ => qualityName(quality),
  };
}

/// The quality list as an anchored popup hanging off the top bar's source ·
/// quality entry, so switching quality no longer covers the player.
class PlaybackQualityPopup extends ConsumerWidget {
  const PlaybackQualityPopup({super.key, required this.track});

  final PlayerTrack track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = availablePlaybackQualityOptions(track);
    final current = Quality.tryFromCode(track.qualityLabel);
    return PlayerPopupCard(
      key: const ValueKey('player-quality-popup'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PlayerPopupHeader(title: '播放音质', subtitle: '切换后保留当前播放进度'),
          for (final option in options)
            PlayerPopupRow(
              key: ValueKey('player-quality-option-${option.type.code}'),
              label: qualityName(option.type),
              subtitle: _knownQualitySize(option),
              selected: option.type == current,
              onTap: () => _select(context, ref, option.type),
            ),
        ],
      ),
    );
  }

  /// Applies [quality] once the popup has closed. The controller and container
  /// are read up front because dismissing the route disposes this widget, and
  /// the track is re-checked so a tap cannot change the quality of a song that
  /// started playing in the meantime.
  void _select(BuildContext context, WidgetRef ref, Quality quality) {
    final container = ProviderScope.containerOf(context, listen: false);
    final controller = ref.read(playerControllerProvider.notifier);
    Navigator.of(context).pop();
    unawaited(() async {
      if (!controller.mounted) return;
      if (container.read(playerControllerProvider).track?.id != track.id) {
        return;
      }
      await controller.switchQuality(quality);
    }());
  }
}

String? _knownQualitySize(QualityOption option) {
  final size = option.size?.trim();
  return size == null || size.isEmpty ? null : size;
}

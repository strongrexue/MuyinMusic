import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/ui/app_toast.dart';
import '../../../theme/app_motion.dart';
import '../../playlists/playlist_models.dart';
import '../../songs/liked_songs_store.dart';
import '../player_controller.dart';
import 'playback_queue_sheet.dart';
import 'player_palette.dart';
import 'player_control_color.dart';
import 'player_layout.dart';
import 'player_slider_thumb_shape.dart';
import 'player_volume_card.dart';

enum _TransportPart { full, progress, controls }

class TransportBar extends ConsumerStatefulWidget {
  const TransportBar({super.key, this.compact = false})
    : _part = _TransportPart.full;

  /// Only the progress line (current time, slider, total time in one
  /// slim row) for the phone-landscape layout's merged bottom stack.
  const TransportBar.progressLine({super.key})
    : compact = false,
      _part = _TransportPart.progress;

  /// Only the transport button cluster (mode, previous, play, next,
  /// queue) at its intrinsic width, for the phone-landscape layout's
  /// merged control row.
  const TransportBar.controlsRow({super.key})
    : compact = false,
      _part = _TransportPart.controls;

  /// Single-row overlay layout for the KTV landscape layout: transport
  /// buttons on the left, the progress slider filling the middle and
  /// the mode / queue buttons on the right, all in one slim row.
  final bool compact;

  final _TransportPart _part;

  @override
  ConsumerState<TransportBar> createState() => _TransportBarState();
}

class _TransportBarState extends ConsumerState<TransportBar> {
  /// 拖动和等待 seek 时保留目标进度，松手只提交一次。
  double? _dragMs;
  Object? _interactionToken;
  String? _trackId;

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(
      playerControllerProvider.select(
        (s) => (
          position: s.position,
          duration: s.duration,
          playing: s.playing,
          loading: s.loading,
          buffering: s.buffering,
          ended: s.processingState == PlayerProcessingState.completed,
          hasTrack: s.track != null,
          trackId: s.track?.id,
          playbackMode: s.playbackMode,
          queueCount: s.queue.isEmpty
              ? (s.track == null ? 0 : 1)
              : s.queue.length,
        ),
      ),
    );
    if (_trackId != vm.trackId) {
      _trackId = vm.trackId;
      _dragMs = null;
      _interactionToken = null;
    }
    final controller = ref.read(playerControllerProvider.notifier);
    final maxMs = math.max(1, vm.duration.inMilliseconds);
    final shownMs = (_dragMs ?? vm.position.inMilliseconds.toDouble()).clamp(
      0.0,
      maxMs.toDouble(),
    );
    final canControl = vm.hasTrack && !vm.loading;
    // Like state for the compact (KTV) bar's heart button, derived the
    // same way as the player action row: the queue entry when there is
    // one, otherwise an entry synthesized from the current music.
    final queueEntry = ref.watch(
      playerControllerProvider.select(
        (s) => s.queueIndex >= 0 && s.queueIndex < s.queue.length
            ? s.queue[s.queueIndex]
            : null,
      ),
    );
    final currentMusic = ref
        .read(playerControllerProvider.notifier)
        .currentMusic;
    final likeEntry =
        queueEntry ??
        (currentMusic == null
            ? null
            : PlaylistTrack.fromMusicInfo(
                currentMusic,
              ).toQueueEntry(playlistId: 'player'));
    final likeKey = likeEntry == null ? null : songIdentityKey(likeEntry);
    final liked =
        likeKey != null &&
        ref.watch(
          likedSongsProvider.select(
            (items) => items.any((row) => songIdentityKey(row) == likeKey),
          ),
        );
    return PlayerControlColor(
      builder: (context, ink) {
        final controlColor = canControl ? ink : ink.withValues(alpha: 0.22);
        final indicatorTextColor =
            ThemeData.estimateBrightnessForColor(ink) == Brightness.dark
            ? Colors.white
            : Colors.black;
        Widget slider(double height, EdgeInsetsGeometry sliderPadding) {
          return SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: widget.compact ? 3 : 4,
              trackShape: const RoundedRectSliderTrackShape(),
              activeTrackColor: ink,
              inactiveTrackColor: ink.withValues(alpha: 0.22),
              thumbColor: ink,
              overlayColor: ink.withValues(alpha: 0.10),
              thumbShape: PlayerSliderThumbShape(
                disableAnimations: MediaQuery.disableAnimationsOf(context),
              ),
              overlayShape: RoundSliderOverlayShape(
                overlayRadius: widget.compact ? 10 : 14,
              ),
              showValueIndicator: ShowValueIndicator.onDrag,
              valueIndicatorShape:
                  const RoundedRectSliderValueIndicatorShape(),
              valueIndicatorColor: ink,
              valueIndicatorTextStyle: TextStyle(
                color: indicatorTextColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: SizedBox(
              height: height,
              child: Slider(
                key: ValueKey(vm.trackId),
                padding: sliderPadding,
                value: shownMs,
                max: maxMs.toDouble(),
                label: _formatDuration(
                  Duration(milliseconds: shownMs.round()),
                ),
                semanticFormatterCallback: (value) =>
                    _formatDuration(Duration(milliseconds: value.round())),
                onChangeStart: canControl
                    ? (value) => setState(() {
                        _interactionToken = Object();
                        _dragMs = value;
                      })
                    : null,
                onChanged: canControl
                    ? (value) => setState(() => _dragMs = value)
                    : null,
                onChangeEnd: canControl
                    ? (value) async {
                        final token = _interactionToken;
                        try {
                          await controller.seek(
                            Duration(milliseconds: value.round()),
                          );
                        } finally {
                          // 旧 seek 结束不能清掉换曲或后一次拖动的状态。
                          if (mounted && identical(_interactionToken, token)) {
                            setState(() {
                              _dragMs = null;
                              _interactionToken = null;
                            });
                          }
                        }
                      }
                    : null,
              ),
            ),
          );
        }

        if (widget.compact) {
          // Keep the end buttons clear of a side notch in landscape.
          final viewPadding = MediaQuery.paddingOf(context);
          return Padding(
            padding: EdgeInsets.fromLTRB(
              math.max(16.0, viewPadding.left),
              2,
              math.max(16.0, viewPadding.right),
              8,
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: '上一首',
                  onPressed: canControl ? controller.playPrevious : null,
                  style: IconButton.styleFrom(
                    fixedSize: const Size.square(48),
                  ),
                  icon: Icon(
                    Icons.skip_previous_rounded,
                    color: controlColor,
                    size: 32,
                  ),
                ),
                _PlayButton(
                  color: ink,
                  playing: vm.playing,
                  showSpinner: vm.loading || vm.buffering,
                  ended: vm.ended,
                  canControl: canControl,
                  controller: controller,
                  compact: true,
                ),
                IconButton(
                  tooltip: '下一首',
                  onPressed: canControl ? controller.playNext : null,
                  style: IconButton.styleFrom(
                    fixedSize: const Size.square(48),
                  ),
                  icon: Icon(
                    Icons.skip_next_rounded,
                    color: controlColor,
                    size: 32,
                  ),
                ),
                IconButton(
                  tooltip: liked ? '取消喜欢' : '喜欢',
                  onPressed: likeEntry == null
                      ? null
                      : () {
                          final nowLiked = ref
                              .read(likedSongsProvider.notifier)
                              .toggle(likeEntry);
                          showAppToast(
                            context,
                            nowLiked ? '已加入我的喜欢' : '已取消喜欢',
                            type: AppToastType.success,
                          );
                        },
                  style: IconButton.styleFrom(
                    fixedSize: const Size.square(48),
                  ),
                  icon: Icon(
                    liked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    size: 27,
                    color: likeEntry == null
                        ? ink.withValues(alpha: 0.22)
                        : liked
                        ? const Color(0xFFFF6382)
                        : ink,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: slider(56, EdgeInsets.zero),
                  ),
                ),
                _PlaybackModeButton(
                  color: ink,
                  mode: vm.playbackMode,
                  enabled: vm.hasTrack,
                  onPressed: controller.cyclePlaybackMode,
                  compact: true,
                ),
                prism.PopupAnchor(
                  placement: prism.PopupPlacement.screenLowerTwoThirds,
                  targetBuilder: (open) => PlaybackQueueButton(
                    color: ink,
                    count: vm.queueCount,
                    enabled: vm.hasTrack,
                    onPressed: open,
                  ),
                  popupBuilder: (_) => const PlaybackQueuePopup(),
                ),
                _VolumeButton(color: ink),
              ],
            ),
          );
        }
        final buttons = <Widget>[
          _PlaybackModeButton(
            color: ink,
            mode: vm.playbackMode,
            enabled: vm.hasTrack,
            onPressed: controller.cyclePlaybackMode,
          ),
          IconButton(
            tooltip: '上一首',
            onPressed: canControl ? controller.playPrevious : null,
            icon: Icon(
              Icons.skip_previous_rounded,
              color: controlColor,
              size: 38,
            ),
          ),
          _PlayButton(
            color: ink,
            playing: vm.playing,
            showSpinner: vm.loading || vm.buffering,
            ended: vm.ended,
            canControl: canControl,
            controller: controller,
          ),
          IconButton(
            tooltip: '下一首',
            onPressed: canControl ? controller.playNext : null,
            icon: Icon(
              Icons.skip_next_rounded,
              color: controlColor,
              size: 38,
            ),
          ),
          prism.PopupAnchor(
            placement: prism.PopupPlacement.screenLowerTwoThirds,
            targetBuilder: (open) => PlaybackQueueButton(
              color: ink,
              count: vm.queueCount,
              enabled: vm.hasTrack,
              onPressed: open,
            ),
            popupBuilder: (_) => const PlaybackQueuePopup(),
          ),
        ];
        if (widget._part == _TransportPart.progress) {
          // Phone landscape: one slim line, times flanking the slider
          // instead of a separate row underneath it.
          final slimTimeStyle = _timeStyle(context).copyWith(fontSize: 13);
          return Row(
            children: [
              Text(
                _formatDuration(Duration(milliseconds: shownMs.round())),
                style: slimTimeStyle,
              ),
              Expanded(
                child: slider(24, const EdgeInsets.symmetric(horizontal: 8)),
              ),
              Text(_formatDuration(vm.duration), style: slimTimeStyle),
            ],
          );
        }
        if (widget._part == _TransportPart.controls) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < buttons.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                buttons[i],
              ],
            ],
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              slider(
                28,
                const EdgeInsets.symmetric(
                  horizontal: playerProgressTrackInset,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: playerProgressTrackInset,
                ),
                child: Row(
                  children: [
                    Text(
                      _formatDuration(Duration(milliseconds: shownMs.round())),
                      style: _timeStyle(context),
                    ),
                    const Spacer(),
                    Text(
                      _formatDuration(vm.duration),
                      style: _timeStyle(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: buttons,
              ),
            ],
          ),
        );
      },
    );
  }

  TextStyle _timeStyle(BuildContext context) {
    return TextStyle(
      color: playerMuted(context),
      fontSize: 15,
      fontWeight: FontWeight.w500,
    );
  }

  String _formatDuration(Duration value) {
    final safe = value.isNegative ? Duration.zero : value;
    final hours = safe.inHours;
    final minutes = safe.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = safe.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

/// Volume entry for the compact (KTV) bar: opens the same anchored
/// [PlayerVolumeCard] as the portrait action row's volume button, sized
/// to this bar's 48dp button tier.
class _VolumeButton extends StatefulWidget {
  const _VolumeButton({required this.color});

  final Color color;

  @override
  State<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<_VolumeButton> {
  final _targetKey = GlobalKey();

  void _open() {
    final box = _targetKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    unawaited(showVolumeCard(context, anchor: origin & box.size));
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _targetKey,
      child: IconButton(
        tooltip: '音量',
        onPressed: _open,
        style: IconButton.styleFrom(fixedSize: const Size.square(48)),
        icon: Icon(Icons.volume_up_outlined, size: 26, color: widget.color),
      ),
    );
  }
}

class _PlaybackModeButton extends StatelessWidget {
  const _PlaybackModeButton({
    required this.color,
    required this.mode,
    required this.enabled,
    required this.onPressed,
    this.compact = false,
  });

  final PlayerPlaybackMode mode;
  final Color color;
  final bool enabled;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final iconColor = enabled ? color : playerMuted(context);
    return IconButton(
      tooltip: mode.label,
      onPressed: enabled ? onPressed : null,
      style: IconButton.styleFrom(fixedSize: const Size.square(48)),
      icon: AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppMotion.medium,
        switchInCurve: AppMotion.emphasizedDecelerate,
        switchOutCurve: AppMotion.emphasizedAccelerate,
        transitionBuilder: (child, animation) {
          final turns = Tween<double>(begin: -0.08, end: 0).animate(animation);
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.82, end: 1).animate(animation),
              child: RotationTransition(turns: turns, child: child),
            ),
          );
        },
        child: Icon(
          _playbackModeIcon(mode),
          key: ValueKey(mode),
          color: iconColor,
          size: compact ? 24 : 25,
        ),
      ),
    );
  }
}

IconData _playbackModeIcon(PlayerPlaybackMode mode) {
  return switch (mode) {
    PlayerPlaybackMode.sequence => Icons.format_list_numbered_rounded,
    PlayerPlaybackMode.shuffle => Icons.shuffle_rounded,
    PlayerPlaybackMode.repeatOne => Icons.repeat_one_rounded,
  };
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.color,
    required this.playing,
    required this.showSpinner,
    required this.ended,
    required this.canControl,
    required this.controller,
    this.compact = false,
  });

  final bool playing;
  final Color color;
  final bool showSpinner;
  final bool ended;
  final bool canControl;
  final PlayerController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: canControl
            ? (ended ? controller.replay : controller.toggle)
            : null,
        child: SizedBox(
          width: compact ? 56 : 72,
          height: compact ? 56 : 72,
          child: Center(
            child: showSpinner
                ? SizedBox.square(
                    dimension: compact ? 20 : 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: color,
                    ),
                  )
                : Icon(
                    ended
                        ? Icons.replay_rounded
                        : playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: compact ? 44 : 56,
                    color: canControl ? color : color.withValues(alpha: 0.22),
                  ),
          ),
        ),
      ),
    );
  }
}

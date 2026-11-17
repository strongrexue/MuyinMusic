import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/storage/settings_store.dart';
import '../../../theme/app_motion.dart';
import '../../player/lyric_parser.dart';
import '../../player/player_controller.dart';
import '../../player/widgets/spinning_cover_art.dart';
import '../player_transition.dart';

/// Playback contents shared by the legacy toolbar pager and native navigation's
/// independent floating player. The parent owns navigation and drag gestures.
class MiniPlayerBar extends ConsumerWidget {
  const MiniPlayerBar({
    super.key,
    required this.width,
    required this.height,
    required this.onOpenPlayer,
    this.large = false,
  });

  final double width;
  final double height;
  final VoidCallback onOpenPlayer;
  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final vm = ref.watch(
      playerControllerProvider.select(
        (s) {
          final lyricIndex = s.lyricLoading || s.lyrics.isEmpty
              ? -1
              : s.lyrics.activeIndex(s.position);
          return (
            track: s.track,
            playing: s.playing,
            loading: s.loading,
            buffering: s.buffering,
            ended: s.processingState == PlayerProcessingState.completed,
            canPrev: s.canPlayPrevious,
            canNext: s.canPlayNext,
            // 只投影当前行对象：同一行内 position 高频更新时行对象引用
            // 不变，record 相等，迷你条不会重建；逐字染色由歌词 widget
            // 自己 watch position，避免拖动整个迷你条。
            lyricLine: lyricIndex >= 0 ? s.lyrics.lines[lyricIndex] : null,
          );
        },
      ),
    );
    final square = ref.watch(
      settingsProvider.select((settings) => settings.squareAlbumCoverEnabled),
    );
    final showMiniLyrics = ref.watch(
      settingsProvider.select((settings) => settings.showMiniLyrics),
    );
    final controller = ref.read(playerControllerProvider.notifier);
    final track = vm.track;
    final canControl = track != null && !vm.loading;
    // Narrow capsules (small screens at min action width) drop the artist
    // line and shrink the artwork/buttons so everything still fits.
    // Shorter capsules scale the artwork and buttons down so they keep an
    // even inset inside the pill.
    final compact = width < 240;
    final coverSlotSize = math.min(
      compact ? 36.0 : (large ? 44.0 : 40.0),
      height - 8,
    );
    final coverSize = coverSlotSize * (square ? 0.82 : 1.0);
    final buttonSize = math.min(
      compact ? 36.0 : (large ? 42.0 : 40.0),
      height - 6,
    );
    // Square artwork needs more leading space than circular artwork.
    final leadingMargin = square ? 15.0 : (large ? 7.0 : 5.0);
    final trailingMargin = (height - buttonSize) / 2;

    return Row(
      children: [
        SizedBox(width: leadingMargin),
        Expanded(
          child: Tooltip(
            message: '打开播放页',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onOpenPlayer,
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: coverSlotSize,
                    child: Center(
                      // Measure the artwork itself as the flight endpoint;
                      // the outer slot only preserves the text's alignment.
                      child: PlayerCoverAnchor(
                        expanded: false,
                        child: SizedBox.square(
                          dimension: coverSize,
                          child: track == null
                              ? _IdleCover(scheme: scheme, size: coverSize)
                              : SpinningCoverArt(
                                  track: track,
                                  size: coverSize,
                                  placeholder: ColoredBox(
                                    color: scheme.surfaceContainerHighest,
                                    child: Center(
                                      child: Icon(
                                        Icons.album_rounded,
                                        size: 20,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _TrackLabels(
                      track: track,
                      compact: compact,
                      scheme: scheme,
                      large: large,
                      lyricLine: showMiniLyrics ? vm.lyricLine : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        _MiniControlButton(
          tooltip: '上一首',
          icon: Icons.skip_previous_rounded,
          size: buttonSize,
          iconSize: large ? 26 : 24,
          onPressed: canControl && vm.canPrev ? controller.playPrevious : null,
        ),
        _MiniPlayButton(
          playing: vm.playing,
          showSpinner: vm.loading || vm.buffering,
          ended: vm.ended,
          canControl: canControl,
          controller: controller,
          size: buttonSize,
          iconSize: large ? 28 : 26,
        ),
        _MiniControlButton(
          tooltip: '下一首',
          icon: Icons.skip_next_rounded,
          size: buttonSize,
          iconSize: large ? 26 : 24,
          onPressed: canControl && vm.canNext ? controller.playNext : null,
        ),
        SizedBox(width: trailingMargin),
      ],
    );
  }
}

class _IdleCover extends ConsumerWidget {
  const _IdleCover({required this.scheme, required this.size});

  final ColorScheme scheme;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final square = ref.watch(
      settingsProvider.select((settings) => settings.squareAlbumCoverEnabled),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: square ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: square
            ? BorderRadius.circular(size * kSquareCoverRadiusFactor)
            : null,
        color: scheme.surfaceContainerHighest,
      ),
      child: Center(
        child: Icon(
          Icons.album_rounded,
          size: 20,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _TrackLabels extends StatelessWidget {
  const _TrackLabels({
    required this.track,
    required this.compact,
    required this.scheme,
    required this.large,
    required this.lyricLine,
  });

  final PlayerTrack? track;
  final bool compact;
  final ColorScheme scheme;
  final bool large;
  final KaraokeLyricLine? lyricLine;

  @override
  Widget build(BuildContext context) {
    final track = this.track;
    if (track == null) {
      return Text(
        '暂无播放',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
          fontSize: large ? 14.5 : 14,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    final artist = track.artist.trim();
    // 副标题行优先显示当前歌词；无歌词（开关关闭 / lyricLoading /
    // 无有效行）时回退到歌手。compact 下歌手本就隐藏，歌词独占该行，
    // 整体始终最多两行，不增加迷你条高度。
    final lyricLine = this.lyricLine;
    final hasLyric = lyricLine != null && lyricLine.words.isNotEmpty;
    final subtitle = hasLyric ? lyricLine.text : (compact ? '' : artist);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: large ? 14.5 : 14,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        if (subtitle.isNotEmpty) ...[
          SizedBox(height: large ? 2 : 1),
          if (hasLyric)
            _MiniKaraokeText(
              line: lyricLine,
              base: scheme.onSurfaceVariant,
              accent: scheme.primary,
              fontSize: large ? 12 : 11.5,
            )
          else
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: large ? 12 : 11.5,
                fontWeight: FontWeight.w500,
                height: 1.2,
              ),
            ),
        ],
      ],
    );
  }
}

/// 迷你条逐字歌词：已唱字用系统强调色，未唱字保持原色。
/// 自己 watch position，只重建这一行，不触发整个迷你条高频重建。
class _MiniKaraokeText extends ConsumerWidget {
  const _MiniKaraokeText({
    required this.line,
    required this.base,
    required this.accent,
    required this.fontSize,
  });

  final KaraokeLyricLine line;
  final Color base;
  final Color accent;
  final double fontSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positionMs = ref.watch(
      playerControllerProvider.select((s) => s.position.inMilliseconds),
    );
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      height: 1.2,
    );
    final spans = <TextSpan>[];
    for (final word in line.words) {
      final sung = positionMs >= word.endMs;
      spans.add(
        TextSpan(
          text: word.text,
          style: style.copyWith(color: sung ? accent : base),
        ),
      );
    }
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(children: spans, style: style.copyWith(color: base)),
    );
  }
}

class _MiniControlButton extends StatelessWidget {
  const _MiniControlButton({
    required this.tooltip,
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final double size;
  final double iconSize;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      icon: Icon(
        icon,
        size: iconSize,
        color: scheme.onSurfaceVariant.withValues(alpha: enabled ? 1 : 0.35),
      ),
    );
  }
}

class _MiniPlayButton extends StatelessWidget {
  const _MiniPlayButton({
    required this.playing,
    required this.showSpinner,
    required this.ended,
    required this.canControl,
    required this.controller,
    required this.size,
    required this.iconSize,
  });

  final bool playing;
  final bool showSpinner;
  final bool ended;
  final bool canControl;
  final PlayerController controller;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.onPrimaryContainer.withValues(
      alpha: canControl ? 1 : 0.35,
    );
    final Widget glyph;
    if (showSpinner) {
      glyph = SizedBox.square(
        key: const ValueKey('mini-play:spinner'),
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2.4, color: color),
      );
    } else {
      final icon = ended
          ? Icons.replay_rounded
          : playing
          ? Icons.pause_rounded
          : Icons.play_arrow_rounded;
      glyph = Icon(
        icon,
        key: ValueKey('mini-play:${icon.codePoint}'),
        size: iconSize,
        color: color,
      );
    }
    return IconButton.filledTonal(
      tooltip: ended
          ? '重播'
          : playing
          ? '暂停'
          : '播放',
      onPressed: canControl
          ? (ended ? controller.replay : controller.toggle)
          : null,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      style: IconButton.styleFrom(
        backgroundColor: scheme.primaryContainer,
        disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.05),
        shape: const CircleBorder(),
        minimumSize: Size.square(size),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppMotion.medium,
        switchInCurve: AppMotion.emphasizedDecelerate,
        switchOutCurve: AppMotion.emphasizedAccelerate,
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.82, end: 1).animate(animation),
              child: child,
            ),
          );
        },
        child: glyph,
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/icons/icons.dart' as prism_glyph;
import '../../../core/ui/music_action_glyphs.dart';
import '../../../theme/app_motion.dart';
import '../../downloads/download_progress.dart';
import '../../downloads/widgets/download_task_chip.dart';
import '../../songs/liked_songs_store.dart';
import '../resolved_playlist_track.dart';
import 'playlist_artwork.dart';

const double _trackCoverSize = 52;
const double _trackRowMinHeight = 68;
const double _trackCoverRadius = 10;

/// Inline download action for a playlist row: shows progress while busy and a
/// disabled tick once the track is already on disk.
class _TrackDownloadButton extends StatelessWidget {
  const _TrackDownloadButton({
    super.key,
    required this.task,
    required this.downloaded,
    required this.onPressed,
  });

  final DownloadTask? task;
  final bool downloaded;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final busy = task?.isBusy ?? false;
    final done = downloaded || task?.stage == DownloadStage.done;
    final paused = task?.isPaused ?? false;
    if ((busy || paused) && task != null) {
      return DownloadTaskChip(
        task: task!,
        dimension: 44,
        progressSize: 20,
        color: paused ? scheme.tertiary : scheme.primary,
      );
    }
    return prism.IconButton(
      tooltip: done ? '已下载' : '下载',
      style: prism.ButtonStyle.from(fixedSize: const Size.square(44)),
      onPressed: done ? null : onPressed,
      icon: prism_glyph.GlyphIcon(
        done ? MusicActionGlyphs.downloaded : MusicActionGlyphs.download,
        size: 21,
        color: done
            ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
            : scheme.onSurfaceVariant,
      ),
    );
  }
}

class PlaylistTrackTile extends ConsumerWidget {
  const PlaylistTrackTile({
    super.key,
    required this.playlistId,
    required this.index,
    required this.item,
    required this.playing,
    required this.batchMode,
    required this.batchSubmitting,
    required this.selected,
    required this.onToggleSelected,
    required this.onPlay,
    required this.onDownload,
    required this.onAddNext,
    required this.onRemove,
  });

  final String playlistId;
  final int index;
  final ResolvedPlaylistTrack item;
  final bool playing;
  final bool batchMode;
  final bool batchSubmitting;
  final bool selected;
  final VoidCallback onToggleSelected;
  final VoidCallback onPlay;
  final VoidCallback? onDownload;
  final VoidCallback? onAddNext;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final music = item.track.musicInfo;
    final task = music == null
        ? null
        : ref.watch(
            downloadProgressProvider.select(
              (value) => value.latestTaskForMusic(music.id),
            ),
          );
    final isLocal = item.localEntry != null;
    final likeEntry = item.queueEntry;
    final likeKey = likeEntry == null ? null : songIdentityKey(likeEntry);
    final liked =
        likeKey != null &&
        ref.watch(
          likedSongsProvider.select(
            (items) => items.any((row) => songIdentityKey(row) == likeKey),
          ),
        );
    final selectionEnabled = !batchSubmitting && task?.isBusy != true;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final shortDuration = reduceMotion ? Duration.zero : AppMotion.short;
    final mediumDuration = reduceMotion ? Duration.zero : AppMotion.medium;

    final backgroundColor = batchMode && selected
        ? scheme.primaryContainer.withValues(alpha: 0.56)
        : playing
        ? scheme.primaryContainer.withValues(alpha: 0.2)
        : Colors.transparent;
    final titleColor = batchMode && selected
        ? scheme.onPrimaryContainer
        : playing
        ? scheme.primary
        : scheme.onSurface;
    final supportingColor = batchMode && selected
        ? scheme.onPrimaryContainer.withValues(alpha: 0.8)
        : playing
        ? scheme.primary.withValues(alpha: 0.86)
        : scheme.onSurfaceVariant;

    return AnimatedContainer(
      duration: shortDuration,
      curve: AppMotion.emphasized,
      constraints: const BoxConstraints(minHeight: _trackRowMinHeight),
      color: backgroundColor,
      child: Material(
        color: Colors.transparent,
        child: Semantics(
          button: true,
          selected: batchMode && selected,
          hint: batchMode ? '轻触选择歌曲' : '轻触播放',
          child: InkWell(
            onTap: batchMode
                ? (selectionEnabled ? onToggleSelected : null)
                : onPlay,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 2, 8),
              child: Row(
                children: [
                  ResolvingPlaylistTrackArtwork(
                    playlistId: playlistId,
                    track: item.track,
                    size: _trackCoverSize,
                    radius: _trackCoverRadius,
                    placeholder: Container(
                      width: _trackCoverSize,
                      height: _trackCoverSize,
                      color: scheme.secondaryContainer,
                      alignment: Alignment.center,
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          color: scheme.onSecondaryContainer,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (playing) ...[
                              Icon(
                                Icons.graphic_eq_rounded,
                                size: 16,
                                color: scheme.primary,
                              ),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                item.track.name.trim().isEmpty
                                    ? '未知歌曲'
                                    : item.track.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: titleColor,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  height: 1.1,
                                  letterSpacing: 0,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            item.track.singer.trim().isEmpty
                                ? '未知歌手'
                                : item.track.singer,
                            isLocal ? '本地' : item.track.source.label,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: supportingColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            height: 1.08,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedSize(
                    duration: mediumDuration,
                    curve: AppMotion.emphasized,
                    alignment: Alignment.centerRight,
                    child: AnimatedSwitcher(
                      duration: mediumDuration,
                      switchInCurve: AppMotion.emphasizedDecelerate,
                      switchOutCurve: AppMotion.emphasizedAccelerate,
                      transitionBuilder: (child, animation) {
                        final offset = Tween<Offset>(
                          begin: const Offset(0.18, 0),
                          end: Offset.zero,
                        ).animate(animation);
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: offset,
                            child: child,
                          ),
                        );
                      },
                      child: batchMode
                          ? SizedBox.square(
                              key: const ValueKey('playlist-select-action'),
                              dimension: 48,
                              child: Center(
                                child: prism.Checkbox(
                                  value: selected,
                                  isCircle: true,
                                  onChanged: selectionEnabled
                                      ? (_) => onToggleSelected()
                                      : null,
                                ),
                              ),
                            )
                          : Row(
                              key: const ValueKey('playlist-row-actions'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                prism.IconButton(
                                  key: ValueKey(
                                    'playlist-like-${item.track.id}',
                                  ),
                                  tooltip: liked ? '取消喜欢' : '喜欢',
                                  style: prism.ButtonStyle.from(
                                    fixedSize: const Size.square(44),
                                  ),
                                  onPressed: likeEntry == null
                                      ? null
                                      : () => ref
                                            .read(likedSongsProvider.notifier)
                                            .toggle(likeEntry),
                                  icon: Icon(
                                    liked
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    size: 22,
                                    color: liked
                                        ? scheme.primary
                                        : supportingColor,
                                  ),
                                ),
                                _TrackDownloadButton(
                                  key: ValueKey(
                                    'playlist-download-${item.track.id}',
                                  ),
                                  task: task,
                                  downloaded: isLocal,
                                  onPressed: onDownload,
                                ),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

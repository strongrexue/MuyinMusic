import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/icons/icons.dart' as prism_glyph;

import '../../../core/models/music_info.dart';
import '../../../core/ui/app_toast.dart';
import '../../../core/ui/music_action_glyphs.dart';
import '../../downloads/download_history_store.dart';
import '../../downloads/download_progress.dart';
import '../../downloads/widgets/download_task_chip.dart';
import '../../playlists/playlist_models.dart';
import '../../playlists/playlist_store.dart';
import '../../playlists/widgets/playlist_add_popup.dart';
import '../../search/widgets/quality_picker_sheet.dart';
import '../../settings/widgets/lyric_settings_popup.dart';
import '../../songs/liked_songs_store.dart';
import '../player_controller.dart';
import 'player_layout.dart';
import 'player_palette.dart';
import 'player_volume_card.dart';

/// Height the action row reserves above the transport bar.
const double playerActionRowExtent = 48;

/// The tap target and glyph metrics shared with the transport bar's own
/// buttons: a 48dp target around a 25–27dp glyph.
const double _playerActionTargetSize = 48;
const double _playerActionGlyphSize = 26;

enum _ActionSection { all, leading, trailing }

/// A single row of round actions above the transport bar: lyric settings,
/// add to playlist, download, like and volume.
///
/// The phone-landscape layout uses the [PlayerActionRow.leading] /
/// [PlayerActionRow.trailing] sections instead: the same buttons at the
/// same size, as the outer segments of its single merged control row.
/// Every other layout uses the default full row, unchanged.
class PlayerActionRow extends ConsumerWidget {
  const PlayerActionRow({super.key}) : _section = _ActionSection.all;

  /// The first three actions (lyric settings, add to playlist,
  /// download), spaced on the landscape control-row pitch.
  const PlayerActionRow.leading({super.key})
    : _section = _ActionSection.leading;

  /// The last two actions (like, volume), spaced on the landscape
  /// control-row pitch.
  const PlayerActionRow.trailing({super.key})
    : _section = _ActionSection.trailing;

  final _ActionSection _section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(
      playerControllerProvider.select((state) => state.track),
    );
    final music = ref.read(playerControllerProvider.notifier).currentMusic;
    final task = music == null
        ? null
        : ref.watch(
            downloadProgressProvider.select(
              (progress) => progress.latestTaskForMusic(music.id),
            ),
          );
    final downloaded =
        music != null &&
        ref
            .watch(downloadHistoryProvider)
            .any((entry) => entry.musicId == music.id && entry.isCompleted);
    final canUseMusic = !(track?.isLocal ?? true) && music != null;
    final disabledReason = track?.isLocal ?? true ? '仅在线歌曲' : '暂无歌曲信息';
    final queueEntry = ref.watch(
      playerControllerProvider.select(
        (state) =>
            state.queueIndex >= 0 && state.queueIndex < state.queue.length
            ? state.queue[state.queueIndex]
            : null,
      ),
    );
    final likeEntry =
        queueEntry ??
        (music == null
            ? null
            : PlaylistTrack.fromMusicInfo(
                music,
              ).toQueueEntry(playlistId: 'player'));
    final likeKey = likeEntry == null ? null : songIdentityKey(likeEntry);
    final liked =
        likeKey != null &&
        ref.watch(
          likedSongsProvider.select(
            (items) => items.any((row) => songIdentityKey(row) == likeKey),
          ),
        );

    final targetSize = _playerActionTargetSize;
    final glyphSize = _playerActionGlyphSize;
    final actions = <Widget>[
      prism.PopupAnchor(
        targetBuilder: (open) => _PlayerActionButton(
          key: const ValueKey('player-action-lyric-settings'),
          tooltip: '歌词界面设置',
          glyph: MusicActionGlyphs.lyrics,
          onPressed: open,
          targetSize: targetSize,
          glyphSize: glyphSize,
        ),
        popupBuilder: (_) => const LyricSettingsPopup(),
      ),
      prism.PopupAnchor(
        targetBuilder: (open) => _PlayerActionButton(
          key: const ValueKey('player-action-playlist'),
          tooltip: canUseMusic ? '添加到歌单' : disabledReason,
          glyph: MusicActionGlyphs.playlistAdd,
          onPressed: canUseMusic ? open : null,
          targetSize: targetSize,
          glyphSize: glyphSize,
        ),
        popupBuilder: (_) => PlaylistAddPopup(
          onPicked: (playlist) {
            final target = music;
            // The popup's own context dies with its route, so the
            // toast is reported against the action row's context,
            // which resolves to the app-wide toast overlay.
            if (target != null) {
              unawaited(
                _addMusicToPlaylist(context, ref, target, playlist),
              );
            }
          },
        ),
      ),
      _DownloadActionButton(
        key: const ValueKey('player-action-download'),
        task: task,
        downloaded: downloaded,
        enabled: canUseMusic,
        disabledReason: disabledReason,
        targetSize: targetSize,
        glyphSize: glyphSize,
        onPressed: !canUseMusic
            ? null
            : () => unawaited(
                showQualityPickerSheet(context, music, asSheet: true),
              ),
      ),
      KeyedSubtree(
        key: const ValueKey('player-action-like'),
        child: prism.IconButton(
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
          style: prism.ButtonStyle.from(fixedSize: Size.square(targetSize)),
          icon: Icon(
            liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            size: glyphSize,
            color: likeEntry == null
                ? playerMuted(context).withValues(alpha: 0.45)
                : liked
                ? const Color(0xFFFF6382)
                : playerInk(context),
          ),
        ),
      ),
      _VolumeActionButton(targetSize: targetSize, glyphSize: glyphSize),
    ];

    return switch (_section) {
      _ActionSection.all => SizedBox(
        height: playerActionRowExtent,
        child: Center(
          child: ConstrainedBox(
            // Matches the transport bar under it, so the outer buttons line up.
            constraints: const BoxConstraints(
              maxWidth: playerWideTransportMaxWidth,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: actions,
            ),
          ),
        ),
      ),
      _ActionSection.leading => Row(
        mainAxisSize: MainAxisSize.min,
        children: _onLandscapePitch(actions.sublist(0, 3)),
      ),
      _ActionSection.trailing => Row(
        mainAxisSize: MainAxisSize.min,
        children: _onLandscapePitch(actions.sublist(3)),
      ),
    };
  }
}

/// Interleaves [buttons] with the landscape control-row gap so their
/// centres land on the shared pitch (see player_layout.dart).
List<Widget> _onLandscapePitch(List<Widget> buttons) {
  return [
    for (var i = 0; i < buttons.length; i++) ...[
      if (i > 0) const SizedBox(width: playerLandscapeControlGap),
      buttons[i],
    ],
  ];
}

/// Adds [music] to the playlist chosen in [PlaylistAddPopup], reporting the
/// outcome with a toast. Mirrors what the bottom-sheet picker used to do,
/// minus the sheet.
Future<void> _addMusicToPlaylist(
  BuildContext context,
  WidgetRef ref,
  MusicInfo music,
  LocalPlaylist playlist,
) async {
  final store = ref.read(localPlaylistsProvider.notifier);
  if (store.byId(playlist.id) == null) {
    if (!context.mounted) return;
    showAppToast(context, '歌单不存在或已被删除', type: AppToastType.warning);
    return;
  }

  try {
    final added = await store.addMusic(playlist.id, music);
    if (!context.mounted) return;
    showAppToast(
      context,
      added == 0 ? '歌曲已在「${playlist.name}」中' : '已添加到「${playlist.name}」',
      type: added == 0 ? AppToastType.info : AppToastType.success,
    );
  } catch (error) {
    if (!context.mounted) return;
    showAppToast(context, '添加到歌单失败：$error', type: AppToastType.error);
  }
}

class _VolumeActionButton extends StatefulWidget {
  const _VolumeActionButton({
    this.targetSize = _playerActionTargetSize,
    this.glyphSize = _playerActionGlyphSize,
  });

  final double targetSize;
  final double glyphSize;

  @override
  State<_VolumeActionButton> createState() => _VolumeActionButtonState();
}

class _VolumeActionButtonState extends State<_VolumeActionButton> {
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
      key: const ValueKey('player-action-volume'),
      child: KeyedSubtree(
        key: _targetKey,
        child: prism.IconButton(
          tooltip: '音量',
          onPressed: _open,
          style: prism.ButtonStyle.from(
            fixedSize: Size.square(widget.targetSize),
          ),
          icon: Icon(
            Icons.volume_up_outlined,
            size: widget.glyphSize,
            color: playerInk(context),
          ),
        ),
      ),
    );
  }
}

class _DownloadActionButton extends StatelessWidget {
  const _DownloadActionButton({
    super.key,
    required this.task,
    required this.downloaded,
    required this.enabled,
    required this.disabledReason,
    required this.onPressed,
    this.targetSize = _playerActionTargetSize,
    this.glyphSize = _playerActionGlyphSize,
  });

  final DownloadTask? task;
  final bool downloaded;
  final bool enabled;
  final String disabledReason;
  final VoidCallback? onPressed;
  final double targetSize;
  final double glyphSize;

  @override
  Widget build(BuildContext context) {
    final busy = task?.isBusy ?? false;
    final paused = task?.isPaused ?? false;
    final done = downloaded || task?.stage == DownloadStage.done;
    final fraction = task?.fraction;
    final tooltip = done
        ? '已下载'
        : busy
        ? fraction == null
              ? '正在下载'
              : '正在下载 ${(fraction * 100).round()}%'
        : enabled
        ? '下载'
        : disabledReason;

    if ((busy || paused) && task != null) {
      return DownloadTaskChip(
        task: task!,
        dimension: targetSize,
        progressSize: glyphSize,
        color: playerInk(context),
      );
    }
    return _PlayerActionButton(
      tooltip: tooltip,
      glyph: done ? MusicActionGlyphs.downloaded : MusicActionGlyphs.download,
      onPressed: done ? null : onPressed,
      forceDisabledLook: done,
      targetSize: targetSize,
      glyphSize: glyphSize,
    );
  }
}

class _PlayerActionButton extends StatelessWidget {
  const _PlayerActionButton({
    super.key,
    required this.tooltip,
    required this.glyph,
    required this.onPressed,
    this.forceDisabledLook = false,
    this.targetSize = _playerActionTargetSize,
    this.glyphSize = _playerActionGlyphSize,
  });

  final String tooltip;
  final prism_glyph.Glyph glyph;
  final VoidCallback? onPressed;
  final bool forceDisabledLook;
  final double targetSize;
  final double glyphSize;

  @override
  Widget build(BuildContext context) {
    final disabled = forceDisabledLook || onPressed == null;
    final color = disabled
        ? playerMuted(context).withValues(alpha: 0.45)
        : playerInk(context);
    return prism.IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: prism.ButtonStyle.from(
        fixedSize: Size.square(targetSize),
        iconSize: glyphSize,
      ),
      icon: prism_glyph.GlyphIcon(
        glyph,
        size: glyphSize,
        color: color,
      ),
    );
  }
}

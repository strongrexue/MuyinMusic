import 'package:flutter/material.dart';
import 'package:prism_ui/icons/icons.dart' as prism_glyph;
import 'package:prism_ui/icons/prism_glyphs.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/ui/music_action_glyphs.dart';
import '../../downloads/download_progress.dart';

/// The action sets used by local songs, saved playlists and online results.
class SongActionsMenu extends StatelessWidget {
  const SongActionsMenu._({super.key, required this.items});

  factory SongActionsMenu.local({
    Key? key,
    required VoidCallback onDelete,
    required VoidCallback onAddToPlaylist,
    required VoidCallback onAddNext,
    VoidCallback? onToggleLike,
    bool liked = false,
  }) => SongActionsMenu._(
    key: key,
    items: [
      if (onToggleLike != null) _like(liked, onToggleLike),
      prism.PopupMenuItem(
        label: '删除',
        glyph: MusicActionGlyphs.trash,
        executeImmediately: true,
        onPressed: onDelete,
        danger: true,
      ),
      _addToPlaylist(onAddToPlaylist),
      _addNext(onAddNext, label: '下一首播放'),
    ],
  );

  factory SongActionsMenu.playlist({
    Key? key,
    required VoidCallback onRemove,
    required VoidCallback? onAddNext,
    required VoidCallback? onDownload,
    DownloadTask? downloadTask,
    bool downloaded = false,
    VoidCallback? onToggleLike,
    bool liked = false,
    VoidCallback? onPauseDownload,
    VoidCallback? onResumeDownload,
    VoidCallback? onCancelDownload,
  }) => SongActionsMenu._(
    key: key,
    items: [
      if (onToggleLike != null) _like(liked, onToggleLike),
      prism.PopupMenuItem(
        label: '移出歌单',
        glyph: MusicActionGlyphs.playlistRemove,
        executeImmediately: true,
        onPressed: onRemove,
        danger: true,
      ),
      _addNext(onAddNext),
      _download(
        onDownload,
        downloadTask,
        downloaded: downloaded,
        onPause: onPauseDownload,
        onResume: onResumeDownload,
        onCancel: onCancelDownload,
      ),
    ],
  );

  factory SongActionsMenu.online({
    Key? key,
    required VoidCallback onDownload,
    required VoidCallback onAddToPlaylist,
    DownloadTask? downloadTask,
    VoidCallback? onToggleLike,
    bool liked = false,
    VoidCallback? onPauseDownload,
    VoidCallback? onResumeDownload,
    VoidCallback? onCancelDownload,
  }) => SongActionsMenu._(
    key: key,
    items: [
      if (onToggleLike != null) _like(liked, onToggleLike),
      _download(
        onDownload,
        downloadTask,
        onPause: onPauseDownload,
        onResume: onResumeDownload,
        onCancel: onCancelDownload,
      ),
      _addToPlaylist(onAddToPlaylist),
    ],
  );

  final List<prism.PopupMenuItem> items;

  static prism.PopupMenuItem _like(bool liked, VoidCallback onPressed) =>
      prism.PopupMenuItem(
        label: liked ? '取消喜欢' : '喜欢',
        glyph: AppGlyphs.star,
        executeImmediately: true,
        onPressed: onPressed,
      );

  static prism.PopupMenuItem _addToPlaylist(VoidCallback? onPressed) =>
      prism.PopupMenuItem(
        label: '添加到歌单',
        glyph: MusicActionGlyphs.playlistAdd,
        executeImmediately: true,
        onPressed: onPressed,
      );

  static prism.PopupMenuItem _addNext(
    VoidCallback? onPressed, {
    String label = '添加到下一首播放',
  }) => prism.PopupMenuItem(
    label: label,
    glyph: MusicActionGlyphs.playNext,
    executeImmediately: true,
    onPressed: onPressed,
  );

  /// A running transfer turns this entry into a submenu, so a download started
  /// from a list can be paused or dropped without visiting the downloads page.
  static prism.PopupMenuItem _download(
    VoidCallback? onPressed,
    DownloadTask? task, {
    bool downloaded = false,
    VoidCallback? onPause,
    VoidCallback? onResume,
    VoidCallback? onCancel,
  }) {
    final busy = task?.isBusy ?? false;
    final paused = task?.isPaused ?? false;
    final done = downloaded || task?.stage == DownloadStage.done;
    final fraction = task?.fraction;
    final active = task != null && (busy || paused) && !done;
    final progressLabel = fraction == null
        ? '正在下载'
        : '正在下载 ${(fraction * 100).round()}%';

    if (active) {
      return prism.PopupMenuItem(
        label: paused ? '已暂停' : progressLabel,
        glyph: paused ? MusicActionGlyphs.pause : MusicActionGlyphs.download,
        subItems: [
          prism.PopupMenuItem(
            label: paused ? '继续下载' : '暂停下载',
            executeImmediately: true,
            onPressed: paused ? onResume : onPause,
          ),
          prism.PopupMenuItem(
            label: '取消下载',
            executeImmediately: true,
            danger: true,
            onPressed: onCancel,
          ),
        ],
      );
    }

    return prism.PopupMenuItem(
      label: done
          ? '已下载'
          : busy
          ? progressLabel
          : '下载',
      glyph: done ? MusicActionGlyphs.downloaded : MusicActionGlyphs.download,
      executeImmediately: true,
      onPressed: busy || done ? null : onPressed,
    );
  }

  @override
  Widget build(BuildContext context) => prism.PopupAnchor(
    targetBuilder: (open) => prism.IconButton(
      tooltip: '歌曲操作',
      onPressed: open,
      icon: const prism_glyph.GlyphIcon(AppGlyphs.more),
    ),
    popupBuilder: (_) => prism.PopupMenu(items: items),
  );
}
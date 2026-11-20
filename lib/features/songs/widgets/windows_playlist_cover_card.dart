import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/icons/icons.dart' as glyph;
import 'package:prism_ui/icons/prism_glyphs.dart' as prism_glyphs;

import '../../../core/models/enums.dart';
import '../../playlists/playlist_models.dart';
import '../../playlists/widgets/playlist_artwork.dart';

/// Windows 歌曲 tab 歌单页专用封面卡。
///
/// 用封面网格替代手机端的单行 tile；排序改为右上角菜单里的上移/下移，
/// 其余交互（打开、取消收藏、更新、批量选择）与 [PlaylistLibraryTile] 一致。
/// 手机端不构建本 widget，零改动。
class WindowsPlaylistCoverCard extends StatelessWidget {
  const WindowsPlaylistCoverCard({
    super.key,
    required this.playlist,
    required this.index,
    required this.total,
    required this.batchMode,
    required this.selected,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onOpen,
    required this.onUnfavorite,
    required this.onToggleSelected,
    this.onUpdate,
    this.updating = false,
    this.onMoveUp,
    this.onMoveDown,
    this.aspectRatio = 1.0,
  });

  final LocalPlaylist playlist;
  final int index;
  final int total;
  final bool batchMode;
  final bool selected;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onOpen;
  final VoidCallback onUnfavorite;
  final VoidCallback onToggleSelected;
  final VoidCallback? onUpdate;
  final bool updating;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final importedSource = MusicSource.fromCode(
      playlist.originSourceCode ?? '',
    );
    final meta = playlist.isOnlineImport
        ? '${importedSource.label}导入 · ${playlist.tracks.length} 首'
        : '${playlist.tracks.length} 首歌曲';
    // 批量态完全不显示菜单；搜索态由调用方把 onMoveUp/onMoveDown 置空。
    final hasMenu =
        !batchMode &&
        (onUpdate != null || onMoveUp != null || onMoveDown != null);

    return LayoutBuilder(
      builder: (context, constraints) {
        final coverSize = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 220.0;
        final placeholder = SizedBox.expand(
          child: Container(
            color: scheme.secondaryContainer,
            alignment: Alignment.center,
            child: Icon(
              playlist.isOnlineImport
                  ? Icons.cloud_done_outlined
                  : Icons.music_note_rounded,
              color: scheme.onSecondaryContainer,
              size: 48,
            ),
          ),
        );

        return prism.Card(
          radius: 18,
          padding: EdgeInsets.zero,
          isSelected: batchMode && selected,
          onPressed: batchMode ? onToggleSelected : onOpen,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AspectRatio(
                  aspectRatio: aspectRatio,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PlaylistCover(
                        playlist: playlist,
                        size: coverSize,
                        radius: 0,
                        placeholder: placeholder,
                      ),
                      if (batchMode)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: _BatchBadge(selected: selected),
                        )
                      else ...[
                        Positioned(
                          top: 6,
                          left: 6,
                          child: _UnfavoriteBadge(
                            playlistId: playlist.id,
                            onPressed: onUnfavorite,
                          ),
                        ),
                        if (hasMenu)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: _OptionsMenu(
                              canMoveUp: canMoveUp,
                              canMoveDown: canMoveDown,
                              onMoveUp: onMoveUp,
                              onMoveDown: onMoveDown,
                              onUpdate: onUpdate,
                              updating: updating,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: prism.AppTextStyle.subheadline.of(
                          context,
                          emphasized: true,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: prism.AppTextStyle.caption1.of(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 右上角选项菜单：更新入口 + 上移/下移（方案 A 排序）。
class _OptionsMenu extends StatelessWidget {
  const _OptionsMenu({
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onUpdate,
    required this.updating,
  });

  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onUpdate;
  final bool updating;

  @override
  Widget build(BuildContext context) {
    return prism.PopupAnchor(
      targetBuilder: (open) => prism.IconButton(
        tooltip: '歌单选项',
        style: prism.ButtonStyle.from(
          fixedSize: const Size.square(32),
          tapTargetSize: prism.TapTargetSize.shrinkWrap,
          padding: EdgeInsets.zero,
          backgroundColor: Colors.black.withValues(alpha: 0.30),
        ),
        onPressed: open,
        icon: const glyph.GlyphIcon(
          prism_glyphs.AppGlyphs.more,
          size: 18,
          color: Colors.white,
        ),
      ),
      popupBuilder: (_) => prism.PopupMenu(
        items: [
          if (onUpdate != null)
            prism.PopupMenuItem(
              label: updating ? '正在更新' : '更新歌单',
              glyph: prism_glyphs.AppGlyphs.refresh,
              executeImmediately: true,
              onPressed: updating ? null : onUpdate,
            ),
          if (canMoveUp && onMoveUp != null)
            prism.PopupMenuItem(
              label: '上移',
              glyph: prism_glyphs.AppGlyphs.arrowUp,
              executeImmediately: true,
              onPressed: onMoveUp,
            ),
          if (canMoveDown && onMoveDown != null)
            prism.PopupMenuItem(
              label: '下移',
              glyph: prism_glyphs.AppGlyphs.arrowDown,
              executeImmediately: true,
              onPressed: onMoveDown,
            ),
        ],
      ),
    );
  }
}

/// 封面左上角的实心爱心：点击取消收藏。
class _UnfavoriteBadge extends StatelessWidget {
  const _UnfavoriteBadge({required this.playlistId, required this.onPressed});

  final String playlistId;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: Tooltip(
        message: '取消收藏',
        child: GestureDetector(
          onTap: onPressed,
          behavior: HitTestBehavior.opaque,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.30),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.favorite_rounded,
              size: 17,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 批量态的圆形勾选标记；实际选择由整卡点击（onToggleSelected）触发。
class _BatchBadge extends StatelessWidget {
  const _BatchBadge({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: selected ? scheme.primary : scheme.surface,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        child: selected
            ? Icon(Icons.check_rounded, size: 16, color: scheme.onPrimary)
            : null,
      ),
    );
  }
}

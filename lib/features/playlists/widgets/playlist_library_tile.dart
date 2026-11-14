import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/icons/icons.dart' as glyph;
import 'package:prism_ui/icons/prism_glyphs.dart' as prism_glyphs;

import '../../../core/models/enums.dart';
import '../../../core/ui/music_action_glyphs.dart';
import '../playlist_models.dart';
import 'playlist_artwork.dart';

/// One playlist row: cover, name, track count and an optional options menu.
///
/// Shared by the standalone playlist management page and the Songs page's
/// 歌单 tab so both entry points look and behave the same.
class PlaylistLibraryTile extends StatelessWidget {
  const PlaylistLibraryTile({
    super.key,
    required this.playlist,
    required this.onOpen,
    this.onRename,
    this.onUpdate,
    this.updating = false,
    this.onDelete,
    this.batchMode = false,
    this.selected = false,
    this.onToggleSelected,
    this.onUnfavorite,
  });

  final LocalPlaylist playlist;
  final VoidCallback onOpen;
  final VoidCallback? onRename;
  final VoidCallback? onUpdate;
  final bool updating;
  final VoidCallback? onDelete;
  final bool batchMode;
  final bool selected;
  final VoidCallback? onToggleSelected;

  /// Drops this playlist out of the library (the filled heart); hidden when
  /// null.
  final VoidCallback? onUnfavorite;

  @override
  Widget build(BuildContext context) {
    final importedSource = MusicSource.fromCode(
      playlist.originSourceCode ?? '',
    );
    final hasMenu =
        !batchMode &&
        (onUpdate != null || onRename != null || onDelete != null);
    return prism.Card(
      radius: prism.AppCorner.xl,
      padding: EdgeInsets.fromLTRB(10, 10, hasMenu ? 4 : 10, 10),
      isSelected: batchMode && selected,
      onPressed: batchMode ? onToggleSelected : onOpen,
      child: Padding(
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            PlaylistLibraryCover(playlist: playlist),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                  const SizedBox(height: 5),
                  Text(
                    playlist.isOnlineImport
                        ? '${importedSource.label}导入 · ${playlist.tracks.length} 首'
                        : '${playlist.tracks.length} 首歌曲',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: prism.AppTextStyle.caption1.of(context),
                  ),
                ],
              ),
            ),
            if (batchMode)
              prism.Checkbox(
                value: selected,
                isCircle: true,
                onChanged: onToggleSelected == null
                    ? null
                    : (_) => onToggleSelected!(),
              )
            else ...[
              if (onUnfavorite != null)
                prism.IconButton(
                  key: ValueKey('playlist-unfavorite-${playlist.id}'),
                  tooltip: '取消收藏',
                  style: prism.ButtonStyle.from(
                    fixedSize: const Size.square(40),
                    tapTargetSize: prism.TapTargetSize.shrinkWrap,
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: onUnfavorite,
                  icon: Icon(
                    Icons.favorite_rounded,
                    size: 21,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              if (hasMenu)
                prism.PopupAnchor(
                  targetBuilder: (open) => prism.IconButton(
                    tooltip: '歌单选项',
                    onPressed: open,
                    icon: const glyph.GlyphIcon(prism_glyphs.AppGlyphs.more),
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
                      if (onRename != null)
                        prism.PopupMenuItem(
                          label: '重命名',
                          glyph: prism_glyphs.AppGlyphs.edit,
                          executeImmediately: true,
                          onPressed: onRename,
                        ),
                      if (onDelete != null)
                        prism.PopupMenuItem(
                          label: '删除',
                          glyph: MusicActionGlyphs.trash,
                          executeImmediately: true,
                          onPressed: onDelete,
                          danger: true,
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The square artwork used by [PlaylistLibraryTile].
class PlaylistLibraryCover extends StatelessWidget {
  const PlaylistLibraryCover({super.key, required this.playlist});

  final LocalPlaylist playlist;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: 58,
      height: 58,
      color: scheme.secondaryContainer,
      alignment: Alignment.center,
      child: Icon(
        playlist.isOnlineImport
            ? Icons.cloud_done_outlined
            : Icons.music_note_rounded,
        color: scheme.onSecondaryContainer,
        size: 25,
      ),
    );
    return PlaylistCover(
      playlist: playlist,
      size: 58,
      radius: 16,
      placeholder: placeholder,
    );
  }
}

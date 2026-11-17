import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/ui/app_toast.dart';
import '../../player/widgets/player_popup_card.dart';
import '../playlist_models.dart';
import '../playlist_store.dart';
import '../playlist_name_dialog.dart';
import 'playlist_artwork.dart';

/// The playlist picker for "add to playlist" as an anchored glass card hanging
/// off the player's playlist action, replacing the bottom sheet so the choice
/// stays next to the entry that opened it.
///
/// [onPicked] runs after the card has popped, so the caller may safely use the
/// global toast overlay rather than the popup's (now dead) context.
class PlaylistAddPopup extends ConsumerWidget {
  const PlaylistAddPopup({super.key, required this.onPicked});

  final ValueSetter<LocalPlaylist> onPicked;

  Future<void> _createPlaylist(BuildContext context, WidgetRef ref) async {
    final name = await showPlaylistNameDialog(
      context,
      title: '新建歌单',
      actionLabel: '创建',
    );
    if (name == null || !context.mounted) return;
    try {
      // 建完不弹走：ref.watch 会自动刷新列表，新歌单立刻出现在下方，点它即可加入歌曲
      await ref.read(localPlaylistsProvider.notifier).create(name);
    } on PlaylistStoreException catch (error) {
      if (context.mounted) {
        showAppToast(context, error.message, type: AppToastType.warning);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(localPlaylistsProvider);

    return PlayerPopupCard(
      key: const ValueKey('playlist-add-popup'),
      maxWidth: 320,
      maxHeight: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PlayerPopupHeader(
            title: '添加到歌单',
            subtitle: '${playlists.length} 个歌单',
          ),
          PlayerPopupRow(
            label: '新建歌单',
            subtitle: '建好后点它即可把歌曲加入',
            leading: Icon(
              Icons.playlist_add_rounded,
              size: 18,
              color: prism.Theme.of(context).colorScheme.primary,
            ),
            onTap: () => _createPlaylist(context, ref),
          ),
          if (playlists.isEmpty)
            const PlayerPopupRow(
              label: '没有可添加的歌单',
              subtitle: '点上面的「新建歌单」即可创建',
            )
          else
            for (final playlist in playlists)
              PlayerPopupRow(
                label: playlist.name,
                subtitle: '${playlist.tracks.length} 首歌曲',
                leading: PlaylistCover(
                  playlist: playlist,
                  size: 20,
                  radius: 5,
                  placeholder: _PlaylistPlaceholder(
                    color:
                        prism.Theme.of(
                          context,
                        ).colorScheme.secondaryContainer,
                  ),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  onPicked(playlist);
                },
              ),
        ],
      ),
    );
  }
}

/// The 20 px square shown when a playlist has no cover artwork.
class _PlaylistPlaceholder extends StatelessWidget {
  const _PlaylistPlaceholder({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color,
      child: const Center(
        child: Icon(Icons.queue_music_rounded, size: 12),
      ),
    );
  }
}

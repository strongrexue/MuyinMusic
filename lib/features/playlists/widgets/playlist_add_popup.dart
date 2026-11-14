import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../player/widgets/player_popup_card.dart';
import '../playlist_models.dart';
import '../playlist_store.dart';
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
          if (playlists.isEmpty)
            const PlayerPopupRow(
              label: '没有可添加的歌单',
              subtitle: '请先在歌单管理中创建或导入歌单',
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

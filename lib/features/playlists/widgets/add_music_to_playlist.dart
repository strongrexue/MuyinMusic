import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/music_info.dart';
import '../../../core/ui/app_toast.dart';
import '../playlist_models.dart';
import '../playlist_store.dart';
import 'playlist_add_popup.dart';

/// Shows the glass playlist picker as a floating card, matching the player's
/// "add to playlist" action, and resolves to the playlist the user picked.
///
/// The card pops itself before reporting, so callers may use the global toast
/// overlay afterwards.
Future<LocalPlaylist?> showPlaylistAddCard(BuildContext context) async {
  LocalPlaylist? picked;
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: Colors.black.withValues(alpha: 0.16),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, _, _) => Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 72),
        child: PlaylistAddPopup(
          onPicked: (playlist) => picked = playlist,
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
  return picked;
}

Future<void> showAddMusicToPlaylist(
  BuildContext context,
  WidgetRef ref,
  MusicInfo music,
) async {
  final picked = await showPlaylistAddCard(context);
  if (!context.mounted || picked == null) return;

  final store = ref.read(localPlaylistsProvider.notifier);
  final playlist = store.byId(picked.id);
  if (playlist == null) {
    showAppToast(context, '歌单不存在或已被删除', type: AppToastType.warning);
    return;
  }

  try {
    final added = await store.addMusic(picked.id, music);
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

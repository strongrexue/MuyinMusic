import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/music_api.dart';
import '../../core/models/online_collection_kind.dart';
import '../../core/models/playlist_info.dart';
import '../../core/models/playlist_summary.dart';
import '../../core/ui/app_toast.dart';
import 'playlist_models.dart';
import 'playlist_store.dart';

/// The saved copy of the online collection behind [summary], if the user
/// already收藏 it.
LocalPlaylist? savedPlaylistFor(
  List<LocalPlaylist> playlists,
  PlaylistSummary summary,
) {
  for (final playlist in playlists) {
    if (playlist.onlinePlaylistId == summary.id &&
        playlist.originSourceCode?.trim() == summary.source.code) {
      return playlist;
    }
  }
  return null;
}

/// Saves [summary] into the library, or drops the saved copy when it is
/// already there. Returns the new "收藏" state.
Future<bool> toggleCollectionFavorite(
  BuildContext context,
  WidgetRef ref,
  PlaylistSummary summary, {
  OnlineCollectionKind kind = OnlineCollectionKind.playlist,
}) async {
  final notifier = ref.read(localPlaylistsProvider.notifier);
  final saved = savedPlaylistFor(ref.read(localPlaylistsProvider), summary);
  try {
    if (saved != null) {
      await notifier.delete(saved.id);
      if (context.mounted) {
        showAppToast(context, '已取消收藏', type: AppToastType.success);
      }
      return false;
    }
    final loaded = await ref
        .read(musicApiProvider)
        .getCollection(source: summary.source, id: summary.id, kind: kind);
    await notifier.importOnline(_withSummaryArtwork(loaded, summary));
    if (context.mounted) {
      showAppToast(context, '已完整收藏到我的歌单', type: AppToastType.success);
    }
    return true;
  } catch (error) {
    if (context.mounted) {
      showAppToast(
        context,
        '${saved == null ? '收藏' : '取消收藏'}失败：$error',
        type: AppToastType.error,
      );
    }
    rethrow;
  }
}

PlaylistInfo _withSummaryArtwork(
  PlaylistInfo playlist,
  PlaylistSummary summary,
) {
  return PlaylistInfo(
    id: playlist.id,
    name: playlist.name.isEmpty ? summary.name : playlist.name,
    source: playlist.source,
    tracks: playlist.tracks,
    coverUrl: summary.coverUrl?.trim().isNotEmpty == true
        ? summary.coverUrl
        : playlist.coverUrl,
    creator: playlist.creator,
    description: playlist.description?.trim().isNotEmpty == true
        ? playlist.description
        : summary.description,
    playCount: playlist.playCount,
    trackCount: playlist.trackCount,
  );
}

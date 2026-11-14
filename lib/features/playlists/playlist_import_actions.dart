import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/app_toast.dart';
import 'lx_playlist_import.dart';
import 'playlist_cover_resolver.dart';
import 'playlist_store.dart';

/// Picks a 洛雪 (.lxmc) file and imports every playlist it holds.
Future<void> importLxPlaylistFile(
  BuildContext context,
  WidgetRef ref, {
  ValueChanged<String?>? onProgress,
}) async {
  try {
    final picked = await ref.read(lxPlaylistFilePickerProvider)();
    if (picked == null || !context.mounted) return;

    final document = parseLxPlaylistFile(picked.bytes, fileName: picked.name);
    final coverResolution = await resolveLxPlaylistCovers(
      document.playlists,
      ref.read(playlistCoverResolverProvider),
      onProgress: (completed, total) =>
          onProgress?.call('封面 $completed/$total'),
    );
    if (!context.mounted) return;
    final imported = await ref
        .read(localPlaylistsProvider.notifier)
        .importLxPlaylists(coverResolution.playlists);
    if (!context.mounted) return;

    final trackCount = imported.fold<int>(
      0,
      (total, playlist) => total + playlist.tracks.length,
    );
    final skipped = document.skippedTrackCount;
    final message = imported.length == 1
        ? '已导入“${imported.single.name}”，共 $trackCount 首'
        : '已导入 ${imported.length} 个洛雪歌单，共 $trackCount 首';
    final coverMessage = coverResolution.resolvedCount > 0
        ? '，补全 ${coverResolution.resolvedCount} 张封面'
        : '';
    final skippedParts = <String>[
      if (document.skippedPlaylistCount > 0)
        '${document.skippedPlaylistCount} 个无效歌单',
      if (skipped > 0) '$skipped 首无效或不支持的歌曲',
    ];
    showAppToast(
      context,
      skippedParts.isEmpty
          ? '$message$coverMessage'
          : '$message$coverMessage，跳过 ${skippedParts.join('、')}',
      type: AppToastType.success,
    );
  } on LxPlaylistImportException catch (error) {
    if (context.mounted) {
      showAppToast(context, error.message, type: AppToastType.warning);
    }
  } catch (_) {
    if (context.mounted) {
      showAppToast(context, '读取洛雪歌单文件失败', type: AppToastType.error);
    }
  } finally {
    onProgress?.call(null);
  }
}

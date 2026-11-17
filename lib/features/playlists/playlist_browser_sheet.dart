import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../core/ui/app_scrollbar.dart';
import '../../core/ui/app_sheet.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/widgets/app_navigation_button.dart';
import 'playlist_name_dialog.dart';
import 'playlist_models.dart';
import 'playlist_store.dart';
import 'widgets/playlist_artwork.dart';

enum PlaylistBrowserMode { browse, addSongs }

Future<String?> showPlaylistBrowserSheet(
  BuildContext context, {
  PlaylistBrowserMode mode = PlaylistBrowserMode.browse,
}) {
  return showAppSheet<String>(
    context: context,
    detents: prism.snapSheetDetents,
    maxHeight: 1000,
    floating: false,
    glass: true, // 玻璃底板，与正例弹窗保持一致（关闭时由入口降级）。
    builder: (_) => _PlaylistBrowserSheet(mode: mode),
  );
}

class _PlaylistBrowserSheet extends ConsumerStatefulWidget {
  const _PlaylistBrowserSheet({required this.mode});

  final PlaylistBrowserMode mode;

  @override
  ConsumerState<_PlaylistBrowserSheet> createState() =>
      _PlaylistBrowserSheetState();
}

class _PlaylistBrowserSheetState extends ConsumerState<_PlaylistBrowserSheet> {
  final _desktopController = ScrollController();

  @override
  void dispose() {
    _desktopController.dispose();
    super.dispose();
  }

  Future<void> _createPlaylist(BuildContext context) async {
    final name = await showPlaylistNameDialog(
      context,
      title: '新建歌单',
      actionLabel: '创建',
    );
    if (name == null || !context.mounted) return;
    try {
      final playlist = await ref
          .read(localPlaylistsProvider.notifier)
          .create(name);
      if (!context.mounted) return;
      Navigator.of(context).pop('/playlists/${playlist.id}');
    } on PlaylistStoreException catch (error) {
      if (context.mounted) {
        showAppToast(context, error.message, type: AppToastType.warning);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = prism.Theme.of(context).colorScheme;
    final playlists = ref.watch(localPlaylistsProvider);
    final selecting = widget.mode == PlaylistBrowserMode.addSongs;
    final scrollController =
        PrimaryScrollController.maybeOf(context) ?? _desktopController;
    return prism.SurfaceScope(
      level: prism.SurfaceLevel.page,
      child: prism.Surface(
        color: prism.SurfaceLevel.page.colorOf(scheme),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            selecting ? '添加歌曲到' : '我的歌单',
                            style: prism.AppTextStyle.title3.of(
                              context,
                              emphasized: true,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${playlists.length} 个歌单',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AppNavigationButton.close(
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              if (!selecting)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: _FixedManagementTile(
                    onTap: () => Navigator.of(context).pop('/playlists'),
                  ),
                ),
              const prism.Divider(height: 1),
              Expanded(
                child: AppScrollbar(
                  controller: scrollController,
                  child: playlists.isEmpty
                      ? _EmptyPlaylists(
                          controller: scrollController,
                          selecting: selecting,
                          // 两种模式都提供新建入口
                          onNewPlaylist: () => _createPlaylist(context),
                        )
                      : prism.PrismListView(
                          controller: scrollController,
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                          // 两种模式都提供新建入口，列表顶部固定 +1
                          itemCount: playlists.length + 1,
                          gap: 6,
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return _NewPlaylistTile(
                                onTap: () => _createPlaylist(context),
                              );
                            }
                            final playlist = playlists[index - 1];
                            return _PlaylistSheetTile(
                              playlist: playlist,
                              selecting: selecting,
                              onTap: () => Navigator.of(
                                context,
                              ).pop('/playlists/${playlist.id}'),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FixedManagementTile extends StatelessWidget {
  const _FixedManagementTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = prism.Theme.of(context).colorScheme;
    return prism.Card(
      onPressed: onTap,
      radius: 20,
      child: prism.ListRow(
        minHeight: 72,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(15),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.library_music_rounded,
            color: scheme.onPrimary,
            size: 23,
          ),
        ),
        title: const Text(
          '歌单管理',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: const Text(
          '新建、导入、重命名与整理歌单',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

class _NewPlaylistTile extends StatelessWidget {
  const _NewPlaylistTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = prism.Theme.of(context).colorScheme;
    return prism.Card(
      onPressed: onTap,
      radius: 18,
      child: prism.ListRow(
        minHeight: 68,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.playlist_add_rounded,
            color: scheme.onSecondaryContainer,
            size: 23,
          ),
        ),
        title: const Text(
          '新建歌单',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: const Text('创建新歌单并添加歌曲'),
        trailing: const Icon(Icons.add_rounded),
      ),
    );
  }
}

class _PlaylistSheetTile extends StatelessWidget {
  const _PlaylistSheetTile({
    required this.playlist,
    required this.selecting,
    required this.onTap,
  });

  final LocalPlaylist playlist;
  final bool selecting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = prism.Theme.of(context).colorScheme;
    return prism.Card(
      onPressed: onTap,
      radius: 18,
      child: prism.ListRow(
        minHeight: 68,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        leading: PlaylistCover(
          playlist: playlist,
          size: 44,
          radius: 14,
          placeholder: Container(
            width: 44,
            height: 44,
            color: scheme.secondaryContainer,
            alignment: Alignment.center,
            child: Icon(
              Icons.queue_music_rounded,
              color: scheme.onSecondaryContainer,
              size: 23,
            ),
          ),
        ),
        title: Text(
          playlist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text('${playlist.tracks.length} 首歌曲'),
        trailing: Icon(
          selecting ? Icons.add_rounded : Icons.chevron_right_rounded,
        ),
      ),
    );
  }
}

class _EmptyPlaylists extends StatelessWidget {
  const _EmptyPlaylists({
    required this.controller,
    required this.selecting,
    this.onNewPlaylist,
  });

  final ScrollController controller;
  final bool selecting;
  final VoidCallback? onNewPlaylist;

  @override
  Widget build(BuildContext context) {
    final scheme = prism.Theme.of(context).colorScheme;
    return ListView(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 24),
      children: [
        Icon(
          Icons.playlist_add_rounded,
          color: scheme.onSurfaceVariant,
          size: 38,
        ),
        const SizedBox(height: 12),
        Text(
          selecting ? '没有可添加的歌单' : '还没有歌单',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          selecting ? '请先创建歌单或前往歌单管理导入' : '进入歌单管理即可新建或导入在线歌单',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
        if (onNewPlaylist != null) ...[
          const SizedBox(height: 20),
          Center(
            child: FilledButton.icon(
              onPressed: onNewPlaylist,
              icon: const Icon(Icons.playlist_add_rounded),
              label: const Text('新建歌单'),
            ),
          ),
        ],
      ],
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/ui/app_scrollbar.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/car_display_layout.dart';
import '../shell/shell_bottom_area.dart';
import '../shell/widgets/scrolling_page_header.dart';
import 'online_playlist_updater.dart';
import 'playlist_import_actions.dart';
import 'playlist_name_dialog.dart';
import 'playlist_models.dart';
import 'playlist_store.dart';
import 'widgets/playlist_library_tile.dart';
import 'widgets/playlist_management_menu.dart';

class PlaylistManagementPage extends ConsumerStatefulWidget {
  const PlaylistManagementPage({super.key});

  @override
  ConsumerState<PlaylistManagementPage> createState() =>
      _PlaylistManagementPageState();
}

class _PlaylistManagementPageState
    extends ConsumerState<PlaylistManagementPage> {
  final ScrollController _scrollController = ScrollController();
  final Object _menuOwner = Object();
  late final _menuState = ref.read(playlistManagementMenuProvider.notifier);

  void _syncMenu() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _menuState.state = PlaylistManagementMenuState(
        owner: _menuOwner,
        onCreate: () => unawaited(_createPlaylist(context, ref)),
        onImportLx: _importingLx ? null : () => unawaited(_importLxPlaylist()),
        importLabel: _importingLx ? _lxImportProgress ?? '正在导入' : '洛雪导入',
      );
    });
  }

  bool _importingLx = false;
  String? _lxImportProgress;
  final Set<String> _updatingPlaylistIds = <String>{};

  @override
  void dispose() {
    final menuState = _menuState;
    scheduleMicrotask(() {
      if (menuState.mounted && identical(menuState.state.owner, _menuOwner)) {
        menuState.state = const PlaylistManagementMenuState();
      }
    });
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(localPlaylistsProvider);
    _syncMenu();
    return Scaffold(
      body: AppScrollbar(
        controller: _scrollController,
        child: CustomScrollView(
          controller: _scrollController,
          key: const PageStorageKey('playlists-manage-scroll'),
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            const SliverToBoxAdapter(child: ScrollHeaderSpacer()),
            if (playlists.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyManagement(),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  12,
                  16,
                  ShellBottomArea.contentPadding(context, 116),
                ),
                sliver: SliverList.separated(
                  itemCount: playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    return Center(
                      child: ConstrainedBox(
                        constraints: CarDisplayLayout.contentConstraints(
                          context,
                          maxWidth: 760,
                        ),
                        child: PlaylistLibraryTile(
                          playlist: playlist,
                          onOpen: () => context.go(
                            _managementDetailLocation(playlist.id),
                          ),
                          onRename: () =>
                              _renamePlaylist(context, ref, playlist),
                          onUpdate: playlist.isOnlineImport
                              ? () => _updatePlaylist(playlist)
                              : null,
                          updating: _updatingPlaylistIds.contains(playlist.id),
                          onDelete: () =>
                              _deletePlaylist(context, ref, playlist),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _createPlaylist(BuildContext context, WidgetRef ref) async {
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
      showAppToast(
        context,
        '歌单“${playlist.name}”已创建',
        type: AppToastType.success,
      );
      context.go(_managementDetailLocation(playlist.id));
    } on PlaylistStoreException catch (error) {
      if (context.mounted) {
        showAppToast(context, error.message, type: AppToastType.warning);
      }
    }
  }

  Future<void> _importLxPlaylist() async {
    if (_importingLx) return;
    setState(() => _importingLx = true);
    try {
      await importLxPlaylistFile(
        context,
        ref,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _lxImportProgress = progress);
        },
      );
    } finally {
      if (mounted) setState(() => _importingLx = false);
    }
  }

  Future<void> _renamePlaylist(
    BuildContext context,
    WidgetRef ref,
    LocalPlaylist playlist,
  ) async {
    final name = await showPlaylistNameDialog(
      context,
      title: '重命名歌单',
      actionLabel: '保存',
      initialValue: playlist.name,
    );
    if (name == null || !context.mounted) return;
    try {
      await ref.read(localPlaylistsProvider.notifier).rename(playlist.id, name);
      if (context.mounted) {
        showAppToast(context, '歌单名称已更新', type: AppToastType.success);
      }
    } on PlaylistStoreException catch (error) {
      if (context.mounted) {
        showAppToast(context, error.message, type: AppToastType.warning);
      }
    }
  }

  Future<void> _updatePlaylist(LocalPlaylist playlist) async {
    if (_updatingPlaylistIds.contains(playlist.id)) return;
    setState(() => _updatingPlaylistIds.add(playlist.id));
    try {
      final result = await ref
          .read(onlinePlaylistUpdaterProvider)
          .update(
            playlist: playlist,
            store: ref.read(localPlaylistsProvider.notifier),
          );
      if (!mounted) return;
      showAppToast(
        context,
        onlinePlaylistUpdateMessage(result),
        type: AppToastType.success,
      );
    } catch (error) {
      if (!mounted) return;
      showAppToast(context, '更新歌单失败：$error', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _updatingPlaylistIds.remove(playlist.id));
    }
  }

  Future<void> _deletePlaylist(
    BuildContext context,
    WidgetRef ref,
    LocalPlaylist playlist,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: const Text('删除这个歌单？'),
        content: Text('“${playlist.name}”会被删除，本地音乐文件和下载记录不会受到影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref.read(localPlaylistsProvider.notifier).delete(playlist.id);
    if (context.mounted) {
      showAppToast(context, '歌单已删除', type: AppToastType.success);
    }
  }
}

String _managementDetailLocation(String playlistId) {
  return Uri(
    path: '/playlists/$playlistId',
    queryParameters: const {'from': 'manage'},
  ).toString();
}

class _EmptyManagement extends StatelessWidget {
  const _EmptyManagement();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        28,
        26,
        28,
        ShellBottomArea.contentPadding(context, 108),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(28),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.playlist_add_rounded,
              color: scheme.onSecondaryContainer,
              size: 38,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '从第一个歌单开始',
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '新建空歌单，或从酷我、酷狗、QQ、网易云和咪咕导入公开歌单。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

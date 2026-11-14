import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shell/shell_navigation.dart';
import '../../songs/songs_toolbar_state.dart';

/// The four round shortcuts that sit right under 继续播放.
class HomeQuickActions extends ConsumerWidget {
  const HomeQuickActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        Expanded(
          child: _QuickAction(
            actionKey: 'home-quick-liked',
            icon: Icons.favorite_rounded,
            label: '我的喜欢',
            onTap: () => _openLibraryTab(ref, context, SongsLibraryTab.liked),
          ),
        ),
        Expanded(
          child: _QuickAction(
            actionKey: 'home-quick-local',
            icon: Icons.smartphone_rounded,
            label: '本地音乐',
            onTap: () => _openLibraryTab(ref, context, SongsLibraryTab.local),
          ),
        ),
        Expanded(
          child: _QuickAction(
            actionKey: 'home-quick-playlists',
            icon: Icons.queue_music_rounded,
            label: '我的歌单',
            onTap: () =>
                _openLibraryTab(ref, context, SongsLibraryTab.playlists),
          ),
        ),
        Expanded(
          child: _QuickAction(
            actionKey: 'home-quick-downloads',
            icon: Icons.download_rounded,
            label: '下载',
            onTap: () => context.push('/home/downloads'),
          ),
        ),
      ],
    );
  }

  void _openLibraryTab(
    WidgetRef ref,
    BuildContext context,
    SongsLibraryTab tab,
  ) {
    ref.read(songsLibraryTabProvider.notifier).select(tab);
    navigateToShellTab(context, ref, '/home', '/home', '/songs');
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.actionKey,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String actionKey;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey(actionKey),
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 23, color: scheme.primary),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

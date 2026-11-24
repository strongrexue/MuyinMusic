import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../core/storage/settings_store.dart';
import '../../core/ui/app_toast.dart';
import '../downloads/download_history_store.dart';
import '../shell/widgets/scrolling_page_header.dart';
import 'local_song_scan_cache.dart';

/// 「已忽略的本地音乐」：被「仅从本地列表移除」的歌曲（文件仍在设备上）
/// 在这里逐首恢复，恢复后触发重扫回到本地列表。
class IgnoredLocalSongsPage extends ConsumerStatefulWidget {
  const IgnoredLocalSongsPage({super.key});

  @override
  ConsumerState<IgnoredLocalSongsPage> createState() =>
      _IgnoredLocalSongsPageState();
}

class _IgnoredLocalSongsPageState extends ConsumerState<IgnoredLocalSongsPage> {
  late final LocalSongScanCache _scanCache;
  final Set<String> _restoring = {};

  @override
  void initState() {
    super.initState();
    _scanCache = ref.read(localSongScanCacheProvider);
  }

  Future<void> _restore(String path) async {
    if (!_restoring.add(path)) return;
    try {
      await ref.read(settingsProvider.notifier).unignoreLocalSongPaths([path]);
      await _scanCache.refresh(
        directories: ref.read(settingsProvider).scanDirectories,
      );
      if (!mounted) return;
      showAppToast(context, '已恢复到本地列表', type: AppToastType.success);
    } finally {
      if (mounted) setState(() => _restoring.remove(path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ignored = ref.watch(settingsProvider).ignoredLocalSongPaths;
    final history = ref.watch(downloadHistoryProvider);
    final historyByKey = <String, DownloadHistoryEntry>{
      for (final entry in history)
        if (entry.savedPath != null && entry.savedPath!.isNotEmpty)
          localSongPathKey(entry.savedPath!): entry,
    };
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        key: const PageStorageKey('ignored-local-songs-scroll'),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          const SliverToBoxAdapter(child: ScrollHeaderSpacer()),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回',
                    onPressed: () => context.pop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      '已忽略的本地音乐',
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (ignored.isNotEmpty)
                    Text(
                      '${ignored.length} 首',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (ignored.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    '没有已忽略的本地音乐\n在歌曲菜单选择「仅从本地列表移除」的歌曲会出现在这里',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13.5,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              sliver: SliverList.separated(
                itemCount: ignored.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final path = ignored[index];
                  final entry = historyByKey[localSongPathKey(path)];
                  final title = entry?.name.trim().isNotEmpty == true
                      ? entry!.name.trim()
                      : _titleFromFileName(p.basename(path));
                  final singer = entry?.singer.trim() ?? '';
                  return ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(8, 2, 4, 2),
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      singer.isEmpty ? path : '$singer · $path',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11.5,
                      ),
                    ),
                    trailing: TextButton(
                      onPressed: _restoring.contains(path)
                          ? null
                          : () => unawaited(_restore(path)),
                      child: Text(_restoring.contains(path) ? '恢复中' : '恢复'),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// 与扫描列表一致的文件名解析：去掉扩展名，「歌手 - 歌名」取后半段。
String _titleFromFileName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final base = dot > 0 ? fileName.substring(0, dot) : fileName;
  final sep = base.indexOf(' - ');
  final title = sep > 0 ? base.substring(sep + 3).trim() : base.trim();
  return title.isEmpty ? fileName : title;
}

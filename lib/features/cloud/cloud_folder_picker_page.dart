import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/storage/settings_store.dart';
import '../../core/ui/app_toast.dart';
import '../shell/shell_bottom_area.dart';
import '../shell/widgets/scrolling_page_header.dart';
import 'cloud_drive2_client.dart';
import 'cloud_library.dart';
import 'cloud_song_path.dart';

/// 云端音乐文件夹浏览器：逐层浏览 CloudDrive2 目录，把某个文件夹选为
/// 云端扫描根。文件只灰显展示、不可选；入口只在歌曲页的云端页签。
class CloudFolderPickerPage extends ConsumerStatefulWidget {
  const CloudFolderPickerPage({super.key});

  @override
  ConsumerState<CloudFolderPickerPage> createState() =>
      _CloudFolderPickerPageState();
}

class _CloudFolderPickerPageState extends ConsumerState<CloudFolderPickerPage> {
  late String _currentPath;
  List<CloudFileItem> _items = const [];
  bool _loading = true;
  String? _error;
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    _currentPath = cloudScanRootPath(
      ref.read(settingsProvider).cloudDrive2MusicRoot,
    );
    unawaited(_load(_currentPath));
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await ref
          .read(cloudDrive2LibraryProvider)
          .listDirectory(path);
      if (!mounted) return;
      setState(() {
        _currentPath = path;
        // 文件夹在前（可进入），文件在后灰显，组内保持服务器顺序。
        _items = [
          for (final item in items)
            if (item.isDirectory) item,
          for (final item in items)
            if (!item.isDirectory) item,
        ];
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法读取这个文件夹，请检查网络后重试';
      });
    }
  }

  Future<void> _select(String root) async {
    if (_selecting) return;
    setState(() => _selecting = true);
    await ref.read(settingsProvider.notifier).setCloudDrive2MusicRoot(root);
    if (!mounted) return;
    showAppToast(
      context,
      root.isEmpty ? '云端音乐将扫描全部文件' : '已切换云端音乐文件夹',
      type: AppToastType.success,
    );
    context.pop();
  }

  List<(String label, String path)> get _crumbs {
    final crumbs = <(String, String)>[('全部文件', '/')];
    if (_currentPath == '/') return crumbs;
    final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
    var path = '';
    for (final part in parts) {
      path = '$path/$part';
      crumbs.add((part, path));
    }
    return crumbs;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              key: const PageStorageKey('cloud-folder-picker-scroll'),
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
                        const Expanded(
                          child: Text(
                            '选择云端音乐文件夹',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  sliver: SliverToBoxAdapter(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final (index, crumb) in _crumbs.indexed) ...[
                            if (index > 0)
                              Icon(
                                Icons.chevron_right_rounded,
                                size: 16,
                                color: scheme.onSurfaceVariant,
                              ),
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: crumb.$2 == _currentPath
                                  ? null
                                  : () => unawaited(_load(crumb.$2)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 4,
                                ),
                                child: Text(
                                  crumb.$1,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: crumb.$2 == _currentPath
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: crumb.$2 == _currentPath
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (_loading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error!,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.tonal(
                            onPressed: () => unawaited(_load(_currentPath)),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (_items.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(
                        '这个文件夹是空的',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    sliver: SliverList.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        if (item.isDirectory) {
                          return ListTile(
                            key: ValueKey('cloud-folder-${item.fullPathName}'),
                            leading: Icon(
                              Icons.folder_rounded,
                              color: scheme.primary,
                            ),
                            title: Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => unawaited(_load(item.fullPathName)),
                          );
                        }
                        // 文件只作参照灰显，不可选、不可点。
                        return ListTile(
                          key: ValueKey('cloud-file-${item.fullPathName}'),
                          enabled: false,
                          leading: const Icon(Icons.music_note_rounded),
                          title: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          // 选择栏不用 bottomNavigationBar：壳层悬浮 dock 会盖住它。
          // 放进 body 并按 ShellBottomArea 留白，栏体落在 dock 上方。
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                ShellBottomArea.contentPadding(context, 12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '当前文件夹：${_currentPath == '/' ? '全部文件（根目录）' : _currentPath}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      TextButton(
                        key: const ValueKey('cloud-folder-select-root'),
                        onPressed: _selecting
                            ? null
                            : () => unawaited(_select('')),
                        child: const Text('全部文件（根目录）'),
                      ),
                      const Spacer(),
                      FilledButton(
                        key: const ValueKey('cloud-folder-select-current'),
                        onPressed: _selecting
                            ? null
                            : () => unawaited(
                                _select(
                                  _currentPath == '/' ? '' : _currentPath,
                                ),
                              ),
                        child: const Text('选择当前文件夹'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

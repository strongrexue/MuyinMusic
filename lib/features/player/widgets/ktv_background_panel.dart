import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/icons/icons.dart' as glyph;
import 'package:prism_ui/icons/prism_glyphs.dart' as prism_glyphs;

import '../../../core/storage/settings_store.dart';
import '../../../core/ui/app_toast.dart';
import '../../../core/ui/music_action_glyphs.dart';
import '../../playlists/playlist_name_dialog.dart';
import '../../settings/widgets/settings_sheet.dart';
import 'ktv_background.dart';
import 'ktv_background_files.dart';
import 'player_popup_card.dart';

final _ktvBackgroundFileProvider = FutureProvider.family<File, String>(
  (ref, fileName) => ktvBackgroundFile(fileName),
);

String _newKtvBackgroundId() {
  final random = math.Random();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${random.nextInt(1 << 24).toRadixString(36)}';
}

/// KTV 背景选择面板：内置背景 + 自定义图库，点选立即生效。
class KtvBackgroundPopup extends ConsumerWidget {
  const KtvBackgroundPopup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(ktvBackgroundMigrationProvider);
    final state = ref.watch(
      settingsProvider.select(
        (s) => (
          style: s.ktvBackgroundStyle,
          items: s.ktvBackgroundItems,
          selectedId: s.ktvBackgroundSelectedId,
        ),
      ),
    );
    return PlayerPopupCard(
      key: const ValueKey('player-ktv-background-popup'),
      minWidth: 264,
      maxWidth: 336,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PlayerPopupHeader(title: 'KTV 背景', subtitle: '切换立即生效'),
          PlayerPopupRow(
            key: const ValueKey('ktv-background-builtin'),
            label: '内置背景',
            subtitle: '默认',
            leading: const ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(4)),
              child: Image(
                image: AssetImage('assets/images/ktv_bg_default.jpg'),
                width: 20,
                height: 20,
                fit: BoxFit.cover,
              ),
            ),
            selected: state.style == KtvBackgroundStyle.builtin,
            onTap: () => unawaited(
              ref.read(settingsProvider.notifier).selectBuiltinKtvBackground(),
            ),
          ),
          for (final item in state.items)
            _CustomItemRow(
              key: ValueKey('ktv-background-item-${item.id}'),
              item: item,
              selected:
                  state.style == KtvBackgroundStyle.custom &&
                  state.selectedId == item.id,
            ),
          PlayerPopupRow(
            key: const ValueKey('ktv-background-import'),
            label: '导入图片',
            leading: const Icon(Icons.add_photo_alternate_outlined, size: 20),
            onTap: () => unawaited(_import(context, ref)),
          ),
        ],
      ),
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    // 用扩展名白名单而非 FileType.image：各平台「图片」类别对 GIF /
    // 动态 WebP 的过滤不稳定（选不到或返回静态副本），按扩展名放行才可靠。
    // 渲染侧 Image+FileImage 原生支持动图多帧播放，无需特殊处理。
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'gif', 'webp'],
    );
    if (result == null) return;
    try {
      final picked = result.files.single;
      final sourcePath = picked.path;
      if (sourcePath == null) {
        throw const FormatException('无法读取所选图片');
      }
      var extension = p.extension(picked.name).toLowerCase();
      if (extension.isEmpty) extension = '.jpg';
      final id = _newKtvBackgroundId();
      final fileName = '$id$extension';
      // 复制进应用文档目录，避免原图被移动/删除后背景失效。
      final target = await ktvBackgroundFile(fileName);
      await File(sourcePath).copy(target.path);
      var name = p.basenameWithoutExtension(picked.name).trim();
      if (name.isEmpty) name = '自定义背景';
      await ref
          .read(settingsProvider.notifier)
          .addKtvBackgroundItem(
            KtvBackgroundItem(id: id, name: name, fileName: fileName),
          );
      if (!context.mounted) return;
      showAppToast(context, '背景图已更新', type: AppToastType.success);
    } catch (error) {
      if (!context.mounted) return;
      showAppToast(context, '导入背景图失败：$error', type: AppToastType.error);
    }
  }
}

class _CustomItemRow extends ConsumerWidget {
  const _CustomItemRow({super.key, required this.item, required this.selected});

  final KtvBackgroundItem item;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = prism.Theme.of(context).colorScheme;
    final file = ref
        .watch(_ktvBackgroundFileProvider(item.fileName))
        .valueOrNull;
    return prism.PressRegion(
      onTap: () => unawaited(
        ref.read(settingsProvider.notifier).selectKtvBackgroundItem(item.id),
      ),
      shape: prism.AppShape.md,
      overlay: prism.PressRegion.hoverOverlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(6)),
              child: SizedBox(
                width: 52,
                height: 30,
                child: file == null
                    ? ColoredBox(color: colorScheme.surfaceContainerHighest)
                    : Image(
                        image: FileImage(file),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: prism.AppTextStyle.subheadline
                    .of(context)
                    .copyWith(fontSize: 14, color: colorScheme.onSurface),
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(Icons.check_rounded, size: 18, color: colorScheme.primary),
            ],
            const SizedBox(width: 4),
            prism.PopupAnchor(
              targetBuilder: (open) => prism.IconButton(
                tooltip: '背景选项',
                onPressed: open,
                icon: const glyph.GlyphIcon(prism_glyphs.AppGlyphs.more),
              ),
              popupBuilder: (_) => prism.PopupMenu(
                items: [
                  prism.PopupMenuItem(
                    label: '重命名',
                    glyph: prism_glyphs.AppGlyphs.edit,
                    executeImmediately: true,
                    onPressed: () => unawaited(_rename(context, ref)),
                  ),
                  prism.PopupMenuItem(
                    label: '删除',
                    glyph: MusicActionGlyphs.trash,
                    executeImmediately: true,
                    onPressed: () => unawaited(_delete(context, ref)),
                    danger: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await showPlaylistNameDialog(
      context,
      title: '重命名背景',
      actionLabel: '保存',
      initialValue: item.name,
    );
    if (name == null) return;
    await ref
        .read(settingsProvider.notifier)
        .renameKtvBackgroundItem(item.id, name);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showSettingsDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => prism.AlertDialog(
        title: '删除这张背景图？',
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
        child: Text('「${item.name}」将被删除，图片文件也会一并移除。'),
      ),
    );
    if (confirmed != true) return;
    final removed = await ref
        .read(settingsProvider.notifier)
        .removeKtvBackgroundItem(item.id);
    if (removed == null) return;
    final file = await ktvBackgroundFile(removed.fileName);
    if (await file.exists()) await file.delete();
  }
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/storage/settings_store.dart';
import 'ktv_background_files.dart';

const String _builtinAsset = 'assets/images/ktv_bg_default.jpg';

/// 一次性把旧版单张自定义背景图迁进图库：把旧文件复制到
/// ktv_backgrounds/ 并登记为「自定义背景」。图库非空或已迁移时
/// [SettingsNotifier.migrateLegacyKtvBackground] 自行跳过。
final ktvBackgroundMigrationProvider = FutureProvider<void>((ref) async {
  final settings = ref.read(settingsProvider);
  if (settings.ktvBackgroundItems.isNotEmpty) return;
  final legacyPath = settings.ktvBackgroundImagePath;
  String? copiedFileName;
  if (legacyPath != null && legacyPath.isNotEmpty) {
    final legacyFile = File(legacyPath);
    if (await legacyFile.exists()) {
      var extension = p.extension(legacyPath).toLowerCase();
      if (extension.isEmpty) extension = '.jpg';
      copiedFileName = 'legacy$extension';
      final target = await ktvBackgroundFile(copiedFileName);
      await legacyFile.copy(target.path);
    }
  }
  await ref
      .read(settingsProvider.notifier)
      .migrateLegacyKtvBackground(copiedFileName);
});

/// 当前选中的自定义背景图片文件；未选中、条目缺失或文件不存在时为 null。
final _selectedKtvBackgroundFileProvider = FutureProvider<File?>((ref) async {
  await ref.watch(ktvBackgroundMigrationProvider.future);
  final item = ref.watch(
    settingsProvider.select((s) => s.selectedKtvBackgroundItem),
  );
  if (item == null) return null;
  final file = await ktvBackgroundFile(item.fileName);
  return await file.exists() ? file : null;
});

/// 横屏 KTV 播放页背景：内置默认图片，或用户导入的自定义图片，
/// 由 [AppSettings.ktvBackgroundStyle] 决定。自定义图缺失时回退内置。
class KtvBackground extends ConsumerWidget {
  const KtvBackground({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(
      settingsProvider.select((s) => s.ktvBackgroundStyle),
    );
    final customFile = style == KtvBackgroundStyle.custom
        ? ref.watch(_selectedKtvBackgroundFileProvider).valueOrNull
        : null;
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (customFile != null)
            Image(
              image: FileImage(customFile),
              fit: BoxFit.cover,
              gaplessPlayback: true,
            )
          else
            Image.asset(
              _builtinAsset,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) =>
                  const ColoredBox(color: Color(0xFF101016)),
            ),
          const _BottomScrim(),
        ],
      ),
    );
  }
}

/// 底部渐隐黑幕，保证歌词在任何背景上可读。
class _BottomScrim extends StatelessWidget {
  const _BottomScrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0x73000000)],
          stops: [0.55, 1.0],
        ),
      ),
    );
  }
}

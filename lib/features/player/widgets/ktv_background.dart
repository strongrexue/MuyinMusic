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

/// 竖屏播放页选中的背景图片文件；图库与 KTV 共用，选中状态独立
/// （[AppSettings.portraitBackgroundSelectedId]）。未选中或文件不存在
/// 时为 null，调用方回退流光背景。
final selectedPortraitBackgroundFileProvider = FutureProvider<File?>((
  ref,
) async {
  await ref.watch(ktvBackgroundMigrationProvider.future);
  final item = ref.watch(
    settingsProvider.select((s) => s.selectedPortraitBackgroundItem),
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

/// 竖屏封面页背景：渲染竖屏选中的图库图片（与 KTV 同一套图片渲染，
/// 动图同样原生多帧播放）。文件未就绪或不存在时不渲染任何内容，
/// 由调用方保留其下的流光背景。罩面沿用 KTV 的渐变罩思路：顶部与
/// 底部各一道黑渐变，保证顶栏文字/图标与底部控件在任意照片上可读，
/// 不依赖封面取色适配照片。
class PortraitBackground extends ConsumerWidget {
  const PortraitBackground({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = ref
        .watch(selectedPortraitBackgroundFileProvider)
        .valueOrNull;
    if (file == null) return const SizedBox.expand();
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image(
            image: FileImage(file),
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
          const _TopScrim(),
          const _BottomScrim(),
        ],
      ),
    );
  }
}

/// 顶部渐隐黑幕：顶端 40% 黑，至 25% 高度处淡完，罩住顶栏区域。
class _TopScrim extends StatelessWidget {
  const _TopScrim();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x66000000), Colors.transparent],
          stops: [0, 0.25],
        ),
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

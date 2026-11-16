import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/models/enums.dart';
import '../../../core/models/playlist_tag.dart';
import '../../../core/ui/app_sheet.dart';
import '../../../core/ui/widgets/header_control_style.dart';
import '../../../theme/app_motion.dart';
import '../discovery_controller.dart';

/// 选择分类（标签轴）：组小标题 + 标签墙，「全部」固定在顶部。
Future<void> showDiscoveryTagSheet({
  required BuildContext context,
  required MusicSource source,
}) {
  return showAppSheet<void>(
    context: context,
    heightFraction: 0.78,
    maxHeight: 720,
    // 和播放页列表弹窗同一层材料：底板走玻璃，标签沿用描边样式。
    glass: true,
    builder: (_) => _DiscoveryTagSheet(source: source),
  );
}

class _DiscoveryTagSheet extends ConsumerWidget {
  const _DiscoveryTagSheet({required this.source});

  final MusicSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = playlistTagGroupsFor(source);
    final selectedId = ref.watch(selectedDiscoveryTagProvider(source));
    return AppSheetLayout(
      title: '选择分类',
      body: ListView(
        key: const ValueKey('discovery-tag-sheet-list'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          const _GroupHeader(label: '全部'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _TagChip(
                key: const ValueKey('discovery-tag-all'),
                label: '全部',
                selected: selectedId == null,
                onTap: () {
                  ref
                      .read(selectedDiscoveryTagProvider(source).notifier)
                      .select(null);
                  Navigator.of(context).maybePop();
                },
              ),
            ],
          ),
          for (final group in groups) ...[
            const SizedBox(height: 18),
            _GroupHeader(label: group.label),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in group.tags)
                  _TagChip(
                    key: ValueKey('discovery-tag-${tag.id}'),
                    label: tag.label,
                    selected: tag.id == selectedId,
                    onTap: () {
                      ref
                          .read(selectedDiscoveryTagProvider(source).notifier)
                          .select(tag.id);
                      Navigator.of(context).maybePop();
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
      child: Text(
        label,
        style: prism.AppTextStyle.caption1
            .of(context)
            .copyWith(
              fontWeight: FontWeight.w600,
              color: prism.Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 玻璃底上再漂一层表面色，标签才有播放页列表那种「卡片落在玻璃上」的
    // 层次；玻璃关闭时退回原来的透明描边。
    final glass = prism.LiquidGlassScope.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : AppMotion.short,
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: glass
                ? headerControlFill(context).withValues(alpha: 0.55)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.6)
                  : scheme.outlineVariant.withValues(alpha: 0.55),
              width: 0.8,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

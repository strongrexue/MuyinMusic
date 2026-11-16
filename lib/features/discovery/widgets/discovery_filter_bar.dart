import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/models/enums.dart';
import '../../../core/models/playlist_category.dart';
import '../../../core/models/playlist_tag.dart';
import '../../../core/ui/widgets/header_control_style.dart';
import '../../../theme/app_motion.dart';
import '../discovery_controller.dart';
import 'discovery_tag_sheet.dart';

/// 胶囊左右内边距。
const double _pillInset = 16;

/// 平台胶囊行下方的一行筛选入口：左侧「排序」、右侧「分类」。
///
/// 两枚都常驻可点，文字不随选中值变化（只换高亮），避免长标签把这一行
/// 的宽度顶得跳来跳去。排序是贴胶囊弹出的浮层，分类是底部 sheet。
class DiscoveryFilterBar extends ConsumerWidget {
  const DiscoveryFilterBar({super.key});

  static const double height = 40;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(selectedDiscoverySourceProvider);
    final tagId = ref.watch(selectedDiscoveryTagProvider(source));
    final sortId = ref.watch(selectedDiscoveryCategoryProvider(source));
    final sorts = playlistSortOptionsFor(source);
    final tags = playlistTagGroupsFor(source);
    final hasTag = tags.isNotEmpty;

    return Padding(
      key: const ValueKey('discovery-filter-bar'),
      // 与平台胶囊行同一套留白：两者都靠页面层面的 Positioned(14) 定位，
      // 这里再各让 14，两端就落在玻璃壳的外缘上。
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            _SortPill(source: source, sorts: sorts, selectedId: sortId),
            const Spacer(),
            if (hasTag)
              _TagPill(source: source, selectedId: tagId)
            else
              const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}

class _SortPill extends ConsumerWidget {
  const _SortPill({
    required this.source,
    required this.sorts,
    required this.selectedId,
  });

  final MusicSource source;
  final List<PlaylistCatalogCategory> sorts;
  final String selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = sorts.firstWhere(
      (sort) => sort.id == selectedId,
      orElse: () => sorts.isNotEmpty ? sorts.first : playlistDefaultCategory,
    );
    return prism.PopupAnchor(
      key: const ValueKey('discovery-sort-anchor'),
      targetBuilder: (open) => _FilterPill(
        key: const ValueKey('discovery-sort-pill'),
        label: selected.label,
        active: true,
        onTap: open,
      ),
      popupBuilder: (_) => prism.PopupMenu(
        // 排序名都是两三个字，菜单不必留到 160 的默认宽度。
        minWidth: 116,
        maxWidth: 168,
        items: [
          for (final sort in sorts)
            prism.PopupMenuItem(
              label: sort.label,
              checked: sort.id == selectedId,
              selectedEmphasis: true,
              executeImmediately: true,
              onPressed: () => ref
                  .read(selectedDiscoveryCategoryProvider(source).notifier)
                  .select(sort.id),
            ),
        ],
      ),
    );
  }
}

class _TagPill extends ConsumerWidget {
  const _TagPill({required this.source, required this.selectedId});

  final MusicSource source;
  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tag = playlistTagFor(source, selectedId);
    return _FilterPill(
      key: const ValueKey('discovery-tag-pill'),
      label: tag?.label ?? '分类',
      active: true,
      onTap: () => showDiscoveryTagSheet(context: context, source: source),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    super.key,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(DiscoveryFilterBar.height / 2);
    // 强调色只落在文字上，底子交给玻璃或主题表面。
    final content = SizedBox(
      height: DiscoveryFilterBar.height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _pillInset),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: active ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
    final surface = prism.LiquidGlassScope.of(context)
        ? ClipRRect(
            borderRadius: radius,
            child: prism.LiquidGlass(
              style: prism.LiquidGlassStyle.pill(
                prism.Theme.of(context).colorScheme,
              ),
              borderRadius: radius,
              child: content,
            ),
          )
        : AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : AppMotion.short,
            decoration: BoxDecoration(
              color: headerControlFill(context),
              borderRadius: radius,
              border: Border.all(
                color: headerControlBorder(context).color,
                width: 0.8,
              ),
            ),
            child: content,
          );
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: surface,
      ),
    );
  }
}

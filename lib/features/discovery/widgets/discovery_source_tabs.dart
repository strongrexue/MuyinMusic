import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/models/enums.dart';
import '../../search/widgets/platform_identity.dart';
import '../discovery_controller.dart';

/// 发现页顶部的平台切换：与底部 dock 同款的悬浮胶囊，内嵌每个平台的小胶囊
/// （图标在上、名称在下），点一下切换发现内容来源。
///
/// 平台数量固定为设置里的 `discoverySourceOrder`，用等分布局保证 5 个平台
/// 在小屏上也能完整显示，不做横向滚动。
class DiscoverySourceTabs extends ConsumerWidget {
  const DiscoverySourceTabs({super.key});

  static const double _innerPadding = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(discoverySourcesProvider);
    final selected = ref.watch(selectedDiscoverySourceProvider);
    if (sources.isEmpty) return const SizedBox.shrink();
    final index = sources.indexOf(selected);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: KeyedSubtree(
        key: const ValueKey('discovery-source-tabs'),
        child: prism.GlassPillBar(
          count: sources.length,
          index: index < 0 ? 0 : index,
          inset: _innerPadding,
          pillGap: 2,
          segmentBuilder: (context, i, active) => _SourcePill(
            key: ValueKey('discovery-source-${sources[i].code}'),
            source: sources[i],
            active: active,
            onTap: () {
              if (sources[i] == selected) return;
              ref.read(selectedDiscoverySourceProvider.notifier).state =
                  sources[i];
            },
          ),
        ),
      ),
    );
  }
}

class _SourcePill extends StatelessWidget {
  const _SourcePill({
    super.key,
    required this.source,
    required this.active,
    required this.onTap,
  });

  final MusicSource source;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Same selection language as the floating dock: the chosen platform keeps
    // its icon untouched and gains accent text.
    return Semantics(
      button: true,
      selected: active,
      label: '${source.fullName}平台',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ExcludeSemantics(
              child: MusicPlatformIcon(source: source, size: 24),
            ),
            const SizedBox(height: 3),
            Text(
              source.shortName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.1,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

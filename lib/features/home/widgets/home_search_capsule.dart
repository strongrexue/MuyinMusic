import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

/// Entry point for online search. The whole search surface lives at
/// `/home/search`, so this capsule only carries the look and pushes that route.
class HomeSearchCapsule extends ConsumerWidget {
  const HomeSearchCapsule({super.key});

  static const String hintText = '搜索歌曲、艺人、歌单、专辑';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    const radius = BorderRadius.all(Radius.circular(18));
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              hintText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.76),
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                height: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
    final surface = prism.LiquidGlassScope.of(context)
        ? prism.LiquidGlass(
            borderRadius: radius,
            style: prism.LiquidGlassStyle.regular(
              prism.Theme.of(context).colorScheme,
            ).copyWith(hazeBlur: 10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh.withValues(alpha: 0.16),
                borderRadius: radius,
                border: Border.all(
                  color: scheme.outline.withValues(alpha: 0.16),
                ),
              ),
              child: SizedBox(height: 52, child: row),
            ),
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: radius,
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.34),
              ),
            ),
            child: SizedBox(height: 52, child: row),
          );
    return prism.ElasticPress(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('home-search-capsule'),
          borderRadius: radius,
          onTap: () => context.push('/home/search'),
          child: surface,
        ),
      ),
    );
  }
}

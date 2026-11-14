import 'package:flutter/material.dart';
import 'package:prism_ui/icons/icons.dart' as prism_glyph;
import 'package:prism_ui/prism_ui.dart' as prism;

import '../../../core/ui/music_action_glyphs.dart';
import '../../../theme/app_motion.dart';

/// Bottom bar shown while the Songs page's playlist tab is selecting rows.
class PlaylistsBatchActionBar extends StatelessWidget {
  const PlaylistsBatchActionBar({
    super.key,
    required this.selectedCount,
    required this.onRemove,
  });

  final int selectedCount;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      key: const ValueKey('playlists-batch-bottom-bar'),
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: prism.GooSurface(
          color: scheme.surfaceContainer,
          glass: prism.LiquidGlassScope.of(context)
              ? prism.LiquidGlassStyle.pill(prism.Theme.of(context).colorScheme)
              : null,
          child: prism.GooPane(
            child: SizedBox(
              height: 64,
              child: Row(
                children: [
                  Expanded(
                    child: _PlaylistsBatchAction(
                      icon: MusicActionGlyphs.playlistRemove,
                      label: selectedCount == 0
                          ? '移除歌单'
                          : '移除 $selectedCount 个歌单',
                      onPressed: onRemove,
                      enabledColor: scheme.error,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistsBatchAction extends StatelessWidget {
  const _PlaylistsBatchAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.enabledColor,
  });

  final prism_glyph.Glyph icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? enabledColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final color = enabled
        ? enabledColor ?? scheme.onSurfaceVariant
        : scheme.onSurface.withValues(alpha: 0.34);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          child: AnimatedOpacity(
            duration: AppMotion.short,
            opacity: enabled ? 1 : 0.72,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                prism_glyph.GlyphIcon(icon, size: 21, fill: 0, color: color),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import '../../../theme/app_motion.dart';
import '../player_controller.dart';
import 'karaoke_lyrics_view.dart';
import 'player_layout.dart';
import 'player_palette.dart';
import 'track_change_switcher.dart';

class LyricsPanel extends ConsumerStatefulWidget {
  const LyricsPanel({
    super.key,
    this.edgeFadeEnabled = true,
    this.horizontalPadding = playerContentInset,
    this.edgeFadeExtent,
    this.edgeFadeExtentTop,
    this.edgeFadeExtentBottom,
    this.edgeFadeDeadZoneTop,
    this.edgeFadeDeadZoneBottom,
    this.scrollAnchor,
    this.lineVerticalPadding,
    this.listPadding,
    this.alignMode,
  });

  final bool edgeFadeEnabled;
  final double horizontalPadding;

  /// Optional panel-scoped overrides forwarded to [KaraokeLyricsView].
  /// All null (the default, used by the portrait page and the
  /// car/tablet layout) keeps the shared lyrics-page behaviour; only
  /// the phone-landscape layout passes its own values.
  final double? edgeFadeExtent;

  /// Optional per-edge fade overrides, forwarded like [edgeFadeExtent].
  /// Null (the default) keeps the symmetric [edgeFadeExtent] fade on
  /// both edges; the phone-landscape panel passes long top/bottom
  /// extents so lines dissolve before reaching its floating chrome.
  final double? edgeFadeExtentTop;
  final double? edgeFadeExtentBottom;

  /// Optional per-edge fade dead zones, forwarded like
  /// [edgeFadeExtentTop]. Within a dead zone a line stays fully
  /// dissolved; it only fades back in over the rest of that edge's
  /// extent. Null (the default) keeps the plain per-edge fade.
  final double? edgeFadeDeadZoneTop;
  final double? edgeFadeDeadZoneBottom;
  final double? scrollAnchor;
  final double? lineVerticalPadding;
  final EdgeInsets? listPadding;
  final LyricAlignMode? alignMode;

  @override
  ConsumerState<LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends ConsumerState<LyricsPanel> {
  bool _showTranslation = true;

  @override
  Widget build(BuildContext context) {
    // Everything here changes only on track switch / lyric load; the
    // per-tick `position` is consumed inside KaraokeLyricsView.
    final vm = ref.watch(
      playerControllerProvider.select(
        (s) => (
          lyricLoading: s.lyricLoading,
          lyrics: s.lyrics,
          localWithoutLyrics: s.track?.isLocal ?? false,
        ),
      ),
    );
    final localWithoutLyrics = vm.localWithoutLyrics;
    final hasTranslation = vm.lyrics.lines.any((line) {
      final translation = line.translation?.trim();
      return translation != null && translation.isNotEmpty;
    });
    final hasRoman = vm.lyrics.lines.any((line) {
      final roman = line.roman?.trim();
      return roman != null && roman.isNotEmpty;
    });
    final hasExtraLyrics = hasTranslation || hasRoman;
    final Widget child;
    final String transitionKey;
    if (vm.lyricLoading) {
      transitionKey = 'lyric-loading';
      child = const _LyricStatus(
        icon: Icons.graphic_eq_rounded,
        title: '歌词加载中',
      );
    } else if (vm.lyrics.isEmpty) {
      transitionKey = 'lyric-empty';
      child = _LyricStatus(
        icon: localWithoutLyrics
            ? Icons.library_music_rounded
            : Icons.lyrics_outlined,
        title: localWithoutLyrics ? '本地播放' : '暂无歌词',
        subtitle: localWithoutLyrics ? '未找到歌词' : null,
      );
    } else {
      final lyricsKey = identityHashCode(vm.lyrics).toString();
      transitionKey = lyricsKey;
      child = Column(
        children: [
          Expanded(
            child: KaraokeLyricsView(
              key: ValueKey('lyrics-view-$lyricsKey'),
              lyrics: vm.lyrics,
              showTranslation: hasExtraLyrics && _showTranslation,
              edgeFadeEnabled: widget.edgeFadeEnabled,
              horizontalPadding: widget.horizontalPadding,
              edgeFadeExtent: widget.edgeFadeExtent,
              edgeFadeExtentTop: widget.edgeFadeExtentTop,
              edgeFadeExtentBottom: widget.edgeFadeExtentBottom,
              edgeFadeDeadZoneTop: widget.edgeFadeDeadZoneTop,
              edgeFadeDeadZoneBottom: widget.edgeFadeDeadZoneBottom,
              scrollAnchor: widget.scrollAnchor,
              lineVerticalPadding: widget.lineVerticalPadding,
              listPadding: widget.listPadding,
              alignModeOverride: widget.alignMode,
            ),
          ),
          if (hasExtraLyrics)
            _LyricsTranslationToggle(
              horizontalPadding: widget.horizontalPadding,
              showTranslation: _showTranslation,
              hasTranslation: hasTranslation,
              hasRoman: hasRoman,
              onTap: () {
                setState(() => _showTranslation = !_showTranslation);
              },
            ),
        ],
      );
    }
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final contentKey = ValueKey(transitionKey);
    // A document change only fades. Moving/scaling the whole masked viewport
    // made the outgoing and incoming blurred lyric lists expensive to draw.
    return RepaintBoundary(
      child: AnimatedSwitcher(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 500),
        reverseDuration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 200),
        switchInCurve: const Cubic(0.4, 0, 0.2, 1),
        switchOutCurve: const Cubic(0.4, 0, 0.2, 1),
        layoutBuilder: (currentChild, previousChildren) => TrackChangeLayout(
          expand: true,
          currentChild: currentChild,
          previousChildren: previousChildren,
        ),
        transitionBuilder: (transitionChild, animation) {
          final incoming = transitionChild.key == contentKey;
          return FadeTransition(
            opacity: animation,
            child: LyricDocumentScope(
              live: incoming,
              child: RepaintBoundary(child: transitionChild),
            ),
          );
        },
        child: KeyedSubtree(key: contentKey, child: child),
      ),
    );
  }
}

class _LyricsTranslationToggle extends StatelessWidget {
  const _LyricsTranslationToggle({
    required this.horizontalPadding,
    required this.showTranslation,
    required this.hasTranslation,
    required this.hasRoman,
    required this.onTap,
  });

  final bool showTranslation;
  final double horizontalPadding;
  final bool hasTranslation;
  final bool hasRoman;
  final VoidCallback onTap;

  String get _buttonText {
    if (!hasTranslation && hasRoman) {
      return showTranslation ? '隐藏罗马音' : '显示罗马音';
    }
    return showTranslation ? '隐藏翻译' : '显示翻译';
  }

  String get _tooltipMessage {
    if (!hasTranslation && hasRoman) {
      return showTranslation ? '隐藏罗马音歌词' : '显示罗马音歌词';
    }
    if (hasTranslation && hasRoman) {
      return showTranslation ? '隐藏歌词翻译及罗马音' : '显示歌词翻译及罗马音';
    }
    return showTranslation ? '隐藏歌词翻译' : '显示歌词翻译';
  }

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppMotion.medium;
    final buttonText = _buttonText;
    final tooltipMessage = _tooltipMessage;
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 4, horizontalPadding, 10),
      child: Align(
        alignment: Alignment.centerRight,
        child: Tooltip(
          message: tooltipMessage,
          child: AnimatedContainer(
            duration: duration,
            curve: AppMotion.emphasized,
            decoration: BoxDecoration(
              color: playerInk(
                context,
              ).withValues(alpha: showTranslation ? 0.11 : 0.06),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedRotation(
                        turns: showTranslation ? 0 : -0.08,
                        duration: duration,
                        curve: AppMotion.emphasized,
                        child: Icon(
                          Icons.translate_rounded,
                          color: playerInk(context).withValues(alpha: 0.76),
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 6),
                      AnimatedSize(
                        duration: duration,
                        curve: AppMotion.emphasized,
                        child: AnimatedSwitcher(
                          duration: duration,
                          switchInCurve: AppMotion.emphasizedDecelerate,
                          switchOutCurve: AppMotion.emphasizedAccelerate,
                          transitionBuilder: (child, animation) {
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, 0.18),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: child,
                              ),
                            );
                          },
                          child: Text(
                            buttonText,
                            key: ValueKey(buttonText),
                            style: TextStyle(
                              color: playerInk(context).withValues(alpha: 0.78),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LyricStatus extends StatelessWidget {
  const _LyricStatus({required this.icon, required this.title, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: playerMuted(context)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: playerInk(context),
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: playerMuted(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

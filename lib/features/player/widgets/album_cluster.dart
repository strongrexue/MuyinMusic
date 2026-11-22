import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_store.dart';
import '../../shell/player_pull_scope.dart';
import '../../shell/player_transition.dart';
import '../player_controller.dart';
import 'mini_lyrics_panel.dart';
import 'player_palette.dart';
import 'spinning_cover_art.dart';
import 'track_change_switcher.dart';

const double _compactAlbumTopPadding = 20;
const double _miniLyricsSlotHeight = 84;

class AlbumPage extends ConsumerWidget {
  const AlbumPage({super.key, this.wide = false, this.onOpenLyrics});

  final bool wide;
  final VoidCallback? onOpenLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(
      playerControllerProvider.select(
        (state) => (
          track: state.track,
          miniLyricsReady: !state.lyricLoading && !state.lyrics.isEmpty,
        ),
      ),
    );
    final miniLyricsEnabled = ref.watch(
      settingsProvider.select((settings) => settings.showMiniLyrics),
    );
    final square = ref.watch(
      settingsProvider.select((settings) => settings.squareAlbumCoverEnabled),
    );
    final track = player.track;
    // The compact column is top-anchored and the mini-lyric slot below the
    // cover keeps a fixed height, so the cover never shifts when the lyrics
    // finish loading or the mini-lyrics setting toggles.
    final reserveMiniLyrics =
        !wide && onOpenLyrics != null && miniLyricsEnabled;
    final showMiniLyrics = reserveMiniLyrics && player.miniLyricsReady;

    return LayoutBuilder(
      builder: (context, constraints) {
        final coverScale = square ? 1.12 : 1.0;
        final maxCoverSize = (wide ? 400.0 : 360.0) * coverScale;
        final coverSize = math.min(
          maxCoverSize,
          math.min(
                constraints.maxWidth * (wide ? 0.88 : 0.86),
                constraints.maxHeight * (wide ? 0.68 : 0.62),
              ) *
              coverScale,
        );
        final resolvedCoverSize = coverSize
            .clamp(160.0, maxCoverSize)
            .toDouble();
        final metadataKey = track == null
            ? 'album-metadata:loading'
            : 'album-metadata:${track.id}:${track.album}';
        final cover = SizedBox.square(
          dimension: resolvedCoverSize,
          // The tap recognizer coexists with the parent's vertical
          // pull recognizer, so dragging still dismisses the page.
          child: PlayerPullHandle(
            child: Semantics(
              button: true,
              label: square ? '切换为圆形封面' : '切换为方形封面',
              child: GestureDetector(
                key: const ValueKey('player-cover-toggle-button'),
                behavior: HitTestBehavior.opaque,
                onTap: () => unawaited(
                  ref
                      .read(settingsProvider.notifier)
                      .setSquareAlbumCoverEnabled(!square),
                ),
                child: PlayerCoverAnchor(
                  expanded: true,
                  child: track == null
                      ? _LoadingAlbumArtwork(size: resolvedCoverSize)
                      : SpinningCoverArt(
                          track: track,
                          size: resolvedCoverSize,
                          placeholder: ColoredBox(
                            color: Colors.white.withValues(alpha: 0.34),
                            child: Center(
                              child: Icon(
                                Icons.album_rounded,
                                size: 56,
                                color: playerMuted(context),
                              ),
                            ),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.16),
                              blurRadius: 28,
                              offset: const Offset(0, 18),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        );

        if (wide) {
          return Center(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  cover,
                  const SizedBox(height: 18),
                  TrackChangeSwitcher(
                    transitionKey: metadataKey,
                    incomingOffset: const Offset(0.12, 0),
                    child: track == null
                        ? const SizedBox(height: 24)
                        : _AlbumMetadata(track: track),
                  ),
                ],
              ),
            ),
          );
        }

        // Compact: the cover hugs the top bar instead of floating in the
        // vertical center, and the mini lyrics sit in flow right below it,
        // centered. The album line is no longer shown here (the top bar
        // already carries the title and artist).
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(0, _compactAlbumTopPadding, 0, 12),
          child: SizedBox(
            width: constraints.maxWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                cover,
                if (reserveMiniLyrics) ...[
                  const SizedBox(height: 22),
                  SizedBox(
                    height: _miniLyricsSlotHeight,
                    child: showMiniLyrics
                        ? MiniLyricsPanel(onOpenLyrics: onOpenLyrics!)
                        : null,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LoadingAlbumArtwork extends ConsumerWidget {
  const _LoadingAlbumArtwork({required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final square = ref.watch(
      settingsProvider.select((settings) => settings.squareAlbumCoverEnabled),
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.22),
        shape: square ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: square
            ? BorderRadius.circular(size * kSquareCoverRadiusFactor)
            : null,
      ),
      alignment: Alignment.center,
      child: CircularProgressIndicator(
        color: playerInk(context),
        strokeWidth: 3,
      ),
    );
  }
}

class _AlbumMetadata extends StatelessWidget {
  const _AlbumMetadata({required this.track});

  final PlayerTrack track;

  @override
  Widget build(BuildContext context) {
    final album = track.album.trim().isEmpty ? '未知专辑' : track.album.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          album,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: playerMuted(context).withValues(alpha: 0.78),
            fontSize: 15,
            fontWeight: FontWeight.w500,
            height: 1.15,
          ),
        ),
      ],
    );
  }
}

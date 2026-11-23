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

/// Total inset subtracted from the album area's extent in the
/// phone-landscape capped sizing: the wide scroll view's 8dp top and
/// bottom padding doubles as the cover's breathing margin, so the
/// cover exactly fills the space between the paddings.
const double _wideFillCoverMargin = 16;

class AlbumPage extends ConsumerWidget {
  const AlbumPage({
    super.key,
    this.wide = false,
    this.onOpenLyrics,
    this.wideHeightFactor,
    this.wideMinCoverSize,
    this.wideShowMetadata = true,
    this.wideCoverCap,
  });

  final bool wide;
  final VoidCallback? onOpenLyrics;

  /// Wide-layout cover sizing overrides. Null keeps the car/tablet
  /// defaults (0.68 of the available height, at least 160dp).
  final double? wideHeightFactor;
  final double? wideMinCoverSize;

  /// Whether the wide layout shows the album-name line under the
  /// cover. The phone-landscape layout hides it so the cover can use
  /// the freed height; car/tablet keeps it.
  final bool wideShowMetadata;

  /// Phone-landscape sizing cap: when set, the cover side is the
  /// album area's smaller extent (less [_wideFillCoverMargin]) capped
  /// at this value, instead of the height-fraction sizing. The
  /// landscape layout passes half the screen's short side, so the cap
  /// itself is the deciding term on ordinary screens and applies
  /// exactly, with no margin subtracted from it. Round and square
  /// covers follow the same rule (the disc's diameter is the side
  /// length). Car/tablet never passes this and keeps the fraction
  /// sizing.
  final double? wideCoverCap;

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
    // The compact column is top-anchored with the cover first, so the
    // cover never shifts when the lyrics finish loading or the
    // mini-lyrics setting toggles.
    final reserveMiniLyrics =
        !wide && onOpenLyrics != null && miniLyricsEnabled;
    final showMiniLyrics = reserveMiniLyrics && player.miniLyricsReady;

    return LayoutBuilder(
      builder: (context, constraints) {
        final coverScale = square ? 1.12 : 1.0;
        final maxCoverSize = (wide ? 400.0 : 360.0) * coverScale;
        final coverCap = wide ? wideCoverCap : null;
        final coverSize = coverCap != null
            ? math.min(
                math.min(constraints.maxWidth, constraints.maxHeight) -
                    _wideFillCoverMargin,
                coverCap,
              )
            : math.min(
                maxCoverSize,
                math.min(
                      constraints.maxWidth * (wide ? 0.88 : 0.86),
                      constraints.maxHeight *
                          (wide ? (wideHeightFactor ?? 0.68) : 0.62),
                    ) *
                    coverScale,
              );
        final minCoverSize = wide ? (wideMinCoverSize ?? 160.0) : 160.0;
        final resolvedCoverSize = coverSize
            .clamp(minCoverSize, coverCap != null ? double.infinity : maxCoverSize)
            .toDouble();
        final metadataKey = track == null
            ? 'album-metadata:loading'
            : 'album-metadata:${track.id}:${track.album}';
        // The tap scaffold shared by every cover form: pull handle,
        // semantics, the tap-to-toggle gesture and the shared-element
        // anchor, wrapped around whatever visual the form shows.
        Widget coverScaffold(double size, Widget visual) {
          return SizedBox.square(
            dimension: size,
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
                  child: PlayerCoverAnchor(expanded: true, child: visual),
                ),
              ),
            ),
          );
        }

        Widget coverVisual(double size) {
          return track == null
              ? _LoadingAlbumArtwork(size: size)
              : SpinningCoverArt(
                  track: track,
                  size: size,
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
                );
        }

        final Widget cover;
        if (!wide && square) {
          // Square portrait: the artwork itself is part of the page
          // background now, so the cover page keeps only a transparent
          // tap target with the old poster's geometry — tap-to-toggle
          // and the shared-element anchor behave exactly as before.
          final hotZoneSize = math.min(
            constraints.maxWidth,
            constraints.maxHeight - 12,
          );
          cover = coverScaffold(hotZoneSize, const SizedBox.expand());
        } else if (!wide) {
          // Round portrait: the disc floats in the ambience on its
          // contact shadow alone — no cover-coloured halo, so the
          // background reads as one continuous layer.
          cover = coverScaffold(
            resolvedCoverSize,
            coverVisual(resolvedCoverSize),
          );
        } else {
          cover = coverScaffold(
            resolvedCoverSize,
            coverVisual(resolvedCoverSize),
          );
        }

        if (wide) {
          return Center(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              // When the cover (plus metadata) is shorter than the
              // scroll area — the capped landscape sizing leaves most
              // of the height empty — stretch the column to the padded
              // viewport height so the cover stays vertically centred
              // instead of hugging the top.
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight.isFinite
                      ? math.max(0, constraints.maxHeight - 16)
                      : 0,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    cover,
                    if (wideShowMetadata) ...[
                      const SizedBox(height: 18),
                      TrackChangeSwitcher(
                        transitionKey: metadataKey,
                        incomingOffset: const Offset(0.12, 0),
                        child: track == null
                            ? const SizedBox(height: 24)
                            : _AlbumMetadata(track: track),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }

        // Compact: the cover hugs the top bar instead of floating in the
        // vertical center, and the mini lyrics are centered in the space
        // left between the cover and the transport bar. The album line
        // is no longer shown here (the top bar already carries the title
        // and artist).
        return Padding(
          padding: EdgeInsets.fromLTRB(
            0,
            square ? 0 : _compactAlbumTopPadding,
            0,
            12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              cover,
              if (reserveMiniLyrics)
                Expanded(
                  child: Center(
                    child: showMiniLyrics
                        ? MiniLyricsPanel(onOpenLyrics: onOpenLyrics!)
                        : null,
                  ),
                ),
            ],
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

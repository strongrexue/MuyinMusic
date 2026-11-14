import 'package:flutter/material.dart';

import '../../../core/models/enums.dart';
import '../../../core/ui/cover_image_source.dart';
import '../../downloads/download_history_store.dart';
import '../../playlists/widgets/playlist_artwork.dart';

const double _railCoverSize = 128;
const double _railHeight = 208;

/// Horizontal shelf of songs used by 每日推荐 / 猜你喜欢 / 最近播放.
class HomeTrackRail extends StatelessWidget {
  const HomeTrackRail({
    super.key,
    required this.entries,
    required this.onPlay,
  });

  final List<DownloadHistoryEntry> entries;
  final ValueChanged<int> onPlay;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _railHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        physics: const BouncingScrollPhysics(),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) => HomeTrackCard(
          entry: entries[index],
          onTap: () => onPlay(index),
        ),
      ),
    );
  }
}

class HomeTrackCard extends StatelessWidget {
  const HomeTrackCard({super.key, required this.entry, required this.onTap});

  final DownloadHistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: _railCoverSize,
      height: _railCoverSize,
      color: scheme.secondaryContainer,
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note_rounded,
        color: scheme.onSecondaryContainer,
        size: 30,
      ),
    );
    return SizedBox(
      width: _railCoverSize,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: PlaylistTrackArtwork(
                localPath: entry.savedPath,
                picUrl: CoverImageSource.normalizeUrl(
                  entry.picUrl,
                  size: (_railCoverSize * 3).round(),
                ),
                size: _railCoverSize,
                radius: 18,
                placeholder: placeholder,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              entry.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              _subtitle(entry),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle(DownloadHistoryEntry entry) {
    final quality = entry.qualityCode.trim();
    final source = MusicSource.fromCode(entry.sourceCode);
    final label = entry.singer.trim();
    if (label.isNotEmpty) return label;
    if (quality.isNotEmpty) return quality.toUpperCase();
    return source.label;
  }
}

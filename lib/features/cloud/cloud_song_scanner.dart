import '../songs/local_song_scan_models.dart';
import 'cloud_drive2_client.dart';
import 'cloud_song_path.dart';

/// Audio extensions mirrored from the local scanner's whitelist
/// (`local_song_scanner.dart`), so cloud enumeration accepts the same files.
const Set<String> kCloudAudioExtensions = {
  'mp3',
  'flac',
  'm4a',
  'aac',
  'ogg',
  'wav',
  'ape',
  'wma',
};

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
}

String _parentOf(String fullPathName) {
  final slash = fullPathName.lastIndexOf('/');
  return slash > 0 ? fullPathName.substring(0, slash) : '/';
}

/// Maps one enumerated cloud file to the shared scan snapshot model.
/// Returns null for directories and non-audio files. The identity is the
/// virtual path; tags already known for an unchanged file are retained by
/// the caller through [LocalSongFileSnapshot.retainingMetadata].
LocalSongFileSnapshot? cloudFileToSnapshot(CloudFileItem item) {
  if (item.isDirectory) return null;
  final extension = _extensionOf(item.name);
  if (!kCloudAudioExtensions.contains(extension)) return null;
  if (item.fullPathName.isEmpty) return null;
  return LocalSongFileSnapshot(
    path: cloudDrive2VirtualPath(item.fullPathName),
    fileName: item.name,
    extension: extension,
    createdAt: item.createdAt,
    modifiedAt: item.modifiedAt,
    sizeBytes: item.sizeBytes,
    directory: _parentOf(item.fullPathName),
    contentHash: item.hash,
  );
}

/// Recursively enumerates a CloudDrive2 tree (starting at `/`) and returns
/// audio files as snapshot rows. A directory that fails to list is skipped
/// so one broken branch never fails the whole enumeration.
Future<List<LocalSongFileSnapshot>> enumerateCloudSongs(
  CloudDrive2Client client, {
  String rootPath = '/',
  int maxDepth = 12,
}) async {
  final out = <LocalSongFileSnapshot>[];
  final pending = <(String, int)>[(rootPath, 0)];
  final seenDirs = <String>{rootPath};
  while (pending.isNotEmpty) {
    final (dir, depth) = pending.removeLast();
    final List<CloudFileItem> items;
    try {
      items = await client.listFiles(dir);
    } catch (_) {
      continue;
    }
    for (final item in items) {
      if (item.isDirectory) {
        if (depth < maxDepth && seenDirs.add(item.fullPathName)) {
          pending.add((item.fullPathName, depth + 1));
        }
        continue;
      }
      final snapshot = cloudFileToSnapshot(item);
      if (snapshot != null) out.add(snapshot);
    }
  }
  return out;
}

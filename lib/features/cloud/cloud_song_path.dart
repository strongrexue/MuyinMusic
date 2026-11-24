/// Virtual path identity for cloud songs.
///
/// Cloud entries live in the same local-song index as files on disk, keyed by
/// a synthetic path: `cloud://cd2` + the file's CloudDrive2 `fullPathName`
/// (which itself starts with `/`, e.g. `cloud://cd2/115/Music/a.flac`).
/// The path is an identity string only — it is never opened as a file; the
/// remote path is recovered by stripping the prefix when talking to the API.
library;

const String kCloudDrive2PathPrefix = 'cloud://cd2';

bool isCloudSongPath(String path) => path.startsWith('$kCloudDrive2PathPrefix/');

/// Builds the virtual identity path for a CloudDrive2 `fullPathName`.
String cloudDrive2VirtualPath(String fullPathName) {
  final normalized = fullPathName.startsWith('/')
      ? fullPathName
      : '/$fullPathName';
  return '$kCloudDrive2PathPrefix$normalized';
}

/// Recovers the CloudDrive2 `fullPathName` from a virtual identity path.
String cloudDrive2RemotePath(String virtualPath) {
  if (!isCloudSongPath(virtualPath)) return virtualPath;
  return virtualPath.substring(kCloudDrive2PathPrefix.length);
}

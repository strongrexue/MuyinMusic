import 'package:path/path.dart' as p;

bool isContentLocation(String value) =>
    Uri.tryParse(value)?.scheme == 'content';

/// Compare document identity across overlapping tree grants without changing
/// the original URI used for I/O (which carries the grant).
String contentDocumentKey(String value) {
  final uri = Uri.parse(value);
  final segments = uri.pathSegments;
  final documentIndex = segments.indexOf('document');
  if (documentIndex < 0 || documentIndex + 1 >= segments.length) return value;
  final id = Uri.encodeComponent(segments[documentIndex + 1]);
  return 'content://${uri.authority}/document/$id';
}

// Content URIs are opaque identifiers, never filesystem paths.
String normalizeStorageLocation(String value) {
  final trimmed = value.trim();
  if (isContentLocation(trimmed)) return trimmed;
  final normalized =
      (trimmed.startsWith('/') ? p.posix : p.context).normalize(trimmed);
  // iOS/macOS: /var 是 /private/var 的符号链接，指向同一目录。path_provider
  // 与 UIDocumentPicker/FileManager 可能返回不同形态，统一到 /var 才能比较归属。
  if (normalized == '/private/var') return '/var';
  if (normalized.startsWith('/private/var/')) {
    return '/var/${normalized.substring('/private/var/'.length)}';
  }
  return normalized;
}

String storageLocationLabel(String value) {
  if (!isContentLocation(value)) return value;
  final uri = Uri.parse(value);
  return uri.pathSegments.lastOrNull ?? '已授权文件夹';
}

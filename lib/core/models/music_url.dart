import 'enums.dart';

class MusicUrl {
  const MusicUrl({required this.url, this.type, this.fileName, this.headers});

  final String url;
  final Quality? type;
  final String? fileName;

  /// HTTP headers the playback/download of [url] requires (e.g. a cloud
  /// drive's direct link UA + auth headers). Null when the URL is plain.
  final Map<String, String>? headers;

  factory MusicUrl.fromJson(Map<String, dynamic> json) => MusicUrl(
    url: (json['url'] as String?) ?? '',
    type: json['type'] is String
        ? Quality.fromCode(json['type'] as String)
        : null,
    fileName: normalizeResolvedFileName(json['fileName']),
    headers: _headersFromJson(json['headers']),
  );
}

Map<String, String>? _headersFromJson(Object? value) {
  if (value is! Map) return null;
  final headers = <String, String>{};
  for (final entry in value.entries) {
    final key = entry.key?.toString().trim() ?? '';
    final headerValue = entry.value?.toString().trim() ?? '';
    if (key.isNotEmpty && headerValue.isNotEmpty) headers[key] = headerValue;
  }
  return headers.isEmpty ? null : Map.unmodifiable(headers);
}

String? normalizeResolvedFileName(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  if (lower == 'null' || lower == 'undefined') return null;
  return trimmed;
}

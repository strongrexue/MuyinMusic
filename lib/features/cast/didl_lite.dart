/// DIDL-Lite metadata building and UPnP time formatting for AVTransport
/// SetAVTransportURI. Pure functions — unit-tested directly.
library;

/// Escapes the five XML predefined entities for text or attribute content.
String escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// Formats [duration] the UPnP way: `H:MM:SS` (hours not zero-padded).
String formatUpnpDuration(Duration duration) {
  final totalSeconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '$hours:${two(minutes)}:${two(seconds)}';
}

/// Parses an UPnP duration string (`H:MM:SS` or `H:MM:SS.mmm`).
/// Returns null for `NOT_IMPLEMENTED`, empty, or malformed values.
Duration? parseUpnpDuration(String? raw) {
  if (raw == null) return null;
  final value = raw.trim();
  if (value.isEmpty || value == 'NOT_IMPLEMENTED') return null;
  final parts = value.split(':');
  if (parts.length != 3) return null;
  final hours = int.tryParse(parts[0]);
  final minutes = int.tryParse(parts[1]);
  final secondsParts = parts[2].split('.');
  final seconds = int.tryParse(secondsParts[0]);
  if (hours == null || minutes == null || seconds == null) return null;
  var millis = 0;
  if (secondsParts.length > 1) {
    final fraction = secondsParts[1].padRight(3, '0').substring(0, 3);
    millis = int.tryParse(fraction) ?? 0;
  }
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: millis,
  );
}

/// Builds the DIDL-Lite document handed to SetAVTransportURI as
/// CurrentURIMetaData. [uri] is the stream URL the renderer should fetch.
String buildDidlLite({
  required String uri,
  required String title,
  String artist = '',
  String album = '',
  String? albumArtUri,
  Duration? duration,
}) {
  final buffer = StringBuffer()
    ..write(
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">',
    )
    ..write('<item id="0" parentID="-1" restricted="1">')
    ..write('<dc:title>${escapeXml(title)}</dc:title>');
  if (artist.trim().isNotEmpty) {
    buffer.write('<upnp:artist>${escapeXml(artist)}</upnp:artist>');
    buffer.write('<dc:creator>${escapeXml(artist)}</dc:creator>');
  }
  if (album.trim().isNotEmpty) {
    buffer.write('<upnp:album>${escapeXml(album)}</upnp:album>');
  }
  if (albumArtUri != null && albumArtUri.trim().isNotEmpty) {
    buffer.write(
      '<upnp:albumArtURI>${escapeXml(albumArtUri)}</upnp:albumArtURI>',
    );
  }
  buffer.write(
    '<upnp:class>object.item.audioItem.musicTrack</upnp:class>',
  );
  buffer.write('<res');
  if (duration != null && duration > Duration.zero) {
    buffer.write(' duration="${formatUpnpDuration(duration)}"');
  }
  buffer.write('>${escapeXml(uri)}</res>');
  buffer.write('</item></DIDL-Lite>');
  return buffer.toString();
}

import 'didl_lite.dart' show escapeXml;

/// A discovered UPnP MediaRenderer with the AVTransport / RenderingControl
/// control URLs resolved against the device description's base URL.
class DlnaDevice {
  const DlnaDevice({
    required this.udn,
    required this.friendlyName,
    required this.descriptionUrl,
    required this.avTransportControlUrl,
    this.modelName = '',
    this.manufacturer = '',
    this.renderingControlUrl,
  });

  final String udn;
  final String friendlyName;
  final String modelName;
  final String manufacturer;

  /// Where the device description was fetched from (its host identifies the
  /// device on the LAN for display purposes).
  final Uri descriptionUrl;
  final Uri avTransportControlUrl;
  final Uri? renderingControlUrl;

  String get host => descriptionUrl.host;

  /// Secondary line in the device picker: model name when known, else host.
  String get subtitle {
    final model = modelName.trim();
    if (model.isNotEmpty && model != friendlyName) return '$model · $host';
    return host;
  }

  @override
  bool operator ==(Object other) =>
      other is DlnaDevice && other.udn == udn;

  @override
  int get hashCode => udn.hashCode;
}

/// One parsed SSDP datagram (M-SEARCH response or NOTIFY).
class SsdpMessage {
  const SsdpMessage({required this.headers});

  /// Header names lower-cased.
  final Map<String, String> headers;

  String? get location => headers['location'];
  String? get usn => headers['usn'];
  String? get searchTarget => headers['st'] ?? headers['nt'];

  bool get isMediaRenderer {
    final target = searchTarget ?? '';
    return target.contains('MediaRenderer') ||
        target.contains('AVTransport');
  }
}

/// Parses a raw SSDP datagram. Returns null when it is not an HTTP-like
/// SSDP message carrying a LOCATION.
SsdpMessage? parseSsdpMessage(String raw) {
  final lines = raw.split(RegExp(r'\r\n|\n'));
  if (lines.isEmpty) return null;
  final first = lines.first.trim();
  if (!first.startsWith('HTTP/') && !first.startsWith('NOTIFY')) return null;
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    headers[line.substring(0, colon).trim().toLowerCase()] = line
        .substring(colon + 1)
        .trim();
  }
  if (headers['location'] == null || headers['location']!.isEmpty) {
    return null;
  }
  return SsdpMessage(headers: headers);
}

String? _tagText(String xml, String tag) {
  final match = RegExp(
    '<$tag(?:\\s[^>]*)?>(.*?)</$tag>',
    dotAll: true,
  ).firstMatch(xml);
  if (match == null) return null;
  return _unescapeXml(match.group(1)!.trim());
}

String _unescapeXml(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// Resolves a (possibly relative) control URL from a device description
/// against [base] per the UPnP spec.
Uri resolveUpnpUrl(Uri base, String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return base;
  return base.resolve(trimmed);
}

/// Parses a device description document fetched from [location].
/// Returns null when the document has no AVTransport service — the device
/// cannot be cast to. [baseOverride] is only for tests.
DlnaDevice? parseDeviceDescription(
  String xml, {
  required Uri location,
  Uri? baseOverride,
}) {
  final deviceSection = _extractDeviceSection(xml);
  if (deviceSection == null) return null;
  final friendlyName = _tagText(deviceSection, 'friendlyName');
  if (friendlyName == null || friendlyName.isEmpty) return null;
  final urlBaseText = _tagText(xml, 'URLBase');
  final base = baseOverride ??
      (urlBaseText != null && urlBaseText.isNotEmpty
          ? Uri.tryParse(urlBaseText) ?? location
          : location);

  Uri? avTransportUrl;
  Uri? renderingControlUrl;
  final servicePattern = RegExp(r'<service>(.*?)</service>', dotAll: true);
  for (final match in servicePattern.allMatches(deviceSection)) {
    final block = match.group(1)!;
    final type = _tagText(block, 'serviceType') ?? '';
    final control = _tagText(block, 'controlURL');
    if (control == null || control.isEmpty) continue;
    if (type.contains('AVTransport')) {
      avTransportUrl = resolveUpnpUrl(base, control);
    } else if (type.contains('RenderingControl')) {
      renderingControlUrl = resolveUpnpUrl(base, control);
    }
  }
  if (avTransportUrl == null) return null;
  return DlnaDevice(
    udn: _tagText(deviceSection, 'UDN') ?? location.toString(),
    friendlyName: friendlyName,
    modelName: _tagText(deviceSection, 'modelName') ?? '',
    manufacturer: _tagText(deviceSection, 'manufacturer') ?? '',
    descriptionUrl: location,
    avTransportControlUrl: avTransportUrl,
    renderingControlUrl: renderingControlUrl,
  );
}

/// The first `<device>…</device>` block (the root device; embedded devices
/// appear later and are ignored).
String? _extractDeviceSection(String xml) {
  final start = xml.indexOf('<device>');
  if (start < 0) return null;
  // The root device block contains a nested <deviceList> with its own
  // <device> elements; walk tags to find the matching close.
  var depth = 0;
  final tagPattern = RegExp(r'<(/?)device>');
  for (final match in tagPattern.allMatches(xml.substring(start))) {
    if (match.group(1) == '/') {
      depth--;
      if (depth == 0) {
        return xml.substring(start, start + match.end);
      }
    } else {
      depth++;
    }
  }
  return xml.substring(start);
}

/// Re-exported so SOAP/DIDL builders share one escaper.
String escapeXmlText(String value) => escapeXml(value);

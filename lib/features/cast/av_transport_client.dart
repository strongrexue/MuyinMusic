import 'dart:async';
import 'dart:io';

import 'didl_lite.dart';
import 'dlna_device.dart';

enum DlnaErrorKind { timeout, network, httpStatus, soapFault, malformed }

/// The only error type the cast layer raises; the session controller turns
/// it into user-facing state, so raw exceptions never reach the UI.
class DlnaException implements Exception {
  const DlnaException(this.kind, this.message, {this.statusCode, this.fault});

  final DlnaErrorKind kind;
  final String message;
  final int? statusCode;
  final String? fault;

  @override
  String toString() => 'DlnaException($kind): $message';
}

enum AvTransportPlaybackState {
  playing,
  paused,
  stopped,
  transitioning,
  noMedia,
  unknown,
}

AvTransportPlaybackState parseTransportState(String? raw) {
  switch ((raw ?? '').trim().toUpperCase()) {
    case 'PLAYING':
      return AvTransportPlaybackState.playing;
    case 'PAUSED_PLAYBACK':
    case 'PAUSED_RECORDING':
      return AvTransportPlaybackState.paused;
    case 'STOPPED':
      return AvTransportPlaybackState.stopped;
    case 'TRANSITIONING':
      return AvTransportPlaybackState.transitioning;
    case 'NO_MEDIA_PRESENT':
      return AvTransportPlaybackState.noMedia;
    default:
      return AvTransportPlaybackState.unknown;
  }
}

class DlnaPositionInfo {
  const DlnaPositionInfo({
    required this.trackDuration,
    required this.position,
    required this.trackUri,
  });

  final Duration trackDuration;
  final Duration position;
  final String trackUri;
}

class DlnaTransportInfo {
  const DlnaTransportInfo({required this.state, required this.rawState});

  final AvTransportPlaybackState state;
  final String rawState;
}

/// Extracts the text of the first element with local name [tag] from a SOAP
/// response, regardless of namespace prefix. Pure — unit-tested.
String? soapValue(String xml, String tag) {
  final match = RegExp(
    '<(?:[A-Za-z0-9_.-]+:)?$tag(?:\\s[^>]*)?>(.*?)</(?:[A-Za-z0-9_.-]+:)?$tag>',
    dotAll: true,
  ).firstMatch(xml);
  if (match == null) return null;
  final text = match.group(1)!.trim();
  return text
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

/// Minimal SOAP client for one renderer's AVTransport (and, when present,
/// RenderingControl) service.
class AvTransportClient {
  AvTransportClient(
    this.device, {
    this.timeout = const Duration(seconds: 8),
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final DlnaDevice device;
  final Duration timeout;
  final HttpClient Function() _clientFactory;

  static const _avTransportType =
      'urn:schemas-upnp-org:service:AVTransport:1';
  static const _renderingControlType =
      'urn:schemas-upnp-org:service:RenderingControl:1';

  Future<String> _invoke(
    Uri controlUrl,
    String serviceType,
    String action,
    Map<String, String> arguments,
  ) async {
    final args = StringBuffer();
    arguments.forEach((name, value) {
      args.write('<$name>${escapeXml(value)}</$name>');
    });
    final envelope =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$serviceType">$args</u:$action></s:Body>'
        '</s:Envelope>';
    final client = _clientFactory();
    try {
      client.connectionTimeout = timeout;
      final request = await client
          .postUrl(controlUrl)
          .timeout(timeout);
      request.headers
        ..contentType = ContentType('text', 'xml', charset: 'utf-8')
        ..set('SOAPAction', '"$serviceType#$action"');
      request.write(envelope);
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(const SystemEncoding().decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode == 200) return body;
      final fault =
          soapValue(body, 'faultstring') ?? soapValue(body, 'errorDescription');
      throw DlnaException(
        DlnaErrorKind.soapFault,
        '$action failed: HTTP ${response.statusCode}'
        '${fault == null ? '' : ' ($fault)'}',
        statusCode: response.statusCode,
        fault: fault,
      );
    } on DlnaException {
      rethrow;
    } on TimeoutException {
      throw DlnaException(DlnaErrorKind.timeout, '$action timed out');
    } on SocketException catch (error) {
      throw DlnaException(DlnaErrorKind.network, '$action: $error');
    } on HttpException catch (error) {
      throw DlnaException(DlnaErrorKind.network, '$action: $error');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> setAvTransportUri(String uri, String metadata) => _invoke(
    device.avTransportControlUrl,
    _avTransportType,
    'SetAVTransportURI',
    {'InstanceID': '0', 'CurrentURI': uri, 'CurrentURIMetaData': metadata},
  ).then((_) {});

  Future<void> play() => _invoke(device.avTransportControlUrl,
      _avTransportType, 'Play', {'InstanceID': '0', 'Speed': '1'}).then((_) {});

  Future<void> pause() => _invoke(device.avTransportControlUrl,
      _avTransportType, 'Pause', {'InstanceID': '0'}).then((_) {});

  Future<void> stop() => _invoke(device.avTransportControlUrl,
      _avTransportType, 'Stop', {'InstanceID': '0'}).then((_) {});

  Future<void> seek(Duration position) => _invoke(
    device.avTransportControlUrl,
    _avTransportType,
    'Seek',
    {
      'InstanceID': '0',
      'Unit': 'REL_TIME',
      'Target': formatUpnpDuration(position),
    },
  ).then((_) {});

  Future<DlnaTransportInfo> getTransportInfo() async {
    final body = await _invoke(
      device.avTransportControlUrl,
      _avTransportType,
      'GetTransportInfo',
      {'InstanceID': '0'},
    );
    final raw = soapValue(body, 'CurrentTransportState') ?? '';
    return DlnaTransportInfo(state: parseTransportState(raw), rawState: raw);
  }

  Future<DlnaPositionInfo> getPositionInfo() async {
    final body = await _invoke(
      device.avTransportControlUrl,
      _avTransportType,
      'GetPositionInfo',
      {'InstanceID': '0'},
    );
    return DlnaPositionInfo(
      trackDuration:
          parseUpnpDuration(soapValue(body, 'TrackDuration')) ?? Duration.zero,
      position:
          parseUpnpDuration(soapValue(body, 'RelTime')) ?? Duration.zero,
      trackUri: soapValue(body, 'TrackURI') ?? '',
    );
  }

  Future<int?> getVolume() async {
    final url = device.renderingControlUrl;
    if (url == null) return null;
    final body = await _invoke(url, _renderingControlType, 'GetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
    });
    return int.tryParse(soapValue(body, 'CurrentVolume') ?? '');
  }

  Future<void> setVolume(int volume) async {
    final url = device.renderingControlUrl;
    if (url == null) return;
    await _invoke(url, _renderingControlType, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '${volume.clamp(0, 100)}',
    });
  }
}

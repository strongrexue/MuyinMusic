import 'dart:async';
import 'dart:io';

import '../../core/services/app_logger.dart';
import 'cast_platform.dart';
import 'dlna_device.dart';

/// SSDP discovery for MediaRenderer devices.
///
/// Sends M-SEARCH for the MediaRenderer device type, the AVTransport
/// service type, and ssdp:all (filtered down to renderers), then fetches
/// and parses each responder's device description. Results stream out as
/// they are confirmed; call [cancel] to stop early.
class DlnaDiscovery {
  DlnaDiscovery({this.searchWindow = const Duration(seconds: 6)});

  final Duration searchWindow;

  static const _multicastAddress = '239.255.255.250';
  static const _ssdpPort = 1900;
  static const _searchTargets = [
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'urn:schemas-upnp-org:service:AVTransport:1',
    'ssdp:all',
  ];

  RawDatagramSocket? _socket;
  Timer? _resendTimer;
  Timer? _stopTimer;
  StreamController<DlnaDevice>? _controller;
  final _seenLocations = <String>{};
  final _seenUdNs = <String>{};
  bool _running = false;

  bool get running => _running;

  /// Starts a search; the returned stream emits each newly confirmed
  /// renderer once and closes when the search window ends.
  Stream<DlnaDevice> search() {
    cancel();
    _running = true;
    final controller = StreamController<DlnaDevice>();
    _controller = controller;
    unawaited(_run(controller));
    return controller.stream;
  }

  Future<void> _run(StreamController<DlnaDevice> controller) async {
    await CastPlatform.acquireMulticastLock();
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      _socket = socket;
      socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket.receive();
          if (datagram == null) return;
          _onDatagram(datagram);
        },
        onError: (Object error) {
          unawaited(AppLogger.write('dlna', 'socket error: $error'));
        },
      );
      _sendSearches(socket);
      _resendTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        final current = _socket;
        if (current != null) _sendSearches(current);
      });
      _stopTimer = Timer(searchWindow, () {
        if (_controller == controller) cancel();
      });
    } catch (error) {
      unawaited(AppLogger.write('dlna', 'search start failed: $error'));
      if (!controller.isClosed) controller.close();
      _running = false;
      await CastPlatform.releaseMulticastLock();
    }
  }

  void _sendSearches(RawDatagramSocket socket) {
    for (final target in _searchTargets) {
      final message =
          'M-SEARCH * HTTP/1.1\r\n'
          'HOST: $_multicastAddress:$_ssdpPort\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 3\r\n'
          'ST: $target\r\n'
          '\r\n';
      try {
        socket.send(
          message.codeUnits,
          InternetAddress(_multicastAddress),
          _ssdpPort,
        );
      } catch (_) {
        // One failed send must not kill the whole search.
      }
    }
  }

  void _onDatagram(Datagram datagram) {
    final message = parseSsdpMessage(
      String.fromCharCodes(datagram.data),
    );
    if (message == null || !message.isMediaRenderer) return;
    final location = message.location!;
    if (!_seenLocations.add(location)) return;
    unawaited(_fetchDevice(location));
  }

  Future<void> _fetchDevice(String location) async {
    final uri = Uri.tryParse(location);
    if (uri == null) return;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(
        'User-Agent',
        'UPnP/1.0 DLNADOC/1.50 PanghuMusic',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode != 200) return;
      final body = await response
          .transform(const SystemEncoding().decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      final device = parseDeviceDescription(body, location: uri);
      if (device == null) return;
      if (!_seenUdNs.add(device.udn)) return;
      final controller = _controller;
      if (controller != null && !controller.isClosed) {
        controller.add(device);
      }
    } catch (error) {
      unawaited(AppLogger.write('dlna', 'description fetch failed: $error'));
    } finally {
      client.close(force: true);
    }
  }

  void cancel() {
    _resendTimer?.cancel();
    _resendTimer = null;
    _stopTimer?.cancel();
    _stopTimer = null;
    _socket?.close();
    _socket = null;
    _seenLocations.clear();
    _seenUdNs.clear();
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) controller.close();
    if (_running) {
      _running = false;
      unawaited(CastPlatform.releaseMulticastLock());
    }
  }
}

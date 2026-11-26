import 'package:flutter_test/flutter_test.dart';

import 'package:panghu_music/features/cast/dlna_device.dart';

void main() {
  group('parseSsdpMessage', () {
    test('parses an M-SEARCH response for a MediaRenderer', () {
      final message = parseSsdpMessage(
        'HTTP/1.1 200 OK\r\n'
        'CACHE-CONTROL: max-age=1800\r\n'
        'LOCATION: http://192.168.50.139:49152/description.xml\r\n'
        'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
        'USN: uuid:abc-123::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
        '\r\n',
      );
      expect(message, isNotNull);
      expect(message!.location, 'http://192.168.50.139:49152/description.xml');
      expect(message.isMediaRenderer, isTrue);
    });

    test('ssdp:all responses are accepted and filtered by caller fields', () {
      final message = parseSsdpMessage(
        'HTTP/1.1 200 OK\r\n'
        'LOCATION: http://192.168.1.2:80/desc.xml\r\n'
        'ST: ssdp:all\r\n'
        '\r\n',
      );
      expect(message, isNotNull);
      expect(message!.isMediaRenderer, isFalse);
    });

    test('rejects datagrams without a location or HTTP shape', () {
      expect(parseSsdpMessage('NOTIFY * HTTP/1.1\r\nNT: upnp:event\r\n\r\n'),
          isNull);
      expect(parseSsdpMessage('garbage'), isNull);
      expect(parseSsdpMessage(''), isNull);
    });
  });

  group('parseDeviceDescription', () {
    const description = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <URLBase>http://192.168.50.139:49152/</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>小爱音箱-3298</friendlyName>
    <manufacturer>Xiaomi</manufacturer>
    <modelName>Mi AI Speaker</modelName>
    <UDN>uuid:9c1e-1234</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/AVTransport/control</controlURL>
        <eventSubURL>/AVTransport/event</eventSubURL>
        <SCPDURL>/AVTransport/scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/RenderingControl/control</controlURL>
        <eventSubURL>/RenderingControl/event</eventSubURL>
        <SCPDURL>/RenderingControl/scpd.xml</SCPDURL>
      </service>
    </serviceList>
  </device>
</root>
''';

    test('resolves services against URLBase', () {
      final device = parseDeviceDescription(
        description,
        location: Uri.parse('http://192.168.50.139:49152/description.xml'),
      );
      expect(device, isNotNull);
      expect(device!.friendlyName, '小爱音箱-3298');
      expect(device.modelName, 'Mi AI Speaker');
      expect(device.manufacturer, 'Xiaomi');
      expect(device.udn, 'uuid:9c1e-1234');
      expect(
        device.avTransportControlUrl.toString(),
        'http://192.168.50.139:49152/AVTransport/control',
      );
      expect(
        device.renderingControlUrl.toString(),
        'http://192.168.50.139:49152/RenderingControl/control',
      );
      expect(device.host, '192.168.50.139');
      expect(device.subtitle, 'Mi AI Speaker · 192.168.50.139');
    });

    test('falls back to the description location without URLBase', () {
      final xml = description.replaceAll(
        '<URLBase>http://192.168.50.139:49152/</URLBase>',
        '',
      );
      final device = parseDeviceDescription(
        xml,
        location: Uri.parse('http://192.168.50.139:49152/description.xml'),
      );
      expect(
        device!.avTransportControlUrl.toString(),
        'http://192.168.50.139:49152/AVTransport/control',
      );
    });

    test('returns null when the device has no AVTransport service', () {
      const xml = '''
<root><device>
<friendlyName>Router</friendlyName>
<UDN>uuid:r1</UDN>
<serviceList><service>
<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
<controlURL>/ctl</controlURL>
</service></serviceList>
</device></root>
''';
      expect(
        parseDeviceDescription(
          xml,
          location: Uri.parse('http://192.168.1.1/desc.xml'),
        ),
        isNull,
      );
    });

    test('absolute control URLs are kept as-is', () {
      final xml = description.replaceAll(
        '<controlURL>/AVTransport/control</controlURL>',
        '<controlURL>http://192.168.50.139:9999/avt</controlURL>',
      );
      final device = parseDeviceDescription(
        xml,
        location: Uri.parse('http://192.168.50.139:49152/description.xml'),
      );
      expect(
        device!.avTransportControlUrl.toString(),
        'http://192.168.50.139:9999/avt',
      );
    });
  });

  group('resolveUpnpUrl', () {
    test('resolves root-relative and plain relative paths', () {
      final base = Uri.parse('http://10.0.0.2:8080/dev/desc.xml');
      expect(
        resolveUpnpUrl(base, '/ctl').toString(),
        'http://10.0.0.2:8080/ctl',
      );
      expect(
        resolveUpnpUrl(base, 'ctl').toString(),
        'http://10.0.0.2:8080/dev/ctl',
      );
    });
  });
}

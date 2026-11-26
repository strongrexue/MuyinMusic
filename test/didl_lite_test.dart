import 'package:flutter_test/flutter_test.dart';

import 'package:panghu_music/features/cast/av_transport_client.dart';
import 'package:panghu_music/features/cast/didl_lite.dart';

void main() {
  group('escapeXml', () {
    test('escapes all five entities, ampersand first', () {
      expect(
        escapeXml('A & B <Live> "quoted" \'single\''),
        'A &amp; B &lt;Live&gt; &quot;quoted&quot; &apos;single&apos;',
      );
    });
  });

  group('buildDidlLite', () {
    test('builds a musicTrack item with escaped fields', () {
      final didl = buildDidlLite(
        uri: 'http://192.168.1.5:8080/r/abc?x=1&y=2',
        title: 'Song & Dance',
        artist: 'The <Band>',
        album: 'Greatest',
        albumArtUri: 'http://img.example.com/cover.jpg',
        duration: const Duration(minutes: 4, seconds: 21),
      );
      expect(didl, contains('<dc:title>Song &amp; Dance</dc:title>'));
      expect(didl, contains('<upnp:artist>The &lt;Band&gt;</upnp:artist>'));
      expect(didl, contains('<upnp:album>Greatest</upnp:album>'));
      expect(
        didl,
        contains(
          '<upnp:albumArtURI>http://img.example.com/cover.jpg</upnp:albumArtURI>',
        ),
      );
      expect(didl, contains('object.item.audioItem.musicTrack'));
      expect(
        didl,
        contains(
          '<res duration="0:04:21">http://192.168.1.5:8080/r/abc?x=1&amp;y=2</res>',
        ),
      );
    });

    test('omits empty optional fields and duration', () {
      final didl = buildDidlLite(uri: 'http://h/a.mp3', title: 'T');
      expect(didl, isNot(contains('upnp:artist')));
      expect(didl, isNot(contains('upnp:album')));
      expect(didl, isNot(contains('albumArtURI')));
      expect(didl, contains('<res>http://h/a.mp3</res>'));
    });
  });

  group('UPnP durations', () {
    test('formatUpnpDuration', () {
      expect(formatUpnpDuration(Duration.zero), '0:00:00');
      expect(
        formatUpnpDuration(const Duration(minutes: 4, seconds: 21)),
        '0:04:21',
      );
      expect(
        formatUpnpDuration(const Duration(hours: 2, minutes: 3, seconds: 5)),
        '2:03:05',
      );
    });

    test('parseUpnpDuration', () {
      expect(
        parseUpnpDuration('0:04:21'),
        const Duration(minutes: 4, seconds: 21),
      );
      expect(
        parseUpnpDuration('1:02:03.5'),
        const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500),
      );
      expect(parseUpnpDuration('NOT_IMPLEMENTED'), isNull);
      expect(parseUpnpDuration(''), isNull);
      expect(parseUpnpDuration(null), isNull);
      expect(parseUpnpDuration('4:21'), isNull);
    });
  });

  group('soapValue', () {
    test('extracts values regardless of namespace prefix', () {
      const body = '''
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
<s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<TrackDuration>0:04:21</TrackDuration>
<RelTime>0:01:02</RelTime>
<TrackURI>http://h/a.mp3?x=1&amp;y=2</TrackURI>
</u:GetPositionInfoResponse></s:Body></s:Envelope>
''';
      expect(soapValue(body, 'TrackDuration'), '0:04:21');
      expect(soapValue(body, 'RelTime'), '0:01:02');
      expect(soapValue(body, 'TrackURI'), 'http://h/a.mp3?x=1&y=2');
      expect(soapValue(body, 'Missing'), isNull);
    });

    test('parseTransportState maps renderer states', () {
      expect(
        parseTransportState('PLAYING'),
        AvTransportPlaybackState.playing,
      );
      expect(
        parseTransportState('PAUSED_PLAYBACK'),
        AvTransportPlaybackState.paused,
      );
      expect(
        parseTransportState('STOPPED'),
        AvTransportPlaybackState.stopped,
      );
      expect(
        parseTransportState('NO_MEDIA_PRESENT'),
        AvTransportPlaybackState.noMedia,
      );
      expect(parseTransportState('???'), AvTransportPlaybackState.unknown);
    });
  });
}

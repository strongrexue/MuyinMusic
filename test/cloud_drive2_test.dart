import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:bass_player/bass_player.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as pb_ts;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/models/music_url.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/cloud/cloud_drive2_client.dart';
import 'package:cy_shine_music/features/cloud/cloud_song_path.dart';
import 'package:cy_shine_music/features/cloud/cloud_song_scanner.dart';
import 'package:cy_shine_music/features/cloud/cloud_tag_reader.dart';
import 'package:cy_shine_music/features/cloud/proto/gen/clouddrive.pb.dart'
    as pb;
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/songs/local_song_scan_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseCloudDrive2Config', () {
    test('bare host gets the default port', () {
      final config = parseCloudDrive2Config('192.168.1.10', 'tok');
      expect(config, isNotNull);
      expect(config!.host, '192.168.1.10');
      expect(config.port, 19798);
      expect(config.useTls, isFalse);
    });

    test('explicit port and scheme are honored', () {
      final config = parseCloudDrive2Config('http://nas.local:21000/', 'tok');
      expect(config!.host, 'nas.local');
      expect(config.port, 21000);
      expect(config.useTls, isFalse);
      final tls = parseCloudDrive2Config('https://example.com', 'tok');
      expect(tls!.useTls, isTrue);
      // No explicit port: the CloudDrive2 default applies even for https.
      expect(tls.port, 19798);
    });

    test('empty server is unconfigured', () {
      expect(parseCloudDrive2Config('', 'tok'), isNull);
      expect(parseCloudDrive2Config('  ', 'tok'), isNull);
      // The parser itself stores a blank token as-is; the settings-level
      // `cloudDrive2Configured` check is what requires a non-empty token.
      expect(parseCloudDrive2Config('host', ' ')!.token, '');
    });
  });

  group('cloud virtual identity', () {
    test('round trips between virtual and remote paths', () {
      const remote = '/Music/Artist/Song.flac';
      final virtual = cloudDrive2VirtualPath(remote);
      expect(virtual, 'cloud://cd2/Music/Artist/Song.flac');
      expect(isCloudSongPath(virtual), isTrue);
      expect(isCloudSongPath('/Music/Artist/Song.flac'), isFalse);
      expect(cloudDrive2RemotePath(virtual), remote);
      // Snapshot keys keep cloud paths verbatim.
      expect(localSongPathKey(virtual), virtual);
    });
  });

  group('proto mapping and fingerprint', () {
    pb.CloudDriveFile file({
      String name = 'Song.flac',
      bool isDirectory = false,
      int size = 2048,
      Map<int, String>? hashes,
    }) {
      final created = DateTime.utc(2026, 1, 2, 3, 4, 5);
      return pb.CloudDriveFile(
        id: '42',
        name: name,
        fullPathName: '/Music/$name',
        isDirectory: isDirectory,
        size: Int64(size),
        createTime: pb_ts.Timestamp.fromDateTime(created),
        writeTime: pb_ts.Timestamp.fromDateTime(
          created.add(const Duration(hours: 1)),
        ),
        fileHashes: (hashes ?? const {1: 'md5value', 2: 'sha1value'}).entries,
      );
    }

    test('prefers md5 and converts timestamps', () {
      final item = cloudFileItemFromProto(file());
      expect(item.hash, 'md5value');
      expect(item.sizeBytes, 2048);
      expect(item.modifiedAt, DateTime.utc(2026, 1, 2, 4, 4, 5));
      expect(item.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('falls back to sha1, then to no hash', () {
      expect(
        cloudFileItemFromProto(file(hashes: const {2: 'sha1only'})).hash,
        'sha1only',
      );
      expect(cloudFileItemFromProto(file(hashes: const {})).hash, isNull);
    });

    test('snapshot mapping carries the hash into the fingerprint', () {
      final snapshot = cloudFileToSnapshot(cloudFileItemFromProto(file()))!;
      expect(snapshot.path, 'cloud://cd2/Music/Song.flac');
      expect(snapshot.contentHash, 'md5value');
      expect(snapshot.metadataRead, isFalse);
      expect(
        snapshot.fingerprint,
        '${snapshot.modifiedAt.microsecondsSinceEpoch}:2048:md5value',
      );
    });

    test('directories and non-audio files map to null', () {
      expect(
        cloudFileToSnapshot(
          cloudFileItemFromProto(file(name: 'Sub', isDirectory: true)),
        ),
        isNull,
      );
      expect(
        cloudFileToSnapshot(cloudFileItemFromProto(file(name: 'cover.jpg'))),
        isNull,
      );
    });

    test('fingerprint falls back to mtime:size without a hash', () {
      final snapshot = cloudFileToSnapshot(
        cloudFileItemFromProto(file(hashes: const {})),
      )!;
      expect(snapshot.contentHash, isNull);
      expect(
        snapshot.fingerprint,
        '${snapshot.modifiedAt.microsecondsSinceEpoch}:2048',
      );
    });
  });

  group('enumeration with a fake client', () {
    CloudFileItem item(String path, {bool dir = false}) {
      final name = path.split('/').last;
      return CloudFileItem(
        id: path,
        name: name,
        fullPathName: path,
        isDirectory: dir,
        sizeBytes: dir ? 0 : 100,
        createdAt: DateTime.utc(2026),
        modifiedAt: DateTime.utc(2026),
      );
    }

    test('walks folders, keeps audio only, tolerates failures', () async {
      final client = _FakeCloudDrive2Client({
        '/': [
          item('/Music', dir: true),
          item('/root.mp3'),
          item('/notes.txt'),
          item('/Broken', dir: true),
        ],
        '/Music': [item('/Music/a.flac'), item('/Music/b.mp3')],
      }, failing: {'/Broken'});
      final rows = await enumerateCloudSongs(client);
      expect(rows.map((row) => row.path), [
        'cloud://cd2/root.mp3',
        'cloud://cd2/Music/a.flac',
        'cloud://cd2/Music/b.mp3',
      ]);
    });
  });

  group('settings persistence', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('cloud drive2 fields default off and round trip', () async {
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      var settings = container.read(settingsProvider);
      expect(settings.cloudDrive2Enabled, isFalse);
      expect(settings.cloudDrive2Server, '');
      expect(settings.cloudDrive2Token, '');
      expect(settings.cloudDrive2Configured, isFalse);

      final notifier = container.read(settingsProvider.notifier);
      await notifier.setCloudDrive2Server('192.168.1.10:19798');
      await notifier.setCloudDrive2Token('token-123');
      await notifier.setCloudDrive2Enabled(true);

      settings = container.read(settingsProvider);
      expect(settings.cloudDrive2Enabled, isTrue);
      expect(settings.cloudDrive2Server, '192.168.1.10:19798');
      expect(settings.cloudDrive2Token, 'token-123');
      expect(settings.cloudDrive2Configured, isTrue);
      expect(prefs.getString('cloud_drive2_api_token'), 'token-123');
      expect(prefs.getBool('cloud_drive2_enabled'), isTrue);
    });
  });

  group('MusicUrl headers', () {
    test('parses the headers map and ignores junk', () {
      final url = MusicUrl.fromJson({
        'url': 'https://example.com/a.flac',
        'headers': {'User-Agent': 'CD2', 'X-Empty': ''},
      });
      expect(url.url, 'https://example.com/a.flac');
      expect(url.headers, {'User-Agent': 'CD2'});

      final bare = MusicUrl.fromJson({'url': 'https://example.com/b.flac'});
      expect(bare.headers, isNull);
    });
  });

  group('headers plumbing to the player backend', () {
    test('PlayerAudioHandler forwards headers to BassPlayer.load', () async {
      final player = _RecordingBassPlayer();
      final handler = PlayerAudioHandler(player: player);
      addTearDown(() async {
        await handler.stop();
      });

      await handler.load(
        item: const MediaItem(id: 'cloud-1', title: 'Cloud Song'),
        sourceUri: Uri.parse('https://example.com/song.flac'),
        headers: const {'User-Agent': 'CD2-UA', 'Referer': 'https://x'},
      );

      expect(player.lastUri.toString(), 'https://example.com/song.flac');
      expect(player.lastHeaders, {
        'User-Agent': 'CD2-UA',
        'Referer': 'https://x',
      });
    });
  });

  group('cloud tag reader', () {
    test('requests a byte range and tolerates non-audio payloads', () async {
      // flutter_test replaces HttpClient with a 400-returning mock; restore
      // the real client so the loopback server below actually gets hit.
      HttpOverrides.global = null;
      String? seenRange;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        seenRange = request.headers.value(HttpHeaders.rangeHeader);
        final bytes = List<int>.filled(1024, 7);
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-1023/1024')
          ..add(bytes);
        request.response.close();
      });

      final reader = CloudTagReader(
        resolveUrl: (remotePath) async => MusicUrl(
          url: 'http://${server.address.host}:${server.port}/song.flac',
        ),
      );
      final tags = await reader.readTags(
        LocalSongFileSnapshot(
          path: 'cloud://cd2/Music/Song.flac',
          fileName: 'Song.flac',
          extension: 'flac',
          createdAt: DateTime.utc(2026),
          modifiedAt: DateTime.utc(2026),
          sizeBytes: 1024,
        ),
      );
      expect(seenRange, startsWith('bytes=0-'));
      // Random bytes carry no tags; the reader must degrade to null.
      expect(tags, isNull);
    });
  });
}

class _FakeCloudDrive2Client implements CloudDrive2Client {
  _FakeCloudDrive2Client(this.tree, {this.failing = const {}});

  final Map<String, List<CloudFileItem>> tree;
  final Set<String> failing;

  @override
  Future<List<CloudFileItem>> listFiles(String path) async {
    if (failing.contains(path)) {
      throw StateError('simulated list failure');
    }
    return tree[path] ?? const [];
  }

  @override
  Future<MusicUrl> resolvePlayback(String remotePath) async =>
      MusicUrl(url: 'https://example.com$remotePath');

  @override
  Future<bool> checkConnection() async => true;

  @override
  Future<CloudConnectionResult> probeConnection() async =>
      const CloudConnectionResult(
        status: CloudConnectionStatus.connected,
        userName: 'tester',
        isLogin: true,
      );

  @override
  Future<void> close() async {}
}

class _RecordingBassPlayer extends BassPlayer {
  Uri? lastUri;
  Map<String, String>? lastHeaders;

  @override
  Future<BassEngineInfo> initialize() async => const BassEngineInfo(
    version: 'test',
    fxVersion: 'test',
    plugins: <String, String>{},
  );

  @override
  Future<Duration?> load(
    Uri uri, {
    Map<String, String> headers = const {},
    String? formatHint,
  }) async {
    lastUri = uri;
    lastHeaders = headers;
    return const Duration(minutes: 3);
  }
}

import 'package:grpc/grpc.dart';
import 'package:protobuf/well_known_types/google/protobuf/empty.pb.dart'
    as pbempty;

import '../../core/models/music_url.dart';
import 'proto/gen/clouddrive.pb.dart' as pb;
import 'proto/gen/clouddrive.pbgrpc.dart' as pbgrpc;

/// Connection settings for one CloudDrive2 server. The API token is only
/// ever placed in the gRPC `authorization` metadata header — it must never
/// be written to logs, analytics or test snapshots.
class CloudDrive2Config {
  const CloudDrive2Config({
    required this.host,
    required this.port,
    required this.useTls,
    required this.token,
  });

  final String host;
  final int port;
  final bool useTls;
  final String token;

  String get scheme => useTls ? 'https' : 'http';
  String get origin => '$scheme://$host:$port';
}

/// Parses a user-entered server address. Accepts `host`, `host:port`,
/// `http://host[:port]` and `https://host[:port]`; the port defaults to
/// CloudDrive2's 19798. Returns null when the input cannot be a server.
CloudDrive2Config? parseCloudDrive2Config(String server, String token) {
  var value = server.trim();
  if (value.isEmpty) return null;
  var useTls = false;
  final schemeMatch = RegExp(r'^(https?)://', caseSensitive: false).firstMatch(value);
  if (schemeMatch != null) {
    useTls = schemeMatch.group(1)!.toLowerCase() == 'https';
    value = value.substring(schemeMatch.end);
  }
  value = value.split('/').first.trim();
  if (value.isEmpty) return null;
  var host = value;
  var port = 19798;
  final colon = value.lastIndexOf(':');
  if (colon > 0) {
    final parsedPort = int.tryParse(value.substring(colon + 1));
    if (parsedPort == null || parsedPort <= 0 || parsedPort > 65535) {
      return null;
    }
    port = parsedPort;
    host = value.substring(0, colon);
  }
  if (host.isEmpty) return null;
  return CloudDrive2Config(
    host: host,
    port: port,
    useTls: useTls,
    token: token.trim(),
  );
}

/// One file or directory as reported by CloudDrive2 enumeration, already
/// mapped off the wire type so the scanner and tests never touch protobuf.
class CloudFileItem {
  const CloudFileItem({
    required this.id,
    required this.name,
    required this.fullPathName,
    required this.sizeBytes,
    required this.createdAt,
    required this.modifiedAt,
    required this.isDirectory,
    this.hash,
    this.thumbnailUrl,
  });

  final String id;
  final String name;
  final String fullPathName;
  final int sizeBytes;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final bool isDirectory;

  /// Content hash (MD5 preferred, SHA1 otherwise) used in the index
  /// fingerprint; null when the cloud did not report one.
  final String? hash;
  final String? thumbnailUrl;
}

CloudFileItem cloudFileItemFromProto(pb.CloudDriveFile file) {
  String? hashOf(int type) {
    final value = file.fileHashes[type];
    return (value == null || value.isEmpty) ? null : value;
  }

  return CloudFileItem(
    id: file.id,
    name: file.name,
    fullPathName: file.fullPathName,
    sizeBytes: file.size.toInt(),
    createdAt: file.hasCreateTime()
        ? file.createTime.toDateTime()
        : DateTime.fromMillisecondsSinceEpoch(0),
    modifiedAt: file.hasWriteTime()
        ? file.writeTime.toDateTime()
        : DateTime.fromMillisecondsSinceEpoch(0),
    isDirectory: file.isDirectory,
    // HashType: Md5 = 1, Sha1 = 2 (see trimmed proto).
    hash: hashOf(1) ?? hashOf(2),
    thumbnailUrl: file.thumbnailUrl.isEmpty ? null : file.thumbnailUrl,
  );
}

/// Outcome categories for a connection probe, so the settings page can
/// tell the user *why* a test failed instead of a bare yes/no.
enum CloudConnectionStatus { connected, unreachable, unauthorized, notReady }

/// Result of probing a CloudDrive2 server from the settings page.
class CloudConnectionResult {
  const CloudConnectionResult({
    required this.status,
    this.userName,
    this.isLogin = false,
  });

  final CloudConnectionStatus status;

  /// Account name reported by the server (GetSystemInfo), when available.
  final String? userName;
  final bool isLogin;

  bool get ok => status == CloudConnectionStatus.connected;

  /// User-facing summary shown inline on the settings page.
  String get message => switch (status) {
    CloudConnectionStatus.connected =>
      userName == null || userName!.isEmpty
          ? '连接成功'
          : '连接成功 · 账号 $userName',
    CloudConnectionStatus.unreachable => '无法连接到服务器，请检查地址与网络',
    CloudConnectionStatus.unauthorized => 'API 令牌无效或无访问权限',
    CloudConnectionStatus.notReady => '服务器尚未就绪，请稍后再试',
  };
}

/// The CloudDrive2 operations MuyinMusic depends on. Tests substitute a
/// fake implementation; production uses [GrpcCloudDrive2Client].
abstract interface class CloudDrive2Client {
  /// Lists one directory level (no recursion).
  Future<List<CloudFileItem>> listFiles(String path);

  /// Resolves a playable URL for [remotePath] at play/download time:
  /// the direct cloud URL (with its UA/headers) when available, otherwise
  /// the server-proxied `/static` URL.
  Future<MusicUrl> resolvePlayback(String remotePath);

  /// Lightweight reachability probe for the settings page.
  Future<bool> checkConnection();

  /// Full probe for the settings page's 测试连接 button: reachability and
  /// readiness via GetSystemInfo, then token validity via an authorized
  /// root listing (GetSystemInfo itself is a public, unauthenticated RPC,
  /// so it cannot detect a bad token on its own).
  Future<CloudConnectionResult> probeConnection();

  Future<void> close();
}

class GrpcCloudDrive2Client implements CloudDrive2Client {
  GrpcCloudDrive2Client(this.config);

  final CloudDrive2Config config;
  ClientChannel? _channel;
  pbgrpc.CloudDriveFileSrvClient? _client;

  pbgrpc.CloudDriveFileSrvClient get _service {
    final existing = _client;
    if (existing != null) return existing;
    final channel = ClientChannel(
      config.host,
      port: config.port,
      options: ChannelOptions(
        credentials: config.useTls
            ? const ChannelCredentials.secure()
            : const ChannelCredentials.insecure(),
        connectionTimeout: const Duration(seconds: 10),
      ),
    );
    _channel = channel;
    return _client = pbgrpc.CloudDriveFileSrvClient(channel);
  }

  CallOptions get _authOptions => CallOptions(
    metadata: {'authorization': 'Bearer ${config.token}'},
    timeout: const Duration(seconds: 30),
  );

  @override
  Future<List<CloudFileItem>> listFiles(String path) async {
    final items = <CloudFileItem>[];
    final stream = _service.getSubFiles(
      pb.ListSubFileRequest(path: path),
      options: _authOptions,
    );
    await for (final reply in stream) {
      for (final file in reply.subFiles) {
        if (file.isForbidden) continue;
        items.add(cloudFileItemFromProto(file));
      }
    }
    return items;
  }

  @override
  Future<MusicUrl> resolvePlayback(String remotePath) async {
    final info = await _service.getDownloadUrlPath(
      pb.GetDownloadUrlPathRequest(
        path: remotePath,
        preview: false,
        getDirectUrl: true,
      ),
      options: _authOptions,
    );
    final directUrl = info.hasDirectUrl() ? info.directUrl.trim() : '';
    if (directUrl.isNotEmpty) {
      return MusicUrl(
        url: directUrl,
        headers: {
          if (info.hasUserAgent() && info.userAgent.trim().isNotEmpty)
            'User-Agent': info.userAgent.trim(),
          ...info.additionalHeaders,
        },
      );
    }
    final pathPart = info.downloadUrlPath.trim();
    if (pathPart.isEmpty) {
      throw StateError('CloudDrive2 没有返回播放地址');
    }
    final assembled = pathPart
        .replaceAll('{SCHEME}', config.scheme)
        .replaceAll('{HOST}', '${config.host}:${config.port}')
        .replaceAll('{PREVIEW}', 'false');
    return MusicUrl(url: '${config.origin}$assembled');
  }

  @override
  Future<bool> checkConnection() async => (await probeConnection()).ok;

  @override
  Future<CloudConnectionResult> probeConnection() async {
    final pb.CloudDriveSystemInfo info;
    try {
      info = await _service.getSystemInfo(
        pbempty.Empty(),
        options: _authOptions,
      );
    } catch (error) {
      return CloudConnectionResult(status: _statusForError(error));
    }
    if (!info.systemReady) {
      return const CloudConnectionResult(
        status: CloudConnectionStatus.notReady,
      );
    }
    // GetSystemInfo needs no authorization; verify the token with an
    // authorized call so a wrong token is reported as such.
    try {
      await listFiles('/');
    } catch (error) {
      return CloudConnectionResult(status: _statusForError(error));
    }
    return CloudConnectionResult(
      status: CloudConnectionStatus.connected,
      userName: info.userName.isEmpty ? null : info.userName,
      isLogin: info.isLogin,
    );
  }

  CloudConnectionStatus _statusForError(Object error) {
    if (error is GrpcError) {
      return switch (error.code) {
        StatusCode.unauthenticated ||
        StatusCode.permissionDenied => CloudConnectionStatus.unauthorized,
        _ => CloudConnectionStatus.unreachable,
      };
    }
    return CloudConnectionStatus.unreachable;
  }

  @override
  Future<void> close() async {
    await _channel?.shutdown();
    _channel = null;
    _client = null;
  }
}

import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'mina_models.dart';

const String _kXiaomiTokenInfoKey = 'xiaomi_token_info_v1';

/// 安全存储抽象（沿用 WebDavSecretStore 的可注入模式，便于单测）。
abstract class XiaomiSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterXiaomiSecretStore implements XiaomiSecretStore {
  const FlutterXiaomiSecretStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// 小米登录产物的落盘与内存缓存。
///
/// 整个 [XiaomiTokenInfo] 以一段 JSON 存安全存储；只存 passToken
/// 与各 sid 的 serviceToken，**绝不存密码**。
class XiaomiTokenStore {
  XiaomiTokenStore(this._secrets);

  final XiaomiSecretStore _secrets;

  XiaomiTokenInfo? _cached;
  bool _loaded = false;

  /// 内存缓存（[load] / [save] 后有效）。
  XiaomiTokenInfo? get cached => _cached;

  Future<XiaomiTokenInfo?> load() async {
    if (_loaded) return _cached;
    _loaded = true;
    _cached = XiaomiTokenInfo.tryDecode(
      await _secrets.read(_kXiaomiTokenInfoKey),
    );
    return _cached;
  }

  Future<void> save(XiaomiTokenInfo tokens) async {
    _loaded = true;
    _cached = tokens;
    await _secrets.write(_kXiaomiTokenInfoKey, tokens.encode());
  }

  Future<void> clear() async {
    _loaded = true;
    _cached = null;
    await _secrets.delete(_kXiaomiTokenInfoKey);
  }

  /// 客户端 deviceId：已有登录产物时沿用其中的，否则生成新的
  /// 并以一份空产物落盘，保证跨重启一致（登录一致性关键）。
  Future<String> deviceId() async {
    final existing = await load();
    if (existing != null && existing.deviceId.isNotEmpty) {
      return existing.deviceId;
    }
    final generated = _generateDeviceId();
    await save(
      XiaomiTokenInfo(
        userId: existing?.userId ?? '',
        deviceId: generated,
        passToken: existing?.passToken ?? '',
        services: existing?.services ?? const {},
        createdAtMs:
            existing?.createdAtMs ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return generated;
  }

  /// 16 字节随机 hex（miot generateDeviceId）。
  static String _generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

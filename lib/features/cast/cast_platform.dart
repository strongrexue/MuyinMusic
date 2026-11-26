import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform hooks for DLNA discovery. Android needs a WifiManager
/// MulticastLock for SSDP responses to reach us while Wi-Fi power saving
/// is on; other platforms need nothing.
class CastPlatform {
  CastPlatform._();

  static const _channel = MethodChannel('panghu_music/dlna');
  static bool _lockHeld = false;

  static Future<void> acquireMulticastLock() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (_lockHeld) return;
    try {
      await _channel.invokeMethod<void>('acquireMulticastLock');
      _lockHeld = true;
    } on PlatformException {
      // Discovery can still work without the lock on many devices.
    } on MissingPluginException {
      // Older builds / tests: discovery proceeds unlocked.
    }
  }

  static Future<void> releaseMulticastLock() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (!_lockHeld) return;
    _lockHeld = false;
    try {
      await _channel.invokeMethod<void>('releaseMulticastLock');
    } on PlatformException {
      // Nothing to release natively; the flag above already dropped it.
    } on MissingPluginException {
      // See acquireMulticastLock.
    }
  }
}

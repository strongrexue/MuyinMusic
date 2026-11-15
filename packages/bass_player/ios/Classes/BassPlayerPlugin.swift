import Flutter
import UIKit

/// iOS placeholder for the BASS playback engine.
/// Methods succeed as a no-op until the AVAudioEngine / BASS-iOS engine lands,
/// so startup never sees a MissingPluginException. Dart's BassPlayer already
/// guards non-Android platforms and won't call these during bootstrap.
public class BassPlayerPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let methods = FlutterMethodChannel(name: "com.cyshine.music/bass_player/methods", binaryMessenger: registrar.messenger())
    let events = FlutterEventChannel(name: "com.cyshine.music/bass_player/events", binaryMessenger: registrar.messenger())
    let instance = BassPlayerPlugin()
    registrar.addMethodCallDelegate(instance, channel: methods)
    events.setStreamHandler(NoopStreamHandler())
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(nil)
  }
}

private class NoopStreamHandler: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { nil }
}

import Flutter
import UIKit

/// iOS placeholder for the BASS playback engine.
/// The real engine (AVAudioEngine or BASS iOS static libs) lands later;
/// for now every method reports `notImplemented` so the Dart side can
/// fall back to the pure-Dart audio path where possible.
public class BassPlayerPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let methods = FlutterMethodChannel(name: "com.cyshine.music/bass_player/methods", binaryMessenger: registrar.messenger())
    let instance = BassPlayerPlugin()
    registrar.addMethodCallDelegate(instance, channel: methods)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }
}

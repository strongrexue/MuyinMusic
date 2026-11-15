import Flutter
import UIKit

/// iOS placeholder for the forked audio_service plugin.
/// Registers both client/handler channels the Android side exposes and
/// answers `notImplemented` until the AVAudioSession implementation lands.
public class AudioServicePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = AudioServicePlugin()
    let client = FlutterMethodChannel(name: "com.ryanheise.audio_service.client.methods", binaryMessenger: registrar.messenger())
    let handler = FlutterMethodChannel(name: "com.ryanheise.audio_service.handler.methods", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: client)
    registrar.addMethodCallDelegate(instance, channel: handler)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }
}

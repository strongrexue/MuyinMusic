import Flutter
import UIKit

/// iOS placeholder for the QuickJS-backed LX source runtime.
/// Methods answer with `notImplemented` until the JavaScriptCore bridge lands.
public class MusicSourceRuntimePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "cy_shine_music/music_source_runtime", binaryMessenger: registrar.messenger())
    let instance = MusicSourceRuntimePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }
}

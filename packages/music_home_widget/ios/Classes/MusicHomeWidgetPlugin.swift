import Flutter
import UIKit

/// iOS placeholder for the home screen music widget.
/// Methods succeed as a no-op until the WidgetKit implementation lands;
/// the Dart service already skips non-Android platforms at startup.
public class MusicHomeWidgetPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "cy_shine_music/home_widget", binaryMessenger: registrar.messenger())
    let instance = MusicHomeWidgetPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(nil)
  }
}

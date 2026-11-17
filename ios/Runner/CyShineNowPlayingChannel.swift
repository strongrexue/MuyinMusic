import Flutter
import Foundation
import MediaPlayer
import UIKit

/// 独立的系统媒体播放卡片通道，只写 MPNowPlayingInfoCenter。
/// 与灵动岛（Live Activity / ActivityKit）完全解耦，无 @available 限制：
/// 巨魔侧载 / iOS 16.x 下 Live Activity 不可用时，这条通道仍能让系统在
/// 灵动岛与锁屏画出标准媒体播放卡片（与胖虎音乐同一套机制）。
final class CyShineNowPlayingChannel: NSObject {
  static let channelName = "cy_shine_music/now_playing"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "publish",
            let a = call.arguments as? [String: Any],
            let title = a["title"] as? String, !title.isEmpty else {
        result(false)
        return
      }
      var info: [String: Any] = [
        MPMediaItemPropertyTitle: title,
        MPMediaItemPropertyArtist: (a["artist"] as? String) ?? "",
        MPNowPlayingInfoPropertyPlaybackRate:
          ((a["playing"] as? Bool) ?? false) ? 1.0 : 0.0,
        MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      ]
      let dur = (a["durationMs"] as? NSNumber)?.doubleValue ?? 0
      let pos = (a["positionMs"] as? NSNumber)?.doubleValue ?? 0
      if dur > 0 { info[MPMediaItemPropertyPlaybackDuration] = dur / 1000 }
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = pos / 1000
      if let cover = a["cover"] as? String, cover.hasPrefix("file://"),
         let url = URL(string: cover),
         let data = try? Data(contentsOf: url),
         let image = UIImage(data: data) {
        info[MPMediaItemPropertyArtwork] =
          MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
      result(true)
    }
  }
}

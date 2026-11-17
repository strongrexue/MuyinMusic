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
      // 关键：在现有 nowPlayingInfo 上合并，而不是整字典覆盖。
      // audio_service 也会写这个中心（artwork / duration / 播放速率等），
      // 直接赋新字典会把它写的完整字段冲掉，导致锁屏/灵动岛卡片不出。
      // 现有字典可能为 nil（首次播放），此时初始化为空字典。
      let center = MPNowPlayingInfoCenter.default()
      var info = center.nowPlayingInfo ?? [String: Any]()
      info[MPMediaItemPropertyTitle] = title
      info[MPMediaItemPropertyArtist] = (a["artist"] as? String) ?? ""
      info[MPNowPlayingInfoPropertyPlaybackRate] =
        ((a["playing"] as? Bool) ?? false) ? 1.0 : 0.0
      info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
      info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
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
      center.nowPlayingInfo = info
      result(true)
    }
  }
}

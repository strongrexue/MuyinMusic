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

  // MPRemoteCommand 的 addTarget 不持有 target，必须自己强引用，否则命令失效。
  private static var commandTargets: [Any] = []
  private static var commandChannel: FlutterMethodChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    commandChannel = channel
    setupRemoteCommands()
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
      // 封面：file:// 缓存优先，http(s) 网络兜底，裸路径也支持。
      // audio_service 写的 artwork 常不可靠，这里按 Dart 传入的 cover 自己补一份。
      if let cover = a["cover"] as? String, !cover.isEmpty,
         let image = Self.artworkImage(cover: cover, args: a) {
        info[MPMediaItemPropertyArtwork] =
          MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      }
      center.nowPlayingInfo = info
      // 五角星实心/空心随喜欢状态刷新；并重新 enable（audio_service 初始化时会
      // 把 likeCommand/dislikeCommand 置 NO，这里每次写入都覆盖回来）。
      Self.syncLikeState(liked: (a["liked"] as? Bool) ?? false)
      result(true)
    }
  }

  /// 注册 like/dislike 远程命令，点击后回调 Dart 切换喜欢（不打开 App）。
  private static func setupRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    commandTargets.removeAll()

    let like = center.likeCommand
    like.isEnabled = true
    let likeTarget: Any = like.addTarget { _ in
      commandChannel?.invokeMethod("toggleLike", arguments: nil)
      return .success
    }
    commandTargets.append(likeTarget)

    let dislike = center.dislikeCommand
    dislike.isEnabled = true
    let dislikeTarget: Any = dislike.addTarget { _ in
      commandChannel?.invokeMethod("toggleLike", arguments: nil)
      return .success
    }
    commandTargets.append(dislikeTarget)
  }

  /// audio_service 在启动时会 disable like/dislike，这里覆盖回来并同步实心/空心。
  private static func syncLikeState(liked: Bool) {
    let center = MPRemoteCommandCenter.shared()
    let like = center.likeCommand
    like.isEnabled = true
    like.active = liked
    let dislike = center.dislikeCommand
    dislike.isEnabled = true
  }

  /// 按 cover 取封面图，支持 file:// / http(s) / 裸路径。
  /// 网络下载带 12s 超时 + semaphore，避免卡住主线程上的媒体信息写入。
  private static func artworkImage(cover: String, args: [String: Any]) -> UIImage? {
    let headers = (args["headers"] as? [String: Any])?
      .reduce(into: [String: String]()) { acc, e in acc[e.key] = String(describing: e.value) } ?? [:]

    let data: Data?
    if cover.hasPrefix("file://"), let url = URL(string: cover) {
      data = try? Data(contentsOf: url)
    } else if let url = URL(string: cover), url.scheme?.hasPrefix("http") == true {
      data = downloadSynchronously(url: url, headers: headers)
    } else {
      data = try? Data(contentsOf: URL(fileURLWithPath: cover))
    }
    guard let data else { return nil }
    return UIImage(data: data)
  }

  private static func downloadSynchronously(url: URL, headers: [String: String]) -> Data? {
    // 这个方法在主线程的方法通道回调里调用，semaphore 等待会冻结 UI。
    // 用短超时 + 专用 session，取不到就放弃（音频继续播，封面交给 audio_service）。
    var request = URLRequest(url: url)
    request.timeoutInterval = 2
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let semaphore = DispatchSemaphore(value: 0)
    var output: Data?
    URLSession.shared.dataTask(with: request) { data, _, _ in
      output = data
      semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 2.5)
    return output
  }
}

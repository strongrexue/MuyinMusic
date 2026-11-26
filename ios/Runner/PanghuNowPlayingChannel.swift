import Flutter
import Foundation
import MediaPlayer
import UIKit
import AVFoundation

/// 独立的系统媒体播放卡片通道，只写 MPNowPlayingInfoCenter。
/// 与灵动岛（Live Activity / ActivityKit）完全解耦，无 @available 限制：
/// 巨魔侧载 / iOS 16.x 下 Live Activity 不可用时，这条通道仍能让系统在
/// 灵动岛与锁屏画出标准媒体播放卡片（与胖虎音乐同一套机制）。
final class PanghuNowPlayingChannel: NSObject {
  static let channelName = "panghu_music/now_playing"

  // MPRemoteCommand 的 addTarget 不持有 target，必须自己强引用，否则命令失效。
  private static var commandTargets: [Any] = []
  private static var commandChannel: FlutterMethodChannel?

  // 封面单一持有：artwork 字段只由本通道写（audio_service 插件已停写）。
  // lastArtTrackId 记住封面归属的曲目，换歌未就绪时清图防串图；
  // artImageCache 按本地路径缓存解码结果，避免重复读盘。
  private static var lastArtTrackId: String?
  private static var artImageCache: [String: UIImage] = [:]

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    commandChannel = channel
    setupRemoteCommands()
    channel.setMethodCallHandler { call, result in
      // 「启用灵动岛」关闭时 Dart 调 clear：整卡清掉并标记停止，
      // 否则已画出的灵动岛/锁屏卡会一直残留。
      if call.method == "clear" {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        lastArtTrackId = nil
        artImageCache.removeAll()
        result(true)
        return
      }
      guard call.method == "publish",
            let a = call.arguments as? [String: Any],
            let title = a["title"] as? String, !title.isEmpty else {
        result(false)
        return
      }
      // ★ 写卡前确保 AVAudioSession 已激活：这是探针能出卡、正常播放不能出卡的
      //   唯一差异。BASS 只在初始化时 setActive 一次且失败被吞，冷启动常没激活；
      //   系统对未激活 session 的 App 不画锁屏卡，即使 nowPlayingInfo 写全也没用。
      //   setCategory/setActive 幂等，BASS 播放中重复调用安全；与探针 :940-941 同款。
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
      } catch {
        NSLog("[nowPlaying] session 激活失败: %@", "\(error)")
      }

      // 关键：在现有 nowPlayingInfo 上合并，而不是整字典覆盖。
      // audio_service 也会写这个中心（album / duration 等），
      // 直接赋新字典会把它写的字段冲掉，导致锁屏/灵动岛卡片不出。
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
      // 封面只认 Dart 给的本地文件路径（artPath），原生侧不再下载网络图：
      // 同步下载曾冻结通道线程、把每行歌词的推送都拖慢数秒。
      Self.applyArtwork(into: &info, args: a)
      center.nowPlayingInfo = info
      // BASS 自研引擎输出不像 AVAudioPlayer 那样被系统天然认作媒体源，必须显式
      // 标记播放态锁屏卡才出现（探针 systemPlayerProbe 即靠这一句 + nowPlayingInfo
      // 画出卡）。飞牛/官方走系统播放器无需此标记，故此前对照里看不出它的必要性。
      center.playbackState = ((a["playing"] as? Bool) ?? false) ? .playing : .paused
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
    like.isActive = liked
    let dislike = center.dislikeCommand
    dislike.isEnabled = true
  }

  /// 封面写入：artTrackId 标识封面归属的曲目。
  /// - 换歌：有本地图就换上；还没就绪（artPath 空）先清掉封面字段，
  ///   绝不留上一首的图串到新歌上，等图就绪后 Dart 会单独补推。
  /// - 同一首：带了 artPath 就补上/更新（图迟到就绪走这里）；
  ///   没带 artPath 的纯歌词/进度更新不动现有封面。
  /// - 载荷没有 artTrackId（老版本 Dart）：整体不动封面。
  private static func applyArtwork(into info: inout [String: Any], args: [String: Any]) {
    guard let artTrackId = args["artTrackId"] as? String else { return }
    let artPath = (args["artPath"] as? String) ?? ""
    if artTrackId != lastArtTrackId {
      if !artPath.isEmpty, let image = cachedImage(path: artPath) {
        info[MPMediaItemPropertyArtwork] =
          MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      } else {
        info.removeValue(forKey: MPMediaItemPropertyArtwork)
      }
      lastArtTrackId = artTrackId
    } else if !artPath.isEmpty, let image = cachedImage(path: artPath) {
      info[MPMediaItemPropertyArtwork] =
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
  }

  /// 只从本地文件读图，按路径缓存解码结果；读不到返回 nil。
  /// 通道线程上不做任何网络请求和等待。
  private static func cachedImage(path: String) -> UIImage? {
    if let cached = artImageCache[path] { return cached }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let image = UIImage(data: data) else { return nil }
    if artImageCache.count > 8 { artImageCache.removeAll() }
    artImageCache[path] = image
    return image
  }
}

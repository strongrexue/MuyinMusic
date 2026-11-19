// CyShineMusic iOS —— BASS 播放引擎插件。
//
// 与 Android 端 packages/bass_player/android/.../BassPlayerPlugin.kt 保持完全相同的
// 对外契约：
//   MethodChannel  com.cyshine.music/bass_player/methods
//     initialize / load / play / pause / stop / seek / setVolume / setEqualizer / dispose
//   EventChannel   com.cyshine.music/bass_player/events
//     {event:"snapshot"|"error", playing, processingState, positionMs,
//      bufferedPositionMs, durationMs, [errorCode, bassCode, errorMessage, operation]}
//   错误码格式 BASS_<int>（dart 侧 BassPlayerException 用正则 ^BASS_(-?\d+)$ 解析）
//
// 因为契约一致，lib/ 与 packages/bass_player/lib/bass_player.dart 都不需要改动。

import AVFAudio
import Flutter
import Foundation
import UIKit
import CBass

public final class BassPlayerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

  // MARK: - 通道名

  private static let methodChannelName = "com.cyshine.music/bass_player/methods"
  private static let eventChannelName = "com.cyshine.music/bass_player/events"

  // MARK: - 状态常量（与 Android 端逐字对应）

  private enum PlaybackState: String {
    case idle, loading, buffering, ready, completed, error
  }

  /// load 被新的 load/stop/dispose 取代时使用。与 Android 端 CANCELLED 常量一致。
  /// 必须显式声明成 Int32：BassError.code 是 Int32，否则字面量会被推成 Int 而报类型错。
  private static let cancelledCode: Int32 = -1000

  // MARK: - 插件入口

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BassPlayerPlugin()
    let messenger = registrar.messenger()
    let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak instance] call, result in
      instance?.handleCall(call, result: result)
    }
    events.setStreamHandler(instance)
    // 让 instance 活到 engine 卸载为止。
    registrar.publish(instance)
  }

  // MARK: - 内部状态

  /// 所有 BASS 调用都在这条串行队列上执行，等价于 Android 端的 engineThread。
  private let engineQueue = DispatchQueue(label: "com.cyshine.music.bass.engine")

  private let sinkLock = NSLock()
  private var eventSink: FlutterEventSink?

  private var initialized = false
  private var stream: HSTREAM = 0
  private var remoteSource = false
  /// HTTP Range 随机访问数据源（网络流）。强引用，生命周期跟随 stream：
  /// BASS 的 FILEPROCS 回调以 user 指针引用它，stream 存活期间不能被释放。
  private var httpSource: ProgressiveHttpSource?
  private var playing = false
  private var completed = false
  private var processingState: PlaybackState = .idle
  private var durationMs: Int?
  /// iOS 无 Android 的 ProgressiveHttpSource，用这组字段缓存"目标未缓冲"的 seek，
  /// 等下载推进后由 ticker 重试落位（对齐 Android pendingSeekMs 机制）。
  private var pendingSeekMs: Int?
  private var pendingSeekPlay = false
  private var pendingSeekOriginMs = 0
  /// 待落位 seek 的放弃截止时间（epoch ms）。超时后回退到 origin 并恢复播放，
  /// 杜绝"进度显示对但永久卡死"。对齐 Android SEEK_ATTEMPT_BUDGET_MS=2000。
  private var pendingSeekDeadline: Double = 0
  private static let seekAttemptBudgetMs: Double = 2_000
  /// 按码率配置网络流缓冲（对齐 Android 的 START/RESUME_BUFFER_SECONDS 与 MIN/MAX）。
  private static let startBufferSeconds = 2.0
  private static let resumeBufferSeconds = 5.0
  private static let minBufferBytes: Int64 = 32 * 1024
  private static let maxBufferBytes: Int64 = 8 * 1024 * 1024
  private static let fallbackBytesPerSecond = 40_000.0
  private var startBufferBytes: Int64 = 256 * 1024
  private var channelVolume: Float = 1.0
  private var bassVersion = "unknown"
  private var fxVersion = "unknown"
  private var pluginVersions: [String: String] = [:]

  /// 用于取消进行中的 load（Android 端用 AtomicInteger 生成号做同一件事）。
  private var loadGeneration = 0

  private var endSync: HSYNC = 0
  private var stallSync: HSYNC = 0
  private var downloadSync: HSYNC = 0
  private var deviceFailureSync: HSYNC = 0

  private var eqChain: OpaquePointer?
  private var eqDsp: HDSP = 0
  private var currentEq: [String: Any]?

  private var tickTimer: DispatchSourceTimer?
  private let audioSessionQueue = DispatchQueue(label: "com.cyshine.music.bass.session")

  // MARK: - 通道回调

  /// 注意：不要把这个方法命名成 `handle(_:result:)`。
  /// Flutter 的 `FlutterPlugin` 协议里有一个可选要求就叫这个名字，撞名会被编译器
  /// 当成「实现了协议要求」，进而报出一串莫名其妙的错误。
  private func handleCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {

    case "initialize":
      engineQueue.async {
        do {
          let value = try self.initializeEngine()
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "load":
      guard let args = call.arguments as? [String: Any],
            let uri = args["uri"] as? String, !uri.isEmpty else {
        result(FlutterError(code: "BASS_ARGUMENT", message: "uri is required", details: nil))
        return
      }
      var headers: [String: String] = [:]
      if let raw = args["headers"] as? [String: Any] {
        for (key, value) in raw { headers[key] = String(describing: value) }
      }
      let formatHint = args["formatHint"] as? String
      engineQueue.async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        do {
          let value = try self.load(uri, headers: headers, formatHint: formatHint,
                                    generation: generation)
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "play":
      engineQueue.async {
        do {
          let value = try self.play()
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "pause":
      engineQueue.async {
        do {
          let value = try self.pause()
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "stop":
      engineQueue.async {
        self.loadGeneration += 1
        do {
          let value = try self.stop()
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "seek":
      let positionMs = (call.arguments as? [String: Any])?["positionMs"] as? Int ?? 0
      engineQueue.async {
        do {
          let value = try self.seek(positionMs)
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "setVolume":
      let volume = (call.arguments as? [String: Any])?["volume"] as? Double ?? 1.0
      engineQueue.async {
        do {
          let value = try self.setVolume(Float(volume))
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "setEqualizer":
      let configuration = call.arguments as? [String: Any] ?? [:]
      engineQueue.async {
        do {
          let value = try self.setEqualizer(configuration)
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(BassPlayerPlugin.flutterError(error)) }
        }
      }

    case "dispose":
      engineQueue.async {
        self.loadGeneration += 1
        self.disposeEngine()
        DispatchQueue.main.async { result([String: Any?]()) }
      }

    // ---- 沐音特有方法（蓝本无）。Dart 侧 BassPlayer 会调用，iOS 不提供对应
    // 能力时返回空值即可，避免 MissingPluginException 中断播放路径。----
    case "setDiagnosticRecording":
      // Dart _initialize() 无条件调用；iOS 暂无诊断层，回空配置即可。
      result(["diagnostics": false, "smartTransition": false])

    case "getDiagnostics":
      result(["lines": []])

    case "setGrooveShift":
      result([String: Any?]())

    case "setGrooveShiftNext":
      result([String: Any?]())

    case "confirmGrooveShift":
      result([String: Any?]())

    case "cancelGrooveShift":
      result([String: Any?]())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 与 Android 的 postResult 对齐：BassError -> "BASS_<code>" + {operation, bassCode}；
  /// 其它错误 -> "BASS_NATIVE" + 当前 BASS_ErrorGetCode()。
  ///
  /// 刻意写成「调用点各自 do/catch」而不是「接 throwing 闭包的 helper」：
  /// Swift 在 DispatchQueue.async 嵌套里会把 throwing 尾随闭包误判成非 throwing，
  /// 报一串 "Call can throw, but it is not marked with 'try'"。
  static func flutterError(_ error: Error) -> FlutterError {
    if let failure = error as? BassError {
      return FlutterError(code: "BASS_\(failure.code)",
                          message: failure.message,
                          details: ["operation": failure.operation,
                                    "bassCode": failure.code])
    }
    let code = Int(BASS_ErrorGetCode())
    return FlutterError(code: "BASS_NATIVE",
                        message: "\(error)",
                        details: ["operation": "native", "bassCode": code])
  }

  // MARK: - EventChannel

  public func onListen(withArguments arguments: Any?,
                       eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sinkLock.lock()
    eventSink = events
    sinkLock.unlock()
    engineQueue.async { self.emitSnapshot() }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sinkLock.lock()
    eventSink = nil
    sinkLock.unlock()
    return nil
  }

  private func send(_ payload: [String: Any?]) {
    sinkLock.lock()
    let sink = eventSink
    sinkLock.unlock()
    guard let sink else { return }
    DispatchQueue.main.async { sink(payload) }
  }

  // MARK: - 引擎初始化

  private func initializeEngine() throws -> [String: Any?] {
    if initialized { return engineInfo() }

    try configureAudioSession()

    let rawVersion = BASS_GetVersion()
    bassVersion = BassPlayerPlugin.versionString(rawVersion)
    if (rawVersion >> 16) != UInt32(BASSVERSION) {
      throw BassError(code: -1, operation: "initialize",
                      message: "BASS API 2.4 与原生库 \(bassVersion) 不匹配")
    }
    // iOS 上没有 BASS_FX：均衡器由内置 biquad DSP 实现，这里如实上报。
    fxVersion = "builtin-biquad"

    _ = BASS_SetConfig(UInt32(BASS_CONFIG_BUFFER), 500)
    _ = BASS_SetConfig(UInt32(BASS_CONFIG_UPDATEPERIOD), 50)
    _ = BASS_SetConfig(UInt32(BASS_CONFIG_NET_TIMEOUT), 15_000)
    _ = BASS_SetConfig(UInt32(BASS_CONFIG_NET_BUFFER), 60_000)
    _ = BASS_SetConfig(UInt32(BASS_CONFIG_NET_PREBUF), 20)
    _ = BASS_SetConfig(UInt32(BASS_CONFIG_FLOATDSP), 1)

    // device = -1 表示默认设备；Apple 平台不需要额外的 win/clsid。
    if BASS_Init(-1, 44_100, 0, nil, nil) == 0 {
      throw BassError.fromLastError(operation: "initialize output")
    }
    initialized = true

    // 这些附加库是以动态 framework 形式链接进来的，链接成功即代表可用。
    // 附加库本身没有独立的 GetVersion 入口（那是 BASS_FX 才有），这里上报核心版本。
    pluginVersions["flac"] = bassVersion
    pluginVersions["ape"] = bassVersion
    pluginVersions["wv"] = bassVersion
    pluginVersions["opus"] = bassVersion
    pluginVersions["dsd"] = bassVersion
    // ALAC / AAC 在 Apple 平台由 BASS 核心走系统解码器，没有独立版本号可读。
    pluginVersions["alac"] = "core (CoreAudio)"

    processingState = .idle
    emitSnapshot()
    return engineInfo()
  }

  private func engineInfo() -> [String: Any?] {
    ["version": bassVersion, "fxVersion": fxVersion, "plugins": pluginVersions]
  }

  private func configureAudioSession() throws {
    // 后台播放 + 锁屏控制依赖 .playback；audio_service 会在 Dart 侧接管
    // NowPlayingInfo，这里只负责把 session 建起来。
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
    } catch {
      // 不起音频会话不该阻断播放（例如单元测试环境），只记录。
      try? AppLog.write("bass", "AVAudioSession 配置失败: \(error)")
    }
  }

  // MARK: - 播放控制

  private func load(_ source: String,
                    headers: [String: String],
                    formatHint: String?,
                    generation: Int) throws -> [String: Any?] {
    _ = try initializeEngine()
    if generation != loadGeneration {
      throw BassError(code: BassPlayerPlugin.cancelledCode, operation: "load",
                      message: "load cancelled")
    }

    releaseStream()
    playing = false
    completed = false
    durationMs = nil
    processingState = .loading
    emitSnapshot()

    let flags = UInt32(BASS_SAMPLE_FLOAT)
    // 用 `?? ""` 归一成非可选再 switch：避免依赖 Swift 对 Optional 的模式匹配推断。
    let scheme = URL(string: source)?.scheme?.lowercased() ?? ""
    let format = BassPlayerPlugin.normalizedFormat(formatHint, source: source)
    let isRemote = ["http", "https", "ftp"].contains(scheme)

    var handle: HSTREAM = 0
    do {
      switch scheme {
      case "http", "https":
        // 仅 http/https 走 HTTP Range 随机访问数据源（BASS_StreamCreateURL 不支持跳转）。
        handle = createNetworkStream(source: source, headers: headers,
                                     format: format, flags: flags)
      case "ftp":
        // FTP 仍走 BASS 内置的顺序下载（URLSession 不支持 FTP）。
        handle = createLegacyNetworkStream(
          format: format,
          request: BassPlayerPlugin.urlWithHeaders(source, headers),
          flags: flags)
      case "file":
        let path = URL(string: source)?.path ?? source
        handle = createFileStream(format: format, path: path, flags: flags)
      case "":
        // 没有 scheme 说明传进来的就是本地文件路径。
        handle = createFileStream(format: format, path: source, flags: flags)
      default:
        throw BassError(code: Int32(BASS_ERROR_FILEOPEN), operation: "load",
                        message: "不支持的 URI scheme: \(scheme)")
      }
    } catch {
      processingState = .error
      emitSnapshot()
      throw error
    }

    if generation != loadGeneration {
      if handle != 0 { _ = BASS_StreamFree(handle) }
      // 自定义源在 createProgressiveStream 里已强持有，取消时须一并关闭，避免下载线程泄漏。
      if let source = httpSource {
        source.cancel()
        source.close()
        httpSource = nil
      }
      throw BassError(code: BassPlayerPlugin.cancelledCode, operation: "load",
                      message: "load cancelled")
    }
    if handle == 0 {
      processingState = .error
      emitSnapshot()
      throw BassError.fromLastError(operation: "load stream")
    }

    stream = handle
    remoteSource = isRemote

    do {
      if BASS_ChannelSetAttribute(stream, UInt32(BASS_ATTRIB_VOL), channelVolume) == 0 {
        throw BassError.fromLastError(operation: "set volume")
      }
      try installSynchronizers()
      try applyEqualizer(currentEq, forceRebuild: true)
      durationMs = readDurationMs()
      if let http = httpSource { configureProgressiveBuffering(http) }
      processingState = .ready
      refreshPlaybackState()
    } catch {
      releaseStream()
      processingState = .error
      throw error
    }

    emitSnapshot()
    return snapshot()
  }

  private func play() throws -> [String: Any?] {
    _ = try initializeEngine()
    if stream == 0 { throw BassError(code: Int32(BASS_ERROR_HANDLE), operation: "play",
                                    message: "没有已加载的音频流") }
    if pendingSeekMs != nil {
      pendingSeekPlay = true
      pendingSeekDeadline = Date().timeIntervalSince1970 * 1000
        + BassPlayerPlugin.seekAttemptBudgetMs
      startTicking()
      refreshPlaybackState()   // processingState = .buffering，界面转圈但不启动解码
      emitSnapshot()
      return snapshot()        // 对齐 Android :503：等落位成功后由 completePendingSeek 起播
    }
    if completed {
      // 播完后再点播放：回到起点重播，与 Android 行为一致。
      let position = BASS_ChannelSeconds2Bytes(stream, 0.0)
      if BASS_ChannelSetPosition(stream, position, UInt32(BASS_POS_BYTE)) == 0 {
        throw BassError.fromLastError(operation: "restart stream")
      }
      completed = false
    }
    // restart=0：从暂停点续播（与 Android BASS_ChannelPlay(channel,false) 一致）。
    // restart=1 会从头播，导致暂停后再点播放从开头开始。
    // completed 分支上方已 seek 到 0，此处 restart=0 从 0 续播等价重播，无冲突。
    if BASS_ChannelPlay(stream, 0) == 0 {
      throw BassError.fromLastError(operation: "play")
    }
    refreshPlaybackState()
    emitSnapshot()
    return snapshot()
  }

  private func pause() throws -> [String: Any?] {
    if stream == 0 { return snapshot() }
    if BASS_ChannelPause(stream) == 0 {
      throw BassError.fromLastError(operation: "pause")
    }
    refreshPlaybackState()
    emitSnapshot()
    return snapshot()
  }

  private func stop() throws -> [String: Any?] {
    if stream == 0 { return snapshot() }
    if BASS_ChannelStop(stream) == 0 {
      throw BassError.fromLastError(operation: "stop")
    }
    let position = BASS_ChannelSeconds2Bytes(stream, 0.0)
    _ = BASS_ChannelSetPosition(stream, position, UInt32(BASS_POS_BYTE))
    resetEqualizerState()
    completed = false
    playing = false
    processingState = .idle
    emitSnapshot()
    return snapshot()
  }

  private func seek(_ positionMs: Int) throws -> [String: Any?] {
    if stream == 0 {
      // stream 未就绪（load 刚开始/网络流未建）：缓存目标，待就绪后落位。
      pendingSeekMs = positionMs
      pendingSeekOriginMs = 0
      pendingSeekPlay = playing
      refreshPlaybackState()
      emitSnapshot()
      return snapshot()
    }
    let seconds = max(0.0, Double(positionMs) / 1000.0)
    let position = BASS_ChannelSeconds2Bytes(stream, seconds)
    // 自定义 Range 源：先把目标字节设为下载优先区，再落位；
    // FILESEEKPROC 会直接改 readPosition，BASS 数据不足时自行 stall。
    if let http = httpSource {
      http.prioritize(Int64(clamping: position))
      pendingSeekDeadline = Date().timeIntervalSince1970 * 1000
        + BassPlayerPlugin.seekAttemptBudgetMs
    }
    if BASS_ChannelSetPosition(stream, position, UInt32(BASS_POS_BYTE)) == 0 {
      if remoteSource {
        // 目标未缓冲：静默缓存而非抛错（抛出会被 Dart 当 non-fatal 吞掉，位置停在 0）。
        if pendingSeekMs == nil { pendingSeekOriginMs = readPositionMs() }
        pendingSeekMs = positionMs
        pendingSeekPlay = playing
        let active = BASS_ChannelIsActive(stream)
        if active == UInt32(BASS_ACTIVE_PLAYING) || active == UInt32(BASS_ACTIVE_STALLED) {
          _ = BASS_ChannelPause(stream)
        }
        startTicking()
        emitSnapshot()
        return snapshot()
      }
      throw BassError.fromLastError(operation: "seek")
    }
    // 落位立即成功：FILESEEKPROC 已把 readPosition 移到目标，清掉临时优先区与旧 pending。
    pendingSeekMs = nil
    pendingSeekDeadline = 0
    httpSource?.prioritize(nil)
    // seek 后滤波器里残留的历史会造成爆音，清掉。
    resetEqualizerState()
    completed = false
    refreshPlaybackState()
    emitSnapshot()
    return snapshot()
  }

  /// 尝试把缓存的 seek 落位；目标仍未缓冲时保留 pending 待下次重试，
  /// 超过 SEEK_ATTEMPT_BUDGET_MS 则放弃并回退，绝不永久卡死。
  private func attemptPendingSeek() {
    guard let target = pendingSeekMs, stream != 0 else { return }
    let bytes = BASS_ChannelSeconds2Bytes(stream, Double(max(0, target)) / 1000.0)
    guard let http = httpSource else {
      if BASS_ChannelSetPosition(stream, bytes, UInt32(BASS_POS_BYTE)) != 0 { completePendingSeek() }
      return
    }
    http.prioritize(Int64(clamping: bytes))
    // 关键：让同步预读在 FILEPROCS 里等数据到齐，避免"碰运气"落位（对齐 Android :637-640）
    http.beginBlocking(budgetMs: Int64(BassPlayerPlugin.seekAttemptBudgetMs))
    let moved = BASS_ChannelSetPosition(stream, bytes, UInt32(BASS_POS_BYTE)) != 0
    let starved = http.endBlocking()
    if starved || !moved {
      let now = Date().timeIntervalSince1970 * 1000
      if pendingSeekDeadline <= 0 {
        pendingSeekDeadline = now + BassPlayerPlugin.seekAttemptBudgetMs
      } else if now > pendingSeekDeadline {
        abandonPendingSeek()
      }
      return
    }
    completePendingSeek()
  }

  /// 落位成功：清 pending、清滤波历史、按原始意图恢复播放。
  private func completePendingSeek() {
    pendingSeekMs = nil
    pendingSeekDeadline = 0
    httpSource?.prioritize(nil)
    httpSource?.holdUntilBuffered(startBufferBytes)   // 对齐 Android :653，消除起播瞬间卡顿
    resetEqualizerState()
    if pendingSeekPlay {
      pendingSeekPlay = false
      if BASS_ChannelPlay(stream, 0) == 0 {
        AppLog.write("bass", "resume after seek failed: \(BassError.fromLastError(operation: "resume").message)")
      }
    }
    refreshPlaybackState()
    emitSnapshot()
  }

  /// seek 预算耗尽：回退到发起 seek 前的位置并恢复播放，绝不遗留 pending。
  private func abandonPendingSeek() {
    pendingSeekMs = nil
    pendingSeekDeadline = 0
    httpSource?.prioritize(nil)
    let origin = pendingSeekOriginMs
    pendingSeekOriginMs = 0
    let bytes = BASS_ChannelSeconds2Bytes(stream, Double(max(0, origin)) / 1000.0)
    _ = BASS_ChannelSetPosition(stream, bytes, UInt32(BASS_POS_BYTE))
    // 只有原本就在播放才恢复；暂停态 seek 超时后不应擅自起播（对齐 completePendingSeek）。
    let shouldResume = pendingSeekPlay
    pendingSeekPlay = false
    if shouldResume {
      if BASS_ChannelPlay(stream, 0) == 0 {
        AppLog.write("bass", "resume after seek timeout failed: \(BassError.fromLastError(operation: "resume").message)")
      }
    }
    refreshPlaybackState()
    emitSnapshot()
  }

  private func setVolume(_ volume: Float) throws -> [String: Any?] {
    channelVolume = min(max(volume, 0), 1)
    if stream != 0 {
      if BASS_ChannelSetAttribute(stream, UInt32(BASS_ATTRIB_VOL), channelVolume) == 0 {
        throw BassError.fromLastError(operation: "set volume")
      }
    }
    return snapshot()
  }

  // MARK: - 均衡器

  private func setEqualizer(_ configuration: [String: Any]) throws -> [String: Any?] {
    currentEq = configuration
    try applyEqualizer(configuration, forceRebuild: false)
    return snapshot()
  }

  private func applyEqualizer(_ configuration: [String: Any]?, forceRebuild: Bool) throws {
    guard stream != 0 else { return }

    let enabled = configuration?["enabled"] as? Bool ?? false
    if !enabled {
      detachEqualizer()
      return
    }

    let inputGainDb = configuration?["inputGainDb"] as? Double ?? 0
    let outputGainDb = configuration?["outputGainDb"] as? Double ?? 0
    let rawBands = configuration?["bands"] as? [[String: Any]] ?? []
    let bands = rawBands.compactMap(BassPlayerPlugin.parseBand)
      .filter { $0.enabled }
      .prefix(Int(CYSHINE_MAX_BIQUAD_BANDS))

    if bands.isEmpty && abs(inputGainDb) < 0.001 && abs(outputGainDb) < 0.001 {
      detachEqualizer()
      return
    }

    if eqChain == nil || forceRebuild {
      detachEqualizer()
      guard let chain = cyshine_biquad_chain_create(sampleRate()) else {
        throw BassError(code: -1, operation: "setEqualizer",
                        message: "无法创建均衡器处理链")
      }
      eqChain = chain
      eqDsp = BASS_ChannelSetDSP(
        stream,
        { (_, channel, buffer, length, user) in
          guard let user, let buffer else { return }
          let plugin = Unmanaged<BassPlayerPlugin>.fromOpaque(user).takeUnretainedValue()
          plugin.processDsp(channel: channel,
                            buffer: buffer.assumingMemoryBound(to: Float.self),
                            length: length)
        },
        Unmanaged.passUnretained(self).toOpaque(),
        0)
      if eqDsp == 0 {
        cyshine_biquad_chain_destroy(eqChain)
        eqChain = nil
        throw BassError.fromLastError(operation: "setEqualizer")
      }
    }

    guard let chain = eqChain else { return }

    var cBands = bands.map { band -> CyShineBiquadBand in
      CyShineBiquadBand(type: Int32(band.filterType.rawValue),
                        frequencyHz: band.frequencyHz,
                        gainDb: band.gainDb,
                        q: band.q)
    }
    // 全部段都关掉但仍要保留输入/输出增益时，用零段配置。
    cyshine_biquad_chain_configure(chain, inputGainDb, outputGainDb, &cBands, Int32(cBands.count))
  }

  private func detachEqualizer() {
    if eqDsp != 0 && stream != 0 {
      _ = BASS_ChannelRemoveDSP(stream, eqDsp)
    }
    eqDsp = 0
    if let chain = eqChain {
      cyshine_biquad_chain_destroy(chain)
      eqChain = nil
    }
  }

  private func resetEqualizerState() {
    guard let chain = eqChain else { return }
    cyshine_biquad_chain_reset(chain)
  }

  /// DSP 在 BASS 的混音线程上执行，这里只做纯计算。
  fileprivate func processDsp(channel: HSTREAM, buffer: UnsafeMutablePointer<Float>, length: UInt32) {
    guard let chain = eqChain else { return }
    let channels = max(streamChannels, 1)
    let frameBytes = UInt32(MemoryLayout<Float>.size) * channels
    guard frameBytes > 0 else { return }
    let frames = length / frameBytes
    if frames == 0 { return }
    cyshine_biquad_chain_process(chain, buffer, UInt(frames), channels)
  }

  /// 交错声道数在 load 时由 BASS_ChannelGetInfo 缓存，避免在音频线程回调 BASS。
  private var streamChannels: UInt32 = 2

  private func sampleRate() -> Double {
    guard stream != 0 else { return 44_100 }
    var info = BASS_CHANNELINFO()
    if BASS_ChannelGetInfo(stream, &info) != 0 {
      if info.freq > 0 { streamChannels = max(info.chans, 1) }
      if info.freq > 0 { return Double(info.freq) }
    }
    return 44_100
  }

  // MARK: - 流创建

  private func createNetworkStream(source: String, headers: [String: String],
                                   format: String, flags: UInt32) -> HSTREAM {
    // 1) HTTP Range 随机访问数据源：支持拖动进度条跳到未缓冲位置。
    let progressive = createProgressiveStream(source: source, headers: headers,
                                              format: format, flags: flags)
    if progressive != 0 { return progressive }
    // 2) fallback：原 BASS_StreamCreateURL 顺序下载（不支持 Range 的源仍能播）。
    return createLegacyNetworkStream(format: format,
                                     request: BassPlayerPlugin.urlWithHeaders(source, headers),
                                     flags: flags)
  }

  /// 按码率推算起播/续播缓冲字节数（对齐 Android configureProgressiveBuffering）。
  private func configureProgressiveBuffering(_ source: ProgressiveHttpSource) {
    let total = source.totalBytes
    let bytesPerSecond: Double
    if let duration = durationMs, duration > 0, total > 0 {
      bytesPerSecond = Double(total) * 1000.0 / Double(duration)
    } else {
      bytesPerSecond = BassPlayerPlugin.fallbackBytesPerSecond
    }
    startBufferBytes = min(max(Int64(bytesPerSecond * BassPlayerPlugin.startBufferSeconds),
                               BassPlayerPlugin.minBufferBytes), BassPlayerPlugin.maxBufferBytes)
    let resume = min(max(Int64(bytesPerSecond * BassPlayerPlugin.resumeBufferSeconds),
                         BassPlayerPlugin.minBufferBytes), BassPlayerPlugin.maxBufferBytes)
    source.setResumeBytes(resume)
    source.holdUntilBuffered(startBufferBytes)
  }

  /// 用自定义 ProgressiveHttpSource + BASS_StreamCreateFileUser 建流。
  /// 返回 0 表示失败（由调用方回退到 URL 版）。
  private func createProgressiveStream(source: String, headers: [String: String],
                                       format: String, flags: UInt32) -> HSTREAM {
    let cacheDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("bass-stream")
    try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
    let cachePath = (cacheDir as NSString).appendingPathComponent("\(UUID().uuidString).cache")
    let cacheFile = URL(fileURLWithPath: cachePath)

    let http: ProgressiveHttpSource
    do {
      http = try ProgressiveHttpSource(url: source, headers: headers, cacheFile: cacheFile) { [weak self] in
        guard let self = self else { return }
        self.engineQueue.async {
          self.refreshPlaybackStateQuietly()
          self.emitSnapshot()
        }
      }
      try http.open(timeoutMs: Int64(8_000))
    } catch {
      AppLog.write("bass", "progressive open failed: \(error)")
      return 0
    }

    // 流创建阶段允许阻塞等待解码所需的数据（对齐 Android beginBlocking(10000)）。
    http.beginBlocking(budgetMs: 10_000)
    var procs = http.fileProcs
    let handle = withUnsafeMutablePointer(to: &procs) { ptr in
      createUserStream(format: format, flags: flags, procs: ptr,
                       user: http.userPointer, httpSource: http)
    }
    _ = http.endBlocking()

    if handle != 0 {
      // 强引用持有，生命周期跟随 stream；releaseStream 里 close。
      self.httpSource = http
      return handle
    }
    http.close()
    return 0
  }

  private func createUserStream(format: String, flags: UInt32,
                                procs: UnsafeMutablePointer<BASS_FILEPROCS>,
                                user: UnsafeMutableRawPointer,
                                httpSource: ProgressiveHttpSource) -> HSTREAM {
    let system = UInt32(STREAMFILE_NOBUFFER)
    func generic() -> HSTREAM {
      httpSource.rewind()
      return BASS_StreamCreateFileUser(system, flags, procs, user)
    }
    func specialized(_ make: (UnsafeMutablePointer<BASS_FILEPROCS>, UnsafeMutableRawPointer) -> HSTREAM) -> HSTREAM {
      httpSource.rewind()
      let h = make(procs, user)
      return h != 0 ? h : generic()
    }
    switch format {
    case "flac":
      return specialized { BASS_FLAC_StreamCreateFileUser(system, flags, $0, $1) }
    case "ape":
      return specialized { BASS_APE_StreamCreateFileUser(system, flags, $0, $1) }
    case "wv":
      return specialized { BASS_WV_StreamCreateFileUser(system, flags, $0, $1) }
    case "opus":
      return specialized { BASS_OPUS_StreamCreateFileUser(system, flags, $0, $1) }
    case "dsd":
      // DSD 附加库比其它库多一个 freq 参数（0 = 保持源采样率）。
      return specialized { BASS_DSD_StreamCreateFileUser(system, flags, $0, $1, 0) }
    case "lossless":
      let g = generic()
      if g != 0 { return g }
      return specialized { BASS_FLAC_StreamCreateFileUser(system, flags, $0, $1) }
    default:
      // generic / m4a / alac：Apple 平台 BASS 核心走 CoreAudio 解码。
      let g = generic()
      if g != 0 { return g }
      return specialized { BASS_FLAC_StreamCreateFileUser(system, flags, $0, $1) }
    }
  }

  private func createLegacyNetworkStream(format: String, request: String, flags: UInt32) -> HSTREAM {
    func core() -> HSTREAM {
      request.withCString { BASS_StreamCreateURL($0, 0, flags, nil, nil) }
    }
    func specialized(_ make: (UnsafePointer<CChar>) -> HSTREAM) -> HSTREAM {
      let handle = request.withCString { make($0) }
      return handle != 0 ? handle : core()
    }

    switch format {
    case "flac":
      return specialized { BASS_FLAC_StreamCreateURL($0, 0, flags, nil, nil) }
    case "ape":
      return specialized { BASS_APE_StreamCreateURL($0, 0, flags, nil, nil) }
    case "wv":
      return specialized { BASS_WV_StreamCreateURL($0, 0, flags, nil, nil) }
    case "opus":
      return specialized { BASS_OPUS_StreamCreateURL($0, 0, flags, nil, nil) }
    case "dsd":
      return specialized { BASS_DSD_StreamCreateURL($0, 0, flags, nil, nil, 0) }
    case "m4a", "alac":
      return core()
    case "lossless":
      let generic = core()
      if generic != 0 { return generic }
      return specialized { BASS_FLAC_StreamCreateURL($0, 0, flags, nil, nil) }
    default:
      let generic = core()
      if generic != 0 { return generic }
      return specialized { BASS_FLAC_StreamCreateURL($0, 0, flags, nil, nil) }
    }
  }

  private func createFileStream(format: String, path: String, flags: UInt32) -> HSTREAM {
    func core() -> HSTREAM {
      path.withCString { BASS_StreamCreateFile(0, $0, 0, 0, flags) }
    }
    switch format {
    case "flac":
      let handle = path.withCString { BASS_FLAC_StreamCreateFile(0, $0, 0, 0, flags) }
      return handle != 0 ? handle : core()
    case "ape":
      let handle = path.withCString { BASS_APE_StreamCreateFile(0, $0, 0, 0, flags) }
      return handle != 0 ? handle : core()
    case "wv":
      let handle = path.withCString { BASS_WV_StreamCreateFile(0, $0, 0, 0, flags) }
      return handle != 0 ? handle : core()
    case "opus":
      let handle = path.withCString { BASS_OPUS_StreamCreateFile(0, $0, 0, 0, flags) }
      return handle != 0 ? handle : core()
    case "dsd":
      // 同 createNetworkStream：DSD 多一个 freq 参数。
      let handle = path.withCString { BASS_DSD_StreamCreateFile(0, $0, 0, 0, flags, 0) }
      return handle != 0 ? handle : core()
    default:
      return core()
    }
  }

  // MARK: - 同步点

  private func installSynchronizers() throws {
    let user = Unmanaged.passUnretained(self).toOpaque()

    endSync = BASS_ChannelSetSync(
      stream, UInt32(BASS_SYNC_END), 0,
      { _, channel, _, user in
        guard let user else { return }
        let plugin = Unmanaged<BassPlayerPlugin>.fromOpaque(user).takeUnretainedValue()
        plugin.engineQueue.async {
          guard channel == plugin.stream, plugin.stream != 0 else { return }
          plugin.handleStreamEnded()
        }
      }, user)

    stallSync = BASS_ChannelSetSync(
      stream, UInt32(BASS_SYNC_STALL), 0,
      { _, _, _, user in
        guard let user else { return }
        let plugin = Unmanaged<BassPlayerPlugin>.fromOpaque(user).takeUnretainedValue()
        plugin.engineQueue.async {
          plugin.refreshPlaybackState()
          plugin.emitSnapshot()
        }
      }, user)

    deviceFailureSync = BASS_ChannelSetSync(
      stream, UInt32(BASS_SYNC_DEV_FAIL), 0,
      { _, _, _, user in
        guard let user else { return }
        let plugin = Unmanaged<BassPlayerPlugin>.fromOpaque(user).takeUnretainedValue()
        plugin.engineQueue.async {
          plugin.processingState = .error
          plugin.playing = false
          plugin.emitSnapshot()
          plugin.emitError(code: Int32(BASS_ERROR_DEVICE),
                           message: "音频设备失效",
                           operation: "device")
        }
      }, user)

    if endSync == 0 || stallSync == 0 || deviceFailureSync == 0 {
      throw BassError.fromLastError(operation: "install playback synchronizers")
    }

    // 下载进度同步点只对网络流有意义，失败不算错误。
    if remoteSource {
      downloadSync = BASS_ChannelSetSync(
        stream, UInt32(BASS_SYNC_DOWNLOAD), 0,
        { _, _, _, user in
          guard let user else { return }
          let plugin = Unmanaged<BassPlayerPlugin>.fromOpaque(user).takeUnretainedValue()
          plugin.engineQueue.async {
            plugin.attemptPendingSeek()
            plugin.emitSnapshot()
          }
        }, user)
    }
  }

  private func handleStreamEnded() {
    // 网络流下载中断也会触发 END，但曲目并未真正播完。
    // 与 Android legacyStreamEndedEarly 一致：提前结束报 error，触发原地重载续播，
    // 而不是判 completed 切下一首。容差 5s 与 Android TRUNCATED_END_TOLERANCE_MS 对齐。
    if remoteSource,
       let duration = durationMs,
       readPositionMs() < duration - 5_000 {
      playing = false
      processingState = .ready
      emitError(code: Int32(BASS_ERROR_ENDED),
                message: "network stream ended before the track finished",
                operation: "stream-ended")
      stopTicking()
      return
    }
    processingState = .completed
    playing = false
    completed = true
    durationMs = readDurationMs() ?? durationMs
    emitSnapshot()
    stopTicking()
  }

  // MARK: - 状态

  private func refreshPlaybackState() {
    if pendingSeekMs != nil {
      playing = pendingSeekPlay
      processingState = .buffering
      durationMs = readDurationMs() ?? durationMs
      syncTicking()
      return
    }
    if stream == 0 || completed || processingState == .loading || processingState == .error {
      return
    }
    durationMs = readDurationMs() ?? durationMs
    switch BASS_ChannelIsActive(stream) {
    case UInt32(BASS_ACTIVE_PLAYING):
      playing = true
      processingState = .ready
    case UInt32(BASS_ACTIVE_STALLED):
      playing = true
      processingState = .buffering
    case UInt32(BASS_ACTIVE_PAUSED), UInt32(BASS_ACTIVE_PAUSED_DEVICE):
      playing = false
      processingState = .ready
    case UInt32(BASS_ACTIVE_STOPPED):
      playing = false
      processingState = .ready
    default:
      break
    }
    syncTicking()
  }

  private func snapshot() -> [String: Any?] {
    let position = pendingSeekMs ?? readPositionMs()
    return [
      "event": "snapshot",
      "playing": playing,
      "processingState": processingState.rawValue,
      "positionMs": position,
      "bufferedPositionMs": readBufferedPositionMs(position),
      "durationMs": durationMs,
    ]
  }

  private func emitSnapshot() {
    send(snapshot())
  }

  private func emitError(code: Int32, message: String, operation: String) {
    var payload = snapshot()
    payload["event"] = "error"
    payload["errorCode"] = Int(code)
    payload["bassCode"] = Int(code)
    payload["errorMessage"] = message
    payload["operation"] = operation
    send(payload)
  }

  private func readPositionMs() -> Int {
    if stream == 0 { return 0 }
    let bytes = BASS_ChannelGetPosition(stream, UInt32(BASS_POS_BYTE))
    if bytes == UInt64.max { return 0 }
    let seconds = BASS_ChannelBytes2Seconds(stream, bytes)
    guard seconds.isFinite, seconds >= 0 else { return 0 }
    return Int(seconds * 1000)
  }

  private func readDurationMs() -> Int? {
    if stream == 0 { return nil }
    let bytes = BASS_ChannelGetLength(stream, UInt32(BASS_POS_BYTE))
    if bytes == 0 || bytes == UInt64.max { return nil }
    let seconds = BASS_ChannelBytes2Seconds(stream, bytes)
    guard seconds.isFinite, seconds > 0 else { return nil }
    return Int(seconds * 1000)
  }

  private func readBufferedPositionMs(_ positionMs: Int) -> Int {
    guard let duration = durationMs else { return positionMs }
    if !remoteSource { return duration }

    // 自定义 Range 源：NOBUFFER 下 BASS_StreamGetFilePosition 不可靠，
    // 用数据源自身已缓存字节 / 总字节估算已缓冲时间点。
    if let http = httpSource {
      let total = http.totalBytes
      let downloaded = http.downloadedBytes
      if total > 0, downloaded >= 0 {
        let mapped = Int(Double(duration) * Double(downloaded) / Double(total))
        return min(max(mapped, positionMs), duration)
      }
      return positionMs
    }

    let fileEnd = BASS_StreamGetFilePosition(stream, UInt32(BASS_FILEPOS_END))
    let downloaded = BASS_StreamGetFilePosition(stream, UInt32(BASS_FILEPOS_DOWNLOAD))
    if fileEnd > 0, fileEnd != UInt64.max, downloaded != UInt64.max {
      let mapped = Int(Double(duration) * Double(downloaded) / Double(fileEnd))
      return min(max(mapped, positionMs), duration)
    }
    // 与 Android 一致：BASS_FILEPOS_BUFFERING 是预缓冲百分比，不能当已下载长度用。
    return positionMs
  }

  // MARK: - 周期快照

  private func syncTicking() {
    let shouldTick = playing || processingState == .buffering || processingState == .loading
    if shouldTick { startTicking() } else { stopTicking() }
  }

  private func startTicking() {
    guard tickTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: engineQueue)
    timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.attemptPendingSeek()
      self.refreshPlaybackStateQuietly()
      self.emitSnapshot()
    }
    tickTimer = timer
    timer.resume()
  }

  private func stopTicking() {
    tickTimer?.cancel()
    tickTimer = nil
  }

  private func refreshPlaybackStateQuietly() {
    if pendingSeekMs != nil { return }
    if stream == 0 || completed { return }
    durationMs = readDurationMs() ?? durationMs
    switch BASS_ChannelIsActive(stream) {
    case UInt32(BASS_ACTIVE_PLAYING):
      playing = true
      processingState = .ready
    case UInt32(BASS_ACTIVE_STALLED):
      playing = true
      processingState = .buffering
    case UInt32(BASS_ACTIVE_PAUSED), UInt32(BASS_ACTIVE_PAUSED_DEVICE):
      playing = false
    case UInt32(BASS_ACTIVE_STOPPED):
      playing = false
    default:
      break
    }
  }

  // MARK: - 释放

  private func releaseStream() {
    pendingSeekMs = nil
    pendingSeekOriginMs = 0
    pendingSeekDeadline = 0
    pendingSeekPlay = false
    stopTicking()
    detachEqualizer()
    if stream != 0 {
      if endSync != 0 { _ = BASS_ChannelRemoveSync(stream, endSync) }
      if stallSync != 0 { _ = BASS_ChannelRemoveSync(stream, stallSync) }
      if downloadSync != 0 { _ = BASS_ChannelRemoveSync(stream, downloadSync) }
      if deviceFailureSync != 0 { _ = BASS_ChannelRemoveSync(stream, deviceFailureSync) }
      _ = BASS_StreamFree(stream)
    }
    endSync = 0
    stallSync = 0
    downloadSync = 0
    deviceFailureSync = 0
    stream = 0
    remoteSource = false
    // stream 已释放，BASS 不会再回调 user 指针；此时安全关闭并释放数据源。
    if let source = httpSource {
      source.cancel()
      source.close()
      httpSource = nil
    }
  }

  private func disposeEngine() {
    releaseStream()
    detachEqualizer()
    if initialized {
      _ = BASS_Free()
    }
    initialized = false
    playing = false
    completed = false
    processingState = .idle
    durationMs = nil
  }

  deinit {
    stopTicking()
    releaseStream()
    detachEqualizer()
  }

  // MARK: - 工具

  /// BASS 的版本 DWORD -> "2.4.x.y"。
  static func versionString(_ version: UInt32) -> String {
    let major = (version >> 24) & 0xFF
    let minor = (version >> 16) & 0xFF
    let build = (version >> 8) & 0xFF
    let revision = version & 0xFF
    return "\(major).\(minor).\(build).\(revision)"
  }

  /// 与 Android 的 urlWithHeaders 完全一致：把请求头追加在 URL 之后，
  /// 用 \r\n 分隔并以空行结束，BASS 会把它当成 HTTP 请求头。
  static func urlWithHeaders(_ source: String, _ headers: [String: String]) -> String {
    if headers.isEmpty { return source }
    var result = source
    result += "\r\n"
    for (name, value) in headers {
      let safeName = name.replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "\n", with: "")
      let safeValue = value.replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "\n", with: "")
      result += "\(safeName): \(safeValue)\r\n"
    }
    result += "\r\n"
    return result
  }

  /// 与 Android 的 normalizedFormat 对齐。
  static func normalizedFormat(_ hint: String?, source: String) -> String {
    let trimmed = (hint ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    let path = URL(string: source)?.path ?? source
    let ext = (path as NSString).pathExtension.lowercased()

    if !trimmed.isEmpty {
      switch trimmed {
      case "flac", "ape", "alac", "m4a", "wv", "opus", "dsd", "ogg":
        return trimmed
      case "flac24bit", "hires", "master", "lossless":
        return "lossless"
      case "generic":
        return "generic"
      default:
        return "generic"
      }
    }

    switch ext {
    case "flac": return "flac"
    case "ape": return "ape"
    case "m4a", "mp4": return "m4a"
    case "wv": return "wv"
    case "opus", "ogg": return "opus"
    case "dsf", "dff": return "dsd"
    case "alac": return "alac"
    default: return "generic"
    }
  }

  struct ParsedBand {
    let filterType: CyShineFilterKind
    let frequencyHz: Double
    let gainDb: Double
    let q: Double
    let enabled: Bool
  }

  enum CyShineFilterKind: Int {
    case peaking = 0
    case lowShelf = 1
    case highShelf = 2
    case lowPass = 3
    case highPass = 4
  }

  static func parseBand(_ raw: [String: Any]) -> ParsedBand? {
    guard let name = raw["filter"] as? String else { return nil }
    let kind: CyShineFilterKind
    switch name {
    case "peaking", "peakingEq": kind = .peaking
    case "lowShelf": kind = .lowShelf
    case "highShelf": kind = .highShelf
    case "lowPass": kind = .lowPass
    case "highPass": kind = .highPass
    default: return nil
    }
    let frequency = (raw["frequencyHz"] as? NSNumber)?.doubleValue ?? 0
    let gain = (raw["gainDb"] as? NSNumber)?.doubleValue ?? 0
    let q = (raw["q"] as? NSNumber)?.doubleValue ?? 0.707
    return ParsedBand(filterType: kind, frequencyHz: frequency, gainDb: gain,
                      q: q, enabled: raw["enabled"] as? Bool ?? true)
  }
}

// MARK: - 错误类型

struct BassError: Error {
  let code: Int32
  let message: String
  let operation: String

  init(code: Int32, operation: String, message: String) {
    self.code = code
    self.operation = operation
    self.message = message
  }

  /// 读取 BASS_ErrorGetCode()，并翻译成与 Android 端 errorMessage 相同的中文/英文描述。
  static func fromLastError(operation: String) -> BassError {
    let code = BASS_ErrorGetCode()
    return BassError(code: code, operation: operation, message: message(for: code))
  }

  static func message(for code: Int32) -> String {
    switch code {
    case Int32(BASS_ERROR_MEM): return "out of memory"
    case Int32(BASS_ERROR_FILEOPEN): return "unable to open the source"
    case Int32(BASS_ERROR_DRIVER): return "can't find a free/valid driver"
    case Int32(BASS_ERROR_HANDLE): return "invalid handle"
    case Int32(BASS_ERROR_FORMAT): return "unsupported sample format"
    case Int32(BASS_ERROR_POSITION): return "invalid position"
    case Int32(BASS_ERROR_INIT): return "BASS_Init has not been successfully called"
    case Int32(BASS_ERROR_SSL): return "SSL/HTTPS support isn't available"
    case Int32(BASS_ERROR_ALREADY): return "already initialized"
    case Int32(BASS_ERROR_NOTAUDIO): return "file does not contain audio"
    case Int32(BASS_ERROR_NOCHAN): return "can't get a free channel"
    case Int32(BASS_ERROR_ILLTYPE): return "an illegal type was specified"
    case Int32(BASS_ERROR_ILLPARAM): return "an illegal parameter was specified"
    case Int32(BASS_ERROR_DEVICE): return "illegal device number"
    case Int32(BASS_ERROR_NOPLAY): return "not playing"
    case Int32(BASS_ERROR_FREQ): return "illegal sample rate"
    case Int32(BASS_ERROR_NONET): return "no internet connection could be opened"
    case Int32(BASS_ERROR_CREATE): return "couldn't create the file"
    case Int32(BASS_ERROR_NOFX): return "effects are not available"
    case Int32(BASS_ERROR_NOTAVAIL): return "requested data/action is not available"
    case Int32(BASS_ERROR_TIMEOUT): return "connection timed out"
    case Int32(BASS_ERROR_FILEFORM): return "unsupported file format"
    case Int32(BASS_ERROR_VERSION): return "invalid BASS version"
    case Int32(BASS_ERROR_CODEC): return "codec is not available/supported"
    case Int32(BASS_ERROR_ENDED): return "the channel/file has ended"
    case Int32(BASS_ERROR_BUSY): return "the device is busy"
    case Int32(BASS_ERROR_UNSTREAMABLE): return "unstreamable file"
    case Int32(BASS_ERROR_PROTOCOL): return "unsupported protocol"
    case Int32(BASS_ERROR_DENIED): return "access denied"
    case Int32(BASS_ERROR_FREEING): return "being freed"
    case Int32(BASS_ERROR_CANCEL): return "cancelled"
    default: return "unknown error (\(code))"
    }
  }
}

// MARK: - 日志桥

/// 与 lib/core/services/app_logger.dart 的 Android 侧行为对齐：iOS 上不写系统日志通道，
/// 只在本地 console 留痕，避免依赖尚未移植的 cy_shine_music/app_task 通道。
enum AppLog {
  static func write(_ tag: String, _ message: String) {
    #if DEBUG
      NSLog("[\(tag)] \(message)")
    #endif
  }
}

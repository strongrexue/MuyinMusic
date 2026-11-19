// CyShineMusic iOS —— HTTP Range 随机访问数据源。
//
// 与 Android 端 ProgressiveHttpSource.kt 语义等价：把网络音频当稀疏文件缓存，
// 用 BASS_StreamCreateFileUser + STREAMFILE_NOBUFFER 的四个 C 回调直接落位，
// 解决 BASS_StreamCreateURL 顺序下载无法跳到未缓冲位置的问题。
//
// BASS C API 依据（官方 bass24-ios.zip 的 bass.h；web_fetch 官方文档复核）：
//   bass.h:23-24  DWORD=uint32_t, QWORD=uint64_t；:29 BOOL=int；:20 CALLBACK 空宏
//   bass.h:486    STREAMFILE_NOBUFFER 0
//   bass.h:491-494 FILECLOSE/FILELEN/FILEREAD/FILESEEK 回调签名（见下方 C 函数指针）
//   bass.h:497-502 BASS_FILEPROCS 字段顺序 close,length,read,seek
//   bass.h:1081   BASS_StreamCreateFileUser(DWORD,DWORD,const BASS_FILEPROCS*,void*)
// FILEREADPROC 官方：NOBUFFER 下返回 -1(=UInt32.max) 表示 EOF，返回 0 让 BASS stall；
// 音频线程必须快速返回，stream 创建/seek 阶段才允许阻塞（由调用方 beginBlocking 包裹）。

import Foundation
import CBass

// MARK: - 稀疏字节区间（ByteRanges.kt 等价）

private struct ByteRanges {
  // 已下载区间，start 递增、相邻/重叠合并，end 开区间。
  private var spans: [(start: Int64, end: Int64)] = []

  mutating func add(_ start: Int64, _ end: Int64) {
    guard end > start else { return }
    spans.append((start, end))
    var merged: [(start: Int64, end: Int64)] = []
    for span in spans.sorted(by: { $0.start < $1.start }) {
      if let last = merged.last, span.start <= last.end {
        merged[merged.count - 1] = (last.start, max(last.end, span.end))
      } else {
        merged.append(span)
      }
    }
    spans = merged
  }

  /// 含 position 的连续已下载区间末端（开区间）；缺口处返回 position 本身。
  func runEnd(_ position: Int64) -> Int64 {
    guard let span = spans.last(where: { $0.start <= position }) else { return position }
    return span.end > position ? span.end : position
  }

  /// position 处缺口向前延伸到哪里（前一区间末端）。
  func gapStart(_ position: Int64) -> Int64 {
    guard let span = spans.last(where: { $0.start <= position }) else { return 0 }
    return min(span.end, position)
  }

  /// position 之后第一个已下载区间起点。
  func nextRun(_ position: Int64) -> Int64? {
    return spans.first { $0.start > position }?.start
  }

  func totalBytes() -> Int64 {
    return spans.reduce(0) { $0 + ($1.end - $1.start) }
  }
}

// MARK: - Content-Range 解析

private struct ContentRange {
  let start: Int64
  let endInclusive: Int64
  let total: Int64?
}

private func parseContentRange(_ value: String?) -> ContentRange? {
  guard let value = value else { return nil }
  let pattern = "^\\s*bytes\\s+(\\d+)-(\\d+)/(\\d+|\\*)\\s*$"
  guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
        let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
        match.numberOfRanges == 4,
        let r1 = Range(match.range(at: 1), in: value),
        let r2 = Range(match.range(at: 2), in: value),
        let r3 = Range(match.range(at: 3), in: value),
        let start = Int64(value[r1]),
        let end = Int64(value[r2]), end >= start else { return nil }
  let totalStr = String(value[r3])
  return ContentRange(start: start, endInclusive: end, total: totalStr == "*" ? nil : Int64(totalStr))
}

// MARK: - 错误类型

enum SourceErrorKind: Equatable {
  case offline, timeout, http, unsupported, cancelled
}

final class SourceError: Error {
  let kind: SourceErrorKind
  let message: String
  let status: Int

  init(_ kind: SourceErrorKind, _ message: String, status: Int = 0) {
    self.kind = kind
    self.message = message
    self.status = status
  }

  /// 音乐源链接会过期，重定向目标也可能先于原链接失效。
  var expiredURL: Bool {
    return kind == .http && [401, 403, 404, 410].contains(status)
  }
}

/// 值得退避重试的传输错误（临时 HTTP 状态、网络抖动、响应体被截断）。
private struct RetryableTransferError: Error {
  let message: String
  let emptyBody: Bool
  let failsOpen: Bool
  let unsupportedSSL: Bool
}

private func makeRetryError(_ message: String, emptyBody: Bool = true,
                            failsOpen: Bool = false, unsupportedSSL: Bool = false) -> RetryableTransferError {
  return RetryableTransferError(message: message, emptyBody: emptyBody,
                                failsOpen: failsOpen, unsupportedSSL: unsupportedSSL)
}

private func classifyNetworkError(_ error: URLError) -> RetryableTransferError {
  switch error.code {
  case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
       .dnsLookupFailed, .networkConnectionLost, .dataNotAllowed:
    return makeRetryError(networkDescription(error), failsOpen: true)
  case .secureConnectionFailed, .serverCertificateUntrusted, .clientCertificateRejected:
    return makeRetryError(networkDescription(error), failsOpen: true, unsupportedSSL: true)
  case .timedOut:
    return makeRetryError("timeout")
  default:
    return makeRetryError(networkDescription(error))
  }
}

private func networkDescription(_ error: URLError) -> String {
  // 播放链接携带签名 token，日志里抹掉 query。
  var text = "\(error.code.rawValue): \(error.localizedDescription)"
  if let q = text.range(of: "?") { text = String(text[..<q.lowerBound]) + "?..." }
  return text
}

// MARK: - BASS C 回调（@convention(c) 全局函数，不能捕获上下文，user 传 Unmanaged）

private let bassCloseProc: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
  // BASS 释放 stream 时调用；真正清理由插件在 BASS_StreamFree 之后调用 source.close()。
}

private let bassLenProc: @convention(c) (UnsafeMutableRawPointer?) -> UInt64 = { user in
  guard let user = user else { return 0 }
  return Unmanaged<ProgressiveHttpSource>.fromOpaque(user).takeUnretainedValue().fileLengthProc()
}

private let bassReadProc: @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> UInt32 = { buffer, length, user in
  guard let user = user, let buffer = buffer else { return UInt32.max }
  return Unmanaged<ProgressiveHttpSource>.fromOpaque(user).takeUnretainedValue()
    .fileReadProc(into: buffer, maxLength: length)
}

private let bassSeekProc: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Int32 = { offset, user in
  guard let user = user else { return 0 }
  return Unmanaged<ProgressiveHttpSource>.fromOpaque(user).takeUnretainedValue()
    .fileSeekProc(offset: Int64(bitPattern: offset)) ? 1 : 0
}

// MARK: - ProgressiveHttpSource

final class ProgressiveHttpSource: NSObject {

  // MARK: 常量（对齐 Android ProgressiveHttpSource.kt companion object）
  private static let readTimeoutSeconds: Double = 15.0
  private static let maxRedirects = 5
  private static let redirectWindowBytes: Int64 = 128 * 1024
  private static let seekLookbackBytes: Int64 = 64 * 1024
  private static let defaultResumeBytes: Int64 = 256 * 1024
  private static let firstRetryDelayMs: Int64 = 500
  private static let maxRetryDelayMs: Int64 = 5_000
  private static let maxEmptyBodies = 4
  private static let httpTimeout = 408
  private static let tooManyRequests = 429
  private static let userAgent = "BASS/2.4"
  // 解码器打开时通常要读文件尾的标签（FLAC 等会 seek 到末尾）；在主下载之外并行预取尾段。
  private static let tailBytes: Int64 = 64 * 1024
  private static let tailMinFileBytes: Int64 = 1024 * 1024

  // 跨歌复用同一个 URLSession：保留连接/DNS/TLS 池（对齐 Android HttpURLConnection
  // keep-alive），避免每首歌重新握手导致起播秒级。实例 own 的 task 在 close() 里单独取消。
  private static let sharedSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    config.timeoutIntervalForRequest = ProgressiveHttpSource.readTimeoutSeconds
    config.timeoutIntervalForResource = 0   // 大文件不设总时长上限
    config.httpMaximumConnectionsPerHost = 4
    config.urlCredentialStorage = nil       // 过期链接不做凭据复用
    return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
  }()

  // MARK: 单一条件锁（等价 Android ReentrantLock + Condition）
  private let cond = NSCondition()

  private let originalURL: String
  private let headers: [String: String]
  private let cacheFile: URL
  private let session: URLSession
  private let onStateChanged: () -> Void

  // 写句柄由下载线程独占；读句柄由 BASS 音频线程独占（各自独立的文件位移，避免 seek 互相踩踏）。
  private var writeHandle: FileHandle?
  private var readHandle: FileHandle?
  private let readLock = NSLock()
  // 写句柄由主下载线程与尾段预取线程共享，seek+write 必须串行化。
  private let writeLock = NSLock()
  private var ranges = ByteRanges()
  private var worker: Thread?

  // guarded
  private var effectiveURL: String
  private var length: Int64 = -1
  private var rangeSupported = false
  private var readPosition: Int64 = 0
  private var priority: Int64?
  private var holdBytes: Int64 = 0
  private var resumeBytes: Int64 = ProgressiveHttpSource.defaultResumeBytes
  private var closed = false
  private var cancelled = false
  private var complete = false
  private var fatal: SourceError?
  private var transientError: RetryableTransferError?
  private var retrySignal = false
  private var received = false
  private var blockingThread: Thread?
  private var blockingDeadline: Double = 0   // epoch ms
  private var starved = false
  private var mainTask: URLSessionDataTask?
  private var mainPosition: Int64 = 0
  private var redirectMain = false
  private var tailPending = false
  private var tailStart: Int64 = 0

  // MARK: 公开只读状态

  var totalBytes: Int64 {
    cond.lock(); defer { cond.unlock() }
    return length
  }

  var downloadedBytes: Int64 {
    cond.lock(); defer { cond.unlock() }
    return ranges.totalBytes()
  }

  var isComplete: Bool {
    cond.lock(); defer { cond.unlock() }
    return complete
  }

  var failure: SourceError? {
    cond.lock(); defer { cond.unlock() }
    return fatal
  }

  var priorityPosition: Int64? {
    cond.lock(); defer { cond.unlock() }
    return priority
  }

  // MARK: 初始化

  init(url: String, headers: [String: String], cacheFile: URL, onStateChanged: @escaping () -> Void) throws {
    self.originalURL = url
    self.effectiveURL = url
    self.headers = headers
    self.cacheFile = cacheFile
    self.onStateChanged = onStateChanged

    self.session = ProgressiveHttpSource.sharedSession

    FileManager.default.createFile(atPath: cacheFile.path, contents: nil)
    self.writeHandle = try FileHandle(forWritingTo: cacheFile)
    self.readHandle = try FileHandle(forReadingFrom: cacheFile)
    super.init()
  }

  deinit {
    close()
  }

  /// 插件用它构造 BASS_FILEPROCS；user 指针在 stream 生命周期内必须被插件强持有。
  var fileProcs: BASS_FILEPROCS {
    return BASS_FILEPROCS(close: bassCloseProc, length: bassLenProc, read: bassReadProc, seek: bassSeekProc)
  }

  var userPointer: UnsafeMutableRawPointer {
    return Unmanaged.passUnretained(self).toOpaque()
  }

  // MARK: - 打开与阻塞控制

  /// 启动下载线程，等到响应头拿到文件长度（对齐 Android open）。
  func open(timeoutMs: Int64) throws {
    cond.lock()
    if worker == nil {
      let thread = Thread { [weak self] in self?.downloadLoop() }
      thread.name = "CyShine-HTTP"
      thread.stackSize = 512 * 1024
      worker = thread
      thread.start()
    }
    let deadline = Date().timeIntervalSince1970 + Double(timeoutMs) / 1000
    while length < 0 && fatal == nil && !closed && !cancelled {
      let remaining = deadline - Date().timeIntervalSince1970
      if remaining <= 0 { break }
      cond.wait(until: Date(timeIntervalSinceNow: remaining))
    }
    if length >= 0 { cond.unlock(); return }
    if let fatal = fatal { cond.unlock(); throw fatal }
    if closed || cancelled { cond.unlock(); throw SourceError(.cancelled, "load cancelled") }
    let last = transientError
    cond.unlock()
    throw SourceError(classifyOpen(last), last?.message ?? "no response within \(timeoutMs)ms")
  }

  /// 允许当前读线程等待缺失数据最多 budgetMs（对齐 beginBlocking）。
  func beginBlocking(budgetMs: Int64) {
    cond.lock()
    blockingThread = Thread.current
    blockingDeadline = Date().timeIntervalSince1970 * 1000 + Double(budgetMs)
    starved = false
    cond.unlock()
  }

  /// 结束阻塞读；返回是否有读因数据未到而放弃。
  @discardableResult
  func endBlocking() -> Bool {
    cond.lock()
    blockingThread = nil
    let result = starved
    starved = false
    cond.unlock()
    return result
  }

  func interruptBlocking() {
    cond.lock()
    blockingDeadline = 0
    cond.broadcast()
    cond.unlock()
  }

  func cancel() {
    cond.lock()
    cancelled = true
    blockingDeadline = 0
    cond.broadcast()
    cond.unlock()
  }

  func rewind() {
    cond.lock()
    readPosition = 0
    cond.unlock()
  }

  /// 优先下载 position 附近（seek 目标文件偏移）。
  func prioritize(_ position: Int64?) {
    var stale: URLSessionDataTask?
    cond.lock()
    priority = position.map { length > 0 ? max(0, min($0, length - 1)) : max($0, 0) }
    if position != nil { retrySignal = true }
    stale = staleMainLocked()
    cond.broadcast()
    cond.unlock()
    stale?.cancel()
  }

  func isBuffered(_ position: Int64, _ bytes: Int64) -> Bool {
    cond.lock(); defer { cond.unlock() }
    if length < 0 { return false }
    let from = max(0, min(position, length))
    let end = ranges.runEnd(from)
    return end - from >= bytes || end >= length
  }

  func runEnd(_ position: Int64) -> Int64 {
    cond.lock(); defer { cond.unlock() }
    return ranges.runEnd(position)
  }

  func setResumeBytes(_ bytes: Int64) {
    cond.lock(); resumeBytes = bytes; cond.unlock()
  }

  func holdUntilBuffered(_ bytes: Int64) {
    cond.lock(); holdBytes = bytes; cond.unlock()
  }

  func retryNow(reconnect: Bool) {
    var stale: URLSessionDataTask?
    cond.lock()
    retrySignal = true
    if reconnect && mainTask != nil && !redirectMain {
      redirectMain = true
      stale = mainTask
    }
    cond.broadcast()
    cond.unlock()
    stale?.cancel()
  }

  /// 释放连接/文件。插件须在 BASS_StreamFree 之后调用，避免回调落在已关闭的源上。
  func close() {
    var active: URLSessionDataTask?
    cond.lock()
    if closed { cond.unlock(); return }
    closed = true
    active = mainTask
    mainTask = nil
    cond.broadcast()
    cond.unlock()
    active?.cancel()
    writeLock.lock()
    // 共享 session 不能 invalidate（会波及其它歌曲）；本实例的 task 已在上面取消。
    try? writeHandle?.close()
    try? readHandle?.close()
    writeLock.unlock()
    writeHandle = nil
    readHandle = nil
    try? FileManager.default.removeItem(at: cacheFile)
  }

  // MARK: - BASS FILEPROCS 回调实现

  func fileLengthProc() -> UInt64 {
    cond.lock()
    let value = length
    cond.unlock()
    return value > 0 ? UInt64(value) : 0
  }

  func fileSeekProc(offset: Int64) -> Bool {
    var stale: URLSessionDataTask?
    cond.lock()
    if closed || offset < 0 || (length >= 0 && offset > length) { cond.unlock(); return false }
    readPosition = offset
    stale = staleMainLocked()
    cond.broadcast()
    cond.unlock()
    stale?.cancel()
    return true
  }

  func fileReadProc(into buffer: UnsafeMutableRawPointer, maxLength: UInt32) -> UInt32 {
    var stale: URLSessionDataTask?
    cond.lock()
    if closed { cond.unlock(); return UInt32.max }          // -1 = EOF
    if length < 0 { cond.unlock(); return 0 }               // 长度未知，stall
    if readPosition >= length { cond.unlock(); return UInt32.max }
    let blocking = blockingThread === Thread.current
    if ranges.runEnd(readPosition) <= readPosition {
      if blocking && priority != nil { priority = readPosition }
      stale = staleMainLocked()
      cond.broadcast()
    }
    cond.unlock()
    stale?.cancel()

    cond.lock()
    if closed { cond.unlock(); return UInt32.max }
    var available = ranges.runEnd(readPosition) - readPosition
    if blocking {
      while available <= 0 && !closed && !cancelled && fatal == nil {
        let remaining = blockingDeadline - nowMs()
        if remaining <= 0 { break }
        // 不支持 Range 时只能等主连接顺序下载，离得太远就放弃这次等待。
        if !rangeSupported && readPosition > mainPosition + ProgressiveHttpSource.redirectWindowBytes { break }
        cond.wait(until: Date(timeIntervalSinceNow: min(remaining, 250) / 1000))
        available = ranges.runEnd(readPosition) - readPosition
      }
      if available <= 0 {
        starved = true
        cond.unlock()
        return 0                                            // stall，要求更多数据
      }
    } else {
      if holdBytes > 0 {
        let end = ranges.runEnd(readPosition)
        let downloading = transientError == nil && fatal == nil
        if downloading && end - readPosition < holdBytes && end < length { cond.unlock(); return 0 }
        if available > 0 { holdBytes = 0 }
      }
      if available <= 0 {
        holdBytes = resumeBytes                             // 请求预缓一段后再续播
        cond.unlock()
        return 0
      }
    }
    let position = readPosition
    let count = Int(min(Int64(maxLength), available))
    cond.unlock()

    // 读句柄由音频线程独占；seek+read 用读锁串起来（防止重入）。
    readLock.lock()
    var data: Data?
    do {
      try readHandle?.seek(toOffset: UInt64(position))
      data = try readHandle?.read(upToCount: count)
    } catch {
      data = nil
    }
    readLock.unlock()
    guard let chunk = data, !chunk.isEmpty else {
      cond.lock()
      let isClosed = closed
      cond.unlock()
      return isClosed ? UInt32.max : 0
    }
    chunk.withUnsafeBytes { raw in
      if let base = raw.baseAddress { memcpy(buffer, base, chunk.count) }
    }
    cond.lock()
    if readPosition == position { readPosition = position + Int64(chunk.count) }
    cond.unlock()
    return UInt32(chunk.count)
  }

  // MARK: - 下载线程

  private func downloadLoop() {
    var failures = 0
    var emptyBodies = 0
    while true {
      guard let plan = nextTransfer() else {
        if isComplete { onStateChanged() }
        return
      }
      let (start, endInclusive) = plan
      do {
        try transfer(start: start, endInclusive: endInclusive, main: true)
        failures = 0
        emptyBodies = 0
      } catch let error as SourceError {
        if error.kind != .cancelled {
          cond.lock()
          if fatal == nil { fatal = error }
          cond.broadcast()
          cond.unlock()
          onStateChanged()
        }
        return
      } catch let error as RetryableTransferError {
        var redirected = false
        cond.lock()
        if closed { cond.unlock(); return }
        redirected = redirectMain
        redirectMain = false
        cond.unlock()
        if redirected { continue }

        var progressed: Bool
        var opening: Bool
        cond.lock()
        progressed = received
        received = false
        opening = length < 0
        cond.unlock()
        failures = progressed ? 1 : failures + 1
        if error.emptyBody && !progressed { emptyBodies += 1 } else { emptyBodies = 0 }
        // 起播阶段（尚未拿到文件长度）快速失败：不再耗满 4 次退避（500+1000+2000ms）。
        // progressive 注定失败时直接让上层回退 legacy BASS_StreamCreateURL，起播不再白等 3.5s。
        let emptyLimit = opening ? 1 : ProgressiveHttpSource.maxEmptyBodies
        if emptyBodies >= emptyLimit {
          cond.lock()
          if fatal == nil { fatal = SourceError(.http, "truncated response: \(error.message)") }
          cond.broadcast()
          cond.unlock()
          onStateChanged()
          return
        }
        setTransientError(error)
        let shift = min(max(0, failures - 1), 5)
        let delay = min(ProgressiveHttpSource.maxRetryDelayMs,
                        ProgressiveHttpSource.firstRetryDelayMs << shift)
        waitForRetry(delayMs: delay)
      } catch {
        cond.lock()
        if fatal == nil { fatal = SourceError(.unsupported, "\(error)") }
        cond.broadcast()
        cond.unlock()
        onStateChanged()
        return
      }
    }
  }

  /// 下一段要请求的范围（start, 含 endInclusive）；nil = 无事可做。
  private func nextTransfer() -> (Int64, Int64?)? {
    cond.lock()
    defer { cond.unlock() }
    while true {
    if closed || fatal != nil { return nil }
    if length < 0 { return (0, nil) }                        // 首次请求以拿到长度

    if let needed = neededLocked() {
      let start = priority != nil
        ? max(ranges.gapStart(needed), needed - ProgressiveHttpSource.seekLookbackBytes)
        : needed
      return (start, rangeEndTailClamped(start))
    }
    if !tailPending {
      if !complete {
        complete = true
        transientError = nil
        cond.broadcast()
      }
      return nil
    }
    // 尾段预取进行中：等它落地再判断是否完成（避免主线程空转）。
    cond.wait(until: Date(timeIntervalSinceNow: 1.0))
    }
  }

  private func neededLocked() -> Int64? {
    let anchor = max(0, min(priority ?? readPosition, length))
    let needed = ranges.runEnd(anchor)
    if tailPending && needed >= tailStart { return nil }
    return needed >= length ? nil : needed
  }

  /// nextRun 的结束位置，但尾段预取期间把主下载截止到 tailStart 之前，避免与尾线程重复拉取。
  private func rangeEndTailClamped(_ start: Int64) -> Int64? {
    guard tailPending && start < tailStart else {
      return ranges.nextRun(start).map { $0 - 1 }
    }
    if let next = ranges.nextRun(start), next <= tailStart {
      return next - 1
    }
    return tailStart - 1
  }

  /// 所需数据不在主连接即将到达的窗口内时，返回该主连接以便取消。
  private func staleMainLocked() -> URLSessionDataTask? {
    guard let task = mainTask, !redirectMain, rangeSupported, length >= 0 else { return nil }
    guard let needed = neededLocked() else { return nil }
    if needed >= mainPosition && needed <= mainPosition + ProgressiveHttpSource.redirectWindowBytes { return nil }
    redirectMain = true
    return task
  }

  private func shouldLeaveMain(_ position: Int64) -> Bool {
    cond.lock()
    defer { cond.unlock() }
    if closed { return true }
    if redirectMain { return true }
    if !rangeSupported { return false }
    if ranges.runEnd(position) - position > ProgressiveHttpSource.redirectWindowBytes { return true }
    if let needed = neededLocked(), needed < position || needed > position + ProgressiveHttpSource.redirectWindowBytes {
      return true
    }
    return false
  }

  // MARK: - 单次 Range 传输

  private func transfer(start: Int64, endInclusive: Int64?, main: Bool) throws {
    let request = try buildRequest(start: start, endInclusive: endInclusive)

    let delegate = TransferDelegate(
      requestedStart: start,
      requestedEndInclusive: endInclusive,
      isMain: main,
      shouldStop: { [weak self] pos in
        guard let self = self else { return true }
        return self.shouldLeaveMain(pos)
      },
      onChunk: { [weak self] offset, data in
        guard let self = self, !data.isEmpty else { return }
        self.writeCache(position: offset, data: data)
        if main {
          self.cond.lock()
          self.mainPosition = offset + Int64(data.count)
          self.cond.unlock()
        }
      },
      onLength: { [weak self] total, rangesWork in
        guard let self = self else { return nil }
        return self.acceptLength(total, rangesWork: rangesWork)
      },
      onRangeUnsupported: { [weak self] in
        guard let self = self else { return }
        self.cond.lock(); self.rangeSupported = false; self.cond.unlock()
      },
      onRedirect: { [weak self] url in
        guard let self = self else { return }
        self.cond.lock(); self.effectiveURL = url.absoluteString; self.cond.unlock()
      }
    )

    let task = session.dataTask(with: request)
    delegate.task = task
    task.delegate = delegate                                 // iOS 15+ task 级 delegate
    if main {
      cond.lock()
      mainTask = task
      mainPosition = start
      redirectMain = false
      cond.unlock()
    }
    task.resume()
    let completed = delegate.waitForCompletion(seconds: ProgressiveHttpSource.readTimeoutSeconds + 5)
    if main {
      cond.lock()
      if mainTask === task { mainTask = nil }
      cond.unlock()
    }

    if let fatal = delegate.fatalError {
      // 重定向目标链接可能先过期：回退原始 URL 再试。
      if fatal.expiredURL {
        cond.lock()
        let didReset = effectiveURL != originalURL
        if didReset { effectiveURL = originalURL }
        cond.unlock()
        if didReset { throw makeRetryError("http \(fatal.status) from redirected URL") }
      }
      throw fatal
    }
    if let retry = delegate.retryFailure { throw retry }
    if !completed { throw makeRetryError("response timeout") }
    if delegate.stopped { return }                            // 主动换行，不算失败
    if let end = delegate.bodyEnd, delegate.written < end - delegate.bodyStart {
      throw makeRetryError("connection closed at \(delegate.written) of \(end - delegate.bodyStart)")
    }
  }

  private func buildRequest(start: Int64, endInclusive: Int64?) throws -> URLRequest {
    cond.lock()
    let urlString = effectiveURL
    let isClosed = closed
    cond.unlock()
    if isClosed { throw SourceError(.cancelled, "closed") }
    guard let url = URL(string: urlString) else { throw SourceError(.unsupported, "bad URL") }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue(ProgressiveHttpSource.userAgent, forHTTPHeaderField: "User-Agent")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    // 透明 gzip 会隐藏 Content-Length 并破坏字节范围。
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(endInclusive.map { "bytes=\(start)-\($0)" } ?? "bytes=\(start)-",
                     forHTTPHeaderField: "Range")
    return request
  }

  /// 返回错误表示长度冲突（调用方据此取消传输）。
  private func acceptLength(_ total: Int64, rangesWork: Bool) -> SourceError? {
    cond.lock()
    defer { cond.unlock() }
    if length < 0 {
      length = total
      rangeSupported = rangesWork
      if rangesWork && total >= ProgressiveHttpSource.tailMinFileBytes {
        tailStart = total - ProgressiveHttpSource.tailBytes
        tailPending = true
      }
      try? writeHandle?.truncate(atOffset: UInt64(total))    // 稀疏占位（等价 Android setLength）
      cond.broadcast()
      let startTail = tailPending
      cond.unlock()
      if startTail {
        let thread = Thread { [weak self] in self?.fetchTail() }
        thread.name = "CyShine-HTTP-tail"
        thread.stackSize = 256 * 1024
        thread.start()
      }
      cond.lock()
      return nil
    }
    if length != total {
      return SourceError(.http, "file length changed from \(length) to \(total)")
    }
    if rangesWork { rangeSupported = true }
    return nil
  }

  /// 尾段预取：解码器打开时常读文件尾标签，阻塞等网络；独立线程先拉最后 64KB。
  private func fetchTail() {
    cond.lock()
    guard tailPending, length >= 0 else { cond.unlock(); return }
    let start = tailStart
    let end = length - 1
    cond.unlock()
    do {
      try transfer(start: start, endInclusive: end, main: false)
    } catch {
      // 尾段失败不影响主下载：主线程走到 tailStart 后会自行继续。
    }
    cond.lock()
    tailPending = false
    cond.broadcast()
    cond.unlock()
  }

  private func writeCache(position: Int64, data: Data) {
    cond.lock()
    guard !closed else { cond.unlock(); return }
    cond.unlock()
    writeLock.lock()
    do {
      try writeHandle?.seek(toOffset: UInt64(position))
      try writeHandle?.write(contentsOf: data)
      writeLock.unlock()
    } catch {
      writeLock.unlock()
      cond.lock()
      if fatal == nil { fatal = SourceError(.unsupported, "cache write failed: \(error)") }
      cond.broadcast()
      cond.unlock()
      return
    }
    cond.lock()
    ranges.add(position, position + Int64(data.count))
    received = true
    cond.broadcast()
    cond.unlock()
  }

  // MARK: - 每次传输的 URLSession 代理（self-contained）

  private final class TransferDelegate: NSObject, URLSessionDataDelegate {
    let requestedStart: Int64
    let requestedEndInclusive: Int64?
    let isMain: Bool
    let shouldStop: (Int64) -> Bool
    let onChunk: (Int64, Data) -> Void
    let onLength: (Int64, Bool) -> SourceError?
    let onRangeUnsupported: () -> Void
    let onRedirect: (URL) -> Void

    private(set) var fatalError: SourceError?
    private(set) var retryFailure: RetryableTransferError?
    private(set) var stopped = false
    private(set) var gotResponse = false
    private(set) var bodyStart: Int64 = 0
    private(set) var bodyEnd: Int64?       // 开区间
    private(set) var written: Int64 = 0
    private var redirectCount = 0
    private let completionSem = DispatchSemaphore(value: 0)
    weak var task: URLSessionDataTask?

    init(requestedStart: Int64, requestedEndInclusive: Int64?, isMain: Bool,
         shouldStop: @escaping (Int64) -> Bool,
         onChunk: @escaping (Int64, Data) -> Void,
         onLength: @escaping (Int64, Bool) -> SourceError?,
         onRangeUnsupported: @escaping () -> Void,
         onRedirect: @escaping (URL) -> Void) {
      self.requestedStart = requestedStart
      self.requestedEndInclusive = requestedEndInclusive
      self.isMain = isMain
      self.shouldStop = shouldStop
      self.onChunk = onChunk
      self.onLength = onLength
      self.onRangeUnsupported = onRangeUnsupported
      self.onRedirect = onRedirect
    }

    func waitForCompletion(seconds: Double) -> Bool {
      return completionSem.wait(timeout: .now() + seconds) == .success
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
      redirectCount += 1
      if redirectCount > ProgressiveHttpSource.maxRedirects {
        retryFailure = makeRetryError("too many redirects")
        completionHandler(nil)
        return
      }
      if let url = request.url { onRedirect(url) }
      completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
      guard let http = response as? HTTPURLResponse else {
        retryFailure = makeRetryError("non-HTTP response")
        completionHandler(.cancel)
        return
      }
      let status = http.statusCode

      guard (200...299).contains(status) else {
        if status == ProgressiveHttpSource.httpTimeout || status == ProgressiveHttpSource.tooManyRequests {
          retryFailure = makeRetryError("http \(status)")
        } else if (400...499).contains(status) {
          fatalError = SourceError(.http, "HTTP \(status)", status: status)
        } else {
          retryFailure = makeRetryError("http \(status)")
        }
        completionHandler(.allow)   // 收完 body 再进 didComplete
        return
      }

      var start = requestedStart
      var endExclusive: Int64?
      var total: Int64
      var rangesWork = false

      if status == 206 {
        guard let range = parseContentRange(http.value(forHTTPHeaderField: "Content-Range")),
              range.start == requestedStart, let t = range.total else {
          retryFailure = makeRetryError("invalid 206 Content-Range")
          completionHandler(.cancel)
          return
        }
        total = t
        start = range.start
        endExclusive = range.endInclusive + 1
        rangesWork = true
      } else { // 200
        guard isMain else {
          retryFailure = makeRetryError("range ignored (200 for non-main)")
          completionHandler(.cancel)
          return
        }
        total = http.expectedContentLength
        guard total > 0 else {
          fatalError = SourceError(.unsupported, "unknown content length")
          completionHandler(.cancel)
          return
        }
        let accept = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "")
          .localizedCaseInsensitiveContains("bytes")
        rangesWork = requestedStart == 0 && accept
        start = 0
        endExclusive = total
        if requestedStart > 0 { onRangeUnsupported() }
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("text/html") {
          fatalError = SourceError(.http, "unexpected text/html response", status: 200)
          completionHandler(.cancel)
          return
        }
      }

      if let error = onLength(total, rangesWork) {
        fatalError = error
        completionHandler(.cancel)
        return
      }
      bodyStart = start
      bodyEnd = endExclusive
      gotResponse = true
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      guard gotResponse, fatalError == nil, retryFailure == nil else { return }
      if isMain && shouldStop(bodyStart + written) {
        stopped = true
        task?.cancel()
        return
      }
      let remaining = bodyEnd.map { max(0, $0 - written) } ?? Int64(data.count)
      let take = Int(min(Int64(data.count), remaining))
      if take <= 0 { return }
      onChunk(bodyStart + written, Data(data.prefix(take)))
      written += Int64(take)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      if let error = error, fatalError == nil, retryFailure == nil, !stopped {
        if let urlError = error as? URLError {
          if urlError.code != .cancelled {
            retryFailure = classifyNetworkError(urlError)
          }
        } else {
          retryFailure = makeRetryError("\(error)")
        }
      }
      completionSem.signal()
    }
  }

  // MARK: - 工具

  private func setTransientError(_ error: RetryableTransferError) {
    cond.lock()
    let before = transientError != nil
    transientError = error
    cond.broadcast()
    cond.unlock()
    if !before { onStateChanged() }
  }

  private func waitForRetry(delayMs: Int64) {
    cond.lock()
    let until = Date().timeIntervalSince1970 + Double(delayMs) / 1000
    while !closed && !retrySignal {
      let remaining = until - Date().timeIntervalSince1970
      if remaining <= 0 { break }
      cond.wait(until: Date(timeIntervalSinceNow: remaining))
    }
    retrySignal = false
    cond.unlock()
  }

  private func classifyOpen(_ error: RetryableTransferError?) -> SourceErrorKind {
    guard let error = error else { return .timeout }
    if error.unsupportedSSL { return .unsupported }
    if error.failsOpen { return .offline }
    return .timeout
  }

  private func nowMs() -> Double {
    return Date().timeIntervalSince1970 * 1000
  }
}

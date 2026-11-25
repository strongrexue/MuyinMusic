import '../mina_constants.dart';
import 'speaker_gateway.dart';
import 'takeover_clock.dart';

/// 推播落地验证的结局。
enum PushVerifyOutcome {
  /// 正证据确认落地：音箱取了我们的流且在播（或直推路径的
  /// position 证据链成立）。
  landed,

  /// 在播的不是我们：audio_id 是外来的，或在播却始终没取我们的流
  /// （原生小爱抢先起播的典型形态）。
  foreignPlaying,

  /// 推送从未被取流，设备也没在播我们的内容。
  notFetched,

  /// 证据不足以下结论（取了流但没在播、状态读不到、直推路径
  /// position 证据链不成立等）。
  unconfirmed,
}

/// 推播落地验证（正证据模型）。
///
/// ubus 回执不可信：返回成功 ≠ 设备真在播（云端受理但设备没拉流），
/// 返回失败 ≠ 没播（3012 超时但已生效）。下发后回读播放状态，
/// 只认**正证据**：
///
/// - 经代理推播（[fetchedSignal] 非空）：落地 ⟺ 代理已被取流且
///   采样在播。在播判定只看状态的播放标志，不依赖 position 数值
///   （LX06 的 position 可为 -1/null，TrackFerry 确认同样只靠
///   fetched+播放中）。position 证据链在此路径**不再成立**——
///   原生在播时 position 照样推进，曾被误记为我们的落地
///   （1.3.26/1.3.27 真机实证）。
/// - 在播但没取流 = 外来播放在播：连续 2 次采样如此即判
///   [PushVerifyOutcome.foreignPlaying]（给设备起播留一帧宽限）。
/// - audio_id 非空且不是 [kDefaultMusicAudioId] 的在播同样是
///   外来播放，立即判 foreign（TrackFerry `foreign` 判定）。
/// - 直推回退（[fetchedSignal] 为空，无取流信号可凭）：沿用
///   position 证据链（两次推进 / 单帧 ≥3000ms / position 恒
///   不可得时连续两次在播），身份门同样生效。
///
/// [onFetchedStale]：取流信号已为真、但迟迟没有在播确认时的一次性
/// 回调（TrackFerry 的 UnmuteAfter：fetched 后 2.5s 仍未确认也先
/// 恢复音量，不让用户干等静音）。触发时刻以采样帧近似（采样间隔
/// 粒度），回调只触发一次，验证本身继续跑满。
///
/// [cancelled]：外部废弃（新指令取代）时提前收尾，返回
/// [PushVerifyOutcome.unconfirmed]，调用方按代际丢弃。
Future<PushVerifyOutcome> verifyPushLanded(
  SpeakerGateway gateway,
  TakeoverClock clock,
  String deviceId, {
  int attempts = 8,
  Duration delay = const Duration(milliseconds: 1200),
  bool Function()? fetchedSignal,
  Duration fetchedUnmuteAfter = const Duration(milliseconds: 2500),
  void Function()? onFetchedStale,
  bool Function()? cancelled,
}) async {
  final fetchedMode = fetchedSignal != null;
  var sawFetched = false;
  var playingNotFetchedStreak = 0;
  int? lastPositionMs;
  var playingStreak = 0;
  var sawPosition = false;
  int? fetchedAtMs;
  var fetchedStaleFired = false;
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (attempt > 0) await clock.sleep(delay);
    if (cancelled?.call() ?? false) return PushVerifyOutcome.unconfirmed;
    // 取流时刻以轮询近似：首次查到 fetched 的采样点记为取流时刻。
    if (fetchedMode && fetchedSignal()) {
      sawFetched = true;
      fetchedAtMs ??= clock.nowMs();
      if (!fetchedStaleFired &&
          onFetchedStale != null &&
          clock.nowMs() - fetchedAtMs >= fetchedUnmuteAfter.inMilliseconds) {
        fetchedStaleFired = true;
        onFetchedStale();
      }
    }
    final status = await gateway.getPlayerStatus(deviceId);
    if (status == null) {
      playingStreak = 0;
      playingNotFetchedStreak = 0;
      continue;
    }
    // 身份门：在播的是原生（外来 audio_id）→ 立即判外来。
    if (status.isForeignPlayback) return PushVerifyOutcome.foreignPlaying;

    if (fetchedMode) {
      final fetched = fetchedSignal();
      if (fetched) sawFetched = true;
      if (!status.isPlaying) {
        playingNotFetchedStreak = 0;
        continue;
      }
      // 正证据：取了我们的流且在播（position 是 -1/null 也算）。
      if (fetched) return PushVerifyOutcome.landed;
      // 在播却没取我们的流：播的是别人（多半是原生抢先起播）。
      playingNotFetchedStreak++;
      if (playingNotFetchedStreak >= 2) {
        return PushVerifyOutcome.foreignPlaying;
      }
      continue;
    }

    // 直推回退：position 证据链。
    if (!status.isPlaying) {
      playingStreak = 0;
      lastPositionMs = status.positionMs ?? lastPositionMs;
      continue;
    }
    playingStreak++;
    final position = status.positionMs;
    if (position == null) {
      // position 恒不可得的设备才走连续在播兜底。
      if (!sawPosition && playingStreak >= 2) {
        return PushVerifyOutcome.landed;
      }
      continue;
    }
    sawPosition = true;
    if (position >= 3000) return PushVerifyOutcome.landed;
    if (lastPositionMs != null &&
        lastPositionMs > 0 &&
        position > lastPositionMs) {
      return PushVerifyOutcome.landed;
    }
    lastPositionMs = position;
  }
  if (fetchedMode && !sawFetched) return PushVerifyOutcome.notFetched;
  return PushVerifyOutcome.unconfirmed;
}

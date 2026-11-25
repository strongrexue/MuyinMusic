import '../mina_constants.dart';
import 'speaker_gateway.dart';
import 'takeover_clock.dart';

/// 推播落地验证（miot `PUSH_VERIFY_*` 参数与 1.7.6 的证据链要求）。
///
/// ubus 回执不可信：返回成功 ≠ 设备真在播（云端受理但设备没拉流），
/// 返回失败 ≠ 没播（3012 超时但已生效）。下发后回读播放状态，
/// 满足以下任一证据才算落地：
/// - 两次采样 position 均 >0 且后一次大于前一次（真推进）；
/// - 单次采样 position ≥ 3000ms 且在播（已播出数秒量级）；
/// - 代理取流信号为真，且至少一份采样在播（取流+在播双证）；
/// - position 恒不可得时，连续两次采样都是播放中（兜底）。
///
/// 首帧 position=0 不算落地：刚下发时设备常先报 status=1/position=0
/// 却始终没拉到流，旧「position 落在起播窗口内即落地」规则会把这种
/// 假播放误判为成功，故已删除。
///
/// 身份门（TrackFerry `foreign` 判定）：全部证据只认归属为我们或
/// 未知的在播——采样在播且 audio_id 非空又不是 [kDefaultMusicAudioId]
/// 时，那是原生小爱在播，立即判未落地。只看 position 会把原生的
/// 播放记成我们的成功（1.3.26 真机实证）。
///
/// [onFetchedStale]：取流信号已为真、但迟迟没有在播确认时的一次性
/// 回调（TrackFerry 的 UnmuteAfter：fetched 后 2.5s 仍未确认也先
/// 恢复音量，不让用户干等静音）。触发时刻以采样帧近似（采样间隔
/// 粒度），回调只触发一次，验证本身继续跑满。
Future<bool> verifyPushLanded(
  SpeakerGateway gateway,
  TakeoverClock clock,
  String deviceId, {
  int attempts = 8,
  Duration delay = const Duration(milliseconds: 1200),
  bool Function()? fetchedSignal,
  Duration fetchedUnmuteAfter = const Duration(milliseconds: 2500),
  void Function()? onFetchedStale,
}) async {
  int? lastPositionMs;
  var playingStreak = 0;
  var sawPosition = false;
  int? fetchedAtMs;
  var fetchedStaleFired = false;
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (attempt > 0) await clock.sleep(delay);
    // 取流时刻以轮询近似：首次查到 fetched 的采样点记为取流时刻。
    if (fetchedSignal != null && fetchedSignal()) {
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
      continue;
    }
    // 身份门：在播的是原生（外来 audio_id）→ 立即判未落地。
    if (status.isForeignPlayback) return false;
    if (!status.isPlaying) {
      playingStreak = 0;
      lastPositionMs = status.positionMs ?? lastPositionMs;
      continue;
    }
    playingStreak++;
    // 取流+在播双证：当前采样已在播且归属非外来，取流信号为真即落地。
    if (fetchedSignal != null && fetchedSignal()) return true;
    final position = status.positionMs;
    if (position == null) {
      // position 恒不可得的设备才走连续在播兜底。
      if (!sawPosition && playingStreak >= 2) return true;
      continue;
    }
    sawPosition = true;
    if (position >= 3000) return true;
    if (lastPositionMs != null &&
        lastPositionMs > 0 &&
        position > lastPositionMs) {
      return true;
    }
    lastPositionMs = position;
  }
  return false;
}

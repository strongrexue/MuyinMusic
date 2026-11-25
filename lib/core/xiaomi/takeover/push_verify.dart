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
Future<bool> verifyPushLanded(
  SpeakerGateway gateway,
  TakeoverClock clock,
  String deviceId, {
  int attempts = 8,
  Duration delay = const Duration(milliseconds: 1200),
  bool Function()? fetchedSignal,
}) async {
  int? lastPositionMs;
  var playingStreak = 0;
  var sawPosition = false;
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (attempt > 0) await clock.sleep(delay);
    final status = await gateway.getPlayerStatus(deviceId);
    if (status == null) {
      playingStreak = 0;
      continue;
    }
    if (!status.isPlaying) {
      playingStreak = 0;
      lastPositionMs = status.positionMs ?? lastPositionMs;
      continue;
    }
    playingStreak++;
    // 取流+在播双证：当前采样已在播，取流信号为真即落地。
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

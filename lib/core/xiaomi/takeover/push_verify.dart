import 'speaker_gateway.dart';
import 'takeover_clock.dart';

/// 推播落地验证（miot `PUSH_VERIFY_*` 参数与 1.7.6 的证据链要求）。
///
/// ubus 回执不可信：返回成功 ≠ 设备真在播（云端受理但设备没拉流），
/// 返回失败 ≠ 没播（3012 超时但已生效）。下发后回读播放状态，
/// 满足以下任一证据才算落地：
/// - 播放中且流内 position 落在起播窗口（≤30s）内；
/// - 连续两次采样 position 在推进；
/// - position 不可得时，连续两次采样都是播放中。
Future<bool> verifyPushLanded(
  SpeakerGateway gateway,
  TakeoverClock clock,
  String deviceId, {
  int attempts = 5,
  Duration delay = const Duration(milliseconds: 1200),
  int startWindowMs = 30000,
}) async {
  int? lastPositionMs;
  var playingStreak = 0;
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
    final position = status.positionMs;
    if (position == null) {
      if (playingStreak >= 2) return true;
      continue;
    }
    if (lastPositionMs != null && position > lastPositionMs) return true;
    if (position <= startWindowMs) return true;
    lastPositionMs = position;
  }
  return false;
}

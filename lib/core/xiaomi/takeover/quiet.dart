import 'dart:async';

import '../mina_models.dart';
import 'speaker_gateway.dart';
import 'takeover_clock.dart';

/// 待恢复音量的落盘接缝（蓝本 `store.PendingVolume` 语义）。
///
/// 接管静音前先把原音量落盘、恢复后才清除，App 异常退出也不会把
/// 音箱留在静音：宿主有周期性的 RecoverVolumes 扫落盘自愈。
/// [savePendingVolume] 已有条目时不覆盖（先落盘的那份才是用户
/// 的真实音量，中途的 0 不是）。
abstract interface class TakeoverMuteStore {
  Future<int?> readPendingVolume(String deviceId);

  Future<void> savePendingVolume(String deviceId, int volume);

  /// 改恢复目标（静音期间用户调了音量）；返回此前是否有待恢复条目。
  Future<bool> changePendingVolume(String deviceId, int volume);

  Future<void> clearPendingVolume(String deviceId);
}

/// 一次静音的结果（蓝本 mute 的返回值打包）。
class MuteResult {
  const MuteResult({
    required this.volume,
    required this.muted,
    required this.statusOk,
    this.statusNote = '',
    this.note = '',
    this.error,
  });

  /// 要恢复到的音量；-1 表示未知（没静音）。
  final int volume;

  /// 是否已持有静音（音量已压到 0，或沿用上一轮的静音）。
  final bool muted;

  /// 状态读是否成功（写 status step 用）。
  final bool statusOk;
  final String statusNote;

  /// 静音附带说明（如沿用落盘音量）。
  final String note;
  final Object? error;
}

/// 静音与音量恢复（蓝本 `quiet.go` 的 mute + `takeover.go` 的
/// putBack / recoverOnce 的移植；深度静音 Deep 是米家 MIoT 通道，
/// LX06 不在 hush 表内、恒走普通静音，故不移植）。
class TakeoverQuiet {
  TakeoverQuiet({
    required SpeakerGateway gateway,
    required TakeoverClock clock,
    required TakeoverMuteStore? store,
    required String deviceId,
    void Function(String message)? onLog,
  }) : _gateway = gateway,
       _clock = clock,
       _store = store,
       _deviceId = deviceId,
       _onLog = onLog;

  final SpeakerGateway _gateway;
  final TakeoverClock _clock;
  final TakeoverMuteStore? _store;
  final String _deviceId;
  final void Function(String message)? _onLog;

  /// 内存里记住的上次非零音量（蓝本 volumes[dev]）。
  int? _knownVolume;

  /// 我们认为音箱正被我们压在 0（静音持有）。
  bool _muteHeld = false;

  bool get muteHeld => _muteHeld;

  /// mute 串行锁（蓝本 d.vol：后来者等先者）。
  Future<void> _muteLock = Future.value();

  /// 顺手记音量：只记 >0 的（0 可能是我们自己压的）。
  void know(MinaPlayerStatus? status) {
    final volume = status?.volume;
    if (volume != null && volume > 0) _knownVolume = volume;
  }

  void knowValue(int volume) {
    if (volume > 0) _knownVolume = volume;
  }

  Future<int?> pendingVolume() async =>
      _store?.readPendingVolume(_deviceId);

  Future<void> clearPending() async =>
      _store?.clearPendingVolume(_deviceId);

  Future<bool> hasPending() async => await pendingVolume() != null;

  /// 下发音量并验回执：失败重试至多 2 次（间隔 300ms）。
  ///
  /// 与蓝本的偏差：蓝本按错误种类分流（明确拒绝才清 pending、
  /// 其余按已送达处理）；我们的网关只有 bool 回执、分不出拒绝
  /// 与丢失，故置 0 走验回执重试，全败时不宣称已静音、pending
  /// 保留给 RecoverVolumes 兜底（1.3.27 审计：回执被丢弃曾让
  /// 静音失败完全静默）。
  Future<bool> setVolumeVerified(int volume) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      bool ok;
      try {
        ok = await _gateway.setVolume(_deviceId, volume);
      } catch (_) {
        ok = false;
      }
      if (ok) return true;
      if (attempt < 2) {
        await _clock.sleep(const Duration(milliseconds: 300));
      }
    }
    return false;
  }

  /// 静音（蓝本 `mute()`）：串行执行。
  ///
  /// 已有落盘待恢复音量时沿用它并视为已静音（上一轮/上个进程
  /// 压的）；否则先读状态确认当前音量（防记错），volume>0 才
  /// 先落盘后置 0；当前音量是 0 时用内存记住的上次音量；
  /// 音量未知则不静音（没把握恢复就不压）。
  Future<MuteResult> mute() {
    final run = _muteLock.then((_) => _muteLocked());
    _muteLock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<MuteResult> _muteLocked() async {
    final store = _store;
    if (store == null) {
      return const MuteResult(volume: -1, muted: false, statusOk: false);
    }
    final pending = await store.readPendingVolume(_deviceId);
    if (pending != null) {
      _muteHeld = true;
      return MuteResult(
        volume: pending,
        muted: true,
        statusOk: true,
        statusNote: '沿用待恢复音量 $pending',
        note: '沿用待恢复音量 $pending',
      );
    }
    MinaPlayerStatus? status;
    try {
      status = await _gateway.getPlayerStatus(_deviceId);
    } catch (_) {
      status = null;
    }
    know(status);
    var volume = status?.volume ?? -1;
    if (volume == 0) volume = _knownVolume ?? -1;
    if (volume <= 0) {
      return MuteResult(
        volume: -1,
        muted: false,
        statusOk: status != null,
        statusNote: status == null ? '状态读不到' : '',
        note: '当前音量未知，没有静音',
      );
    }
    // 先落盘后置 0：置 0 之后崩溃也有据可恢复。
    await store.savePendingVolume(_deviceId, volume);
    final ok = await setVolumeVerified(0);
    if (!ok) {
      return MuteResult(
        volume: volume,
        muted: false,
        statusOk: true,
        note: '静音没有下发成功',
        error: 'setVolume(0) not acknowledged',
      );
    }
    _muteHeld = true;
    return MuteResult(volume: volume, muted: true, statusOk: status != null);
  }

  /// 恢复音量（蓝本 `putBack`）：最多 3 轮，间隔 300ms；每轮
  /// 重读落盘值（静音期间用户改过恢复目标就用新值），恢复的
  /// 值与落盘一致才清除落盘。返回 (设上的音量, 错误)。
  Future<({int volume, Object? error})> putBack(int fallbackVolume) async {
    final store = _store;
    var target = fallbackVolume;
    Object? lastError;
    for (var round = 0; round < 3; round++) {
      final pending = await store?.readPendingVolume(_deviceId);
      if (pending != null) target = pending;
      if (target <= 0) {
        _muteHeld = false;
        return (volume: target, error: null);
      }
      bool ok;
      try {
        ok = await _gateway.setVolume(_deviceId, target);
      } catch (e) {
        ok = false;
        lastError = e;
      }
      if (ok) {
        knowValue(target);
        final now = await store?.readPendingVolume(_deviceId);
        if (now == null || now == target) {
          await store?.clearPendingVolume(_deviceId);
          _muteHeld = false;
          return (volume: target, error: null);
        }
        target = now; // 恢复期间被改过：用新值再设一轮
        continue;
      }
      lastError ??= 'setVolume($target) not acknowledged';
      if (round < 2) {
        await _clock.sleep(const Duration(milliseconds: 300));
      }
    }
    return (volume: target, error: lastError ?? 'restore failed');
  }

  /// 静音期间改音量：只改恢复目标（蓝本 control.SetVolume）。
  Future<bool> changePendingVolume(int volume) async {
    final store = _store;
    if (store == null) return false;
    final changed = await store.changePendingVolume(_deviceId, volume);
    if (changed) knowValue(volume);
    return changed;
  }

  /// RecoverVolumes 的一轮（蓝本 recoverOnce）：[held] 为真
  /// （有 run/quiet 正持有这台音箱）时跳过；落盘有待恢复音量时，
  /// 当前音量已被调回（>0）只清落盘，仍是 0 则设回去再清。
  /// 返回是否处理了一笔（供日志）。
  Future<bool> recoverOnce({required bool held}) async {
    final store = _store;
    if (store == null || held) return false;
    final pending = await store.readPendingVolume(_deviceId);
    if (pending == null) return false;
    MinaPlayerStatus? status;
    try {
      status = await _gateway.getPlayerStatus(_deviceId);
    } catch (_) {
      status = null;
    }
    final volume = status?.volume;
    if (volume == null) return false; // 读不到，下一轮再试
    know(status);
    if (volume > 0) {
      await store.clearPendingVolume(_deviceId);
      _muteHeld = false;
      return true;
    }
    final ok = await _gateway.setVolume(_deviceId, pending);
    if (ok) {
      knowValue(pending);
      await store.clearPendingVolume(_deviceId);
      _muteHeld = false;
      _onLog?.call('takeover recovered muted volume $pending');
      return true;
    }
    return false;
  }
}

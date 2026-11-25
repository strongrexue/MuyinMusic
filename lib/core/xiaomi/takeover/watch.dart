import 'dart:async';
import 'dart:math' as math;

import '../mina_models.dart';
import 'speaker_stream_proxy.dart';
import 'takeover_clock.dart';
import 'takeover_types.dart';

/// watch 阶段对引擎的最小依赖面。
abstract interface class WatchHost {
  Future<MinaPlayerStatus?> status();
  Future<bool> playUrl(String url);
  Future<void> halt();
  bool runInactive(TakeoverRun run);
  void knowVolume(MinaPlayerStatus? status);
  bool isForeign(MinaPlayerStatus status);
}

/// 跟随播放（蓝本 `watch.go` 的移植）。
///
/// 推播的流在音箱状态里不报进度，watch 自维护播放时钟（取流
/// 时刻 + startLag 起算）；有人跟小爱说话把歌打断时按谈话窗
/// 等待、必要时续推；歌放完时主动停掉音箱的单曲循环；外来
/// 播放持续出现则让行退出。偏离蓝本处：heard 事件经 run 的
/// 缓冲队列投递，处理延迟以回看间隔为界（蓝本是通道即时唤醒）；
/// 按钮 Press 的 deaf/cut 分支无 UI 入口，不移植（语音 pause
/// 走 byUser 路径，语义一致）。
class TakeoverWatcher {
  TakeoverWatcher({
    required WatchHost host,
    required TakeoverClock clock,
    required TakeoverTiming timing,
  }) : _host = host,
       _clock = clock,
       _timing = timing;

  final WatchHost _host;
  final TakeoverClock _clock;
  final TakeoverTiming _timing;

  Future<TakeoverEnd> watch(TakeoverRun run, StreamHandle track) async {
    final tm = _timing;
    final length = track.lengthMs;
    final fetchedAt = track.fetchedAtMs ?? _clock.nowMs();
    final limitMs = _clock.nowMs() + tm.maxWatch.inMilliseconds;

    var base = 0; // anchor 之前已播的毫秒
    var anchor = fetchedAt + tm.startLag.inMilliseconds;
    var sounding = true;
    int at() => sounding
        ? base + math.max(0, _clock.nowMs() - anchor)
        : base;

    var talkedUntilMs = 0;
    var silent = 0;
    var foreign = 0;
    var byUser = false;
    var cut = false;
    var yield_ = false;
    var pausedAtMs = 0;
    var resumes = 0;
    var lastOkMs = _clock.nowMs();
    int? handledRestartAt;

    void pauseClock(int whenMs) {
      if (!sounding) return;
      base = math.max(0, base + whenMs - anchor);
      if (length > 0 && base > length) base = length;
      sounding = false;
      pausedAtMs = _clock.nowMs();
    }

    void playClock(int fromMs, int whenMs) {
      base = fromMs;
      anchor = whenMs;
      sounding = true;
      pausedAtMs = 0;
    }

    // rest：等谈话窗过去，报告是否可以接下一首（蓝本 rest）。
    Future<bool> rest() async {
      void take(HeardEvent h) {
        if (h.control == 'resume') {
          // 继续放不算打断。
        } else if (h.control != null || h.audio) {
          byUser = true;
        } else if (h.woke) {
          talkedUntilMs = _clock.nowMs() + 15000;
        } else {
          talkedUntilMs =
              h.atMs +
              tm.pause.inMilliseconds +
              math.min(45000, h.answerRunes * tm.speakPerRune.inMilliseconds);
        }
      }

      while (!_host.runInactive(run)) {
        final drained = run.drainHeard();
        for (final h in drained) {
          take(h);
        }
        if (drained.isNotEmpty) continue;
        final left = talkedUntilMs - _clock.nowMs();
        if (byUser || yield_ || talkedUntilMs == 0 || left <= 0) {
          return !byUser && !yield_;
        }
        await _waitSlice(run, Duration(milliseconds: left));
      }
      return false;
    }

    // finish：歌放完的收尾——停掉音箱的单曲循环（蓝本 finish）。
    Future<TakeoverEnd> finish(String why) async {
      final p = await _host.status();
      if (p != null && _host.isForeign(p)) {
        run.step(TakeoverStepName.ended, true, '$why，音箱在放别的，不动它');
        return TakeoverEnd.other;
      }
      if (p != null && !p.isPlaying) {
        run.step(TakeoverStepName.ended, true, '$why，音箱已经停了');
        return await rest() ? TakeoverEnd.played : TakeoverEnd.other;
      }
      Object? stopError;
      for (var i = 0; i < 4; i++) {
        await _host.halt();
        stopError = null;
        // halt 只回 stop 结果：无从得知成败时按蓝本以「停没停」
        // 复查——这里 halt 已尽力，循环按蓝本次数走完或提前确认。
        final s = await _host.status();
        if (s == null || !s.isPlaying) break;
        if (i < 3) {
          await _clock.sleep(Duration(seconds: i + 1));
          if (_host.runInactive(run)) break;
        }
      }
      run.step(
        TakeoverStepName.ended,
        stopError == null,
        '$why，停止循环',
      );
      return await rest() ? TakeoverEnd.played : TakeoverEnd.other;
    }

    // again：从断点续推（蓝本 again）。
    Future<bool> again() async {
      if (resumes >= 20) return false;
      resumes++;
      final from = math.max(1000, base - 1500);
      StreamHandle nTrack = track;
      var start = 0;
      var resumed = false;
      try {
        final r = await track.resume(from);
        if (r != null) {
          nTrack = r.handle;
          start = r.startMs;
          resumed = true;
        }
      } catch (_) {
        resumed = false;
      }
      var ok = await _host.playUrl(nTrack.url);
      for (var i = 0; !ok && i < 3; i++) {
        if (await _sleepOrInactive(run, Duration(milliseconds: (i + 1) * 400))) {
          return false;
        }
        ok = await _host.playUrl(nTrack.url);
      }
      if (!ok) {
        run.step(TakeoverStepName.resume, false, '推送失败');
        return false;
      }
      if (resumed) {
        // 等新流被取（蓝本等 Fetched，6 秒封顶）。
        final deadline = _clock.nowMs() + 6000;
        while (!nTrack.fetched &&
            _clock.nowMs() < deadline &&
            !_host.runInactive(run)) {
          await _clock.sleep(const Duration(milliseconds: 100));
        }
        if (!nTrack.fetched) {
          run.step(TakeoverStepName.resume, false, '音箱没有来取流');
          return false;
        }
        track = nTrack;
      } else {
        // 从头重推：蓝本等一个 6 秒的确认窗再继续。
        if (await _sleepOrInactive(run, const Duration(seconds: 6))) {
          return false;
        }
      }
      playClock(start, _clock.nowMs() + tm.startLag.inMilliseconds);
      if (start == 0) {
        run.step(TakeoverStepName.resume, true, '这个格式只能从头放');
      } else {
        final m = start ~/ 60000;
        final s = (start % 60000) ~/ 1000;
        run.step(
          TakeoverStepName.resume,
          true,
          '从 $m:${s.toString().padLeft(2, '0')} 接着放',
        );
      }
      return true;
    }

    Future<TakeoverEnd?> over(String stepName, String why) async {
      run.step(stepName, true, why);
      await _host.status();
      return TakeoverEnd.other;
    }

    // ===== 主循环 =====
    while (true) {
      if (_host.runInactive(run)) {
        run.step(
          run.stopRequested
              ? TakeoverStepName.stopped
              : TakeoverStepName.cancelled,
          true,
          run.stopRequested ? '按了停止' : '',
        );
        return TakeoverEnd.other;
      }
      if (_clock.nowMs() >= limitMs) return TakeoverEnd.other;

      // 音箱从头重取（流层 restart 事件：宽限期外、无请求在途
      // 的从头请求）：按重取时刻的播放位置分流。未到 80% 且
      // 上一请求未供满 90% → 中途断流后音箱自愈从头重播，时钟
      // 按重取时刻重同步到 0 并记 step——1.3.29《体面》实证：
      // 断流后音箱自取重播，旧逻辑只认 restartGap（9/10 时长）
      // 的循环信号，中途重取既无日志也无重同步，时钟仍按原
      // 时间轴走，到 length+slack 误判播完、歌没放完就切走。
      // 已近尾声 → 单曲循环重取，走 finish 停循环；歌尾重取
      // 若落在 slack 窗口内会先于时钟判尾触发，与蓝本 ended
      // 定时器/Restarted 竞速同理，finish 是同一个。时钟判尾
      // 是给「播完不重取」型结尾的兜底（见状态评估段）。
      final restartAt = track.restartAtMs;
      if (restartAt != null && restartAt != handledRestartAt) {
        handledRestartAt = restartAt;
        final posAtRestart = sounding
            ? base + math.max(0, restartAt - anchor)
            : base;
        final nearEnd =
            (length > 0 && posAtRestart >= length * 8 ~/ 10) ||
            track.restartServedRatio >= 0.9;
        if (!nearEnd) {
          playClock(0, restartAt + tm.startLag.inMilliseconds);
          run.step(
            TakeoverStepName.restarted,
            true,
            '音箱从头重取，时钟重同步',
          );
          continue;
        }
        return finish('音箱又从头放了');
      }

      // heard 事件先于状态评估处理（蓝本 select 同级）。
      final events = run.drainHeard();
      var restartLoop = false;
      for (final h in events) {
        if (h.woke) {
          if (!byUser) talkedUntilMs = _clock.nowMs() + 15000;
        } else if (h.control == 'stop') {
          return (await over(TakeoverStepName.stopped, '说了停止'))!;
        } else if (h.control == 'pause') {
          byUser = true;
          talkedUntilMs = 0;
        } else if (h.control == 'resume') {
          byUser = false;
          if (cut) {
            cut = false;
            if (!await again()) {
              if (!_host.runInactive(run)) {
                return (await over(TakeoverStepName.stopped, '没能接着放'))!;
              }
              return TakeoverEnd.other;
            }
            restartLoop = true;
            break;
          }
          talkedUntilMs = _clock.nowMs() + tm.pause.inMilliseconds;
        } else if (h.control != null || h.audio) {
          yield_ = true;
          talkedUntilMs = 0;
        } else {
          byUser = false;
          yield_ = false;
          run.step(TakeoverStepName.talked, true, '');
          final int speakMs = math.min(
            45000,
            h.answerRunes * tm.speakPerRune.inMilliseconds,
          );
          final byAnswer = h.atMs + tm.pause.inMilliseconds + speakMs;
          final byNow = _clock.nowMs() + tm.pause.inMilliseconds;
          talkedUntilMs = math.max(byAnswer, byNow);
        }
      }
      if (restartLoop) continue;
      if (events.isNotEmpty) continue;

      // 回看间隔：谈话中/刚暂停用 LookClose，其余 Look；
      // 暂停久了放宽到至多 10 秒（蓝本同式）。
      final now0 = _clock.nowMs();
      final close =
          talkedUntilMs != 0 || (!sounding && now0 - pausedAtMs < 20000);
      var tick = close ? tm.lookClose : tm.look;
      if (!sounding && now0 - pausedAtMs > 120000) {
        final widened = tm.look * 4;
        tick = widened > const Duration(seconds: 10)
            ? const Duration(seconds: 10)
            : widened;
      }
      final woke = await _waitSlice(run, tick);
      if (woke) continue; // 有 heard 事件或被取消，回到循环顶处理

      final now = _clock.nowMs();
      final talking = talkedUntilMs != 0 && now < talkedUntilMs;
      final p = await _host.status();
      if (p == null) continue;
      _host.knowVolume(p);
      final lost = track.lost;
      final ours =
          p.isPlaying &&
          !_host.isForeign(p) &&
          !(lost && (talking || !sounding));
      if (ours) {
        silent = 0;
        foreign = 0;
        if (!sounding && !talking) {
          playClock(base, lastOkMs + (now - lastOkMs) ~/ 2);
          byUser = false;
          run.step(TakeoverStepName.continued, true, '');
        }
        if (talkedUntilMs != 0 && now > talkedUntilMs + 2000) {
          talkedUntilMs = 0;
        }
        // 判尾（蓝本 ended 定时器：fetchedAt + Duration + EndSlack
        // 即 finish）：我们用自维护的发声时钟 at() 等价实现——
        // 暂停不推进 at()，不会像蓝本的墙钟定时器那样在长暂停
        // 后误判播完（偏离蓝本一处，语义更稳）。阈值取 EndSlack
        // 原值 1.5s：收尾（stop-loop/下一首推送）抢在固件循环
        // 重取把过期直链打成失败播报之前落地。
        if (length > 0 && at() > length + tm.endSlack.inMilliseconds) {
          return finish('播完了');
        }
      } else {
        foreign = p.isPlaying ? foreign + 1 : 0;
        silent++;
        if (sounding) {
          final when = lastOkMs + (now - lastOkMs) ~/ 2;
          if (length > 0 && at() > length - 6000) {
            return finish('播完了');
          }
          pauseClock(when);
          run.step(TakeoverStepName.paused, true, '');
        }
        if ((yield_ && foreign >= 2) ||
            (yield_ && now - pausedAtMs > 15000)) {
          return (await over(TakeoverStepName.stopped, '小爱在放别的'))!;
        }
        if (foreign >= 12) {
          return (await over(TakeoverStepName.stopped, '音箱在放别的'))!;
        }
        // 偏离蓝本一处（断流实证驱动）：蓝本此分支只管谈话恢复，
        // 无谈话的静默靠墙钟 ended 定时器兜底判尾；我们的发声
        // 时钟在暂停后冻结、没有墙钟兜底，推流中途死亡（条目
        // lost + 设备不在播、无人说话）会够不到 again、躺平到
        // maxPause。故把 lost 并入恢复分支的入口条件：用户明确
        // 暂停（byUser）与让行（yield_）仍旧只等，不抢播。
        if (byUser || yield_ || (talkedUntilMs == 0 && !lost)) {
          if (now - pausedAtMs > tm.maxPause.inMilliseconds) {
            return (await over(TakeoverStepName.stopped, '停了很久，不再等'))!;
          }
        } else if (!talking && silent >= 2 && !p.isPlaying) {
          talkedUntilMs = 0;
          silent = 0;
          if (!await again()) {
            if (!_host.runInactive(run)) {
              return (await over(TakeoverStepName.stopped, '没能接着放'))!;
            }
            return TakeoverEnd.other;
          }
        }
      }
      lastOkMs = now;
    }
  }

  /// 等待 [d]：heard 事件到达或 run 失效时提前醒（返回 true）。
  Future<bool> _waitSlice(TakeoverRun run, Duration d) async {
    final endMs = _clock.nowMs() + d.inMilliseconds;
    while (true) {
      if (_host.runInactive(run)) return true;
      if (run.heardQueue.isNotEmpty) return true;
      final remainMs = endMs - _clock.nowMs();
      if (remainMs <= 0) return false;
      await _clock.sleep(
        Duration(milliseconds: remainMs < 200 ? remainMs : 200),
      );
    }
  }

  /// 可取消睡眠：run 失效时返回 true。
  Future<bool> _sleepOrInactive(TakeoverRun run, Duration d) async {
    final endMs = _clock.nowMs() + d.inMilliseconds;
    while (true) {
      if (_host.runInactive(run)) return true;
      final remainMs = endMs - _clock.nowMs();
      if (remainMs <= 0) return _host.runInactive(run);
      await _clock.sleep(
        Duration(milliseconds: remainMs < 100 ? remainMs : 100),
      );
    }
  }
}

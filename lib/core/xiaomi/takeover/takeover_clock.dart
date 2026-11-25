import 'dart:async';

/// 接管核心的时间抽象。
///
/// 核心层（监听 / 接管时序 / 队列接力）只依赖这个接口，不直接用
/// DateTime.now / Future.delayed：单测用假时钟精确驱动时序，
/// 将来搬到 headless 服务端时也只需换一个实现。
abstract interface class TakeoverClock {
  /// 当前墙钟毫秒。
  int nowMs();

  /// 等待 [duration]；宿主停止时应能被 [wake] 打断（见实现注释）。
  Future<void> sleep(Duration duration);
}

/// 基于真实时钟的实现（App 与服务端通用）。
class SystemTakeoverClock implements TakeoverClock {
  const SystemTakeoverClock();

  @override
  int nowMs() => DateTime.now().millisecondsSinceEpoch;

  @override
  Future<void> sleep(Duration duration) => Future<void>.delayed(duration);
}

/// 可被取消的睡眠：等待 [duration]，或 [cancelSignal] 先完成时提前返回。
///
/// 监听 / 接力循环用它实现「stop 后立刻退出」，不必等当前间隔走完。
Future<void> cancellableSleep(
  TakeoverClock clock,
  Duration duration,
  Future<void> cancelSignal,
) {
  return Future.any([clock.sleep(duration), cancelSignal]);
}

import 'dart:io';

import 'package:flutter/services.dart';

/// 小爱接管前台服务的宿主适配（Android）。
///
/// 原生侧 XiaoaiMonitorService 只负责「进程活着 + 常驻通知」，
/// 不做任何业务：轮询与接管逻辑全部跑在主 Flutter engine 的
/// 核心层里（直链解析依赖主 engine 的 QuickJS 通道，独立
/// isolate 里跑不了）。服务被系统杀掉时监听随进程一起停，
/// 这是本方案的已知限制（见模块二汇报）。
class XiaoaiForegroundHost {
  const XiaoaiForegroundHost();

  static const MethodChannel _channel = MethodChannel(
    'muyin_music/xiaoai_monitor',
  );

  Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('start');
    } catch (_) {
      // 宿主起不来不阻断监听本身（前台时仍可工作）。
    }
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // 忽略：停止失败最多多留一条常驻通知。
    }
  }
}

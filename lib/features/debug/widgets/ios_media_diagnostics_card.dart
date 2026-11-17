import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// iOS 媒体会话诊断卡片（仅调试用）。
///
/// 灵动岛/锁屏卡片本质是系统读 MPNowPlayingInfoCenter 自绘，与 ActivityKit 无关。
/// 这两层状态一次读全，用来区分「通道没写」还是「写了系统不画」：
///   ① 读当前 mediaSession / widgetStatus / diagnostics
///   ② 强制写一张测试卡片，再读一次 —— 由此判定 nowPlayingInfo 写入是否生效
class IosMediaDiagnosticsCard extends StatefulWidget {
  const IosMediaDiagnosticsCard({super.key});

  @override
  State<IosMediaDiagnosticsCard> createState() =>
      _IosMediaDiagnosticsCardState();
}

class _IosMediaDiagnosticsCardState extends State<IosMediaDiagnosticsCard> {
  static const _taskChannel = MethodChannel('cy_shine_music/app_task');
  static const _nowPlayingChannel =
      MethodChannel('cy_shine_music/now_playing');

  String _result = '尚未读取。先点「① 读取当前状态」。';
  bool _busy = false;

  Future<void> _guarded(Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } catch (e) {
      setState(() => _result = '调用失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _stringify(String method) async {
    final data = await _taskChannel.invokeMapMethod<String, dynamic>(method);
    if (data == null) return '$method → 返回 null（通道未实现？）';
    final buffer = StringBuffer('$method:\n');
    data.forEach((key, value) => buffer.writeln('  $key = $value'));
    return buffer.toString();
  }

  Future<void> _readAll() => _guarded(() async {
        final parts = <String>[];
        for (final method in [
          'mediaSession',
          'widgetStatus',
          'diagnostics',
        ]) {
          try {
            parts.add(await _stringify(method));
          } catch (e) {
            parts.add('$method → 失败: $e');
          }
        }
        setState(() => _result = parts.join('\n\n'));
      });

  Future<void> _forceWrite() => _guarded(() async {
        final ok = await _nowPlayingChannel.invokeMethod<bool>('publish', {
          'title': '诊断测试',
          'artist': 'MARIO',
          'durationMs': 180000,
          'positionMs': 30000,
          'playing': true,
        });
        final after = await _stringify('mediaSession');
        setState(() => _result =
            '强制写入返回 = $ok\n\n$after\n\n请现在息屏，看锁屏是否出现「诊断测试」卡片。');
      });

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'iOS 媒体会话诊断',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _busy ? null : _readAll,
                  child: const Text('① 读取当前状态'),
                ),
                ElevatedButton(
                  onPressed: _busy ? null : _forceWrite,
                  child: const Text('② 强制写测试卡片'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _result,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

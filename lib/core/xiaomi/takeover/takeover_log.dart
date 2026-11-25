/// 接管诊断日志缓冲（纯 Dart）：带时间戳的环形缓冲，宿主经
/// [onChanged] 落盘（SharedPreferences），页面据此展示最近条目。
///
/// 生产环境此前 onLog 无落点，静音/推播的静默失败在设备上不留
/// 任何痕迹（1.3.27 审计定版），故日志必须落盘且 UI 可见。
class TakeoverLogBuffer {
  TakeoverLogBuffer({
    List<String> initial = const [],
    void Function(List<String> entries)? onChanged,
    DateTime Function()? now,
    this.maxEntries = 100,
  }) : _onChanged = onChanged,
       _now = now ?? DateTime.now {
    _entries.addAll(initial);
    _trim();
  }

  final void Function(List<String> entries)? _onChanged;
  final DateTime Function() _now;

  /// 最多保留条数（超出丢最旧）。
  final int maxEntries;

  final List<String> _entries = [];

  /// 全部条目（旧→新），条目自带 `HH:mm:ss` 时间戳前缀。
  List<String> get entries => List<String>.unmodifiable(_entries);

  void add(String message) {
    final t = _now();
    String two(int v) => v.toString().padLeft(2, '0');
    _entries.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)} $message');
    _trim();
    _onChanged?.call(entries);
  }

  void _trim() {
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
  }
}

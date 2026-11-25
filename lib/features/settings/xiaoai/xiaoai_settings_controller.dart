import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/settings_store.dart';
import '../../../core/xiaomi/mina_models.dart';
import '../../../core/xiaomi/takeover/wake_word_filter.dart';
import '../../../core/xiaomi/takeover_providers.dart';
import '../../../core/xiaomi/xiaomi_providers.dart';

/// 已选音箱的落盘键（存设备快照 JSON，字段名与 device_list 原样对齐，
/// 读回时直接走 [MinaDevice.fromJson]）。
const String kXiaoaiDevicePrefsKey = 'xiaoai_speaker_device_v1';

/// 接管开关的用户意图落盘键（自启恢复只认它，不认运行时状态）。
const String kXiaoaiEnabledPrefsKey = 'xiaoai_speaker_takeover_enabled_v1';

/// 专属口令开关落盘键。
const String kXiaoaiWakeWordEnabledPrefsKey =
    'xiaoai_speaker_wake_word_enabled_v1';

/// 专属口令词落盘键。
const String kXiaoaiWakeWordPrefsKey = 'xiaoai_speaker_wake_word_v1';

/// 「小爱音箱」卡是否展示：V1 仅 Android（前台宿主与轮询承载都是安卓的）。
/// 独立成 provider，方便测试覆盖。
final xiaoaiCardSupportedProvider = Provider<bool>((ref) => Platform.isAndroid);

/// 音箱展示名：name → alias → hardware（与接管总控同口径）。
String minaDeviceDisplayName(MinaDevice device) {
  if (device.name.isNotEmpty) return device.name;
  if (device.alias.isNotEmpty) return device.alias;
  return device.hardware;
}

const Object _unsetValue = Object();

/// 设置页「小爱音箱」卡的状态：登录态、设备与开关意图都在这里，
/// 监听相位与最近接管记录消费模块二的 [XiaoaiTakeoverState]，不另建源。
class XiaoaiSettingsState {
  const XiaoaiSettingsState({
    this.initialized = false,
    this.loggedIn = false,
    this.devices = const [],
    this.selectedDevice,
    this.takeoverEnabled = false,
    this.wakeWordEnabled = false,
    this.wakeWord = kDefaultWakeWord,
    this.statusNote,
  });

  final bool initialized;
  final bool loggedIn;

  /// 最近一次拉到的设备列表（ presence 以这份为准）。
  final List<MinaDevice> devices;

  /// 已选音箱：列表刷新后按 deviceId 换成列表里的实时对象，
  /// 拉不到列表时用落盘快照。
  final MinaDevice? selectedDevice;

  /// 接管开关的用户意图（落盘值）。
  final bool takeoverEnabled;

  /// 专属口令开关（落盘值）：开启后只有带口令的指令才被接管。
  final bool wakeWordEnabled;

  /// 专属口令词（落盘值）。
  final String wakeWord;

  /// 自启恢复失败时留下的状态说明，展示在「监听状态」行；
  /// 用户重新开开关或重新登录后清除。
  final String? statusNote;

  XiaoaiSettingsState copyWith({
    bool? initialized,
    bool? loggedIn,
    List<MinaDevice>? devices,
    Object? selectedDevice = _unsetValue,
    bool? takeoverEnabled,
    bool? wakeWordEnabled,
    String? wakeWord,
    Object? statusNote = _unsetValue,
  }) {
    return XiaoaiSettingsState(
      initialized: initialized ?? this.initialized,
      loggedIn: loggedIn ?? this.loggedIn,
      devices: devices ?? this.devices,
      selectedDevice: identical(selectedDevice, _unsetValue)
          ? this.selectedDevice
          : selectedDevice as MinaDevice?,
      takeoverEnabled: takeoverEnabled ?? this.takeoverEnabled,
      wakeWordEnabled: wakeWordEnabled ?? this.wakeWordEnabled,
      wakeWord: wakeWord ?? this.wakeWord,
      statusNote: identical(statusNote, _unsetValue)
          ? this.statusNote
          : statusNote as String?,
    );
  }
}

/// 「小爱音箱」卡的总控：只做状态汇总与持久化，登录走模块一
/// （[MinaAuth] / [MinaClient]），接管走模块二的 Controller。
class XiaoaiSettingsController extends StateNotifier<XiaoaiSettingsState> {
  XiaoaiSettingsController({
    required SharedPreferences prefs,
    required Future<XiaomiTokenInfo?> Function() loadTokens,
    required Future<List<MinaDevice>> Function() fetchDevices,
    required Future<bool> Function() validateSession,
    required Future<void> Function() doLogout,
    required Future<void> Function(MinaDevice device) enableTakeover,
    required Future<void> Function() disableTakeover,
    void Function(WakeWordFilter filter)? syncWakeWordFilter,
  }) : _prefs = prefs,
       _loadTokens = loadTokens,
       _fetchDevices = fetchDevices,
       _validateSession = validateSession,
       _doLogout = doLogout,
       _enableTakeover = enableTakeover,
       _disableTakeover = disableTakeover,
       _syncWakeWordFilter = syncWakeWordFilter,
       super(const XiaoaiSettingsState());

  final SharedPreferences _prefs;
  final Future<XiaomiTokenInfo?> Function() _loadTokens;
  final Future<List<MinaDevice>> Function() _fetchDevices;
  final Future<bool> Function() _validateSession;
  final Future<void> Function() _doLogout;
  final Future<void> Function(MinaDevice device) _enableTakeover;
  final Future<void> Function() _disableTakeover;
  final void Function(WakeWordFilter filter)? _syncWakeWordFilter;

  Future<void>? _initFuture;

  /// 首次读状态（幂等）：落盘的开关意图与设备快照 + 登录态。
  Future<void> initialize() => _initFuture ??= _initialize();

  Future<void> _initialize() async {
    final enabled = _prefs.getBool(kXiaoaiEnabledPrefsKey) ?? false;
    final wakeEnabled =
        _prefs.getBool(kXiaoaiWakeWordEnabledPrefsKey) ?? false;
    final wakeWord = _prefs.getString(kXiaoaiWakeWordPrefsKey);
    final snapshot = _decodeDevice(_prefs.getString(kXiaoaiDevicePrefsKey));
    XiaomiTokenInfo? tokens;
    try {
      tokens = await _loadTokens();
    } catch (_) {
      tokens = null;
    }
    if (!mounted) return;
    state = XiaoaiSettingsState(
      initialized: true,
      loggedIn: tokens?.isLoggedIn ?? false,
      selectedDevice: snapshot,
      takeoverEnabled: enabled,
      wakeWordEnabled: wakeEnabled,
      wakeWord: (wakeWord == null || wakeWord.trim().isEmpty)
          ? kDefaultWakeWord
          : wakeWord,
    );
    _syncWakeWord();
    if (state.loggedIn) await refreshDevices();
  }

  /// 把当前口令设置同步给接管总控的过滤器。
  void _syncWakeWord() {
    _syncWakeWordFilter?.call(
      WakeWordFilter(enabled: state.wakeWordEnabled, word: state.wakeWord),
    );
  }

  /// 专属口令开关：落盘 + 同步过滤器。
  Future<void> setWakeWordEnabled(bool enabled) async {
    await _prefs.setBool(kXiaoaiWakeWordEnabledPrefsKey, enabled);
    if (!mounted) return;
    state = state.copyWith(wakeWordEnabled: enabled);
    _syncWakeWord();
  }

  /// 专属口令词：trim 后为空不更新；更新后落盘 + 同步过滤器。
  Future<void> setWakeWord(String word) async {
    final trimmed = word.trim();
    if (trimmed.isEmpty) return;
    await _prefs.setString(kXiaoaiWakeWordPrefsKey, trimmed);
    if (!mounted) return;
    state = state.copyWith(wakeWord: trimmed);
    _syncWakeWord();
  }

  /// 重新拉设备列表，并把已选设备换成列表里的实时对象（在线状态以此为准）。
  Future<void> refreshDevices() async {
    if (!state.loggedIn) return;
    List<MinaDevice> devices;
    try {
      devices = await _fetchDevices();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final current = state.selectedDevice;
    var selected = current;
    if (current != null) {
      for (final device in devices) {
        if (device.deviceId == current.deviceId) {
          selected = device;
          break;
        }
      }
    }
    state = state.copyWith(devices: devices, selectedDevice: selected);
  }

  /// 登录成功后由登录页调用：刷新登录态与设备；账号下只有一台音箱时
  /// 自动选中。若开关意图原本是开着的（多为重新登录场景），重新 enable，
  /// 顺带清掉模块二里残留的 error 相位。
  Future<void> handleLoginSuccess() async {
    XiaomiTokenInfo? tokens;
    try {
      tokens = await _loadTokens();
    } catch (_) {
      tokens = null;
    }
    if (!mounted) return;
    state = state.copyWith(
      initialized: true,
      loggedIn: tokens?.isLoggedIn ?? false,
      statusNote: null,
    );
    await refreshDevices();
    if (state.selectedDevice == null && state.devices.length == 1) {
      await _persistSelection(state.devices.single);
    }
    final device = state.selectedDevice;
    if (state.takeoverEnabled && device != null) {
      await _enableTakeover(device);
    }
  }

  /// 选中一台音箱（落盘）；开关开着时把接管切到这台。
  Future<void> selectDevice(MinaDevice device) async {
    await _persistSelection(device);
    if (state.takeoverEnabled) await _enableTakeover(device);
  }

  Future<void> _persistSelection(MinaDevice device) async {
    await _prefs.setString(
      kXiaoaiDevicePrefsKey,
      jsonEncode(_deviceToJson(device)),
    );
    if (!mounted) return;
    state = state.copyWith(selectedDevice: device);
  }

  /// 开关接管：开时必须已有选中设备（无设备返回 false，UI 先引导选设备）；
  /// 真正的探活与监听启停在模块二 Controller 里。
  Future<bool> setTakeoverEnabled(bool enabled) async {
    if (!enabled) {
      await _prefs.setBool(kXiaoaiEnabledPrefsKey, false);
      if (mounted) {
        state = state.copyWith(takeoverEnabled: false, statusNote: null);
      }
      await _disableTakeover();
      return true;
    }
    final device = state.selectedDevice;
    if (device == null) return false;
    await _prefs.setBool(kXiaoaiEnabledPrefsKey, true);
    if (mounted) {
      state = state.copyWith(takeoverEnabled: true, statusNote: null);
    }
    await _enableTakeover(device);
    return true;
  }

  /// 退出登录：先停接管，再清模块一凭据与本地选择。
  Future<void> logout() async {
    await _disableTakeover();
    await _prefs.setBool(kXiaoaiEnabledPrefsKey, false);
    await _prefs.remove(kXiaoaiDevicePrefsKey);
    await _doLogout();
    if (!mounted) return;
    // 口令设置与账号无关，落盘保留，状态也一并保留。
    state = XiaoaiSettingsState(
      initialized: true,
      wakeWordEnabled: state.wakeWordEnabled,
      wakeWord: state.wakeWord,
    );
  }

  /// App 启动恢复：上次开关为开且会话有效时自动重新 enable
  /// （进程被杀后模块二的监听不会自恢复，靠这里补上）。
  /// 失败一律静默：关掉开关意图、留一条状态说明，不弹窗不抛错。
  Future<void> restoreOnStartup() async {
    try {
      await initialize();
      if (!state.loggedIn || !state.takeoverEnabled) return;
      final device = state.selectedDevice;
      if (device == null) {
        await _failRestore('未找到已选音箱，接管已关闭');
        return;
      }
      bool valid;
      try {
        valid = await _validateSession();
      } catch (_) {
        valid = false;
      }
      if (!valid) {
        await _failRestore('登录态已失效，接管已关闭，请重新登录');
        return;
      }
      await _enableTakeover(device);
    } catch (_) {
      await _failRestore('接管恢复失败，已关闭');
    }
  }

  Future<void> _failRestore(String note) async {
    await _prefs.setBool(kXiaoaiEnabledPrefsKey, false);
    if (!mounted) return;
    state = state.copyWith(takeoverEnabled: false, statusNote: note);
  }

  static Map<String, Object?> _deviceToJson(MinaDevice device) => {
    'deviceID': device.deviceId,
    'miotDID': device.miotDid,
    'name': device.name,
    'alias': device.alias,
    'model': device.model,
    'hardware': device.hardware,
    'presence': device.presence,
    'serialNumber': device.serialNumber,
    'mac': device.mac,
    'ssid': device.ssid,
    'ip': device.ip,
    'rom': device.rom,
  };

  static MinaDevice? _decodeDevice(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return null;
      final device = MinaDevice.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      return device.deviceId.isEmpty ? null : device;
    } catch (_) {
      return null;
    }
  }
}

final xiaoaiSettingsProvider =
    StateNotifierProvider<XiaoaiSettingsController, XiaoaiSettingsState>((
      ref,
    ) {
      final tokenStore = ref.watch(xiaomiTokenStoreProvider);
      final client = ref.watch(minaClientProvider);
      final auth = ref.watch(minaAuthProvider);
      return XiaoaiSettingsController(
        prefs: ref.watch(sharedPreferencesProvider),
        loadTokens: tokenStore.load,
        fetchDevices: client.getDeviceList,
        validateSession: client.validateToken,
        doLogout: auth.logout,
        enableTakeover: (device) =>
            ref.read(xiaoaiTakeoverControllerProvider.notifier).enable(device),
        disableTakeover: () =>
            ref.read(xiaoaiTakeoverControllerProvider.notifier).disable(),
        syncWakeWordFilter: (filter) => ref
            .read(xiaoaiTakeoverControllerProvider.notifier)
            .setWakeWordFilter(filter),
      );
    });

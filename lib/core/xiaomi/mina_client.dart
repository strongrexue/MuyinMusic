import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'mina_auth.dart';
import 'mina_constants.dart';
import 'mina_http.dart';
import 'mina_models.dart';
import 'xiaomi_token_store.dart';

/// MiNA 云端客户端：设备列表、ubus 播控、对话记录
/// （蓝本：miot `src/mina/client.ts` 的 MinaHTTPClient）。
///
/// 所有请求遇 HTTP 401 先经 [MinaAuth] 用 passToken 刷新
/// serviceToken，再重试一次（miot 的 onTokenExpired 语义）。
/// 同一设备的 ubus 请求串行排队，控制指令优先于状态查询
/// （miot enqueueUbus/drainUbus）。
class MinaClient {
  MinaClient({
    required MinaHttpTransport http,
    required MinaAuth auth,
    required XiaomiTokenStore tokenStore,
  }) : _http = http,
       _auth = auth,
       _tokenStore = tokenStore;

  final MinaHttpTransport _http;
  final MinaAuth _auth;
  final XiaomiTokenStore _tokenStore;

  final Map<String, _UbusQueue> _ubusQueues = {};

  // ===== 设备 =====

  /// 设备列表；失败时返回空列表（miot getDeviceList 语义）。
  /// 判断 token 是否有效请用 [validateToken]，不要用列表空否推断。
  Future<List<MinaDevice>> getDeviceList() async {
    final result = await _fetchDeviceListRaw();
    return result ?? const [];
  }

  /// token 探活：实际调一次 device_list，code=0 即有效
  /// （无设备时也是 code=0；miot validateToken）。
  Future<bool> validateToken() async {
    try {
      final resp = await _getJson(
        Uri.parse('$kMinaApiBaseUrl/admin/v2/device_list?master=1'),
      );
      if (resp == null) return false;
      return (resp['code'] as num?)?.toInt() == 0;
    } catch (_) {
      return false;
    }
  }

  Future<List<MinaDevice>?> _fetchDeviceListRaw() async {
    final resp = await _getJson(
      Uri.parse('$kMinaApiBaseUrl/admin/v2/device_list?master=1'),
    );
    if (resp == null) return null;
    if ((resp['code'] as num?)?.toInt() != 0) return null;
    final data = resp['data'];
    if (data is! List) return null;
    return [
      for (final raw in data)
        if (raw is Map) MinaDevice.fromJson(raw.cast<String, Object?>()),
    ];
  }

  // ===== ubus 基础 =====

  /// 原始 ubus 调用（经每设备串行队列）。
  ///
  /// 只要拿到可解析的响应就返回 [UbusResult]（含外层非零 code），
  /// 传输失败 / 响应不可解析时返回 null。成败判定看
  /// [UbusResult.isDeviceOk]，不要只看外层 code。
  Future<UbusResult?> ubusRequest(
    String deviceId,
    String method,
    String path,
    Map<String, Object?> message,
  ) {
    return _enqueueUbus(
      deviceId,
      isStatus: method == 'player_get_play_status',
      run: () => _doUbus(deviceId, method, path, message),
    );
  }

  Future<UbusResult?> _doUbus(
    String deviceId,
    String method,
    String path,
    Map<String, Object?> message,
  ) async {
    final form = <String, String>{
      'deviceId': deviceId,
      'method': method,
      'path': path,
      'message': jsonEncode(message),
      'requestId': _generateRequestId(),
    };
    final body = form.entries
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');

    var resp = await _sendMina(
      'POST',
      Uri.parse('$kMinaApiBaseUrl/remote/ubus'),
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
      body: body,
      timeout: kMinaUbusTimeout,
    );
    if (resp != null && resp.statusCode == 401) {
      if (await _auth.refreshServiceToken()) {
        resp = await _sendMina(
          'POST',
          Uri.parse('$kMinaApiBaseUrl/remote/ubus'),
          headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
          body: body,
          timeout: kMinaUbusTimeout,
        );
      }
    }
    if (resp == null || resp.statusCode < 200 || resp.statusCode >= 300) {
      return null;
    }
    final json = _parseJson(resp.bodyText);
    if (json == null) return null;
    return UbusResult.fromJson(json);
  }

  // ===== 播控封装 =====

  /// 播放状态；失败返回 null。status 的可信度有限（推流时可能
  /// 误报暂停），上层判断「还在播」应结合 position 是否推进。
  Future<MinaPlayerStatus?> getPlayerStatus(String deviceId) async {
    final result = await ubusRequest(
      deviceId,
      'player_get_play_status',
      'mediaplayer',
      const {},
    );
    if (result == null) return null;
    return MinaPlayerStatus.tryParseInfo(result.data);
  }

  Future<bool> playerPlay(String deviceId) =>
      _playerOperation(deviceId, 'play');

  Future<bool> playerPause(String deviceId) =>
      _playerOperation(deviceId, 'pause');

  /// 单次 stop 操作。注意：部分型号单独 stop 不生效，接管层应
  /// 组合 pause→stop 两轮（miot playerStop / playerStopGuarded），
  /// 本层只提供原语。
  Future<bool> playerStop(String deviceId) =>
      _playerOperation(deviceId, 'stop');

  Future<bool> _playerOperation(String deviceId, String action) async {
    final result = await ubusRequest(
      deviceId,
      'player_play_operation',
      'mediaplayer',
      {'action': action, 'media': 'app_ios'},
    );
    return result?.isDeviceOk ?? false;
  }

  /// 设置音量（0–100，自动钳制）。
  Future<bool> setVolume(String deviceId, int volume) async {
    final v = volume.clamp(0, 100).toInt();
    final result = await ubusRequest(
      deviceId,
      'player_set_volume',
      'mediaplayer',
      {'volume': v, 'media': 'app_ios'},
    );
    return result?.isDeviceOk ?? false;
  }

  /// 读音量（没有独立方法，从播放状态的 info.volume 取）；未知返回 null。
  Future<int?> getVolume(String deviceId) async {
    final status = await getPlayerStatus(deviceId);
    return status?.volume;
  }

  /// player_play_url 直推（{url, type, media:"app_ios"}）。
  ///
  /// type：1 = MUSIC/亮灯环语义，2 = 普通（默认）。
  /// 该路径没有 REPLACE_ALL 语义，推新歌前上层要先 pause→stop
  /// 清旧媒体上下文。只可靠播放 MP3 直链（见协议文档 1.7）。
  Future<bool> playUrl(String deviceId, String url, {int type = 2}) async {
    final result = await ubusRequest(
      deviceId,
      'player_play_url',
      'mediaplayer',
      {'url': url, 'type': type, 'media': 'app_ios'},
    );
    return result?.isDeviceOk ?? false;
  }

  /// player_play_music 推播（LX06 等型号的主路径，自带
  /// play_behavior=REPLACE_ALL）。
  ///
  /// [audioId] 是占位/封面歌词 ID，缺省用 [kDefaultMusicAudioId]；
  /// [musicAudioType] 为 true 时 audio_type 置 "MUSIC"
  /// （miot keepLight 语义，触屏歌词的前提）。
  Future<bool> playMusic(
    String deviceId,
    String url, {
    String? audioId,
    bool musicAudioType = false,
  }) async {
    final effectiveAudioId = audioId ?? kDefaultMusicAudioId;
    final music = <String, Object?>{
      'payload': {
        'audio_type': musicAudioType ? 'MUSIC' : '',
        'audio_items': [
          {
            'item_id': {
              'audio_id': effectiveAudioId,
              'cp': {
                'album_id': '-1',
                'episode_index': 0,
                'id': kMusicCpId,
                'name': 'xiaowei',
              },
            },
            'stream': {'url': url},
          },
        ],
        'list_params': {
          'listId': '-1',
          'loadmore_offset': 0,
          'origin': 'xiaowei',
          'type': 'MUSIC',
        },
      },
      'play_behavior': 'REPLACE_ALL',
    };
    final result = await ubusRequest(
      deviceId,
      'player_play_music',
      'mediaplayer',
      {'startaudioid': effectiveAudioId, 'music': jsonEncode(music)},
    );
    return result?.isDeviceOk ?? false;
  }

  /// TTS 播报（只封装，V1 暂不调用）：先 mibrain 的
  /// text_to_speech，失败再回退 mediaplayer 的 player_play_tts。
  ///
  /// 返回 null 表示「超时但可能已播出」（101/3012），
  /// 调用方绝不能据此重发（miot ttsAcceptance 的三态语义）。
  Future<bool?> textToSpeech(String deviceId, String text) async {
    final primary = await ubusRequest(deviceId, 'text_to_speech', 'mibrain', {
      'text': text,
    });
    final primaryVerdict = _ttsAcceptance(primary);
    if (primaryVerdict == null) return null;
    if (primaryVerdict) return true;

    final fallback = await ubusRequest(
      deviceId,
      'player_play_tts',
      'mediaplayer',
      {'text': text},
    );
    return _ttsAcceptance(fallback);
  }

  /// miot ttsAcceptance 的三态：true=确认播出，false=未成功
  /// （可回退下一通道），null=3012 超时无法确认（绝不能重发）。
  bool? _ttsAcceptance(UbusResult? result) {
    if (result == null) return false;
    if (result.isAmbiguousTimeout) return null;
    final dd = result.deviceDataCode;
    return result.code == 0 && result.isDeviceOk && (dd == null || dd == 0);
  }

  // ===== 对话记录 =====

  /// 拉取最新对话记录（主路径 userprofile 接口；LX06 用此路）。
  ///
  /// 返回值区分「失败」与「成功但无记录」，见 [ConversationFetchResult]。
  /// 失败内部重试 [kConversationMaxRetries] 次，重试复用同一时间戳
  /// （miot getLatestAskFromXiaoai）。
  ///
  /// TODO(模块二): M01 等型号需走 ubus nlp_result_get 备路径
  /// （见 [kAskByMinaModels]），V1 目标只有 LX06，不实现。
  Future<ConversationFetchResult> fetchLatestAsk({
    required String deviceId,
    required String hardware,
    int limit = 2,
    int? timestampMs,
  }) async {
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    final url = Uri.parse(formatLatestAskUrl(hardware, ts, limit));
    var lastReason = 'unknown';
    for (var attempt = 0; attempt < kConversationMaxRetries; attempt++) {
      final outcome = await _fetchLatestAskOnce(deviceId, url);
      if (outcome.result != null) return outcome.result!;
      lastReason = outcome.reason ?? 'unknown';
    }
    return ConversationFetchFailure(
      'conversation fetch failed after $kConversationMaxRetries attempts: $lastReason',
    );
  }

  Future<({ConversationFetchResult? result, String? reason})>
  _fetchLatestAskOnce(String deviceId, Uri url) async {
    final resp = await _sendMina('GET', url, extraCookie: 'deviceId=$deviceId');
    if (resp == null) return (result: null, reason: 'transport error');
    if (resp.statusCode == 401) {
      await _auth.refreshServiceToken();
      return (result: null, reason: 'unauthorized');
    }
    if (resp.statusCode != 200) {
      return (result: null, reason: 'HTTP ${resp.statusCode}');
    }
    final outer = _parseJson(resp.bodyText);
    if (outer == null) return (result: null, reason: 'bad outer json');
    final dataStr = outer['data'];
    if (dataStr == null || (dataStr is String && dataStr.isEmpty)) {
      return (result: const ConversationFetchSuccess([]), reason: null);
    }
    if (dataStr is! String) {
      return (result: null, reason: 'data is not a string');
    }
    final data = _parseJson(dataStr);
    if (data == null) return (result: null, reason: 'bad data json');
    final rawRecords = data['records'];
    if (rawRecords is! List || rawRecords.isEmpty) {
      return (result: const ConversationFetchSuccess([]), reason: null);
    }
    return (
      result: ConversationFetchSuccess([
        for (final raw in rawRecords)
          if (raw is Map)
            ConversationRecord.fromJson(raw.cast<String, Object?>()),
      ]),
      reason: null,
    );
  }

  // ===== HTTP 辅助 =====

  /// MiNA 域 GET 并解析 JSON；401 时刷新 token 重试一次。
  Future<Map<String, Object?>?> _getJson(Uri url) async {
    var resp = await _sendMina('GET', url);
    if (resp != null && resp.statusCode == 401) {
      if (await _auth.refreshServiceToken()) {
        resp = await _sendMina('GET', url);
      }
    }
    if (resp == null || resp.statusCode != 200) return null;
    return _parseJson(resp.bodyText);
  }

  /// 发送 MiNA 域请求：UA + token Cookie 由登录态拼装。
  Future<MinaHttpResponse?> _sendMina(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? extraCookie,
    String? body,
    Duration? timeout,
  }) async {
    final tokens = await _tokenStore.load();
    if (tokens == null) return null;
    final svc = tokens.service(kMinaSid);
    final cookieParts = <String>[
      'userId=${tokens.userId}',
      'serviceToken=${svc?.serviceToken ?? ''}',
      'channel=MI_APP_STORE',
      if (extraCookie != null && extraCookie.isNotEmpty) extraCookie,
    ];
    try {
      return await _http.send(
        method,
        url,
        headers: {
          'User-Agent': formatXiaomiUserAgent(tokens.deviceId),
          'Cookie': cookieParts.join('; '),
          ...headers,
        },
        body: body,
        timeout: timeout ?? kMinaHttpTimeout,
      );
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object?>? _parseJson(String text) {
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } catch (_) {
      return null;
    }
    return null;
  }

  static String _generateRequestId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    final suffix = String.fromCharCodes(
      Iterable.generate(30, (_) => chars.codeUnitAt(random.nextInt(36))),
    );
    return 'app_ios_$suffix';
  }

  // ===== ubus 每设备串行队列（miot enqueueUbus/drainUbus） =====

  Future<UbusResult?> _enqueueUbus(
    String deviceId, {
    required bool isStatus,
    required Future<UbusResult?> Function() run,
  }) {
    final queue = _ubusQueues.putIfAbsent(deviceId, _UbusQueue.new);
    final completer = Completer<UbusResult?>();
    queue.tasks.add(
      _UbusTask(isStatus: isStatus, run: run, completer: completer),
    );
    unawaited(_drainUbus(deviceId, queue));
    return completer.future;
  }

  Future<void> _drainUbus(String deviceId, _UbusQueue queue) async {
    if (queue.running) return;
    queue.running = true;
    try {
      while (queue.tasks.isNotEmpty) {
        // 控制指令优先于状态查询。
        var index = queue.tasks.indexWhere((t) => !t.isStatus);
        if (index < 0) index = 0;
        final task = queue.tasks.removeAt(index);
        try {
          task.completer.complete(await task.run());
        } catch (e, st) {
          task.completer.completeError(e, st);
        }
      }
    } finally {
      queue.running = false;
      if (queue.tasks.isEmpty && identical(_ubusQueues[deviceId], queue)) {
        _ubusQueues.remove(deviceId);
      }
    }
  }
}

class _UbusTask {
  _UbusTask({
    required this.isStatus,
    required this.run,
    required this.completer,
  });

  final bool isStatus;
  final Future<UbusResult?> Function() run;
  final Completer<UbusResult?> completer;
}

class _UbusQueue {
  bool running = false;
  final List<_UbusTask> tasks = [];
}

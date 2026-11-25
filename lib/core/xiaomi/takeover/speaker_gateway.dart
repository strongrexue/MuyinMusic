import '../mina_client.dart';
import '../mina_constants.dart';
import '../mina_models.dart';

/// 接管核心对 MiNA 客户端的最小依赖面。
///
/// 核心只认这个接口：单测用假实现断言调用时序；真实环境由
/// [MinaClientGateway] 适配模块一的 [MinaClient]；将来搬到
/// headless 服务端时换一个实现即可，核心不动。
abstract interface class SpeakerGateway {
  /// 拉取最新对话记录（失败与无记录必须可区分，见模块一语义）。
  Future<ConversationFetchResult> fetchLatestAsk({
    required String deviceId,
    required String hardware,
    int limit,
  });

  Future<MinaPlayerStatus?> getPlayerStatus(String deviceId);

  Future<bool> playerPlay(String deviceId);

  Future<bool> playerPause(String deviceId);

  /// 单次 stop 原语（组合两轮压制在接管引擎里做）。
  Future<bool> playerStop(String deviceId);

  Future<bool> setVolume(String deviceId, int volume);

  /// player_play_music 推播（LX06 等型号主路径，自带 REPLACE_ALL）。
  Future<bool> playMusic(String deviceId, String url);

  /// player_play_url 直推（推前需先清旧媒体上下文）。
  Future<bool> playUrl(String deviceId, String url);

  /// 该型号是否默认走 play_music（模块一型号表）。
  bool usePlayMusicApi(String hardware);
}

/// [MinaClient] 的适配实现。
class MinaClientGateway implements SpeakerGateway {
  MinaClientGateway(this._client);

  final MinaClient _client;

  @override
  Future<ConversationFetchResult> fetchLatestAsk({
    required String deviceId,
    required String hardware,
    int limit = 5,
  }) {
    return _client.fetchLatestAsk(
      deviceId: deviceId,
      hardware: hardware,
      limit: limit,
    );
  }

  @override
  Future<MinaPlayerStatus?> getPlayerStatus(String deviceId) =>
      _client.getPlayerStatus(deviceId);

  @override
  Future<bool> playerPlay(String deviceId) => _client.playerPlay(deviceId);

  @override
  Future<bool> playerPause(String deviceId) => _client.playerPause(deviceId);

  @override
  Future<bool> playerStop(String deviceId) => _client.playerStop(deviceId);

  @override
  Future<bool> setVolume(String deviceId, int volume) =>
      _client.setVolume(deviceId, volume);

  @override
  Future<bool> playMusic(String deviceId, String url) =>
      _client.playMusic(deviceId, url);

  @override
  Future<bool> playUrl(String deviceId, String url) =>
      _client.playUrl(deviceId, url);

  @override
  bool usePlayMusicApi(String hardware) => needUsePlayMusicApi(hardware);
}

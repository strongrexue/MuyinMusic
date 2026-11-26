import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/app_logger.dart';
import '../../core/storage/settings_store.dart';
import '../../core/ui/cover_image_source.dart';
import 'lyric_frame.dart';
import 'now_playing_push_gate.dart';
import 'player_audio_handler.dart';
import 'player_controller.dart';
import '../songs/liked_songs_store.dart';

/// 是否发起自绘 Live Activity（灵动岛/锁屏自定义卡）。
/// 切回系统标准播放卡后关闭：只写 MPNowPlayingInfoCenter，不再 start/update Activity。
/// 设 false 后 _push 直接返回，_activeStarted 永远为 false，_end 也天然不会再发。
const bool kEnableLiveActivity = false;

/// 灵动岛 / 锁屏实时活动（Live Activity）的驱动。
///
/// 只在 iOS 上生效，且系统「设置 → 栖弦 → 实时活动」打开时才真正工作。
/// 原生实现见 ios/Runner/PanghuLiveActivityBridge.swift，
/// 渲染见 ios/PanghuMusicWidget/PanghuLiveActivityWidget.swift。
///
/// 更新频率刻意压得很低：只在**换歌 / 播放暂停 / 跳转**时推一次。
/// 进度条由原生侧的 `ProgressView(timerInterval:)` 自己推进，
/// 所以不需要每秒推更新。
final liveActivityProvider = Provider<LiveActivityService>((ref) {
  final service = LiveActivityService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// 与 `musicHomeWidgetSyncProvider` 同样的作用：声明它就开始跟随播放状态。
final liveActivitySyncProvider = Provider<void>((ref) {
  final service = ref.read(liveActivityProvider);
  ref.listen<PlayerState>(playerControllerProvider, (_, state) {
    service.publish(state);
  }, fireImmediately: true);
  // 喜欢状态变化也要刷新系统卡五角星（实心/空心）。
  ref.listen(likedSongsProvider, (_, _) {
    service.refreshNowPlaying();
  });
  // 「启用灵动岛」开关：关闭即清卡停发，打开即按当前状态重推。
  ref.listen<bool>(
    settingsProvider.select((s) => s.iosDynamicIslandEnabled),
    (_, enabled) {
      unawaited(service.setDynamicIslandEnabled(enabled));
    },
    fireImmediately: true,
  );
});

class LiveActivityService {
  LiveActivityService(this._ref);

  static const MethodChannel _channel = MethodChannel(
    'panghu_music/live_activity',
  );
  static const MethodChannel _nowPlayingChannel =
      MethodChannel('panghu_music/now_playing');

  final Ref _ref;
  bool _available = false;
  bool _checking = false;
  bool _subscriptionsReady = false;
  String? _activeTrackId;
  String? _lastSignature;
  StreamSubscription<PlaybackState>? _playbackSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  Future<void> _queue = Future<void>.value();

  /// 点灵动岛 / 锁屏卡片时把播放器推到前台。
  Future<void> Function()? onOpenPlayer;

  Future<void> initialize() async {
    if (!Platform.isIOS) return;
    _channel.setMethodCallHandler(_handleNativeCall);
    // 系统卡通道升级为双向：接收五角星 like/dislike 的 toggleLike 回调。
    _nowPlayingChannel.setMethodCallHandler(_handleNativeCall);
    await _ensureAvailable();
  }

  /// 喜欢状态变化后主动重推一次系统卡，让五角星实心/空心立即同步。
  void refreshNowPlaying() {
    unawaited(_enqueueNowPlaying());
  }

  bool _dynamicIslandEnabled = true;

  /// 「启用灵动岛」开关变化（设置页切换 / 启动时同步存量值）。
  ///
  /// 关闭：两条发布路径一起停（自研通道在这里门控，audio_service 凭
  /// mediaItem 的写入在 handler 侧抑制），并立即清掉现有系统卡；
  /// 打开：清掉去重签名，按当前播放状态立即重推一次，不等切歌。
  Future<void> setDynamicIslandEnabled(bool enabled) async {
    if (!Platform.isIOS || _dynamicIslandEnabled == enabled) return;
    _dynamicIslandEnabled = enabled;
    _ref
        .read(playerAudioHandlerProvider)
        .setIosNowPlayingSuppressed(!enabled);
    _npGate.reset();
    _tickGate.reset();
    if (enabled) {
      await _enqueueNowPlaying();
      return;
    }
    _syncHeartbeat(false);
    try {
      await _nowPlayingChannel.invokeMethod<bool>('clear');
    } on MissingPluginException {
      // 老版本原生没有 clear 方法，忽略。
    } catch (error) {
      await AppLogger.write('live-activity', '清除播放卡片失败: $error');
    }
  }

  /// 检查系统的实时活动开关。
  ///
  /// 刻意做成可以反复调用：用户可能先播放、才想起来去
  /// 「设置 → 栖弦 → 实时活动」打开开关 —— 只在启动时检查一次的话，
  /// 就得重启 App 才生效，表现成「灵动岛怎么都不出现」。
/// 每次播放状态变化都会重试一次，代价只是一次轻量通道调用。
  ///
  /// [force] 用于「通知授权刚被回答」这种外部状态变化的场景：
  /// 之前拿到过 false 而放弃了，必须强制重新判定一次。
  Future<void> _ensureAvailable({bool force = false}) async {
    if (!Platform.isIOS || (_available && !force) || _checking) return;
    _checking = true;
    try {
      final supported =
          await _channel.invokeMethod<bool>('isSupported') ?? false;
      if (!supported) {
        await AppLogger.write(
          'live-activity',
          '系统未开启实时活动（设置 → 栖弦 → 实时活动），暂不推送；开关打开后无需重启即可生效',
        );
        _available = false;
        return;
      }
      _available = true;
      _attachListeners();
      await AppLogger.write('live-activity', '实时活动已就绪');
    } on MissingPluginException {
      _available = false;
    } catch (error) {
      _available = false;
      await AppLogger.write('live-activity', '初始化失败: $error');
    } finally {
      _checking = false;
    }
  }

  void _attachListeners() {
    if (_subscriptionsReady) return;
    _subscriptionsReady = true;
    final handler = _ref.read(playerAudioHandlerProvider);
    // 播放传输走 playbackState，曲目变化走 playerController。
    _playbackSubscription = handler.playbackState.listen(_onPlaybackState);
    // 时长通常比播放状态晚一步解析出来，进度条要靠这次更新才会出现。
    _durationSubscription = handler.durationStream.listen(
      (_) => unawaited(_push(afterArtwork: false)),
    );
  }

  // MARK: - 原生回调

Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'control':
        final action = call.arguments as String? ?? '';
        // 串行化，避免连点灵动岛按钮时互相打断。
        _queue = _queue
            .then((_) => _control(action))
            .catchError((Object error) async {
              await AppLogger.write('live-activity', 'control 失败: $error');
            });
        return true;
      case 'openPlayer':
        await onOpenPlayer?.call();
        return true;
      case 'authorizationResolved':
        // 原生的通知授权弹窗刚被回答。此刻 areActivitiesEnabled 才翻成 true，
        // 立刻重新判定一次并把当前曲目推上去 —— 否则要等下一次播放状态变化
        // 才恢复，表现为「授权完了还是没反应，再播一次才有」。
        await _ensureAvailable(force: true);
        final state = _ref.read(playerControllerProvider);
        if (state.track != null) {
          _activeStarted = false;
          _lastSignature = null;
          await _push(afterArtwork: true);
        }
        return true;
      case 'toggleLike':
        // 系统卡五角星被点击（MPRemoteCommandCenter like/dislike）。
        // 后台 isolate 常驻，SharedPreferences 纯本地读写，可直接切换。
        final state = _ref.read(playerControllerProvider);
        final entry = state.queueIndex >= 0 && state.queueIndex < state.queue.length
            ? state.queue[state.queueIndex]
            : null;
        if (entry == null) return false;
        final nowLiked = _ref.read(likedSongsProvider.notifier).toggle(entry);
        await AppLogger.write('live-activity', '系统卡切换喜欢: $nowLiked');
        // toggle 会改变 likedSongsProvider，上面的 listen 会触发系统卡重推刷新。
        return nowLiked;
    }
    throw MissingPluginException('未知的实时活动方法: ${call.method}');
  }

  Future<void> _control(String action) async {
    _ref.read(liveActivitySyncProvider);
    final player = _ref.read(playerControllerProvider.notifier);
    await player.waitForSessionRestore();
    if (!_ref.read(playerControllerProvider).hasTrack) {
      await onOpenPlayer?.call();
      return;
    }
    switch (action) {
      case 'toggle':
        await player.toggle();
      case 'previous':
        await player.playPrevious();
      case 'next':
        await player.playNext();
    }
    await AppLogger.write('live-activity', '控制: $action');
  }

  // MARK: - 状态推送

  /// 曲目变化（可能是换歌，也可能是首次播放）。
  ///
  /// 位置 tick 每 40ms 都会调进来：只有歌词行、播放态（播/停/seek/换歌）、
  /// 喜欢变化才进系统卡队列，纯位置推进由 2 秒心跳兜底——否则队列常年
  /// 排着 25 个/秒的无操作项，真正的歌词行推送被堵在后面。
  void publish(PlayerState state) {
    final payload = _payload();
    if (payload == null) {
      // 无曲目：仍进一次队列，让内部停掉心跳（内部在 payload 为空时
      // 直接返回，不碰封面解析）。
      unawaited(_enqueueNowPlaying());
    } else if (_tickGate.shouldEnqueue(
      trackId: payload['trackId'] as String,
      artist: payload['artist'] as String,
      playing: payload['playing'] == true,
      liked: payload['liked'] == true,
      positionMs: payload['positionMs'] as int,
    )) {
      unawaited(_enqueueNowPlaying());
    }
    if (!_available) {
      // 可能只是「实时活动开关后来才打开」，重试一次而不是永远放弃。
      unawaited(_ensureAvailable());
      return;
    }
    final track = state.track;
    if (track == null) {
      _end();
      return;
    }
    final changed = track.id != _activeTrackId;
    _activeTrackId = track.id;
    unawaited(_push(afterArtwork: changed));
  }

  void _onPlaybackState(PlaybackState state) {
    unawaited(_enqueueNowPlaying());
    if (!_available) {
      unawaited(_ensureAvailable());
      return;
    }
    final playerState = _ref.read(playerControllerProvider);
    if (playerState.track == null) {
      _end();
      return;
    }
    final processing = state.processingState;
    final stopped =
        processing == AudioProcessingState.idle ||
        processing == AudioProcessingState.error;
    // 注意：completed 不停活动 —— 下一首马上会接着 start，
    // 停掉再建会让灵动岛闪一下。
    if (stopped && !state.playing) {
      _end();
      return;
    }
    unawaited(_push(afterArtwork: false));
  }

  /// 计算要推给原生的载荷。
  ///
  /// 返回 null 表示这次没有实质变化（比如进度回调），可以跳过，
  /// 避免把通道刷爆。
  Map<String, dynamic>? _payload() {
    final audioHandler = _ref.read(playerAudioHandlerProvider);
    final playback = audioHandler.playbackState.value;
    final state = _ref.read(playerControllerProvider);
    final track = state.track;
    if (track == null) return null;

    final playing =
        playback.playing &&
        playback.processingState != AudioProcessingState.idle &&
        playback.processingState != AudioProcessingState.completed &&
        playback.processingState != AudioProcessingState.error;
    final loading =
        playback.processingState == AudioProcessingState.loading ||
        playback.processingState == AudioProcessingState.buffering;

    // audio_service 的 updatePosition 是「上次更新时的位置」，
    // 播放中要按经过时间补上，否则进度条会一直落后。
    var positionMs = playback.updatePosition.inMilliseconds;
    if (playing) {
      final elapsed =
          DateTime.now().difference(playback.updateTime).inMilliseconds;
      if (elapsed > 0) positionMs += elapsed;
    }
    // 时长在 MediaItem 上，不在 PlaybackState 上；而且往往播放开始后才解析出来，
    // 所以这里每次都重新读，解析到之后会通过 durationStream 再推一次更新。
    final durationMs = audioHandler.duration?.inMilliseconds ??
        audioHandler.mediaItem.value?.duration?.inMilliseconds ??
        0;
    if (positionMs < 0) positionMs = 0;
    if (durationMs > 0 && positionMs > durationMs) positionMs = durationMs;

    var lyricText = '';
    final lyrics = state.lyrics;
    if (!lyrics.isEmpty) {
      final idx = lyrics.activeIndex(Duration(milliseconds: positionMs));
      if (idx >= 0 && idx < lyrics.lines.length) {
        lyricText = LyricFrameAlgorithms.frameForLine(
          lyrics.lines[idx], positionMs,
        ).text;
      }
    }

    // 系统锁屏卡副标题用的「整行」歌词：上面的 lyricText 是灵动岛的逐字分帧
    // 短文本，直接当锁屏行会被切成半截字。这里取当前行完整文本，无歌词则空串。
    var lyricLine = '';
    if (!lyrics.isEmpty) {
      final lineIdx = lyrics.activeIndex(Duration(milliseconds: positionMs));
      if (lineIdx >= 0 && lineIdx < lyrics.lines.length) {
        lyricLine = lyrics.lines[lineIdx].text.trim();
      }
    }

    // 当前曲目是否已喜欢：队列条目即 DownloadHistoryEntry，直接比身份键。
    final queueEntry = state.queueIndex >= 0 && state.queueIndex < state.queue.length
        ? state.queue[state.queueIndex]
        : null;
    final liked = queueEntry != null &&
        _ref.read(likedSongsProvider.notifier).isLiked(queueEntry);

    return {
      'trackId': track.id,
      'title': track.title,
      // 系统卡副标题位塞当前歌词行；无歌词回退真歌手（对齐胖虎做法）。
      'artist': lyricLine.isNotEmpty ? lyricLine : track.artist,
      'displaySubtitle': track.artist,
      'durationMs': durationMs,
      'positionMs': positionMs,
      'playing': playing,
      'loading': loading,
      'lyricText': lyricText,
      'lyricLine': lyricLine,
      'liked': liked,
    };
  }

  Future<void> _push({required bool afterArtwork}) async {
    // 切回系统标准卡：不再发起/更新自绘 Live Activity。
    if (!kEnableLiveActivity) return;
    if (!_available) return;
    final payload = _payload();
    if (payload == null) return;

    // 只有「换歌 / 播放状态变化 / 明显跳转」才值得推一次更新。
    // 位置量化到 5 秒，避免连续微调把通道刷爆；seek 会直接改变量化后的值。
    final signature = [
      payload['trackId'],
      payload['playing'],
      (payload['positionMs'] as int) ~/ 5000,
      payload['durationMs'],
      payload['lyricText'],
    ].join('|');
    // 首帧（换歌）必须推一次，哪怕签名"看起来"没变。
    if (!afterArtwork && _activeStarted && signature == _lastSignature) return;
    _lastSignature = signature;

    try {
      final method = _activeStarted ? 'update' : 'start';
      await _channel.invokeMethod<dynamic>(method, {
        ...payload,
        ...await _coverPayload(),
      });
      _activeStarted = true;
    } on MissingPluginException {
      _available = false;
    } catch (error) {
      await AppLogger.write('live-activity', '推送失败: $error');
    }
  }

  // MARK: - 系统卡推送（串行队列 + 去重门 + 心跳兜底）

  final NowPlayingPushGate _npGate = NowPlayingPushGate();
  final NowPlayingTickGate _tickGate = NowPlayingTickGate();
  final NowPlayingArtMemo _artMemo = NowPlayingArtMemo();
  Future<void> _npQueue = Future<void>.value();
  Timer? _npHeartbeat;
  String? _artFetchKey;

  /// 所有系统卡推送都过这条串行队列：慢推送（封面文件解析等）不会被
  /// 后发的推送反超落地，去重判定与 invoke 的顺序也因此严格一致。
  Future<void> _enqueueNowPlaying({bool force = false}) {
    final run = _npQueue.then((_) => _pushNowPlayingInternal(force: force));
    _npQueue = run.catchError((Object error) async {
      await AppLogger.write('live-activity', '写播放卡片失败: $error');
    });
    return run;
  }

  /// 无条件写系统媒体播放卡片（灵动岛/锁屏）。
  /// 与 Live Activity 可用性完全解耦：即使 ActivityKit 不可用（巨魔/低版本 iOS），
  /// 只要写了 nowPlayingInfo，系统就会画出标准播放卡片。
  Future<void> _pushNowPlayingInternal({bool force = false}) async {
    try {
      // 「启用灵动岛」关闭时停发系统卡（灵动岛与锁屏是同一张卡）。
      if (!_dynamicIslandEnabled) {
        _syncHeartbeat(false);
        return;
      }
      final payload = _payload();
      if (payload == null) {
        _syncHeartbeat(false);
        return;
      }
      final trackId = payload['trackId'] as String;
      final playing = payload['playing'] == true;
      final positionMs = payload['positionMs'] as int;
      // 去重先行：用内存 memo 里的封面身份算 key，不碰 SQLite；
      // 没命中的推送直接丢，只有放行的才解析封面。
      final artUri =
          _ref.read(playerAudioHandlerProvider).mediaItem.value?.artUri;
      final coverUrl = artUri?.toString() ?? '';
      final provisionalKey = NowPlayingPushGate.keyFor(
        trackId: trackId,
        artist: payload['artist'] as String,
        playing: playing,
        liked: payload['liked'] == true,
        coverIdentity: _memoizedCoverIdentity(trackId, coverUrl, artUri),
      );
      if (!_npGate.decide(
        key: provisionalKey,
        trackId: trackId,
        positionMs: positionMs,
        playing: playing,
        force: force,
      )) {
        _syncHeartbeat(
          NowPlayingPushGate.heartbeatWanted(
            enabled: true,
            hasTrack: true,
            playing: playing,
          ),
        );
        return;
      }
      final art = await _nowPlayingArtPayload(payload);
      // 用解析后的真实封面身份重新算 key 落盘：封面刚就绪时身份从 URL
      // 变成本地路径，下一次同行推送按新 key 去重，不会重复发同一张卡。
      final resolvedKey = NowPlayingPushGate.keyFor(
        trackId: trackId,
        artist: payload['artist'] as String,
        playing: playing,
        liked: payload['liked'] == true,
        coverIdentity: art.identity,
      );
      try {
        await _nowPlayingChannel.invokeMethod<bool>('publish', {
          ...payload,
          'artPath': art.artPath,
          'artTrackId': trackId,
        });
        _npGate.commit(
          key: resolvedKey,
          trackId: trackId,
          positionMs: positionMs,
          playing: playing,
        );
      } on MissingPluginException {
        // 老版本原生没有该通道，忽略。
      }
      _syncHeartbeat(
        NowPlayingPushGate.heartbeatWanted(
          enabled: true,
          hasTrack: true,
          playing: playing,
        ),
      );
    } catch (error) {
      await AppLogger.write('live-activity', '写播放卡片失败: $error');
    }
  }

  /// 播放中每 2 秒兜底重推一次：后台节流漏掉的歌词/进度更新能在下一次
  /// 心跳自愈（载荷按当前墙钟重新外推位置）。暂停/停止/关开关即停。
  void _syncHeartbeat(bool wanted) {
    if (wanted) {
      _npHeartbeat ??= Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_enqueueNowPlaying(force: true));
      });
    } else {
      _npHeartbeat?.cancel();
      _npHeartbeat = null;
    }
  }

  /// 去重 key 用的封面身份（纯内存，不碰磁盘）：
  /// 本地文件封面直接用路径；网络封面用 memo 里已解析的路径，
  /// 未解析时用 URL 占位——文件下好后 memo 回填、身份变路径，key 随之变化补推。
  String _memoizedCoverIdentity(String trackId, String coverUrl, Uri? artUri) {
    if (artUri != null && artUri.scheme == 'file') {
      return artUri.toFilePath();
    }
    return _artMemo.lookup(trackId, coverUrl) ?? coverUrl;
  }

  /// 系统卡封面载荷：只给本地文件路径，原生侧不再同步下载网络封面
  /// （同步下载曾冻结通道线程，把每行歌词的推送都拖慢数秒）。
  ///
  /// 嵌入封面走 handler 的 cacheArtwork（media_art/ 下的摘要文件）；
  /// 网络封面与 audio_service 共用同一个缓存管理器——它给会话解析的
  /// 正是同一份缓存文件：命中直接用；未命中时后台触发同一份下载
  /// （不阻塞本次推送），文件就绪后戳一次重推（封面身份已进 key）。
  /// memo 命中时直接返回，不查 SQLite。
  Future<({String artPath, String identity})> _nowPlayingArtPayload(
    Map<String, dynamic> payload,
  ) async {
    final trackId = payload['trackId'] as String;
    var artPath = '';
    var coverUrl = '';
    try {
      final handler = _ref.read(playerAudioHandlerProvider);
      final track = _ref.read(playerControllerProvider).track;
      final mediaItem = handler.mediaItem.value;
      final artUri = mediaItem?.artUri;
      if (artUri != null) coverUrl = artUri.toString();
      final memoPath = _artMemo.lookup(trackId, coverUrl);
      if (memoPath != null) {
        return (artPath: memoPath, identity: memoPath);
      }
      final embedded = await handler.cacheArtwork(track?.coverBytes);
      if (embedded != null) {
        artPath = embedded.toFilePath();
      } else if (artUri != null) {
        if (artUri.scheme == 'file') {
          artPath = artUri.toFilePath();
        } else if (artUri.scheme == 'http' || artUri.scheme == 'https') {
          final cached =
              await AudioService.cacheManager.getFileFromCache(coverUrl);
          if (cached != null) {
            artPath = cached.file.path;
          } else {
            _fetchArtInBackground(trackId, coverUrl, mediaItem?.artHeaders);
          }
        }
      }
      // 解析到本地路径后回填 memo：下一次去重直接用内存身份。
      if (artPath.isNotEmpty) {
        _artMemo.store(trackId, coverUrl, artPath);
      }
    } catch (error) {
      await AppLogger.write('live-activity', '封面文件解析失败: $error');
    }
    return (
      artPath: artPath,
      identity: NowPlayingPushGate.coverIdentity(
        artPath: artPath,
        coverUrl: coverUrl,
      ),
    );
  }

  /// 后台把网络封面下进 audio_service 的共享缓存（与它给会话取的是同一份）。
  void _fetchArtInBackground(
    String trackId,
    String url,
    Map<String, String>? headers,
  ) {
    final fetchKey = '$trackId|$url';
    if (_artFetchKey == fetchKey) return;
    _artFetchKey = fetchKey;
    unawaited(() async {
      try {
        final File file;
        if (headers != null) {
          file =
              await AudioService.cacheManager.getSingleFile(url, headers: headers);
        } else {
          file = await AudioService.cacheManager.getSingleFile(url);
        }
        // 下载完成即回填 memo：随后那次重推的去重 key 直接用路径身份放行。
        _artMemo.store(trackId, url, file.path);
      } catch (_) {
        // 下载失败不重试本次，等下一次推送/心跳再触发。
        if (_artFetchKey == fetchKey) _artFetchKey = null;
        return;
      }
      if (_artFetchKey == fetchKey) _artFetchKey = null;
      unawaited(_enqueueNowPlaying());
    }());
  }

  bool _activeStarted = false;

  Future<Map<String, dynamic>> _coverPayload() async {
    try {
      final track = _ref.read(playerControllerProvider).track;
      final embedded = await _ref
          .read(playerAudioHandlerProvider)
          .cacheArtwork(track?.coverBytes);
      final cover =
          embedded?.toString() ??
          CoverImageSource.normalizeUrl(track?.coverUrl, size: 512) ??
          '';
      return {'cover': cover, 'headers': CoverImageSource.headersFor(cover) ?? {}};
    } catch (error) {
      await AppLogger.write('live-activity', '封面处理失败: $error');
      return {'cover': '', 'headers': <String, String>{}};
    }
  }

  void _end() {
    if (!_available || !_activeStarted) return;
    _activeStarted = false;
    _activeTrackId = null;
    _lastSignature = null;
    unawaited(
      _channel.invokeMethod<void>('end').catchError((Object error) async {
        await AppLogger.write('live-activity', '结束活动失败: $error');
      }),
    );
  }

  void dispose() {
    _end();
    _syncHeartbeat(false);
    unawaited(_playbackSubscription?.cancel());
    _playbackSubscription = null;
    unawaited(_durationSubscription?.cancel());
    _durationSubscription = null;
  }
}

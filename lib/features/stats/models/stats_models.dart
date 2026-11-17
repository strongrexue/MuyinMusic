/// 统计服务接收的播放快照（由播放器层根据当前歌曲 + 播放状态组装）。
///
/// 飞牛音乐使用其内部的 PlaybackSnapshot；本项目播放器没有现成的等价物，
/// 因此在统计模块自定义同名结构，字段语义与飞牛保持一致。
class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.isPlaying,
    this.song,
    this.durationMs,
  });

  /// 当前是否正在播放。
  final bool isPlaying;

  /// 当前歌曲元数据；切歌间隙可能为 null。
  final StatsSong? song;

  /// 当前歌曲总时长（毫秒），仅用于原始事件记录。
  final int? durationMs;
}

/// 参与统计的歌曲元数据，对应本项目的 PlayerTrack 关键字段：
/// id(String) / title / artist / album / coverUrl。
class StatsSong {
  const StatsSong({
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;

  /// 写入 songs 表的行（飞牛 SongEntity.toMap 的精简版）。
  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'coverUrl': coverUrl,
      };

  /// 从 songs 表行还原。
  factory StatsSong.fromMap(Map<String, Object?> map) => StatsSong(
        id: map['id'] as String? ?? '',
        title: map['title'] as String? ?? '',
        artist: map['artist'] as String? ?? '',
        album: map['album'] as String? ?? '',
        coverUrl: map['coverUrl'] as String?,
      );

  /// 从本项目 PlayerTrack 映射（避免统计模块直接依赖播放器模块）。
  static StatsSong fromTrack({
    required String id,
    required String title,
    String artist = '',
    String album = '',
    String? coverUrl,
  }) =>
      StatsSong(
        id: id,
        title: title,
        artist: artist,
        album: album,
        coverUrl: coverUrl,
      );
}

/// 某一天的收听汇总（对应飞牛 DayListeningStat）。
class DayListeningStat {
  const DayListeningStat({
    required this.dayKey,
    required this.listenMs,
    required this.playCount,
  });

  /// 形如 yyyy-MM-dd 的日期键。
  final String dayKey;
  final int listenMs;
  final int playCount;

  factory DayListeningStat.fromMap(Map<String, Object?> map) =>
      DayListeningStat(
        dayKey: map['dayKey'] as String? ?? '',
        listenMs: (map['listenMs'] as num?)?.toInt() ?? 0,
        playCount: (map['playCount'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toMap() => {
        'dayKey': dayKey,
        'listenMs': listenMs,
        'playCount': playCount,
      };
}

/// 单曲收听汇总（对应飞牛 SongListeningStat）。
class SongListeningStat {
  const SongListeningStat({
    required this.songId,
    required this.listenMs,
    required this.playCount,
    required this.lastPlayedMs,
  });

  final String songId;
  final int listenMs;
  final int playCount;
  final int lastPlayedMs;

  factory SongListeningStat.fromMap(Map<String, Object?> map) =>
      SongListeningStat(
        songId: map['songId'] as String? ?? '',
        listenMs: (map['listenMs'] as num?)?.toInt() ?? 0,
        playCount: (map['playCount'] as num?)?.toInt() ?? 0,
        lastPlayedMs: (map['lastPlayedMs'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toMap() => {
        'songId': songId,
        'listenMs': listenMs,
        'playCount': playCount,
        'lastPlayedMs': lastPlayedMs,
      };
}

/// 专辑播放汇总（对应飞牛 AlbumPlaybackStat）。
class AlbumPlaybackStat {
  const AlbumPlaybackStat({
    required this.albumName,
    required this.playCount,
    required this.lastPlayedMs,
  });

  final String albumName;
  final int playCount;
  final int lastPlayedMs;

  factory AlbumPlaybackStat.fromMap(Map<String, Object?> map) =>
      AlbumPlaybackStat(
        albumName: map['albumName'] as String? ?? '',
        playCount: (map['playCount'] as num?)?.toInt() ?? 0,
        lastPlayedMs: (map['lastPlayedMs'] as num?)?.toInt() ?? 0,
      );
}

/// 歌单播放汇总（对应飞牛 PlaylistPlaybackStat）。
class PlaylistPlaybackStat {
  const PlaylistPlaybackStat({
    required this.playlistId,
    required this.playCount,
    required this.lastPlayedMs,
  });

  final String playlistId;
  final int playCount;
  final int lastPlayedMs;

  factory PlaylistPlaybackStat.fromMap(Map<String, Object?> map) =>
      PlaylistPlaybackStat(
        playlistId: map['playlistId'] as String? ?? '',
        playCount: (map['playCount'] as num?)?.toInt() ?? 0,
        lastPlayedMs: (map['lastPlayedMs'] as num?)?.toInt() ?? 0,
      );
}

/// 总体汇总（对应飞牛 StatsTotals）。
class StatsTotals {
  const StatsTotals({
    required this.listenMs,
    required this.playCount,
  });

  final int listenMs;
  final int playCount;

  static const empty = StatsTotals(listenMs: 0, playCount: 0);
}

/// 原始播放事件（对应飞牛 report_events 表的一行），用于外部导出/分析。
class ListeningEvent {
  const ListeningEvent({
    required this.dayKey,
    required this.hour,
    required this.songId,
    required this.songTitle,
    required this.artistsJson,
    required this.albumJson,
    required this.coverId,
    required this.durationMs,
    required this.playMs,
    required this.completed,
    required this.sessionStartMs,
    required this.sessionEndMs,
  });

  final String dayKey;
  final int hour;
  final String songId;
  final String songTitle;
  final String artistsJson;
  final String albumJson;
  final String coverId;
  final int durationMs;
  final int playMs;
  final int completed;
  final int sessionStartMs;
  final int sessionEndMs;

  Map<String, Object?> toMap() => {
        'dayKey': dayKey,
        'hour': hour,
        'songId': songId,
        'songTitle': songTitle,
        'artistsJson': artistsJson,
        'albumJson': albumJson,
        'coverId': coverId,
        'durationMs': durationMs,
        'playMs': playMs,
        'completed': completed,
        'sessionStartMs': sessionStartMs,
        'sessionEndMs': sessionEndMs,
      };
}

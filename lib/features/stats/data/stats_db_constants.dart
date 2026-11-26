/// 听歌统计数据库常量。
///
/// 独立于主业务库，避免改动项目现有的本地存储结构；表结构按飞牛音乐
/// FeiNiuMusic 的统计 schema 精简而来，完整支持首页摘要与排行榜查询。
class StatsDbConstants {
  const StatsDbConstants._();

  static const String dbName = 'panghu_listening_stats.db';
  static const int dbVersion = 1;

  /// 歌曲元数据（id/title/artist/album/coverUrl），供排行榜展示歌曲名。
  static const String tableSongs = 'songs';

  /// 聚合：每首歌的累计时长、播放次数、最近播放时间。
  static const String tableSongStats = 'song_stats';

  /// 聚合：每天的累计时长、播放次数。
  static const String tableListeningDays = 'listening_days';

  /// 聚合：专辑播放次数。
  static const String tableAlbumStats = 'album_stats';

  /// 聚合：歌单播放次数。
  static const String tablePlaylistStats = 'playlist_stats';

  /// 原始事件：每次「单曲播放 session」一条记录，90 天滚动清理。
  static const String tableReportEvents = 'report_events';
}

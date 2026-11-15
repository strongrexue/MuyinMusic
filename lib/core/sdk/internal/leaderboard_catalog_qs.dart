import '../../models/leaderboard_info.dart';

/// 汽水音乐 drives its charts from the homepage reply, so there is no static
/// directory to cache here: [MusicApi.getLeaderboards] asks `QsSdk.boards()`
/// instead and every other page reaches the detail endpoint by board id.
const List<LeaderboardSummary> qsLeaderboards = <LeaderboardSummary>[];

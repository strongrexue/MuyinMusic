import '../../models/enums.dart';
import '../../models/leaderboard_info.dart';
import '../qishui_sdk.dart';

/// 汽水音乐 only ships a handful of charts; they are stable enough to list.
final List<LeaderboardSummary> qishuiLeaderboards = List.unmodifiable([
  for (final entry in QishuiSdk.chartIds)
    LeaderboardSummary(
      id: '${MusicSource.qishui.code}__${entry.$1}',
      boardId: entry.$1,
      name: entry.$2,
      source: MusicSource.qishui,
      updateFrequency: '每日更新',
    ),
]);

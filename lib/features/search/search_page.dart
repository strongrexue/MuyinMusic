import 'package:flutter/material.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import '../discovery/discovery_content.dart';
import '../discovery/widgets/discovery_source_tabs.dart';
import '../shell/widgets/shell_header.dart';

/// 发现页：顶部平台胶囊 tab + 公共内容（榜单 / 精选歌单）。
/// 在线搜索整体在首页（`/home/search`），这里不持有任何搜索状态。
///
/// 平台胶囊浮在内容之上（与底部 dock 同一种层），列表从它下面开始，
/// 往下滚动时内容从玻璃后面穿过。
class SearchPage extends StatelessWidget {
  const SearchPage({super.key});

  /// 胶囊 56 + 上边距 6 + 与首行内容的间距 8。
  static const double _tabsSlot = prism.kGlassPillBarHeight + 14;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RepaintBoundary(
        child: Column(
          children: [
            // 发现区路由由 AppShell 关闭顶栏占位，页面自绘标题。
            const ShellSectionHeader(title: '发现', compact: true, fontSize: 22),
            Expanded(
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: DiscoveryContent(topPadding: _tabsSlot),
                  ),
                  const Positioned(
                    top: 6,
                    left: 14,
                    right: 14,
                    child: DiscoverySourceTabs(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

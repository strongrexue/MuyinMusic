import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../search/online_search_body.dart';
import '../shell/widgets/shell_header.dart';

/// 首页的在线搜索页：完整持有输入、历史/联想、分类与结果列表。
class HomeSearchPage extends StatelessWidget {
  const HomeSearchPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RepaintBoundary(
        child: Column(
          children: [
            const ShellSectionHeader(title: '搜索', compact: true, fontSize: 22),
            Expanded(
              child: OnlineSearchBody(
                openEntryOnMount: true,
                onClosed: () {
                  if (!context.mounted) return;
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/home');
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

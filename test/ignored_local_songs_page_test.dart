import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:panghu_music/core/storage/settings_store.dart';
import 'package:panghu_music/features/songs/ignored_local_songs_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  // 只作 path_provider 的返回值，不实际建目录：页面在列表态不写盘。
  const supportPath = '/tmp/panghu-ignored-page-test';

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (_) async {
          return supportPath;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
  });

  Future<void> pumpPage(
    WidgetTester tester,
    Map<String, Object> initialValues,
  ) async {
    SharedPreferences.setMockInitialValues(initialValues);
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const MaterialApp(home: IgnoredLocalSongsPage()),
      ),
    );
    await tester.pump();
  }

  testWidgets('lists ignored songs with a restore action', (tester) async {
    await pumpPage(tester, {
      'local_music_ignored_paths': ['$supportPath/Artist - Song.mp3'],
    });

    expect(find.text('已忽略的本地音乐'), findsOneWidget);
    expect(find.text('Song'), findsOneWidget);
    expect(find.text('恢复'), findsOneWidget);
  });

  testWidgets('shows stored title and singer for a MediaStore entry', (
    tester,
  ) async {
    const contentPath = 'content://media/external_primary/audio/media/154346';
    await pumpPage(tester, {
      'local_music_ignored_paths': [contentPath],
      'local_music_ignored_records': jsonEncode([
        {
          'path': contentPath,
          'title': '麦恩莉',
          'singer': '方大同',
          'location': '/storage/emulated/0/Music/麦恩莉.mp3',
        },
      ]),
    });

    expect(find.text('麦恩莉'), findsOneWidget);
    expect(
      find.text('方大同 · /storage/emulated/0/Music/麦恩莉.mp3'),
      findsOneWidget,
    );
    // 不再把 content URI 末段的数字 ID 当标题。
    expect(find.text('154346'), findsNothing);
    expect(find.text('恢复'), findsOneWidget);
  });

  testWidgets('shows an empty state when nothing is ignored', (tester) async {
    await pumpPage(tester, {});

    expect(find.textContaining('没有已忽略的本地音乐'), findsOneWidget);
  });
}

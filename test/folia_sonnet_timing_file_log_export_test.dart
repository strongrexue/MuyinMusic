// File/export half of the sonnet-timing file journal: AppLogger.write
// with scope 'sonnet-timing' reaches panghu.log and exportFile() while
// the 商籁时序诊断 category is enabled, and reaches neither while it
// is off. The widget half (the stage actually calling write with this
// scope) is covered by folia_sonnet_timing_file_log_test.dart.
//
// Plain tests only, on purpose — this file must never contain a widget
// test. See the note in the widget test file: a file-write chain link
// queued during pumping never drains in FakeAsync, and the chain is
// process-global, so it would hang a flush here too.
//
// NOTE: temporary diagnostic coverage; goes away with the flag.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:panghu_music/core/services/app_logger.dart';
import 'package:panghu_music/core/services/log_category.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('panghu-sonnet-log-test-');
    messenger.setMockMethodCallHandler(paths, (_) async => temp.path);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppLogger.configureRecording(await SharedPreferences.getInstance());
    await AppLogger.clear();
  });

  tearDownAll(() async {
    await AppLogger.setRecordingCategories({});
    await AppLogger.flush();
    messenger.setMockMethodCallHandler(paths, null);
    await temp.delete(recursive: true);
  });

  test(
    'with 商籁时序诊断 enabled, scope lines reach file and export',
    () async {
      await AppLogger.setRecordingCategories({AppLogCategory.sonnetTiming});
      await AppLogger.write(
        'sonnet-timing',
        'lyrics songId=export-on lines=2 withWordTiming=2',
      );
      await AppLogger.write(
        'sonnet-timing',
        'line 0 1000-5000 words=10 '
        'starts=[1000,1100,1200,1300,1400,1500,1600,1700,1800,1900]',
      );
      await AppLogger.write('sonnet-timing', 'raw=2500 now=2500 playing=false');
      await AppLogger.flush();

      final logText =
          await File('${temp.path}/logs/panghu.log').readAsString();
      expect(logText, contains('[sonnet-timing] lyrics songId=export-on'));
      expect(
        logText,
        contains(
          'starts=[1000,1100,1200,1300,1400,1500,1600,1700,1800,1900]',
        ),
      );
      expect(logText, contains('[sonnet-timing] raw=2500 now=2500'));

      final exported =
          await File(await AppLogger.exportFile()).readAsString();
      expect(exported, contains('[sonnet-timing] lyrics songId=export-on'));
      expect(exported, contains('[sonnet-timing] raw=2500 now=2500'));
    },
  );

  test(
    'with 商籁时序诊断 off, scope lines reach neither file nor export',
    () async {
      await AppLogger.setRecordingCategories({AppLogCategory.playback});
      await AppLogger.write('sonnet-timing', 'lyrics songId=export-off lines=2');
      await AppLogger.flush();

      final logText =
          await File('${temp.path}/logs/panghu.log').readAsString();
      expect(logText, isNot(contains('sonnet-timing')));
      final exported =
          await File(await AppLogger.exportFile()).readAsString();
      expect(exported, isNot(contains('sonnet-timing')));
      expect(
        AppLogger.recentMemoryLines.join('\n'),
        isNot(contains('sonnet-timing')),
      );
    },
  );
}

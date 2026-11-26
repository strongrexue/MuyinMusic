import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:audio_service/audio_service.dart';

void main() {
  group('SharedArtworkLoader', () {
    test('concurrent loads for the same key share one in-flight load',
        () async {
      final loader = SharedArtworkLoader();
      var calls = 0;
      final gate = Completer<String?>();

      Future<String?> load() {
        calls++;
        return gate.future;
      }

      final first = loader.load('https://example.com/a.jpg', load);
      final second = loader.load('https://example.com/a.jpg', load);
      expect(calls, 1);

      gate.complete('/cache/a.jpg');
      expect(await first, '/cache/a.jpg');
      expect(await second, '/cache/a.jpg');
    });

    test('different keys load independently', () async {
      final loader = SharedArtworkLoader();
      var calls = 0;

      Future<String?> load() async {
        calls++;
        return '/cache/$calls.jpg';
      }

      expect(await loader.load('a', load), '/cache/1.jpg');
      expect(await loader.load('b', load), '/cache/2.jpg');
      expect(calls, 2);
    });

    test('a completed load is forgotten, so a later load runs again',
        () async {
      final loader = SharedArtworkLoader();
      var calls = 0;

      Future<String?> load() async {
        calls++;
        return '/cache/$calls.jpg';
      }

      expect(await loader.load('a', load), '/cache/1.jpg');
      expect(await loader.load('a', load), '/cache/2.jpg');
      expect(calls, 2);
    });

    test('a failed load does not blacklist the key', () async {
      final loader = SharedArtworkLoader();
      var calls = 0;

      Future<String?> load() async {
        calls++;
        return calls == 1 ? null : '/cache/retry.jpg';
      }

      expect(await loader.load('a', load), isNull);
      expect(await loader.load('a', load), '/cache/retry.jpg');
      expect(calls, 2);
    });

    test('an erroring load does not blacklist the key', () async {
      final loader = SharedArtworkLoader();
      var calls = 0;

      Future<String?> load() {
        calls++;
        if (calls == 1) {
          return Future<String?>.error(StateError('boom'));
        }
        return Future<String?>.value('/cache/retry.jpg');
      }

      await expectLater(loader.load('a', load), throwsStateError);
      expect(await loader.load('a', load), '/cache/retry.jpg');
      expect(calls, 2);
    });
  });
}

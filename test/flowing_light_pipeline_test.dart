import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:muyin_music/features/player/flowing_light_pipeline.dart';
import 'package:muyin_music/features/player/flowing_light_spec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Regression test for the soft horizontal divider that showed just
  // under the portrait top bar: an offset copy's square edge crosses
  // the buffer and the visible field switches wholesale between two
  // copies' tones. The homogenising wash over the copies plus the
  // wider blur (see composeFlowingLightFrame) keep the vertical warmth
  // profile of a composed frame smooth — no single row-to-row jump.
  testWidgets('composed frame has no hard horizontal warmth step', (
    tester,
  ) async {
    final result = await tester.runAsync(() async {
      // Artwork with a strong horizontal colour-field edge: warm top
      // half over a cool bottom half.
      final artwork = await _twoToneArtwork(96);
      final spec = FlowingLightSpec.forViewport(
        physicalWidth: 900,
        physicalHeight: 1800,
        devicePixelRatio: 1,
        dark: false,
      );
      final frame = composeFlowingLightFrame(
        artwork: artwork,
        baseColor: const Color(0xFFC9CFD8),
        spec: spec,
        // Mid-animation: all three copies are rotated, as they are
        // when the divider shows on device.
        clock: const Duration(seconds: 23),
        history: null,
      );
      final bytes = await frame.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final profile = _rowWarmthProfile(
        bytes!.buffer.asUint8List(),
        frame.width,
        left: spec.cropLeft.round(),
        top: spec.cropTop.round(),
        width: spec.visibleWidth.round(),
        height: spec.visibleHeight.round(),
      );
      artwork.dispose();
      frame.dispose();
      return profile;
    });
    final profile = result!;
    var maxStep = 0.0;
    for (var i = 1; i < profile.length; i++) {
      final step = (profile[i] - profile[i - 1]).abs();
      if (step > maxStep) maxStep = step;
    }
    // Before the fix this scene measured 2.62; the wash + wider blur
    // bring it to ~0.69. The threshold sits between the two.
    expect(maxStep, lessThan(1.5));
  });
}

/// A square image whose top half is warm and bottom half is cool.
Future<ui.Image> _twoToneArtwork(int size) {
  final bytes = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    final warm = y < size ~/ 2;
    for (var x = 0; x < size; x++) {
      final offset = (y * size + x) * 4;
      bytes[offset] = warm ? 232 : 96;
      bytes[offset + 1] = warm ? 168 : 128;
      bytes[offset + 2] = warm ? 92 : 190;
      bytes[offset + 3] = 255;
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes,
    size,
    size,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// Mean (R − B) per row over the given crop of an RGBA buffer.
List<double> _rowWarmthProfile(
  Uint8List bytes,
  int stride, {
  required int left,
  required int top,
  required int width,
  required int height,
}) {
  return [
    for (var row = 0; row < height; row++)
      () {
        var warmth = 0.0;
        for (var x = 0; x < width; x++) {
          final offset = ((top + row) * stride + left + x) * 4;
          warmth += bytes[offset] - bytes[offset + 2];
        }
        return warmth / width;
      }(),
  ];
}

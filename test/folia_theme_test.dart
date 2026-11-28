import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panghu_music/features/folia/folia_theme.dart';

Uint8List _solidRgba(int r, int g, int b, {int count = 16}) {
  final bytes = Uint8List(count * 4);
  for (var i = 0; i < count; i++) {
    bytes[i * 4] = r;
    bytes[i * 4 + 1] = g;
    bytes[i * 4 + 2] = b;
    bytes[i * 4 + 3] = 255;
  }
  return bytes;
}

void main() {
  group('extractFoliaTheme', () {
    test('empty pixels give the fallback theme', () {
      expect(extractFoliaTheme(Uint8List(0)), FoliaTheme.fallback);
      expect(
        extractFoliaTheme(Uint8List.fromList([10, 20, 30, 0])),
        FoliaTheme.fallback,
      );
    });

    test('a red cover gives a dark background and a red accent', () {
      final theme = extractFoliaTheme(_solidRgba(200, 30, 30));
      expect(
        HSLColor.fromColor(theme.background).lightness,
        lessThanOrEqualTo(0.22),
      );
      final accentHsl = HSLColor.fromColor(theme.accent);
      expect(accentHsl.saturation, greaterThanOrEqualTo(0.55));
      expect(accentHsl.hue, lessThan(10));
      expect(theme.primary, Colors.white);
    });

    test('a black cover keeps a dark background and the amber accent', () {
      final theme = extractFoliaTheme(_solidRgba(0, 0, 0));
      expect(theme.background, const Color(0xFF000000));
      expect(theme.accent, const Color(0xFFFFB547));
    });

    test('a white cover darkens the background instead of staying white', () {
      final theme = extractFoliaTheme(_solidRgba(255, 255, 255));
      expect(
        HSLColor.fromColor(theme.background).lightness,
        closeTo(0.22, 0.01),
      );
      expect(theme.accent, const Color(0xFFFFB547));
    });
  });

  group('FoliaTheme.fromArtwork', () {
    test('maps base to background and keeps a saturated accent', () {
      final theme = FoliaTheme.fromArtwork(
        base: const Color(0xFF803030),
        accents: const [Colors.blue, Colors.green],
      );
      expect(
        HSLColor.fromColor(theme.background).lightness,
        lessThanOrEqualTo(0.22),
      );
      expect(theme.accent, Colors.blue);
      expect(theme.primary, Colors.white);
    });

    test('falls back to amber when no accent is saturated', () {
      final theme = FoliaTheme.fromArtwork(
        base: const Color(0xFF808080),
        accents: const [Color(0xFF808080)],
      );
      expect(theme.accent, const Color(0xFFFFB547));
    });
  });

  group('FoliaThemeService', () {
    test('derives from RGBA and from artwork colors', () {
      const service = FoliaThemeService();
      expect(
        service.deriveFromRgba(Uint8List(0)),
        FoliaTheme.fallback,
      );
      expect(
        service
            .deriveFromArtwork(base: Colors.red, accents: const [Colors.red])
            .accent,
        Colors.red,
      );
    });
  });
}

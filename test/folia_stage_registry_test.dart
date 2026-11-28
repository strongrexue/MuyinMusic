import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panghu_music/features/folia/folia_stage_registry.dart';

FoliaStageStyle _style(String id, String label) => FoliaStageStyle(
  id: id,
  label: label,
  builder: (context, stage) => const SizedBox(),
);

FoliaStageBackground _background(String id, String label) =>
    FoliaStageBackground(
      id: id,
      label: label,
      builder: (context, stage) => const SizedBox(),
    );

void main() {
  group('FoliaStageRegistry styles', () {
    test('starts empty and lists styles in registration order', () {
      final registry = FoliaStageRegistry();
      expect(registry.styles, isEmpty);
      expect(registry.byId('none'), isNull);

      registry.register(_style('director', '导演'));
      registry.register(_style('rings', '年轮'));
      expect(
        registry.styles.map((style) => style.id),
        ['director', 'rings'],
      );
      expect(registry.byId('rings')?.label, '年轮');
    });

    test('a duplicate style id throws', () {
      final registry = FoliaStageRegistry();
      registry.register(_style('director', '导演'));
      expect(
        () => registry.register(_style('director', '导演2')),
        throwsStateError,
      );
    });

    test('unregister removes the style', () {
      final registry = FoliaStageRegistry();
      registry.register(_style('director', '导演'));
      registry.unregister('director');
      expect(registry.styles, isEmpty);
      expect(registry.byId('director'), isNull);
    });
  });

  group('FoliaStageRegistry backgrounds (reserved slot)', () {
    test('starts empty; backgrounds register like styles', () {
      final registry = FoliaStageRegistry();
      expect(registry.backgrounds, isEmpty);

      registry.registerBackground(_background('monet', '莫奈'));
      expect(registry.backgroundById('monet')?.label, '莫奈');
      expect(
        () => registry.registerBackground(_background('monet', '莫奈2')),
        throwsStateError,
      );
      registry.unregisterBackground('monet');
      expect(registry.backgrounds, isEmpty);
    });
  });
}

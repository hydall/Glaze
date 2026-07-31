import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/services/featured_presets.dart';
import 'package:glaze_flutter/features/presets/preset_image.dart';

void main() {
  group('isFeaturedPreset', () {
    test('recognises every bundled featured preset', () {
      expect(featuredPresets, isNotEmpty);
      for (final f in featuredPresets) {
        expect(isFeaturedPreset(f.id), isTrue, reason: f.id);
      }
    });

    test('is false for user presets and for null', () {
      expect(isFeaturedPreset('some_generated_id'), isFalse);
      // A clone of a featured preset gets a fresh id, so it stays editable.
      expect(isFeaturedPreset('${featuredPresets.first.id}_copy'), isFalse);
      expect(isFeaturedPreset(null), isFalse);
    });
  });

  group('presetCoverImage', () {
    test('a plain preset without an image has no cover', () {
      expect(presetCoverImage(const Preset(id: 'p1', name: 'P')), isNull);
    });

    test('a featured preset resolves its bundled cover from its id', () {
      final featured = featuredPresets.first;
      final cover = presetCoverImage(Preset(id: featured.id, name: 'P'));
      expect(cover, isA<AssetImage>());
      expect((cover! as AssetImage).assetName, featured.imageAsset);
    });

    test('an asset path stored on the preset wins over the id lookup', () {
      const asset = 'assets/presets/renri.jpg';
      final cover = presetCoverImage(
        const Preset(id: 'clone', name: 'P', imagePath: asset),
      );
      expect(cover, isA<AssetImage>());
      expect((cover! as AssetImage).assetName, asset);
    });

    test('a stored file path resolves to a file image', () {
      final cover = presetCoverImage(
        const Preset(
          id: 'p1',
          name: 'P',
          imagePath: '/tmp/glaze/avatars/preset_p1.png',
        ),
      );
      expect(cover, isA<FileImage>());
    });

    test('a user image overrides a featured preset cover', () {
      final featured = featuredPresets.first;
      final cover = presetCoverImage(
        Preset(
          id: featured.id,
          name: 'P',
          imagePath: '/tmp/glaze/avatars/preset_custom.png',
        ),
      );
      expect(cover, isA<FileImage>());
    });
  });

  test('presetImageStorageId namespaces preset covers', () {
    expect(presetImageStorageId('abc'), 'preset_abc');
  });
}

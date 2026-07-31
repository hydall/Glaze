import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/services/featured_presets.dart';
import 'package:glaze_flutter/features/presets/preset_image.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('glaze_preset_cover');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String writeCover(String name) {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name')
      ..writeAsBytesSync([0x89, 0x50, 0x4E, 0x47]);
    return file.path;
  }

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

    test('a stored cover that exists on disk resolves to a file image', () {
      final path = writeCover('preset_p1_1.png');
      final cover = presetCoverImage(
        Preset(id: 'p1', name: 'P', imagePath: path),
      );
      expect(cover, isA<FileImage>());
    });

    test('a user cover overrides a featured preset cover', () {
      final featured = featuredPresets.first;
      final path = writeCover('preset_custom_1.png');
      final cover = presetCoverImage(
        Preset(id: featured.id, name: 'P', imagePath: path),
      );
      expect(cover, isA<FileImage>());
    });

    test('a cover whose file is missing reports no cover', () {
      // Happens between pulling a preset from the cloud and its image binary
      // arriving — the card must fall back instead of rendering a broken image.
      final cover = presetCoverImage(
        Preset(
          id: 'p1',
          name: 'P',
          imagePath: '${tempDir.path}/never_written.png',
        ),
      );
      expect(cover, isNull);
    });

    test('a missing user cover on a featured preset falls back to the art', () {
      final featured = featuredPresets.first;
      final cover = presetCoverImage(
        Preset(
          id: featured.id,
          name: 'P',
          imagePath: '${tempDir.path}/never_written.png',
        ),
      );
      expect(cover, isA<AssetImage>());
      expect((cover! as AssetImage).assetName, featured.imageAsset);
    });
  });

  group('cover path helpers', () {
    test('storage ids are namespaced and versioned', () {
      expect(presetImageStorageId('abc', 42), 'preset_abc_42');
      // A new pick must produce a new path, otherwise the preset JSON is
      // unchanged and cloud sync never notices the replacement.
      expect(
        presetImageStorageId('abc', 42),
        isNot(presetImageStorageId('abc', 43)),
      );
    });

    test('stored paths are relative to the data dir', () {
      expect(
        presetImageRelativePath('preset_abc_42', 'png'),
        'avatars/preset_abc_42.png',
      );
    });

    test('the storage id round-trips out of a stored path', () {
      expect(
        presetImageStorageIdOf('avatars/preset_abc_42.png'),
        'preset_abc_42',
      );
      expect(
        presetImageStorageIdOf(r'C:\Glaze\avatars\preset_abc_42.png'),
        'preset_abc_42',
      );
    });

    test('bundled assets and empty paths own no file', () {
      expect(presetImageStorageIdOf('assets/presets/renri.jpg'), isNull);
      expect(presetImageStorageIdOf(null), isNull);
      expect(presetImageStorageIdOf(''), isNull);
    });

    test('asset paths are recognised', () {
      expect(isPresetAssetImage('assets/presets/renri.jpg'), isTrue);
      expect(isPresetAssetImage('avatars/preset_abc_42.png'), isFalse);
      expect(isPresetAssetImage(null), isFalse);
    });
  });
}

import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/gallery_entry.dart';
import 'package:glaze_flutter/core/navigation/router.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/character_gallery/gallery_provider.dart';

import 'helpers/pump_glaze_app.dart';

/// Renders the character sheet's Images tab, empty and populated, to PNG.
///
/// Run with:
///   GLAZE_GOLDENS=1 flutter test --update-goldens test/character_gallery_golden_test.dart
Future<ByteData> _font(String path) async =>
    ByteData.view(Uint8List.fromList(File(path).readAsBytesSync()).buffer);

Future<void> _loadFonts() async {
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      _font(
        '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}'
        '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    );
  await icons.load();
  final loader = FontLoader('Inter')
    ..addFont(
      File('assets/fonts/InterVariable.ttf').readAsBytes().then(
        (bytes) => ByteData.view(Uint8List.fromList(bytes).buffer),
      ),
    );
  await loader.load();
}

final bool _runGoldens = Platform.environment['GLAZE_GOLDENS'] == '1';

List<GalleryEntry> _makeImages(int count) {
  final dir = Directory.systemTemp.createTempSync('glaze_gallery_golden');
  final colors = [
    [180, 120, 60],
    [70, 90, 160],
    [150, 60, 90],
    [60, 140, 110],
    [200, 170, 80],
    [110, 80, 170],
    [90, 90, 90],
  ];
  return [
    for (var i = 0; i < count; i++)
      () {
        final c = colors[i % colors.length];
        final im = img.Image(width: 64, height: 64);
        img.fill(im, color: img.ColorRgb8(c[0], c[1], c[2]));
        final f = File('${dir.path}/$i.png')
          ..writeAsBytesSync(img.encodePng(im));
        return GalleryEntry(
          id: 'g$i',
          characterId: 'c-juno',
          imagePath: f.path,
          label: i == 1 ? 'Casual outfit' : null,
        );
      }(),
  ];
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await _loadFonts();
  });

  Future<void> pumpImagesTab(
    WidgetTester tester,
    List<GalleryEntry> entries,
    String golden,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final router = buildRouter(
      GlobalKey<NavigatorState>(),
      isForceMobile: () => true,
    );
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        routerProvider.overrideWithValue(router),
        galleryProvider.overrideWith((ref, id) async => entries),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await container.read(characterRepoProvider).put(
      const Character(id: 'c-juno', name: 'Juno', creator: 'VVADark'),
    );
    await tester.binding.setSurfaceSize(const Size(412, 892));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpGlazeApp(tester, container: container);
    router.go('/character/c-juno');
    for (var i = 0; i < 4; i++) {
      await pumpNavigation(tester);
    }

    // The tab bar scrolls horizontally; bring the last tab on screen first.
    await tester.drag(
      find.text('section_prompt_blocks'.tr()).last,
      const Offset(-300, 0),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('section_images'.tr()).last);
    await pumpNavigation(tester);
    await tester.runAsync(() async {
      for (final e in entries) {
        await precacheImage(
          FileImage(File(e.imagePath)),
          tester.element(find.byType(MaterialApp)),
        );
      }
    });
    await tester.pump(const Duration(milliseconds: 600));
    await tester.drag(find.text('Juno').last, const Offset(0, -350));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$golden'),
    );
  }

  testWidgets('Images tab, empty', (tester) async {
    await pumpImagesTab(tester, const [], 'character_gallery_empty.png');
  }, skip: !_runGoldens);

  testWidgets('Images tab, populated', (tester) async {
    await pumpImagesTab(tester, _makeImages(7), 'character_gallery_grid.png');
  }, skip: !_runGoldens);
}

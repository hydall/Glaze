import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_header.dart';
import 'package:glaze_flutter/shared/theme/app_colors.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/widgets/glass_surface.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Visual review shots for the Appearance corner settings.
///
/// Run with:
///   GLAZE_GOLDENS=1 flutter test --update-goldens \
///     test/corner_customization_golden_test.dart
final bool _runGoldens = Platform.environment['GLAZE_GOLDENS'] == '1';

const _preset = ThemePreset(id: 'default', name: 'Default');
const _character = Character(id: 'c1', name: 'Seraphina', color: '#8E7CC3');

Future<ByteData> _font(String path) async =>
    ByteData.view(Uint8List.fromList(File(path).readAsBytesSync()).buffer);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await (FontLoader('MaterialIcons')..addFont(
          _font(
            '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}'
            '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
        ))
        .load();
    await (FontLoader(
      kInterFontFamily,
    )..addFont(_font('assets/fonts/InterVariable.ttf'))).load();
  });

  testWidgets('Appearance corner sliders', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(420 * 2, 360 * 2);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(_preset, fontFamily: kInterFontFamily),
          home: Builder(
            builder: (context) => Scaffold(
              backgroundColor: context.cs.surface,
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: MenuGroup(
                  header: 'Внешний вид',
                  items: [
                    MenuRangeItem(
                      label: 'Закругление углов',
                      description:
                          'Закругление кнопок и окон. 0% делает их квадратными.',
                      value: 100,
                      min: 0,
                      max: 200,
                      divisions: 40,
                      decimalPlaces: 0,
                      unit: '%',
                      onChanged: (_) {},
                    ),
                    MenuRangeItem(
                      label: 'Закругление аватарок',
                      description:
                          'Закругление аватарок в чате и списке чатов. 0% делает их квадратными.',
                      value: 100,
                      min: 0,
                      max: 100,
                      divisions: 20,
                      decimalPlaces: 0,
                      unit: '%',
                      onChanged: (_) {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/corner_settings_appearance.png'),
    );
  }, skip: !_runGoldens);

  testWidgets('Rounded versus square buttons, windows and avatars', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(760 * 2, 330 * 2);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(_preset, fontFamily: kInterFontFamily),
          home: Builder(
            builder: (context) => Scaffold(
              backgroundColor: context.cs.surface,
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _scalePreview(context, 1.0)),
                    const SizedBox(width: 16),
                    Expanded(child: _scalePreview(context, 0.0)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/corner_customization_compare.png'),
    );
  }, skip: !_runGoldens);
}

Widget _scalePreview(BuildContext context, double scale) {
  return Theme(
    data: AppTheme.dark(
      _preset,
      fontFamily: kInterFontFamily,
      cornerScale: scale,
      avatarRoundness: scale,
    ),
    child: Builder(
      builder: (context) => Material(
        color: context.cs.surface,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                scale == 1.0 ? '100% — как сейчас' : '0% — квадратные',
                style: TextStyle(
                  color: context.cs.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              GlassSurface(
                borderRadius: BorderRadius.circular(20),
                tint: context.cs.primary.withValues(alpha: 0.18),
                border: Border.all(
                  color: context.cs.primary.withValues(alpha: 0.22),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.auto_awesome,
                        size: 16,
                        color: context.cs.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Кнопка',
                        style: TextStyle(
                          color: context.cs.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              GlassSurface(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: context.cs.outlineVariant),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Окно',
                        style: TextStyle(
                          color: context.cs.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Карточки, диалоги и шторки',
                        style: TextStyle(
                          color: context.cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              ChatHeader(character: _character, sessionName: 'Сессия #3'),
            ],
          ),
        ),
      ),
    ),
  );
}
